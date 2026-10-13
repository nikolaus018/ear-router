//! EAR Routing (Essen auf Rädern Routing) — delivery route planner.
//!
//! Serves a single self-contained `index.html` at `/` (inlined CSS +
//! MapLibre GL JS, ASBÖ-branded, PWA-ready — no JS/CSS build step at
//! request time; the Tailwind utilities are compiled ahead of time and
//! pasted into the file's own `<style>` block, so there is nothing to
//! build here and no CSS compiler shipped to the phone — see that block's
//! comment for how to regenerate it; the
//! map draws either OpenFreeMap's vector tiles or Stadt Wien's aerial
//! imagery, which is why `CONTENT_SECURITY_POLICY` allows both hosts) and a
//! matching `/sw.js` service worker for offline app-shell
//! caching, both read straight off disk on every request (see
//! `assets_dir`/`read_static` below) rather than compiled into the
//! binary, so editing either file takes effect immediately. The JSON API is
//! otherwise the main interface. Axum backend, SQLite storage. Geocoding
//! and routing both run against real, actively-maintained open services
//! instead of a hand-rolled local dataset/algorithm that can only ever be a
//! stale, incomplete snapshot:
//!   - Geocoding tries Vienna's own official address register first
//!     (data.wien.gv.at, see `wien_ogd_geocode`) and falls back to
//!     Nominatim (nominatim.openstreetmap.org), OpenStreetMap's official
//!     geocoder — both live databases, not a one-time Vienna export. An
//!     address neither can find falls through to manual pin-drop handling
//!     (`lat`/`lon` supplied directly in the request); that verdict is
//!     cached for a few hours (`geocode_miss`) so a re-submitted list
//!     doesn't pay for the same dead address again.
//!   - Route distances/durations and stop-order optimization both come
//!     from OSRM (router.project-osrm.org) — the standard open-source
//!     routing engine (contraction hierarchies), used in production by a
//!     lot of real routing software. Its `/trip` endpoint solves the
//!     actual multi-stop ordering problem; there's no reason to hand-roll
//!     a weaker 2-opt/or-opt solver when a well-tested one is a request
//!     away. See `osrm_route_through`/`osrm_trip` below.
//!
//! Both Nominatim and OSRM's public servers are free to use but shared —
//! Nominatim's usage policy caps at ~1 request/second, enforced here via
//! `nominatim_throttle` (see `AppState::nominatim_last`) rather than
//! trusting callers not to hammer it, and OSRM's demo server caps a single
//! `/trip` call at `OSRM_MAX_TRIP_COORDS` waypoints.
//!
//! Environment:
//!   - `EAR_PORT` — listen port (default 8000; `PORT` is read when it is
//!     not set, which is what a hosting panel provides).
//!   - `EAR_ADMIN_PASSWORD` — the password of the `admin` account. Applied
//!     on start; unset, an existing admin keeps the one it has.
//!   - `EAR_DATA_DIR` — where `rerouter.db` is kept. Defaults to the
//!     binary's own directory.
//!   - `EAR_ASSETS_DIR` — where index.html/sw.js/icon.png are read from.
//!     Defaults to the directory this was built in, then to the binary's
//!     own directory (see `assets_dir`).
//!   - `EAR_TRUST_PROXY` — set to 1/true/yes only when a trusted reverse
//!     proxy sits in front, so rate limiting uses `X-Forwarded-For`
//!     instead of the proxy's own address (see `client_ip`).
//!   - `EAR_OSRM_URL`, `EAR_NOMINATIM_URL`, `EAR_WIEN_OGD_URL` — point the
//!     three upstreams at self-hosted instances instead of the shared
//!     public ones (see `Upstreams`).
//!
//! `GET /api/health` reports process and database health for a monitor;
//! it sits outside the rate limiter so a check can't consume the driver's
//! budget.

use std::collections::{HashMap, HashSet};
use std::marker::PhantomData;
use std::net::{IpAddr, SocketAddr};
use std::ops::{Deref, DerefMut};
use std::path::{Path as FsPath, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use axum::{
    extract::{ConnectInfo, DefaultBodyLimit, Path as AxPath, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, patch, post, put},
    Json, Router,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use text::{normalize_strasse_text, simplify_housenumber};
use tokio::sync::{Mutex as AsyncMutex, Semaphore};
use tokio::task::JoinSet;
use tower_http::{catch_panic::CatchPanicLayer, timeout::TimeoutLayer, trace::TraceLayer};

/// How precisely a geocoded point is known to be located, coarsest last.
/// Derived from how much of Nominatim's structured address breakdown came
/// back with the top hit — see `geocode_address`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Precision {
    /// Nominatim matched down to a house number.
    Exact,
    /// Matched a street, but not that exact house number.
    Street,
    /// Only a coarser area (suburb/city/district) matched.
    District,
}

impl Precision {
    fn as_str(self) -> &'static str {
        match self {
            Precision::Exact => "exact",
            Precision::Street => "street",
            Precision::District => "district",
        }
    }

    /// What a stop/route-update response tags `location_precision` with —
    /// `None` for an exact match (the common case, and what a legacy row
    /// with no approximation at all also reads back as), `Some(..)` only
    /// when the location is an admitted guess the driver should double
    /// check. The same `(precision != Precision::Exact).then(...)` was
    /// written out three separate times across `add_stop`, `update_stop`,
    /// and the bulk JSON import before this existed.
    fn tag(self) -> Option<&'static str> {
        (self != Precision::Exact).then(|| self.as_str())
    }
}

// ---------------------------------------------------------------------
// Austrian/Viennese street-address text normalization, applied before a
// query is sent to Nominatim.
// ---------------------------------------------------------------------
mod text {
    use once_cell::sync::Lazy;
    use regex::Regex;

    static WHITESPACE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
    // Rust's `regex` crate has no lookahead, so "str.(?=\s|$|\d)" from the
    // original Python version is rewritten to capture-and-reinsert the
    // trailing context instead of asserting it.
    //
    // The "s" is captured in both and put back as it was written: replaced
    // with a fixed "straße", a street word standing on its own lost its
    // capital -- "Mariahilfer Str. 5" came out as "Mariahilfer straße 5".
    static STR_ABBR_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(s)tr\.(\s|$|\d)").unwrap());
    static STRASSE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(s)trasse\b").unwrap());
    // Viennese addresses are routinely written as "{street} {housenumber
    // or range}/{Stiege}/{Tür or Stock}[...]" — e.g. "Gentzgasse
    // 129/1/2/23" or "Dr.-Heinrich-Maier-Straße 28-34/Haus 2/12". Neither
    // geocoder indexes that per-apartment detail at all, so sending it
    // through verbatim just fails to match — this strips everything after
    // the housenumber down to the "{street} {number}" form they do index.
    // The housenumber/range itself ("28-34") is kept whole, not collapsed
    // to its first number: Vienna's own address register (unlike a plain
    // OSM assumption) indexes a combined range as its *own* address
    // distinct from the standalone numbers inside it (e.g. "Gutzkowplatz
    // 2-5" is a real, separate entry from "Gutzkowplatz 2" or "...5") — so
    // dropping the range could silently match the wrong building instead
    // of just failing to match at all.
    static HOUSENUMBER_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^(?P<street>.+?)\s+(?P<num>\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?)(?:[/\s(].*)?$").unwrap()
    });
    // Same shape as HOUSENUMBER_RE, but requires (and captures) whatever
    // follows the housenumber — the sub-address. See
    // `housenumber_with_sub`. Separated from the housenumber by a slash OR
    // by whitespace, because both spellings turn up in real lists
    // ("9/Parz.68" and "9 Parz. 68"), and anything past the first slash is
    // ignored rather than rejected, so "129/1/2/23" yields sub = "1".
    static SUB_ADDRESS_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^(?P<street>.+?)\s+(?P<num>\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?)(?:/|\s+)(?P<sub>[^/]+)").unwrap()
    });
    // The tail after "{street} {housenumber}" in an address string the
    // register itself produced — used to read back which sub-address it
    // actually matched. See `sub_address_of`.
    static HOUSENUMBER_TAIL_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^.+?\s+\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?(?P<tail>.*)$").unwrap()
    });

    pub fn normalize_strasse_text(strasse: &str) -> String {
        let s = WHITESPACE_RE.replace_all(strasse.trim(), " ").to_string();
        let s = STR_ABBR_RE.replace_all(&s, "${1}traße$2").to_string();
        STRASSE_RE.replace_all(&s, "${1}traße").to_string()
    }

    /// Best-effort "{street} {housenumber}" simplification for geocoding —
    /// falls back to the input unchanged if it doesn't look like
    /// "street + number" at all (e.g. a place name with no housenumber).
    pub fn simplify_housenumber(strasse: &str) -> String {
        match HOUSENUMBER_RE.captures(strasse) {
            Some(caps) => format!("{} {}", &caps["street"], &caps["num"]),
            None => strasse.to_string(),
        }
    }

    /// The address's *sub-address* — what comes after the housenumber:
    /// a Stiege ("129/1"), a Kleingarten-Parzelle ("9/Parz.68"), a Top.
    /// Returns the query form to ask the register with, plus a normalized
    /// key for verifying what came back.
    ///
    /// Vienna's register indexes these as addresses in their own right, at
    /// their own front door:
    ///   - "Gentzgasse 129/1" and "Gentzgasse 129/2" are ~30 m apart on one
    ///     Gemeindebau block.
    ///   - "Großfeldstraße 9 Parz. 68" is a specific plot in a Kleingarten
    ///     colony, ~130 m from the "Großfeldstraße 9" the colony as a whole
    ///     answers to — and asking for the bare housenumber there returns
    ///     an arbitrary neighbouring plot ("Parz. 8"), not the colony
    ///     entrance, so the bare form is actively misleading.
    ///
    /// `simplify_housenumber` throws all of that away — necessarily, since
    /// it exists for Nominatim, which indexes none of it — so the register
    /// is asked with the sub-address still attached first.
    ///
    /// Only the first segment after the housenumber is kept: what follows
    /// is Tür/Stock ("129/1/2/23"), which no register indexes and which
    /// only makes the query fail to match.
    pub fn housenumber_with_sub(strasse: &str) -> Option<(String, String)> {
        let caps = SUB_ADDRESS_RE.captures(strasse)?;
        let sub = caps["sub"].trim();
        let key = sub_address_key(sub);
        // "Hauptstraße 12 " or "Gentzgasse 129/" carry no sub-address, and a
        // key with nothing alphanumeric in it can never verify anything.
        if key.is_empty() {
            return None;
        }
        // Slash-joined regardless of how the driver wrote it: that is the
        // form the register accepts for both a Stiege ("129/1") and a
        // Parzelle ("9/Parz. 68"), whereas a space-joined query drops back
        // to matching the housenumber alone.
        Some((format!("{} {}/{}", &caps["street"], &caps["num"], sub), key))
    }

    /// The form two addresses are compared in when deciding whether they are
    /// the *same address* — used to match a re-pasted list against the stops
    /// already on a route (see `import_entries`), where getting it
    /// wrong means deleting and re-inserting a stop, and losing the tick
    /// saying it was already delivered.
    ///
    /// On top of the "straße" spellings `normalize_strasse_text` handles,
    /// this collapses every run of punctuation and whitespace to one space,
    /// so the same door survives being re-exported by a different system:
    /// "Großfeldstraße 9/Parz.68", "Großfeldstraße 9 Parz. 68" and
    /// "Großfeldstraße 9 / Parz. 68" are one address. Collapsed rather than
    /// deleted, because deleting separators would make "Gentzgasse 129/1"
    /// and "Gentzgasse 12/91" collide.
    ///
    /// And ß, ä, ö, ü are spelled out (`german_fold`), so a list re-exported
    /// by a system that strips umlauts is still the same doors -- and so the
    /// register's own answer is recognised: it is tolerant on input and
    /// canonical on output, answering "Doeblinger Hauptstrasse 1" with
    /// "Döblinger Hauptstraße". The name of a customer is compared in this
    /// form too.
    pub fn address_match_key(strasse: &str) -> String {
        let normalized = german_fold(&normalize_strasse_text(strasse).to_lowercase());
        let mut out = String::with_capacity(normalized.len());
        let mut pending_space = false;
        for c in normalized.chars() {
            if c.is_alphanumeric() {
                if pending_space && !out.is_empty() {
                    out.push(' ');
                }
                pending_space = false;
                out.push(c);
            } else {
                pending_space = true;
            }
        }
        out
    }

    /// ß→ss, ä→ae, ö→oe, ü→ue, on text that is already lower case.
    /// Expanding rather than contracting: that only ever merges the two
    /// spellings of one name, where contracting would have to guess whether
    /// a real "ae" was meant as an umlaut.
    pub fn german_fold(lowercased: &str) -> String {
        let mut out = String::with_capacity(lowercased.len() + 4);
        for c in lowercased.chars() {
            match c {
                'ß' => out.push_str("ss"),
                'ä' => out.push_str("ae"),
                'ö' => out.push_str("oe"),
                'ü' => out.push_str("ue"),
                other => out.push(other),
            }
        }
        out
    }

    /// Whether two street keys differ by exactly one letter -- one missing,
    /// one extra, or one swapped for another. Only for names of eight letters
    /// or more: on a short name one letter is as likely another street as a
    /// typo.
    pub fn is_one_typo_apart(a: &str, b: &str) -> bool {
        let (x, y): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
        if x == y || x.len().min(y.len()) < 8 || x.len().abs_diff(y.len()) > 1 {
            return false;
        }
        let (mut i, mut j, mut edits) = (0, 0, 0);
        while i < x.len() && j < y.len() {
            if x[i] == y[j] {
                i += 1;
                j += 1;
                continue;
            }
            edits += 1;
            if edits > 1 {
                return false;
            }
            match x.len().cmp(&y.len()) {
                std::cmp::Ordering::Greater => i += 1,
                std::cmp::Ordering::Less => j += 1,
                std::cmp::Ordering::Equal => {
                    i += 1;
                    j += 1;
                }
            }
        }
        edits + (x.len() - i) + (y.len() - j) == 1
    }

    // "Haus", "Stiege" and "Stg." say nothing about which door: the register
    // writes a lettered Gemeindebau block as "57 Haus A/1" and a staircase
    // sometimes as "Stg. 2", a printed list writes the same doors as "57/A1"
    // and "/2", and a driver may type either.
    static GENERIC_SUB_WORD_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\b(haus|stiege|stg)\b").unwrap());
    static ANY_SUB_LABEL_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"(?i)\b(haus|stiege|stg|obj|objekt|pav|pavillon|parz|parzelle|gruppe|grp)\b").unwrap()
    });
    // Everything after "{street} {housenumber}" in what the driver typed.
    static SUB_ADDRESS_ALL_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^.+?\s+\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?(?:/|\s+)(?P<tail>.+)$").unwrap()
    });

    /// Compares sub-addresses the way a human would, ignoring the many ways
    /// the same one gets written: the driver types "9/Parz.68", the register
    /// answers "Großfeldstraße 9 Parz. 68", and a Stiege comes back as
    /// "/1". Everything that isn't a letter or a digit is noise here, and
    /// so are case, the umlauts, and the words "Haus", "Stiege" and "Stg.".
    pub fn sub_address_key(sub: &str) -> String {
        let bare = GENERIC_SUB_WORD_RE.replace_all(sub, " ");
        german_fold(&bare.to_lowercase()).chars().filter(|c| c.is_alphanumeric()).collect()
    }

    /// A sub-address as the bare numbers and letters that identify it, with
    /// every label word gone: "Gruppe F Parz. 7" and "F/7" are both
    /// ["f", "7"], "Obj. 62A" and "62A" both ["62a"]. Looser than
    /// `sub_address_key`, so only ever used when that finds nothing, and
    /// only trusted when it singles out one door.
    pub fn sub_address_tokens(sub: &str) -> Vec<String> {
        let bare = german_fold(&ANY_SUB_LABEL_RE.replace_all(sub, " ").to_lowercase());
        bare.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()).map(str::to_string).collect()
    }

    /// Everything after the house number in what the driver typed, one entry
    /// per slash: "Promenadegasse 57/A1/1" is ["A1", "1"].
    pub fn sub_address_segments(strasse: &str) -> Vec<String> {
        let Some(caps) = SUB_ADDRESS_ALL_RE.captures(strasse) else { return Vec::new() };
        caps["tail"].split('/').map(str::trim).filter(|p| !p.is_empty()).map(str::to_string).collect()
    }

    /// The register's own sub-address text -- "Haus A/1", "Parz. 68", "/2" --
    /// or `None` when it answered with a bare housenumber.
    pub fn sub_address_tail(adresse: &str) -> Option<String> {
        let caps = HOUSENUMBER_TAIL_RE.captures(adresse)?;
        let tail = caps["tail"].trim();
        (!tail.is_empty()).then(|| tail.to_string())
    }

    /// The sub-address of an address string as the *register* spells it —
    /// everything after "{street} {housenumber}", normalized by
    /// `sub_address_key`. `None` when the register answered with a bare
    /// housenumber and no sub-address at all.
    pub fn sub_address_of(adresse: &str) -> Option<String> {
        let key = sub_address_key(&sub_address_tail(adresse)?);
        (!key.is_empty()).then_some(key)
    }

    /// Just the street-name portion, no housenumber — used to cross-check
    /// that a geocoder result actually landed on the street we asked for
    /// rather than a fuzzy string-similarity match onto a *different*
    /// street entirely (see `wien_ogd_search_one`).
    pub fn street_name_only(strasse: &str) -> String {
        match HOUSENUMBER_RE.captures(strasse) {
            Some(caps) => caps["street"].trim().to_string(),
            None => strasse.trim().to_string(),
        }
    }
}

// ---------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------

// Precise coordinates for the two fixed route points (Petritschgasse 24 /
// Oberlaaer Straße 298), looked up once ahead of time. Route creation
// never needs to resolve these at runtime.
const START_LAT: f64 = 48.2788118;
const START_LON: f64 = 16.4356537;
const VIA_LAT: f64 = 48.1499425;
const VIA_LON: f64 = 16.3587494;

// ---------------------------------------------------------------------
// External service endpoints — the three upstreams this app calls out to
// (see the module doc comment above). Kept together at the top, rather
// than next to the code that uses each one, so self-hosting any of them
// is a one-line edit here instead of a hunt through the file. Each has a
// matching `EAR_*_URL` environment variable that overrides it at startup
// without touching this file at all — see `Upstreams::from_env`.
// ---------------------------------------------------------------------

/// Vienna OGD "Adressservice Wien" `GetAddressInfo` endpoint — tried first
/// for geocoding, see `wien_ogd_search_one`. Override with `EAR_WIEN_OGD_URL`.
const WIEN_OGD_URL_DEFAULT: &str = "https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo";
/// Nominatim (OpenStreetMap) `/search` endpoint — geocoding fallback, see
/// `geocode_address`. Override with `EAR_NOMINATIM_URL`.
const NOMINATIM_URL_DEFAULT: &str = "https://nominatim.openstreetmap.org/search";
/// OSRM base URL, no trailing slash — routing/trip-optimization, see
/// `osrm_route_through`/`osrm_trip`. Override with `EAR_OSRM_URL`. Currently a
/// self-hosted instance on the local network; `osrm_get` automatically
/// falls back to `OSRM_PUBLIC_FALLBACK` if this one is unreachable, so a
/// self-host outage degrades routing rather than breaking it.
const OSRM_BASE_DEFAULT: &str = "http://192.168.178.216:5000";
/// The public OSRM demo server, used only as a fallback when the configured
/// primary (`OSRM_BASE_DEFAULT`/`EAR_OSRM_URL`) is unreachable — see
/// `osrm_get`. Not itself overridable by env var: it's a last resort, not a
/// deployment choice, so there's nothing to configure.
const OSRM_PUBLIC_FALLBACK: &str = "https://router.project-osrm.org";
/// OSRM's public demo server refuses a `/trip` request with more waypoints
/// than this (`max-trip-size`, 100 by default) — checked before sending so
/// an oversized route gets a German sentence explaining the real limit
/// instead of an opaque relayed "OSRM trip: TooBig". A self-hosted OSRM
/// instance may raise `max-trip-size`; bump this to match if so — but note
/// the public fallback above still enforces the default 100, so a bump only
/// helps while the self-hosted primary is actually reachable.
const OSRM_MAX_TRIP_COORDS: usize = 100;

// ---------------------------------------------------------------------
// Input validation — every one of these guards a value that ends up
// either stored forever, sent to a shared third-party service (Nominatim
// enforces a usage policy per *client*, not per request — a client that
// sends it garbage risks the whole app's shared IP getting blocked), or
// serialized back into route geometry (see `reoptimize_route`), so
// letting bad data slip through here is worse than rejecting it early
// with a clear 400.
// ---------------------------------------------------------------------

/// The 23 real Vienna postal codes — exactly what the frontend's own
/// `<select>` of districts offers (see `VIENNA_DISTRICTS` in index.html),
/// so validating against this exact set can never reject a legitimate
/// request from the app's own UI, only ones crafted by hand/script.
const VIENNA_PLZ: &[&str] = &[
    "1010", "1020", "1030", "1040", "1050", "1060", "1070", "1080", "1090", "1100", "1110",
    "1120", "1130", "1140", "1150", "1160", "1170", "1180", "1190", "1200", "1210", "1220",
    "1230",
];

fn is_valid_vienna_plz(plz: &str) -> bool {
    VIENNA_PLZ.contains(&plz)
}

/// Any Austrian postcode: four digits, the first not a zero. Nearly every
/// stop is in Vienna, but a tour from the portal reaches into Gerasdorf or
/// Schwechat often enough that refusing those cost a stop a day.
fn is_valid_plz(plz: &str) -> bool {
    plz.len() == 4 && plz.bytes().all(|b| b.is_ascii_digit()) && !plz.starts_with('0')
}

fn check_plz(plz: &str) -> Result<(), AppError> {
    if !is_valid_plz(plz) {
        return Err(AppError::BadRequest(format!("Ungültige Postleitzahl: {plz}")));
    }
    Ok(())
}

/// "1180 Wien, Österreich" or "2201, Österreich": what follows the street
/// when an address is handed to a geocoder. "Wien" only where the postcode
/// says Vienna -- appended to a Gerasdorf street it sends the search to the
/// wrong municipality.
fn place_suffix(plz: &str) -> String {
    if is_valid_vienna_plz(plz) { format!("{plz} Wien, Österreich") } else { format!("{plz}, Österreich") }
}

/// Rejects a field that's over `max` chars — cheap insurance against a
/// malicious/broken client storing megabyte-sized strings forever in
/// every route JSON response from then on.
fn check_len(value: &str, field: &str, max: usize) -> Result<(), AppError> {
    if value.chars().count() > max {
        return Err(AppError::BadRequest(format!("{field} ist zu lang (max. {max} Zeichen).")));
    }
    Ok(())
}

/// Rejects a field containing raw control characters (embedded NUL, escape
/// sequences, etc.) — never legitimate in a name/address/package label, and
/// they can corrupt how downstream tooling (the sqlite3 CLI, a terminal-based
/// log viewer, a future CSV export) reads the stored text back. `notiz` is
/// the one free-text field a driver might genuinely paste multi-line text
/// into, so it alone allows newlines/tabs through.
fn check_no_control_chars(value: &str, field: &str, allow_newlines: bool) -> Result<(), AppError> {
    let has_bad_char = value
        .chars()
        .any(|c| c.is_control() && !(allow_newlines && matches!(c, '\n' | '\r' | '\t')));
    if has_bad_char {
        return Err(AppError::BadRequest(format!("{field} enthält ungültige Steuerzeichen.")));
    }
    Ok(())
}

const MAX_KUNDE_LEN: usize = 120;
const MAX_STRASSE_LEN: usize = 200;
/// As long as the portal makes it. A delivery's Paket is every line of every
/// parcel joined up, and a household with a week of frozen dishes runs to
/// well over a thousand characters; at the 200 this used to be, the text was
/// cut mid-dish and the Ladeliste then counted what was left. The same
/// figure as the iOS app's.
const MAX_PAKET_LEN: usize = 10_000;
const MAX_NOTIZ_LEN: usize = 1000;
const MAX_TELEFON_LEN: usize = 40;

/// A phone number as typed: trimmed, `None` when blank, refused when it is
/// too long or carries control characters. Not parsed further -- how a
/// number is written is the office's business, and the app only ever hands
/// its digits to the dialler.
fn clean_telefon(raw: Option<&str>) -> Result<Option<String>, AppError> {
    let Some(t) = raw.map(str::trim).filter(|t| !t.is_empty()) else { return Ok(None) };
    check_len(t, "Telefon", MAX_TELEFON_LEN)?;
    check_no_control_chars(t, "Telefon", false)?;
    Ok(Some(t.to_string()))
}
const MAX_ROUTE_NAME_LEN: usize = 200;
/// Upper bound on stops accepted in one list loaded from the portal.
/// Uncached entries each cost a throttled ~1.1s Nominatim round-trip
/// (see `NOMINATIM_MIN_INTERVAL`), so an unbounded list turns one HTTP
/// request into an effectively unbounded amount of work tying up a
/// handler and hammering a shared public service. Pinned to what OSRM can
/// actually optimize in one `/trip` call (its cap, minus the fixed
/// warehouse and destination waypoints) so an oversized paste is rejected
/// in milliseconds, up front — rather than geocoding for minutes first and
/// only then failing at the routing step with the stops already saved.
const MAX_BULK_STOPS: usize = OSRM_MAX_TRIP_COORDS - 2;
/// Compile-time guard on the sentence above: a full-size paste plus the
/// fixed warehouse and destination waypoints must fit in one OSRM `/trip`
/// call. Breaks the build, not a route, if the two constants ever drift.
const _: () = assert!(MAX_BULK_STOPS + 2 <= OSRM_MAX_TRIP_COORDS);

/// How many `geocode_address` calls a load from the portal runs at
/// once (see `import_entries`). Modest on purpose: this is a
/// polite concurrency limit against Vienna's own address service (which
/// has no documented rate limit but is still a shared production system,
/// not a load-test target), not an attempt to extract maximum throughput
/// — Nominatim, the only *actually* rate-limited upstream in this chain,
/// is protected independently by `nominatim_throttle` regardless of what
/// this is set to.
const BULK_GEOCODE_CONCURRENCY: usize = 6;

/// Worst-case bytes one bulk-import entry can occupy on the wire, derived
/// from the field limits rather than guessed at.
///
/// The field limits count *characters* (`check_len` uses `chars().count()`),
/// and a UTF-8 character is up to 4 bytes — so the byte size of a
/// perfectly legal request is up to four times what the character limits
/// suggest. This is not hypothetical at the low end: every umlaut and ß in
/// ordinary German text is already two bytes, which alone puts a full-size
/// import of realistic notes at ~245 KB.
const MAX_BULK_ENTRY_BYTES: usize = {
    let field_chars = MAX_KUNDE_LEN + MAX_STRASSE_LEN + MAX_PAKET_LEN + MAX_NOTIZ_LEN + MAX_TELEFON_LEN + 8 /* plz */;
    // 4 bytes per char worst case, plus the JSON scaffolding around one
    // object: five `"key": "value",` pairs, braces, and room for escapes.
    field_chars * 4 + 128
};

/// The request-body cap. Derived from the limits above with real headroom,
/// not a round number picked by eye: a body limit smaller than what the
/// field limits permit means a request this server documents as valid gets
/// rejected before any handler sees it — and rejected by a layer whose
/// error message the frontend can't turn into a sentence.
///
/// The `+ 64 KiB` covers the array scaffolding and any pretty-printing
/// whitespace a hand-edited paste carries.
const MAX_BODY_BYTES: usize = MAX_BULK_STOPS * MAX_BULK_ENTRY_BYTES + 64 * 1024;

/// Breaks the build if the two limits ever drift apart again: every request
/// that passes field validation must have been able to arrive in the first
/// place.
const _: () = assert!(MAX_BODY_BYTES >= MAX_BULK_STOPS * MAX_BULK_ENTRY_BYTES);

/// A generous bounding box around Vienna and its immediate surroundings
/// (well outside the city limits in every direction) — just enough to
/// reject obviously-wrong input (NaN/Infinity smuggled in as an
/// out-of-range JSON number literal, `0,0`, a swapped lat/lon, a
/// fat-fingered extra digit) before it's ever stored or handed to OSRM.
const LAT_MIN: f64 = 46.3;
const LAT_MAX: f64 = 49.1;
const LON_MIN: f64 = 9.4;
const LON_MAX: f64 = 17.2;

fn is_plausible_latlon(lat: f64, lon: f64) -> bool {
    lat.is_finite()
        && lon.is_finite()
        && (LAT_MIN..=LAT_MAX).contains(&lat)
        && (LON_MIN..=LON_MAX).contains(&lon)
}

/// The box a point has to be in for the postcode it is filed under: the tight
/// one around Vienna for a Vienna postcode, all of Austria otherwise. A stop
/// under 1210 whose point is in Graz is a mistake however wide the app's
/// reach is.
fn is_plausible_for_plz(lat: f64, lon: f64, plz: &str) -> bool {
    if is_valid_vienna_plz(plz) { is_in_vienna(lat, lon) } else { is_plausible_latlon(lat, lon) }
}

/// Refuses a hand-placed pin far from the postcode it belongs to, while the
/// driver is still looking at the map they placed it on.
fn check_pin(lat: f64, lon: f64, plz: &str) -> Result<(), AppError> {
    check_latlon(lat, lon)?;
    if !is_plausible_for_plz(lat, lon, plz) {
        return Err(AppError::BadRequest(format!(
            "Der Pin liegt zu weit von der PLZ {plz} entfernt. Bitte ihn bei der Adresse setzen."
        )));
    }
    Ok(())
}

fn check_latlon(lat: f64, lon: f64) -> Result<(), AppError> {
    if !is_plausible_latlon(lat, lon) {
        return Err(AppError::BadRequest(
            "Ungültige Koordinaten (außerhalb des erwarteten Bereichs).".into(),
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Error handling — mirrors the FastAPI error shape the frontend expects:
// plain HTTPException -> {"detail": "message"}
// GeocodeError         -> {"detail": {"message": ..., "code": ...}}
// ---------------------------------------------------------------------

#[derive(Debug)]
enum AppError {
    NotFound(String),
    BadRequest(String),
    Forbidden(String),
    /// Nobody is signed in. The app answers this one by showing the login.
    Unauthorized,
    /// A geocoding outcome the frontend has a designed response for, keyed
    /// by `code` rather than by parsing `message`. `plz` carries the
    /// district the register actually files the address under, for the one
    /// code (`wrong_district`) that has one -- the app pre-selects it in the
    /// form so the fix is a single tap. It is a field rather than something
    /// to scrape back out of the German sentence: a reworded message must
    /// never be able to break the correction.
    Geocode { status: u16, code: String, message: String, plz: Option<String> },
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, body) = match self {
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, json!({ "detail": msg })),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, json!({ "detail": msg })),
            AppError::Forbidden(msg) => (StatusCode::FORBIDDEN, json!({ "detail": msg })),
            AppError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                json!({ "detail": { "message": "Bitte anmelden.", "code": "unauthorized" } }),
            ),
            AppError::Geocode { status, code, message, plz } => {
                let mut detail = json!({ "message": message, "code": code });
                // Only present on the codes that have one, so the frontend can
                // treat "no plz" and "not this kind of error" identically.
                if let Some(plz) = plz {
                    detail["plz"] = Value::String(plz);
                }
                (
                    StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
                    json!({ "detail": detail }),
                )
            }
            AppError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, json!({ "detail": msg })),
        };
        (status, Json(body)).into_response()
    }
}

impl From<rusqlite::Error> for AppError {
    fn from(e: rusqlite::Error) -> Self {
        // The raw rusqlite error (constraint names, SQL fragments) is
        // useful for debugging but not for a client — log it server-side
        // and hand back a message that doesn't describe internal schema.
        tracing::error!(error = %e, "database error");
        AppError::Internal("Datenbankfehler.".into())
    }
}

// ---------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------

struct AppState {
    db_path: PathBuf,
    /// Idle connections, handed out by `db()` and returned on drop.
    db_pool: Arc<StdMutex<Vec<Connection>>>,
    /// Directory `index.html`/`sw.js`/`icon.png` are served from — resolved
    /// once at startup (see `assets_dir`) rather than baked in at compile
    /// time, so the binary stays movable.
    assets: PathBuf,
    http: reqwest::Client,
    // Timestamp of the last outbound Nominatim request, gating
    // `nominatim_throttle` so concurrent geocode calls still serialize to
    // Nominatim's ~1 req/s public usage policy instead of bursting past it.
    nominatim_last: AsyncMutex<Option<Instant>>,
    // Per-client-IP request counters backing `rate_limit_mw` — see there
    // for why this exists at all.
    rate_limit: AsyncMutex<HashMap<IpAddr, RateEntry>>,
    /// Whether to believe `X-Forwarded-For` when identifying a client for
    /// rate limiting — see `client_ip`.
    trust_proxy: bool,
    /// The three upstream services, resolved once at startup.
    ///
    /// Configurable rather than hardcoded for two reasons that are really
    /// the same reason. Operationally: the public Nominatim and OSRM
    /// servers are shared goodwill infrastructure with usage policies this
    /// app works hard to respect, and anyone running this for a real
    /// service should be able to point it at their own instance without
    /// editing Rust. For testing: handlers that reach the network can't be
    /// tested offline or deterministically, so the entire route/stop API
    /// goes untested — pointing these at an unreachable address is what
    /// would make handler-level tests possible. Nothing does that yet; the
    /// suite at the bottom of this file covers only the network-free parts.
    upstreams: Upstreams,
    /// One lock per route id, held for the duration of `reoptimize_route`.
    /// Two optimizations of the *same* route running concurrently (a stop
    /// added while a bulk import is still finishing, say) would each compute
    /// a complete stop order from the state they read at the start and then
    /// write it wholesale — last writer wins, and the losing side's stops
    /// keep the leg distances of an order that no longer exists. Different
    /// routes never contend with each other.
    route_locks: AsyncMutex<HashMap<i64, Arc<AsyncMutex<()>>>>,
    /// When the primary OSRM (`upstreams.osrm_base`) was last seen failing,
    /// if it was recently enough that `osrm_get` should skip straight to
    /// `OSRM_PUBLIC_FALLBACK` instead of paying a full connect timeout on
    /// every request while a self-hosted instance stays down. `None` means
    /// either it's never failed or it has since recovered — see `osrm_get`.
    osrm_primary_down_since: StdMutex<Option<Instant>>,
}

#[derive(Clone)]
struct Upstreams {
    /// OSRM base URL, no trailing slash (e.g. `https://router.project-osrm.org`).
    osrm_base: String,
    /// Nominatim `/search` endpoint.
    nominatim_search: String,
    /// Vienna OGD `GetAddressInfo` endpoint.
    wien_ogd: String,
}

impl Default for Upstreams {
    fn default() -> Self {
        Self {
            osrm_base: OSRM_BASE_DEFAULT.to_string(),
            nominatim_search: NOMINATIM_URL_DEFAULT.to_string(),
            wien_ogd: WIEN_OGD_URL_DEFAULT.to_string(),
        }
    }
}

impl Upstreams {
    fn from_env() -> Self {
        let d = Self::default();
        let get = |key: &str, fallback: String| {
            std::env::var(key).ok().filter(|v| !v.trim().is_empty()).unwrap_or(fallback)
        };
        Self {
            // Trailing slash trimmed so `{base}/route/v1/...` can't become
            // a double slash that some OSRM deployments 404 on.
            osrm_base: get("EAR_OSRM_URL", d.osrm_base).trim_end_matches('/').to_string(),
            nominatim_search: get("EAR_NOMINATIM_URL", d.nominatim_search),
            wien_ogd: get("EAR_WIEN_OGD_URL", d.wien_ogd),
        }
    }
}

impl AppState {
    /// Borrow a database connection.
    ///
    /// Reusing connections rather than opening one per call site is worth
    /// doing because the call sites are not one per request: adding a stop
    /// alone touches the database four separate times (existence check,
    /// geocode cache read, geocode cache write, the insert), and every
    /// `Connection::open` re-runs four `PRAGMA` statements before doing any
    /// work. The handlers stay written the same way — borrow, use, drop —
    /// they just stop paying setup each time.
    fn db(&self) -> Result<PooledConn, AppError> {
        let idle = self.db_pool.lock().ok().and_then(|mut p| p.pop());
        let conn = match idle {
            Some(conn) => conn,
            None => open_db(&self.db_path)?,
        };
        Ok(PooledConn {
            conn: Some(conn),
            pool: Arc::clone(&self.db_pool),
            _not_send: PhantomData,
        })
    }

    /// The lock guarding optimizations of one specific route, creating it on
    /// first use. Returned as an `Arc` so the caller can await it *after*
    /// releasing the outer map lock — holding the map lock across the whole
    /// optimization would serialize every route against every other one.
    async fn route_lock(&self, route_id: i64) -> Arc<AsyncMutex<()>> {
        let mut map = self.route_locks.lock().await;
        // Nobody is waiting on a lock nobody else holds a handle to: an
        // entry whose only remaining reference is the map's own is dead
        // weight from a route that finished (or was deleted) long ago.
        map.retain(|id, lock| *id == route_id || Arc::strong_count(lock) > 1);
        Arc::clone(map.entry(route_id).or_default())
    }
}

// ---------------------------------------------------------------------
// Rate limiting — the sign-in itself, and everything behind it, is
// reachable by anyone who can reach the port and has (or guesses at) an
// account. Without a cap, a script (or just a buggy retry loop) hitting `/api`
// hard can: exhaust this process's SQLite/CPU budget, and worse, burn
// through Nominatim's/OSRM's shared public-usage allowance fast enough
// to get this server's IP rate-limited or banned by them — which would
// break geocoding/routing for the actual driver, not just the abuser.
// A simple fixed-window per-IP counter is cheap insurance against both.
// ---------------------------------------------------------------------

const RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);
// Generous for one driver actively working a route (interactive add/
// edit/delete/optimize calls), well below what a scripted flood would
// send.
const RATE_LIMIT_MAX_REQUESTS: u32 = 120;

/// Which IP a request is counted against. The TCP peer address is the only
/// value that can't be forged — but it's also the *proxy's* address the
/// moment this app sits behind nginx/Caddy/Cloudflare, which would collapse
/// every driver into one shared 120 req/min bucket and let one phone lock
/// out the rest. `X-Forwarded-For`'s first entry is the real client there,
/// but it's trivially spoofable when the app is exposed directly (a
/// scripted flood could then present a fresh IP per request and bypass the
/// limiter entirely), so it's only honored when `EAR_TRUST_PROXY` says a
/// trusted proxy is actually in front — never by default.
fn client_ip(headers: &HeaderMap, peer: SocketAddr, trust_proxy: bool) -> IpAddr {
    if trust_proxy {
        if let Some(fwd) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
            if let Some(first) = fwd.split(',').next() {
                // A proxy may write "203.0.113.5:41234" or "[2001:db8::1]:443"
                // rather than a bare address; parse the bare form first and
                // fall back to stripping a port before giving up.
                if let Ok(ip) = first.trim().parse::<IpAddr>() {
                    return ip;
                }
                if let Ok(sock) = first.trim().parse::<SocketAddr>() {
                    return sock.ip();
                }
            }
        }
    }
    peer.ip()
}

/// Per-IP counters: (current window start, count in it, count in the one
/// before). Two counts, not one, because a plain fixed window lets a
/// client send the full allowance in the last instant of one window and
/// the full allowance again in the first instant of the next — twice the
/// intended rate, right at the boundary, which is exactly when a retry
/// loop tends to fire.
type RateEntry = (Instant, u32, u32);

/// Requests attributable to the last full window, weighted by how far into
/// the current one we are — the standard sliding-window-counter
/// approximation. At the moment a window flips, the previous window still
/// counts fully and decays smoothly to nothing over the next minute,
/// so the effective rate stays at the limit across the boundary instead of
/// doubling.
fn sliding_count(entry: &RateEntry, now: Instant) -> f64 {
    let (start, current, previous) = *entry;
    let elapsed = now.duration_since(start).as_secs_f64();
    let window = RATE_LIMIT_WINDOW.as_secs_f64();
    let carry_over = ((window - elapsed) / window).clamp(0.0, 1.0);
    previous as f64 * carry_over + current as f64
}

async fn rate_limit_mw(
    State(state): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let ip = client_ip(req.headers(), addr, state.trust_proxy);
    let now = Instant::now();
    let over_limit = {
        let mut map = state.rate_limit.lock().await;
        // Opportunistic cleanup so this map can't grow without bound if
        // many distinct IPs ever hit the server.
        map.retain(|_, (start, _, _)| now.duration_since(*start) < RATE_LIMIT_WINDOW * 4);
        let entry = map.entry(ip).or_insert((now, 0, 0));
        let elapsed = now.duration_since(entry.0);
        if elapsed >= RATE_LIMIT_WINDOW * 2 {
            // Long idle: both windows are ancient, start clean.
            *entry = (now, 0, 0);
        } else if elapsed >= RATE_LIMIT_WINDOW {
            // Roll over: the window that just ended becomes the previous one.
            *entry = (now, 0, entry.1);
        }
        entry.1 += 1;
        sliding_count(entry, now) > RATE_LIMIT_MAX_REQUESTS as f64
    };
    if over_limit {
        tracing::warn!(%ip, "rate limit exceeded");
        return (
            StatusCode::TOO_MANY_REQUESTS,
            [(header::RETRY_AFTER, "60")],
            Json(json!({ "detail": "Zu viele Anfragen. Bitte kurz warten und erneut versuchen." })),
        )
            .into_response();
    }
    next.run(req).await
}

/// Content-Security-Policy matching exactly what index.html actually loads
/// — nothing more. Written out explicitly (rather than left off, or set to
/// a permissive `default-src *`) because the one thing this app renders is
/// attacker-influencable free text: customer names, addresses and notes go
/// through `innerHTML` in the frontend, and while every one of those is run
/// through `escapeHtml`/`escapeAttr` there, a CSP is what turns "one
/// forgotten escape somewhere" from script execution into a blocked
/// console message.
///
/// The awkward parts are all load-bearing, not laziness:
///   - `'unsafe-inline'` for scripts: index.html is deliberately a single
///     self-contained file with inline `<script>` blocks (no build step),
///     so a nonce would have to be injected into the file on every request.
///   - `blob:` in `worker-src`/`child-src`: MapLibre GL runs its tile
///     parsing in a worker created from a blob URL.
///   - `data:` in `manifest-src`: the PWA manifest is an inline data: URI
///     (see the `addTag('link', { rel: 'manifest' ... })` call).
///   - `maps.wien.gv.at` in BOTH `img-src` and `connect-src`: it serves the
///     aerial basemap's tiles (see `aerialStyle` in index.html), and
///     MapLibre fetches raster tiles with `fetch` (for `createImageBitmap`)
///     rather than as plain `<img>` elements — listing only `img-src` left
///     every aerial tile failing as an opaque "Failed to fetch".
const CONTENT_SECURITY_POLICY: &str = "default-src 'self'; \
script-src 'self' 'unsafe-inline' https://unpkg.com; \
style-src 'self' 'unsafe-inline' https://unpkg.com; \
img-src 'self' data: blob: https://tiles.openfreemap.org https://maps.wien.gv.at; \
font-src 'self' data:; \
connect-src 'self' https://tiles.openfreemap.org https://maps.wien.gv.at https://unpkg.com; \
worker-src 'self' blob:; \
child-src 'self' blob:; \
manifest-src 'self' data:; \
base-uri 'self'; \
form-action 'self'; \
frame-ancestors 'none'";

/// A handful of defensive response headers that cost nothing to always
/// send and don't touch the frontend's own markup/behavior at all — just
/// tells browsers not to sniff content types, not to frame this app, and
/// not to leak the URL (which can contain a street address) via Referer.
async fn security_headers_mw(req: Request, next: Next) -> Response {
    let mut res = next.run(req).await;
    let headers = res.headers_mut();
    headers.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    headers.insert(header::REFERRER_POLICY, HeaderValue::from_static("same-origin"));
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(CONTENT_SECURITY_POLICY),
    );
    res
}

/// Every `/api/*` response describes live, mutable state (a route's stops,
/// what's been delivered) — a browser or intermediate proxy replaying a
/// cached copy of one would show a driver a delivery list that's quietly
/// out of date. `no-store` rather than `no-cache` because there is no
/// version of this data worth keeping on disk at all.
///
/// Path-checked and mounted on the *outer* router rather than inside the
/// API router, for the same reason `api_error_shape_mw` is: the two `/api`
/// responses that don't come from a handler were missing the header
/// entirely. `/api/health` is deliberately mounted outside the rate limiter
/// (so a monitor can't be starved by a flood), and the limiter's own 429 is
/// generated above every layer the API router nests inside — so neither
/// could ever reach a middleware living in there. The health one is the
/// one that mattered: a 200 with no freshness information at all is
/// heuristically cacheable, and a proxy replaying a stale "ok" while the
/// database is unreachable defeats the entire point of the endpoint.
///
/// The path check is what keeps this off the static routes, which have
/// their own deliberate caching (`no-cache` + ETag for the app shell, a
/// day's `max-age` for the logo) and must not be flattened to `no-store`.
async fn api_no_store_mw(req: Request, next: Next) -> Response {
    let is_api = req.uri().path().starts_with("/api");
    let mut res = next.run(req).await;
    if is_api {
        res.headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
    res
}

/// Anything that isn't a known route. Without this, axum answers with a
/// bare empty 404 body — which the frontend's `api()` helper can't parse a
/// `detail` out of, so a mistyped/removed endpoint surfaces to the driver
/// as the generic "Ein Fehler ist aufgetreten." instead of something that
/// says what actually happened.
async fn not_found() -> impl IntoResponse {
    (StatusCode::NOT_FOUND, Json(json!({ "detail": "Nicht gefunden." })))
}

/// Liveness *and* readiness in one: it actually touches the database
/// rather than just proving the process answers sockets. A server whose
/// disk has filled or whose database file has gone missing still accepts
/// connections perfectly happily, and reporting that as healthy is how a
/// broken deployment stays up all day.
async fn health(State(state): State<Arc<AppState>>) -> Response {
    match state.db().and_then(|conn| {
        conn.query_row("SELECT COUNT(*) FROM routes", [], |r| r.get::<_, i64>(0))
            .map_err(AppError::from)
    }) {
        Ok(routes) => (
            StatusCode::OK,
            Json(json!({ "status": "ok", "routes": routes, "version": env!("CARGO_PKG_VERSION") })),
        )
            .into_response(),
        Err(e) => {
            tracing::error!(error = ?e, "health check failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({ "status": "error", "detail": "Datenbank nicht erreichbar." })),
            )
                .into_response()
        }
    }
}

/// Rewrites the errors this app does *not* generate itself — the ones
/// axum's own extractors produce before a handler ever runs — into the
/// `{"detail": "..."}` shape every other error here uses.
///
/// Those rejections come back as `text/plain` with English internals:
/// "Failed to buffer the request body: length limit exceeded",
/// "Failed to parse the request body as JSON: expected `,` at line 4
/// column 3", "Expected request with `Content-Type: application/json`".
/// The frontend reads a `detail` field or nothing, so every one of them
/// currently reaches the driver as the flat "Ein Fehler ist aufgetreten."
/// — no indication that the paste has a stray comma on line 4, or that the
/// import is simply too large.
///
/// Handler errors already carry the right shape (see `AppError`) and are
/// passed through untouched; this only fills in for the layers underneath.
async fn api_error_shape_mw(req: Request, next: Next) -> Response {
    // Mounted on the *outer* router so it also sees the responses the outer
    // layers generate themselves — the request timeout and the panic
    // catcher — which the API router's own layers are nested inside and
    // therefore cannot reach. The path check is what keeps it from
    // rewriting errors for the HTML routes, which are not consumed by
    // `api()` and have no reason to speak JSON.
    let is_api = req.uri().path().starts_with("/api");
    let res = next.run(req).await;
    let status = res.status();
    if !is_api || (!status.is_client_error() && !status.is_server_error()) {
        return res;
    }
    let is_json = res
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|ct| ct.starts_with("application/json"));
    if is_json {
        return res;
    }

    // Deliberately not the upstream text: it describes this server's
    // plumbing in English, to a German-speaking driver who can only act on
    // "your paste is too big" or "your JSON has a syntax error".
    let detail = match status {
        StatusCode::PAYLOAD_TOO_LARGE => format!(
            "Die Daten sind zu groß (max. {} KB). Bitte in kleineren Gruppen importieren.",
            MAX_BODY_BYTES / 1024
        ),
        StatusCode::BAD_REQUEST => {
            "Die Daten konnten nicht gelesen werden. Bitte das JSON auf Tippfehler prüfen.".to_string()
        }
        StatusCode::UNSUPPORTED_MEDIA_TYPE => {
            "Ungültiges Datenformat (erwartet wird JSON).".to_string()
        }
        StatusCode::METHOD_NOT_ALLOWED => "Diese Aktion ist hier nicht möglich.".to_string(),
        StatusCode::REQUEST_TIMEOUT => {
            "Zeitüberschreitung — der Vorgang hat zu lange gedauert.".to_string()
        }
        _ => "Ein Fehler ist aufgetreten.".to_string(),
    };
    // The original *body* is dropped — it has already been logged where it
    // mattered, and passing an upstream's raw error text to a client is how
    // internals leak — but its headers are kept, since inner layers may have
    // put things there worth preserving across the reshape. (`Cache-Control:
    // no-store` is no longer among them — `api_no_store_mw` now sits outside
    // this and stamps it on whatever comes out.)
    tracing::debug!(%status, "rewrote a non-JSON rejection into the API error shape");
    let (mut parts, _) = res.into_parts();
    let body = Json(json!({ "detail": detail })).into_response();
    let (json_parts, json_body) = body.into_parts();
    parts.status = status;
    // Content-Type/Length now describe the JSON body, not the discarded one.
    for key in [header::CONTENT_TYPE, header::CONTENT_LENGTH] {
        parts.headers.remove(&key);
        if let Some(v) = json_parts.headers.get(&key) {
            parts.headers.insert(key, v.clone());
        }
    }
    Response::from_parts(parts, json_body)
}


fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339()
}

// ---------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------

/// How many idle connections the pool keeps. This app is one driver on one
/// phone plus, at most, a monitoring check — a handful of connections
/// covers every concurrent handler there will ever be, and anything beyond
/// that is closed rather than hoarded.
const DB_POOL_MAX_IDLE: usize = 8;

/// A SQLite connection borrowed from the pool, returned on drop.
///
/// The `PhantomData<*const ()>` is the point of this type, not an
/// implementation detail: it makes the guard `!Send`, which makes holding
/// a database connection across an `.await` a **compile error**.
///
/// That rule matters here more than in most apps. Handlers in this file
/// interleave database work with geocoding and routing calls that can take
/// seconds — a stop lookup, then a throttled Nominatim round trip, then a
/// write. A connection held across one of those pins a SQLite handle (and,
/// inside a transaction, a write lock on the whole database) for the
/// duration of a network call to a third party. The code already avoided
/// this by convention; now it can't be done by accident.
///
/// Note that `Connection` alone would *not* have given this: rusqlite's
/// `Connection` is `Send` (just not `Sync`), so a future holding one stays
/// `Send` and compiles fine. An earlier comment in this file claimed
/// otherwise — the discipline was real, the compiler was never enforcing
/// it.
struct PooledConn {
    conn: Option<Connection>,
    pool: Arc<StdMutex<Vec<Connection>>>,
    _not_send: PhantomData<*const ()>,
}

impl Deref for PooledConn {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        // `None` only between `Drop::drop` taking the connection and the
        // value going away, which no other code can observe.
        self.conn.as_ref().expect("pooled connection used after drop")
    }
}

impl DerefMut for PooledConn {
    fn deref_mut(&mut self) -> &mut Connection {
        self.conn.as_mut().expect("pooled connection used after drop")
    }
}

impl Drop for PooledConn {
    fn drop(&mut self) {
        let Some(conn) = self.conn.take() else { return };
        // A poisoned pool mutex means another thread panicked mid-borrow.
        // Dropping this connection is a fine response — the pool refills
        // itself on demand — and is certainly better than panicking again
        // inside a `Drop`.
        if let Ok(mut idle) = self.pool.lock() {
            if idle.len() < DB_POOL_MAX_IDLE {
                idle.push(conn);
            }
        }
    }
}

fn open_db(path: &FsPath) -> Result<Connection, AppError> {
    let conn = Connection::open(path)?;
    // `synchronous = NORMAL` is the documented companion to WAL: it drops
    // the fsync on every single commit (keeping one at each checkpoint), so
    // a bulk import's dozens of small transactions stop paying a disk flush
    // each. The durability it trades away is a power-cut losing the last
    // few commits — not corruption, and not a risk worth a multi-second
    // import for a delivery list that can be re-pasted.
    conn.execute_batch(
        "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; \
         PRAGMA busy_timeout = 10000;",
    )?;
    Ok(conn)
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS routes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    completed_at TEXT,
    geometry TEXT,
    needs_optimize INTEGER NOT NULL DEFAULT 0,
    -- Where the driver was when they last said so, and when (unix seconds).
    -- Only ever used for a tour whose Start is switched off: "start from
    -- where I am". See `reoptimize_route`.
    here_lat REAL,
    here_lon REAL,
    here_at INTEGER,
    -- 1 once the driver has put the stops in an order of their own. Such a
    -- tour is routed as listed -- an edit never throws that order away --
    -- until they ask for a fresh one.
    hand_ordered INTEGER NOT NULL DEFAULT 0,
    -- Whose tour this is.
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    -- 'vm' or 'tk', once the driver has picked one in the Ladeliste. NULL
    -- until then, on purpose: a tour nobody has switched by hand keeps
    -- following its name, including after a rename.
    ladeliste_mode TEXT,
    -- When the van left for the Lager today (RFC 3339): the moment the
    -- driver started navigation there. See `mark_departed`.
    departed_at TEXT
);

CREATE TABLE IF NOT EXISTS stops (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'customer',
    kunde TEXT,
    strasse TEXT,
    plz TEXT,
    paket TEXT,
    notiz TEXT,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    order_index INTEGER NOT NULL DEFAULT 0,
    delivered INTEGER NOT NULL DEFAULT 0,
    next_leg_km REAL,
    next_leg_min REAL,
    created_at TEXT NOT NULL,
    -- Only ever 1 on a fixed stop (start/via/end). Every route gets the same
    -- three fixed points, but not every tour actually drives them: a shift
    -- that starts straight from the warehouse, or ends somewhere other than
    -- the depot, would otherwise be planned around two legs it never drives.
    -- An excluded stop stays on the route (it's still shown, greyed, and can
    -- be switched back on) but is left out of the OSRM optimization entirely
    -- and carries no leg distance -- see `reoptimize_route`.
    excluded INTEGER NOT NULL DEFAULT 0,
    -- 1 when the driver placed this stop's pin by hand (the pin-drop sheet).
    -- A hand-placed pin outranks anything a geocoder has to say about the
    -- address, so `recheck_addresses` leaves it alone: the driver stood in
    -- front of the building and told us where it is.
    pinned INTEGER NOT NULL DEFAULT 0,
    -- What happened at the door: 'delivered', 'notHome' or 'toLager'. NULL is
    -- an open stop -- or one ticked before this column existed, which reads
    -- as delivered through its `delivered` bit (see `effective_outcome`).
    -- `delivered` stays alongside as the summary every count already reads.
    outcome TEXT,
    -- When the driver said so. NULL on an open stop.
    settled_at TEXT,
    -- The customer's own number, from the Zusteller-Portal or typed in --
    -- distinct from one merely mentioned in `notiz`.
    telefon TEXT,
    -- How many physical parcels this delivery is: the portal's bundle count.
    -- NULL on every stop not loaded from the portal.
    paket_count INTEGER,
    -- The house number's entrance, where the register has one: what a
    -- navigation app is sent to. NULL outside Vienna and until looked up.
    entrance_lat REAL,
    entrance_lon REAL,
    -- NULL = exact match (or a human placed the pin). 'street'/'district'
    -- mean geocoding only found an approximate fallback location — see
    -- `Precision` and `geocode_address`. Surfaced in the UI so a driver knows
    -- to double check before setting off, instead of an approximation
    -- silently pretending to be precise.
    location_precision TEXT
);

CREATE TABLE IF NOT EXISTS geocode_cache (
    query TEXT PRIMARY KEY,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    display_name TEXT,
    precision TEXT NOT NULL DEFAULT 'exact',
    -- Unix seconds this row was (last) written. Only exact answers are
    -- kept and served -- see `cache_lookup`.
    cached_at INTEGER
);

-- Addresses that every geocoder confidently reported as not existing.
-- Without this, the one flow that's *guaranteed* to resubmit a failed
-- address — a list import, which deliberately skips deletions until
-- everything resolves, so the driver has to paste again — pays the full
-- Wien-OGD + two throttled Nominatim + district-fallback round trips for
-- that same dead address on every single retry. `checked_at` is unix
-- seconds; entries expire (see GEOCODE_MISS_TTL_SECS) so a genuinely new
-- building that gets registered tomorrow isn't blacklisted forever.
CREATE TABLE IF NOT EXISTS geocode_miss (
    query TEXT PRIMARY KEY,
    checked_at INTEGER NOT NULL
);

-- Every single stop query in this app filters by `route_id` (usually
-- ordering by `order_index` on top of it). Without this, SQLite has no
-- choice but a full scan of every stop of every route ever created for
-- each of those — cheap today, needlessly linear in the app's whole
-- history forever after.
CREATE INDEX IF NOT EXISTS idx_stops_route_order ON stops(route_id, order_index);

-- The few things this server remembers that are not a route: today, the
-- Zusteller-Portal login.
-- Who may use the app. Every route belongs to one of them (`routes.user_id`)
-- and nobody sees another's. The portal login is each driver's own, kept on
-- their row once they have entered it.
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    portal_username TEXT,
    portal_password TEXT
);

-- One row per signed-in browser. The token is the cookie's value.
CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_seen INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"#;

fn init_db(path: &FsPath) -> Result<(), AppError> {
    let conn = open_db(path)?;
    conn.execute_batch(SCHEMA)?;

    // Safe migration for a database created before `location_precision` /
    // `precision` existed — CREATE TABLE IF NOT EXISTS above is a no-op on
    // an existing table, so add the columns by hand if they're missing.
    let stop_cols: HashSet<String> = conn
        .prepare("PRAGMA table_info(stops)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<Result<_, _>>()?;
    if !stop_cols.contains("location_precision") {
        conn.execute("ALTER TABLE stops ADD COLUMN location_precision TEXT", [])?;
    }
    if !stop_cols.contains("excluded") {
        conn.execute("ALTER TABLE stops ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0", [])?;
    }
    if !stop_cols.contains("pinned") {
        conn.execute("ALTER TABLE stops ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0", [])?;
    }
    if !stop_cols.contains("outcome") {
        conn.execute("ALTER TABLE stops ADD COLUMN outcome TEXT", [])?;
    }
    if !stop_cols.contains("settled_at") {
        conn.execute("ALTER TABLE stops ADD COLUMN settled_at TEXT", [])?;
    }
    if !stop_cols.contains("telefon") {
        conn.execute("ALTER TABLE stops ADD COLUMN telefon TEXT", [])?;
    }
    if !stop_cols.contains("entrance_lat") {
        conn.execute_batch("ALTER TABLE stops ADD COLUMN entrance_lat REAL; ALTER TABLE stops ADD COLUMN entrance_lon REAL;")?;
    }
    if !stop_cols.contains("paket_count") {
        conn.execute("ALTER TABLE stops ADD COLUMN paket_count INTEGER", [])?;
    }
    let route_cols: HashSet<String> = conn
        .prepare("PRAGMA table_info(routes)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<Result<_, _>>()?;
    if !route_cols.contains("here_at") {
        conn.execute_batch(
            "ALTER TABLE routes ADD COLUMN here_lat REAL; \
             ALTER TABLE routes ADD COLUMN here_lon REAL; \
             ALTER TABLE routes ADD COLUMN here_at INTEGER;",
        )?;
    }
    if !route_cols.contains("hand_ordered") {
        conn.execute("ALTER TABLE routes ADD COLUMN hand_ordered INTEGER NOT NULL DEFAULT 0", [])?;
    }
    if !route_cols.contains("ladeliste_mode") {
        conn.execute("ALTER TABLE routes ADD COLUMN ladeliste_mode TEXT", [])?;
    }
    if !route_cols.contains("departed_at") {
        conn.execute("ALTER TABLE routes ADD COLUMN departed_at TEXT", [])?;
    }
    if !route_cols.contains("user_id") {
        conn.execute("ALTER TABLE routes ADD COLUMN user_id INTEGER REFERENCES users(id) ON DELETE CASCADE", [])?;
    }

    // The administrator. Its password comes from the environment,
    // `EAR_ADMIN_PASSWORD`, and is written onto the account on every start
    // it differs from what is stored -- so there is always one account that
    // can get in and make the others, including after a database has been
    // replaced, and changing the password is changing one setting. What is
    // stored is its hash.
    //
    // Without the variable an admin that already exists keeps the password
    // it has. One that does not exist yet is created locked: nobody can sign
    // in as it until the variable is set, which is said in the log rather
    // than left to be found out at the login screen.
    let existing: Option<String> = conn
        .query_row("SELECT password_hash FROM users WHERE username = ?1", params![ADMIN_USERNAME], |r| r.get(0))
        .optional()?;
    let configured = std::env::var("EAR_ADMIN_PASSWORD").ok().filter(|p| !p.is_empty());
    let admin_hash = match (&configured, &existing) {
        // Already what is stored: hashing again would only change the salt.
        (Some(password), Some(hash)) if verify_password(password, hash) => None,
        (Some(password), _) => Some(hash_password(password)?),
        (None, Some(_)) => None,
        (None, None) => {
            tracing::warn!("EAR_ADMIN_PASSWORD is not set -- the admin account exists but nobody can sign in as it until it is");
            Some(hash_password(&new_session_token())?)
        }
    };
    conn.execute(
        "INSERT INTO users (username, password_hash, is_admin, created_at) VALUES (?1, COALESCE(?2, ''), 1, ?3) \
         ON CONFLICT(username) DO UPDATE SET password_hash = COALESCE(?2, password_hash), is_admin = 1",
        params![ADMIN_USERNAME, admin_hash, now_iso()],
    )?;
    let admin_id: i64 = conn.query_row("SELECT id FROM users WHERE username = ?1", params![ADMIN_USERNAME], |r| r.get(0))?;
    // Everything from before there were accounts belongs to the admin: the
    // tours, and the portal login the server used to keep for everybody.
    conn.execute("UPDATE routes SET user_id = ?1 WHERE user_id IS NULL", params![admin_id])?;
    for (key, column) in [("portal_username", "portal_username"), ("portal_password", "portal_password")] {
        conn.execute(
            &format!("UPDATE users SET {column} = (SELECT value FROM settings WHERE key = ?1) \
                      WHERE id = ?2 AND {column} IS NULL AND EXISTS (SELECT 1 FROM settings WHERE key = ?1)"),
            params![key, admin_id],
        )?;
    }
    conn.execute("DELETE FROM settings WHERE key IN ('portal_username', 'portal_password')", [])?;

    let cache_cols: HashSet<String> = conn
        .prepare("PRAGMA table_info(geocode_cache)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<Result<_, _>>()?;
    if !cache_cols.contains("precision") {
        conn.execute("ALTER TABLE geocode_cache ADD COLUMN precision TEXT NOT NULL DEFAULT 'exact'", [])?;
    }
    if !cache_cols.contains("cached_at") {
        conn.execute("ALTER TABLE geocode_cache ADD COLUMN cached_at INTEGER", [])?;
        // Backfilled to "now", not left NULL: a pre-existing approximate
        // entry's real age is unknown, and treating unknown as "ancient" —
        // NULL/0 — would expire every one of them on the very next lookup
        // after an upgrade, undoing the whole point of a persistent cache
        // for every driver's route the moment this migration runs. Starting
        // the TTL fresh from "now" is the conservative reading of an
        // unknown age.
        conn.execute(
            "UPDATE geocode_cache SET cached_at = ?1 WHERE cached_at IS NULL",
            params![chrono::Utc::now().timestamp()],
        )?;
    }

    // One-time geocode-cache invalidation, bumped whenever the resolver
    // itself learns to place an address better than the cached answer did.
    //
    // `exact` cache rows never expire on their own (see `cache_lookup`) —
    // correctly, since a confirmed door doesn't move. But when the *resolver*
    // improves, every one of those rows is a confidently-wrong answer that
    // would outlive the fix forever: version 2 is the sub-address work (see
    // `wien_ogd_geocode`), which resolves a Stiege to its own staircase and a
    // Kleingarten-Parzelle to its own plot instead of to whatever the bare
    // housenumber answers to. The whole cache is cleared rather than the rows
    // guessed to be affected: which keys those are depends on how each
    // address happened to be typed, and re-resolving a Vienna address costs
    // one unthrottled call to the register.
    //
    // Guarded by `user_version`, so it happens once per upgrade rather than
    // on every restart. Only the *cache* is cleared — stops already on a
    // route keep the coordinates they were created with until something
    // re-geocodes them (editing the address, or a JSON re-import). Moving a
    // live route's pins out from under a driver at startup is not this
    // function's call to make.
    //
    // 3: the register's answer is matched the way the iOS app matches it --
    // umlauts and punctuation folded, one letter of slack on the street name,
    // lettered houses, Haus/Kleingarten/Obj. doors, and a neighbouring number
    // ("8B" for "8") no longer taken as exact.
    const GEOCODER_GENERATION: i64 = 3;
    let cache_generation: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if cache_generation < GEOCODER_GENERATION {
        let cleared = conn.execute("DELETE FROM geocode_cache", [])?;
        conn.pragma_update(None, "user_version", GEOCODER_GENERATION)?;
        if cleared > 0 {
            tracing::info!(cleared, "cleared the geocode cache so addresses re-resolve with the sub-address-aware lookup");
        }
    }

    // The warehouse stop was originally written as "Oberlaa Straße 298",
    // which isn't a real street name — the actual one is "Oberlaaer
    // Straße". It's cosmetic in the app itself (the coordinates were
    // always right) but not in the "In Maps öffnen" link, which hands the
    // stored text to the phone's own Maps app to geocode from scratch and
    // gets a dead search for it. Fix it in place on routes created before
    // that was corrected.
    conn.execute(
        "UPDATE stops SET strasse = 'Oberlaaer Straße 298' WHERE kind = 'via' AND strasse = 'Oberlaa Straße 298'",
        [],
    )?;

    // Expired negative-geocode entries are dead weight: past their TTL they
    // are skipped anyway (see `miss_lookup`), so they only ever sit there.
    // Cleared at startup rather than on a timer — this table gains at most
    // a handful of rows a day, and a restart is a more than frequent enough
    // broom.
    //
    // `geocode_cache` is deliberately *not* pruned alongside it: a
    // successful geocode stays true, and every row discarded there is a
    // throttled round trip to a shared public service that has to be paid
    // again. It grows with the number of distinct addresses this service
    // has ever delivered to, which is a number of rows, not a problem.
    let expired = conn.execute(
        "DELETE FROM geocode_miss WHERE checked_at < ?1",
        params![chrono::Utc::now().timestamp() - GEOCODE_MISS_TTL_SECS],
    )?;
    if expired > 0 {
        tracing::debug!(expired, "pruned expired geocode misses");
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Geocoding — Nominatim (nominatim.openstreetmap.org), OpenStreetMap's own
// geocoder. Real, live, global address data instead of a static export
// that's stale the day it's built and was never going to cover every
// address anyway.
// ---------------------------------------------------------------------

/// Sent on every outbound call to a shared public service (geocoders and
/// OSRM's public fallback alike). Nominatim's usage policy requires a
/// calling application to identify itself so a misbehaving client can be
/// traced/blocked individually instead of the shared server being locked
/// down for everyone; Wien-OGD doesn't require it, but there's no reason to
/// be anonymous there either. The public OSRM demo server goes further and
/// outright rejects a request with no `User-Agent` at all (403) — reqwest
/// sends none by default, so without this header `osrm_get`'s fallback to
/// it would fail every single time, not just when the primary is down too.
const UPSTREAM_USER_AGENT: &str = "EAR-Routing/1.0 (local delivery route planner)";

fn geocode_error_not_found(query: &str) -> AppError {
    AppError::Geocode {
        status: 422,
        code: "address_not_found".into(),
        plz: None,
        message: format!("Adresse nicht automatisch gefunden: {}.", query),
    }
}

/// The register knows this address, but under a different district than the
/// one the stop was entered with.
///
/// This is the most common way a stop ends up somewhere wrong, and it is a
/// data-entry slip rather than a geocoding failure: Favoritenstraße runs
/// through the 4th, 5th and 10th, several districts have a Hauptstraße, and
/// the district is a dropdown that is easy to leave on whatever the previous
/// stop used. Every lookup strategy then correctly refuses to place the
/// address — it genuinely isn't in the district it was filed under — and
/// without this the driver just gets a vague district-centre pin and no idea
/// why. Naming the right district turns that into a one-tap fix.
fn geocode_error_wrong_district(query: &str, actual_plz: &str) -> AppError {
    let bezirk = actual_plz
        .get(1..3)
        .and_then(|d| d.parse::<u32>().ok())
        .map(|n| format!("{n}. Bezirk"))
        .unwrap_or_else(|| actual_plz.to_string());
    AppError::Geocode {
        status: 422,
        code: "wrong_district".into(),
        plz: Some(actual_plz.to_string()),
        message: format!("„{query}\" liegt laut Adressregister im {bezirk} ({actual_plz}), nicht im gewählten Bezirk. Bitte Bezirk prüfen."),
    }
}

/// The geocoders themselves are down/unreachable — a different situation
/// from "this address doesn't exist", and one the frontend handles the same
/// productive way (offering the manual pin-drop sheet) as long as it can
/// tell the two apart, which is what the `geocode_unavailable` code is for.
/// Returned as 503 rather than a bare 500 because it is explicitly a
/// temporary upstream failure, not a bug in this app.
fn geocode_error_unavailable() -> AppError {
    AppError::Geocode {
        status: 503,
        code: "geocode_unavailable".into(),
        plz: None,
        message: "Geocoding-Dienst nicht erreichbar. Standort bitte manuell setzen.".into(),
    }
}

/// A remembered answer, exact ones only.
///
/// A confirmed door does not move, so remembering one costs nothing and
/// saves the lookup on every daily load of the same customers. An
/// approximation is the opposite: an admitted guess that a better lookup --
/// or a fix to this server's own matching -- should replace the next time it
/// is asked. Kept for thirty days, as it used to be, an "≈" outlived the day
/// the lookup learned to place the address. Rows written before this rule
/// are simply not served.
fn cache_lookup(conn: &Connection, key: &str) -> Result<Option<(f64, f64, String, Precision)>, AppError> {
    let row = conn
        .query_row(
            "SELECT lat, lon, display_name, precision FROM geocode_cache WHERE query = ?1",
            params![key],
            |r| {
                Ok((
                    r.get::<_, f64>(0)?,
                    r.get::<_, f64>(1)?,
                    r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    parse_precision(&r.get::<_, String>(3)?),
                ))
            },
        )
        .optional()?;
    Ok(row.filter(|hit| hit.3 == Precision::Exact))
}

/// Remembers an exact answer. Anything less is not kept -- see `cache_lookup`.
fn cache_store(conn: &Connection, key: &str, lat: f64, lon: f64, display_name: &str, precision: Precision) -> Result<(), AppError> {
    if precision != Precision::Exact {
        return Ok(());
    }
    conn.execute(
        "INSERT OR REPLACE INTO geocode_cache (query, lat, lon, display_name, precision, cached_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![key, lat, lon, display_name, precision.as_str(), chrono::Utc::now().timestamp()],
    )?;
    Ok(())
}

fn parse_precision(s: &str) -> Precision {
    match s {
        "street" => Precision::Street,
        "district" => Precision::District,
        _ => Precision::Exact,
    }
}

/// How long a "no geocoder knows this address" verdict is trusted before
/// it's worth asking again. Long enough to make a driver's retry loop (fix
/// one typo, resubmit the whole list) cheap, short enough that a building
/// newly added to Vienna's register resolves the same working day.
const GEOCODE_MISS_TTL_SECS: i64 = 6 * 60 * 60;

/// True if this exact query was recently confirmed unresolvable. Only ever
/// records a *definitive* negative — never an upstream outage, which is a
/// transient condition reported separately (see `geocode_error_unavailable`)
/// and must not poison later lookups of a perfectly valid address.
fn miss_lookup(conn: &Connection, key: &str) -> Result<bool, AppError> {
    let checked_at: Option<i64> = conn
        .query_row("SELECT checked_at FROM geocode_miss WHERE query = ?1", params![key], |r| r.get(0))
        .optional()?;
    Ok(match checked_at {
        Some(ts) => chrono::Utc::now().timestamp() - ts < GEOCODE_MISS_TTL_SECS,
        None => false,
    })
}

fn miss_store(conn: &Connection, key: &str) -> Result<(), AppError> {
    conn.execute(
        "INSERT OR REPLACE INTO geocode_miss (query, checked_at) VALUES (?1, ?2)",
        params![key, chrono::Utc::now().timestamp()],
    )?;
    Ok(())
}

/// Drops a stale negative for an address that has since started resolving
/// — otherwise a hit stored today would sit behind an expired-but-present
/// miss row forever, and the row would never be cleaned up at all.
fn miss_clear(conn: &Connection, key: &str) -> Result<(), AppError> {
    conn.execute("DELETE FROM geocode_miss WHERE query = ?1", params![key])?;
    Ok(())
}

// ---------------------------------------------------------------------
// Vienna's own official address register (data.wien.gv.at "Adressservice
// Wien" / OGD Address Web Service) — tried *before* Nominatim. It's the
// city's own ground-truth building register, not community-mapped OSM
// data, so it covers real, currently-occupied addresses that OSM/Nominatim
// sometimes simply hasn't caught up on yet (a genuine building with no
// volunteer having mapped its housenumber point). Vienna-only, which is
// exactly this app's scope, so it's a strictly better primary source here;
// Nominatim stays as the fallback for anything it doesn't recognize (a
// service outage, or on the rare chance a query isn't in its register).
// Docs: https://digitales.wien.gv.at/adressservice-doku
// ---------------------------------------------------------------------
#[derive(Deserialize)]
struct OgdFeatureCollection {
    #[serde(default)]
    features: Vec<OgdFeature>,
}

#[derive(Deserialize)]
struct OgdFeature {
    geometry: OgdGeometry,
    properties: OgdProperties,
}

#[derive(Deserialize)]
struct OgdGeometry {
    coordinates: [f64; 2], // [lon, lat]
}

#[derive(Deserialize)]
struct OgdProperties {
    #[serde(rename = "StreetName")]
    street_name: Option<String>,
    #[serde(rename = "PostalCode")]
    postal_code: Option<String>,
    #[serde(rename = "Kategorie")]
    kategorie: Option<String>,
    #[serde(rename = "Adresse")]
    adresse: Option<String>,
    #[serde(rename = "Ranking")]
    ranking: Option<f64>,
    #[serde(rename = "StreetNumber")]
    street_number: Option<String>,
    /// "23" -- present even on the answers that carry no `PostalCode`.
    #[serde(rename = "Bezirk", default, deserialize_with = "text_or_number")]
    bezirk: Option<String>,
}

/// A field the register writes as text, read without minding if it ever
/// writes it as a number: one answer's odd field must not cost the lookup.
fn text_or_number<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    Ok(match Option::<Value>::deserialize(deserializer)? {
        Some(Value::String(s)) => Some(s),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    })
}

/// What the caller knows about the address's sub-address (Stiege,
/// Kleingarten-Parzelle, Top — see `text::housenumber_with_sub`) and how
/// strictly the register's answer has to honour it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SubCheck<'a> {
    /// The address has no sub-address; anything the register returns for the
    /// housenumber is as precise as this address gets.
    Absent,
    /// Accept *only* an answer carrying this sub-address. Used for the first
    /// attempt, the one that can actually place the van at the right
    /// staircase or plot.
    Require(&'a str),
    /// Accept whatever the register returns, but if it carries a *different*
    /// sub-address than this one, the point is a neighbour rather than the
    /// address asked for — precise-looking, and wrong. Used for the
    /// housenumber-only fallback, where it downgrades the result to
    /// `Precision::Street` so the app shows its "≈" warning instead of
    /// presenting a guess as a confirmed door.
    Downgrade(&'a str),
}

impl<'a> SubCheck<'a> {
    /// The sub-address an answer must carry to be accepted at all.
    fn required(self) -> Option<&'a str> {
        match self {
            SubCheck::Require(sub) => Some(sub),
            SubCheck::Absent | SubCheck::Downgrade(_) => None,
        }
    }

    /// Whether `adresse` (as the register spells it) is a *different*
    /// sub-address than the one asked for — the "confidently wrong
    /// neighbour" case.
    fn is_wrong_neighbour(self, adresse: Option<&str>) -> bool {
        let SubCheck::Downgrade(want) = self else { return false };
        adresse
            .and_then(text::sub_address_of)
            .is_some_and(|got| got != want)
    }
}

// What the picking below reads off one answer. The same rules as the iOS
// app's `Geocoder`, which were worked out against the live register on some
// nine hundred of the round's addresses; the two are kept alike on purpose.

fn ogd_ranking(f: &OgdFeature) -> f64 {
    f.properties.ranking.unwrap_or(f64::MAX)
}

/// The house number an answer is for, as the entrance layer files it.
fn ogd_number(f: &OgdFeature) -> Option<String> {
    f.properties.street_number.as_deref().and_then(entrance_number)
}

/// The answer's own sub-address text, if it has one.
fn ogd_tail(f: &OgdFeature) -> Option<String> {
    f.properties.adresse.as_deref().and_then(text::sub_address_tail)
}

fn ogd_street_key(f: &OgdFeature) -> String {
    text::address_match_key(f.properties.street_name.as_deref().unwrap_or(""))
}

/// Metres between two answers, near enough for telling one door from another.
fn ogd_metres(a: &OgdFeature, b: &OgdFeature) -> f64 {
    let ([alon, alat], [blon, blat]) = (a.geometry.coordinates, b.geometry.coordinates);
    let per_degree = 111_320.0;
    let dx = (alon - blon) * per_degree * alat.to_radians().cos();
    let dy = (alat - blat) * per_degree;
    (dx * dx + dy * dy).sqrt()
}

/// The house numbers an answer may carry and still be the one asked for:
/// "12" -- and "12a" too when the letter was typed apart from it,
/// "Hauptstraße 12 A" or "12/A/3". Without that the register's own "12A" is
/// a neighbouring number. The number as typed comes first.
fn asked_numbers(number: Option<&str>, segments: &[String]) -> Vec<String> {
    let Some(number) = number else { return Vec::new() };
    let mut out = vec![number.to_string()];
    if number.ends_with(|c: char| c.is_ascii_digit()) {
        if let Some(first) = segments.first().and_then(|s| s.split_whitespace().next()) {
            let mut letters = first.chars();
            if let (Some(letter), None) = (letters.next(), letters.next()) {
                if letter.is_alphabetic() {
                    out.push(format!("{number}{}", letter.to_lowercase()));
                }
            }
        }
    }
    out
}

/// Picks the one usable feature out of an OGD response.
///
/// Candidates are *filtered first, ranked second*, and the order matters:
/// the postcode must match exactly and the returned street name must be the
/// street we actually asked for, because a query with no real match — a
/// typo, or a genuinely unregistered street — still comes back populated,
/// with the closest *different* street by string similarity sometimes
/// carrying a deceptively low `Ranking`. Only once those checks have thrown
/// out everything that isn't the requested address does `Ranking` decide,
/// and only among what's left: its scale isn't uniform across match types
/// (an exact hit is ~0, "same street, wrong housenumber" jumps to the
/// hundreds), so it can order candidates but must never be what selects one.
///
/// The street is compared through `address_match_key`, because the register
/// is tolerant on input and canonical on output: asked for "Dr. Karl
/// Lueger-Platz 1" it answers with the right building under the name
/// "Dr.-Karl-Lueger-Platz", and a raw comparison threw that away over two
/// hyphens.
///
/// One letter of slack on the street name, and only as a second choice:
/// "Pfenningeldgasse 9" is how the office's list spells Pfenninggeldgasse.
/// Accepted only when no candidate matches exactly, only in the right
/// postcode, only on a name long enough that one letter is a typo rather
/// than another street, and only when the register itself placed the house
/// number (`Ranking` < 1).
///
/// The register leaves `PostalCode` empty on some answers -- "Breitenfurter
/// Straße 390 Haus 2" -- while still giving their `Bezirk`. Those count as
/// in the district when the `Bezirk` is the one the postcode belongs to.
///
/// `segments` and `numbers` are what the driver typed after the street: see
/// `pick_among`.
fn pick_ogd_feature<'f>(
    features: &'f [OgdFeature],
    plz: &str,
    street_key: &str,
    require_sub: Option<&str>,
    segments: &[String],
    numbers: &[String],
) -> Option<&'f OgdFeature> {
    let bezirk: Option<u32> = is_valid_vienna_plz(plz).then(|| plz.get(1..3).and_then(|d| d.parse().ok())).flatten();
    let in_district: Vec<&OgdFeature> = features
        .iter()
        .filter(|f| match f.properties.postal_code.as_deref().map(str::trim).filter(|c| !c.is_empty()) {
            Some(code) => code == plz,
            None => {
                bezirk.is_some()
                    && f.properties.bezirk.as_deref().and_then(|b| b.trim().parse::<u32>().ok()) == bezirk
            }
        })
        .collect();
    let exact: Vec<&OgdFeature> = in_district.iter().copied().filter(|f| ogd_street_key(f) == street_key).collect();
    if let Some(hit) = pick_among(&exact, require_sub, segments, numbers) {
        return Some(hit);
    }
    let near: Vec<&OgdFeature> = in_district
        .iter()
        .copied()
        .filter(|f| ogd_ranking(f) < 1.0 && text::is_one_typo_apart(&ogd_street_key(f), street_key))
        .collect();
    pick_among(&near, require_sub, segments, numbers)
}

/// The answer for the door asked for, among candidates already known to be
/// on the right street in the right district.
///
/// With a sub-address required and no answer carrying it as written, the
/// same door written without its label is looked for: "Mühlweg 4/2/5" for
/// "Gruppe 2 Parz. 5", "Salzergasse 36/1" for "Obj. 1", "57/A/1/1" for "Haus
/// A/1". Compared on the bare numbers and letters, first of the first part
/// after the housenumber, then of the first two -- and only accepted when
/// that leaves exactly one door, because a site with an "Obj. 1" and a "Pav.
/// 1" cannot be told apart from "/1". On the number asked for only: the
/// register ranks "8B Obj. 1" as a match for "8/1".
fn pick_among<'f>(
    features: &[&'f OgdFeature],
    require_sub: Option<&str>,
    segments: &[String],
    numbers: &[String],
) -> Option<&'f OgdFeature> {
    // The number asked for, before a neighbour the register ranks above it.
    // Asked for "Rabengasse 3" it puts "3A" first, at 0.00000001, and the
    // Rabenhof itself -- "3-9" -- second. Taken as the best answer overall,
    // the pin went on the house next door and was then marked "≈" for
    // carrying the wrong number, with the right house in the same answer.
    // Only when no answer carries the number is the best of the rest taken
    // -- and `is_uncertain_door` says so.
    let own: Vec<&OgdFeature> = if numbers.is_empty() {
        Vec::new()
    } else {
        features.iter().copied().filter(|f| ogd_number(f).is_some_and(|n| numbers.contains(&n))).collect()
    };
    let hit = pick_exact_sub(&own, require_sub, segments).or_else(|| pick_exact_sub(features, require_sub, segments));
    if hit.is_some() {
        return hit;
    }
    require_sub?;
    let placed: Vec<&OgdFeature> = features
        .iter()
        .copied()
        .filter(|f| ogd_ranking(f) < 1.0 && (numbers.is_empty() || ogd_number(f).is_some_and(|n| numbers.contains(&n))))
        .collect();
    for n in 1..=2 {
        if segments.len() < n {
            continue;
        }
        let wanted = text::sub_address_tokens(&segments[..n].join("/"));
        if wanted.is_empty() {
            continue;
        }
        let hits: Vec<&OgdFeature> = placed
            .iter()
            .copied()
            .filter(|f| ogd_tail(f).is_some_and(|tail| text::sub_address_tokens(&tail) == wanted))
            .collect();
        // The register lists some doors twice under two spellings, a few
        // metres apart. One door, not two to choose between.
        if let Some(first) = hits.first() {
            if hits.iter().all(|h| ogd_metres(h, first) < 25.0) {
                return hits.iter().copied().min_by(|a, b| ogd_ranking(a).total_cmp(&ogd_ranking(b)));
            }
        }
    }
    None
}

fn pick_exact_sub<'f>(
    features: &[&'f OgdFeature],
    require_sub: Option<&str>,
    segments: &[String],
) -> Option<&'f OgdFeature> {
    // "Breitenfurter Straße 510" has both a "Haus 2" and a Stiege "/2",
    // which key alike. A driver who wrote "Haus" meant the house.
    let says_haus = segments.first().is_some_and(|s| s.to_lowercase().contains("haus"));
    let label_disagrees =
        |f: &OgdFeature| ogd_tail(f).unwrap_or_default().to_lowercase().contains("haus") != says_haus;
    features
        .iter()
        .copied()
        // A sub-address query only counts if the register came back with
        // *that* sub-address. Asked for one it has never heard of, the
        // service answers with a neighbour at a near-zero `Ranking` — which
        // would otherwise be accepted as an exact match and quietly point
        // the driver at the wrong staircase, or the wrong garden plot 130 m
        // down the lane. Compared through `sub_address_of` rather than as
        // raw text, because the register writes what the driver typed as
        // "9/Parz.68" as "Großfeldstraße 9 Parz. 68".
        //
        // And only on the house number asked for (`Ranking` < 1).
        // "Pfenninggeldgasse 9/2/15": number 9 has no Stiege 2, the house
        // across the street, 6-12, does -- and the register offers "6-12/2",
        // ranked in the thousands for the wrong number.
        .filter(|f| match require_sub {
            None => true,
            Some(want) => {
                ogd_ranking(f) < 1.0
                    && f.properties.adresse.as_deref().and_then(text::sub_address_of).is_some_and(|got| got == want)
            }
        })
        .min_by(|a, b| {
            let disagrees = |f: &OgdFeature| require_sub.is_some() && label_disagrees(f);
            disagrees(a).cmp(&disagrees(b)).then(ogd_ranking(a).total_cmp(&ogd_ranking(b)))
        })
}

/// Whether an answer the register ranked as a match is still not provably
/// the door that was asked for -- so it goes to the driver as "≈" to check,
/// not as a confident pin.
///
/// Two ways that happens. The register ranks a neighbouring *number* as a
/// match: asked for "Doningasse 8" it answers "Doningasse 8B" at a ranking of
/// 0.00000001. And the driver asked for a door the register could not single
/// out -- "Wolkersbergenstraße 1/1", where number 1 is an "Obj. 1" and a
/// "Pav. 1" 130 m apart -- and the answer is the bare number, a point that is
/// neither. A number the register does not split into buildings stays exact:
/// the Stiegen of one Gemeindebau stand a few dozen metres from the number's
/// own point, and "129/5/12" with its Stock and Tür is still that house.
///
/// And a third, since the number asked for is taken ahead of a neighbour the
/// register ranks first (see `pick_among`): the driver named no door
/// (`no_door_named`), and what was taken in the neighbour's place is one
/// building of several far apart -- "Doningasse 8", answered "8B" first, where
/// number 8 is an "Obj. 1" and a Stiege 3 sixty metres from it. That stays
/// "≈", as it was when the neighbour was taken.
fn is_uncertain_door(
    chosen: &OgdFeature,
    features: &[OgdFeature],
    street_key: &str,
    numbers: &[String],
    sub_asked: bool,
    no_door_named: bool,
) -> bool {
    if numbers.is_empty() {
        return false;
    }
    if ogd_number(chosen).is_some_and(|theirs| !numbers.contains(&theirs)) {
        return true;
    }
    let outranked = || {
        features.iter().any(|f| {
            ogd_street_key(f) == street_key
                && ogd_number(f).is_some_and(|n| !numbers.contains(&n))
                && ogd_ranking(f) < ogd_ranking(chosen)
        })
    };
    let in_doubt = if ogd_tail(chosen).is_some() { no_door_named && outranked() } else { sub_asked };
    if !in_doubt {
        return false;
    }
    features.iter().any(|f| {
        ogd_number(f).is_some_and(|n| numbers.contains(&n))
            && ogd_street_key(f) == street_key
            && ogd_ranking(f) < 1.0
            && ogd_tail(f).is_some()
            && ogd_metres(chosen, f) > 40.0
    })
}

/// One raw Wien-OGD lookup: the request, and the parse. `None` when the
/// register could not be asked or its reply not read, and an empty list when
/// it answered that it has nothing. Never an error: that is what lets
/// `geocode_address` treat the register as a first attempt rather than a hard
/// dependency — an outage the night before a route is due degrades to the
/// Nominatim pipeline, not a failure.
///
/// Split out from `wien_ogd_search_one` so the *filtering* — which feature
/// counts as the address we asked for — can be done more than one way
/// against the same response shape (see `wien_ogd_district_hint`, which asks
/// the same question with the postcode filter deliberately removed).
async fn wien_ogd_fetch(state: &AppState, query: &str) -> Option<Vec<OgdFeature>> {
    // Only genuine failure modes (network error, a non-2xx status, a body
    // that doesn't even parse) are logged here — a "no match" (an empty
    // body, or a body with no feature surviving the callers' filters) is the
    // ordinary, expected outcome for most queries and would just be log
    // spam. Without this distinction, none of the real failure modes were
    // logged at all: a broken/misconfigured Wien-OGD endpoint degraded the
    // app to Nominatim-only geocoding silently, indistinguishable in the
    // logs from every query simply not being in Vienna's register.
    let resp = match state
        .http
        .get(&state.upstreams.wien_ogd)
        .query(&[("Address", query), ("crs", "EPSG:4326")])
        .header(reqwest::header::USER_AGENT, UPSTREAM_USER_AGENT)
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(error = %e, query, "wien ogd unreachable, falling back to nominatim");
            return None;
        }
    };
    if !resp.status().is_success() {
        tracing::warn!(status = %resp.status(), query, "wien ogd returned an error status, falling back to nominatim");
        return None;
    }
    // A query with zero matches comes back as an HTTP 200 with a completely
    // empty body (not `{"features":[]}`) — has to be checked before handing
    // an empty string to the JSON parser. It is an answer, "none", and not a
    // failure.
    let body = match resp.text().await {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(error = %e, query, "wien ogd response body unreadable, falling back to nominatim");
            return None;
        }
    };
    if body.trim().is_empty() {
        return Some(Vec::new());
    }
    match serde_json::from_str::<OgdFeatureCollection>(&body) {
        Ok(parsed) => Some(parsed.features),
        Err(e) => {
            tracing::warn!(error = %e, query, "wien ogd response did not parse, falling back to nominatim");
            None
        }
    }
}

/// A resolved address: where, what the geocoder calls it, and how far the
/// point can be trusted.
type GeocodeHit = (f64, f64, String, Precision);

/// Turns the one feature the register chose into an answer -- the decision
/// about *how much to trust it*, and the coordinates that go with it.
fn ogd_result(best: &OgdFeature, query: &str, plz: &str, sub: SubCheck<'_>) -> Option<GeocodeHit> {
    let props = &best.properties;
    let precision = if props.kategorie.as_deref() == Some("Straßenname") {
        // The register answered with a street rather than a building.
        Precision::Street
    } else if sub.is_wrong_neighbour(props.adresse.as_deref()) {
        // The register knows this housenumber, but only as somebody else's
        // staircase or garden plot. Same street, same number, different
        // door — reported as the approximation it is.
        tracing::debug!(query, matched = ?props.adresse, "wien ogd matched a neighbouring sub-address, downgrading to street precision");
        Precision::Street
    } else if ogd_ranking(best) < 1.0 {
        // Genuine housenumber (and usually Stiege/Parzelle/Tür) match.
        Precision::Exact
    } else {
        // Real street, but the exact housenumber wasn't registered —
        // matched to the nearest one instead.
        Precision::Street
    };
    let [lon, lat] = best.geometry.coordinates;
    // `crs=EPSG:4326` is requested, but a service that ever ignored it would
    // hand back projected metres that look nothing like degrees — fall
    // through to Nominatim rather than storing a point in the middle of the
    // ocean as a confident "exact" match. The tight box, not the
    // country-wide one: this register only answers for Vienna.
    if !is_in_vienna(lat, lon) {
        tracing::warn!(lat, lon, query, "wien ogd returned out-of-range coordinates, ignoring");
        return None;
    }
    let display_name = match &props.adresse {
        Some(a) => format!("{a}, {plz} Wien"),
        None => format!("{query}, {plz} Wien"),
    };
    Some((lat, lon, display_name, precision))
}

/// One Vienna OGD address lookup. `None` for anything short of a verified
/// hit; `failed` is set when that was because the register could not be
/// asked at all.
async fn wien_ogd_search_one(
    state: &AppState,
    query: &str,
    plz: &str,
    sub: SubCheck<'_>,
    segments: &[String],
    numbers: &[String],
    failed: &mut bool,
) -> Option<GeocodeHit> {
    let Some(features) = wien_ogd_fetch(state, query).await else {
        *failed = true;
        return None;
    };
    let street_key = text::address_match_key(&text::street_name_only(query));
    let best = pick_ogd_feature(&features, plz, &street_key, sub.required(), segments, numbers)?;
    let hit = ogd_result(best, query, plz, sub)?;
    let (sub_asked, no_door_named) = (matches!(sub, SubCheck::Downgrade(_)), sub == SubCheck::Absent);
    if hit.3 == Precision::Exact && is_uncertain_door(best, &features, &street_key, numbers, sub_asked, no_door_named) {
        tracing::debug!(query, "wien ogd answer is not provably the door asked for, downgrading to street precision");
        return Some((hit.0, hit.1, hit.2, Precision::Street));
    }
    Some(hit)
}

/// Tries, in order of how precisely each form can place the van:
///   1. `"{street} {housenumber}/{sub-address}"`, when the address carries
///      a Stiege, Parzelle or Top — the register knows that staircase's or
///      plot's own door, tens to hundreds of metres from what the bare
///      housenumber answers to (see `text::housenumber_with_sub`).
///      Accepted only if the register really matched that sub-address (see
///      `SubCheck`).
///   2. The lettered house, when a letter was typed apart from the number:
///      "Töllergasse 26 A" and "26/B" are the houses 26A and 26B when the
///      register has them -- not house 26. Only an answer carrying that
///      lettered number is taken.
///   3. The simplified `"{street} {housenumber}"`. If the address *did*
///      carry a sub-address, an answer for somebody else's is downgraded to
///      `Precision::Street` rather than passed off as the right door.
///   4. The fuller normalized string, for an address that was never
///      "street + number" to begin with and which simplifying would only
///      have mangled.
///
/// Unlike the Nominatim path below, which pays a throttled ~1.1 s per
/// attempt, these are unthrottled calls to a service with no published
/// rate limit, so trying the most precise form first costs a few hundred
/// milliseconds on the addresses that have a sub-address and nothing at all
/// on the ones that don't.
///
/// The second value says the register could not be asked: no answer was
/// found and at least one of the calls failed outright. It may well have the
/// address.
async fn wien_ogd_geocode(state: &AppState, strasse: &str, plz: &str) -> (Option<GeocodeHit>, bool) {
    let mut failed = false;
    let hit = wien_ogd_search(state, strasse, plz, &mut failed).await;
    let unreachable = hit.is_none() && failed;
    (hit, unreachable)
}

async fn wien_ogd_search(state: &AppState, strasse: &str, plz: &str, failed: &mut bool) -> Option<GeocodeHit> {
    let normalized = normalize_strasse_text(strasse);
    let simplified = simplify_housenumber(&normalized);
    let sub = text::housenumber_with_sub(&normalized);
    let number = simplified.split(' ').next_back().and_then(entrance_number);
    let segments = text::sub_address_segments(&normalized);
    let numbers = asked_numbers(number.as_deref(), &segments);

    if let Some((query, key)) = &sub {
        let check = SubCheck::Require(key);
        if let Some(hit) = wien_ogd_search_one(state, query, plz, check, &segments, &numbers, failed).await {
            return Some(hit);
        }
    }
    if let Some(lettered) = numbers.get(1) {
        let query = format!("{} {}", text::street_name_only(&simplified), lettered.to_uppercase());
        let only = std::slice::from_ref(lettered);
        let hit = wien_ogd_search_one(state, &query, plz, SubCheck::Absent, &[], only, failed).await;
        if let Some(hit) = hit.filter(|hit| hit.3 == Precision::Exact) {
            return Some(hit);
        }
    }
    let fallback_check = match &sub {
        Some((_, key)) => SubCheck::Downgrade(key),
        None => SubCheck::Absent,
    };
    if let Some(hit) = wien_ogd_search_one(state, &simplified, plz, fallback_check, &[], &numbers, failed).await {
        return Some(hit);
    }
    if simplified != normalized {
        if let Some(hit) = wien_ogd_search_one(state, &normalized, plz, fallback_check, &[], &numbers, failed).await {
            return Some(hit);
        }
    }
    None
}

/// Which Vienna district the register actually files this street+number
/// under, when the answer is unambiguous.
///
/// Deliberately narrow: it asks the same question `wien_ogd_geocode` just
/// asked, minus the postcode filter, and speaks up only when *every*
/// candidate for the requested street agrees on one postcode that isn't the
/// one the stop was entered with. A street that genuinely runs through
/// several districts yields several postcodes and no hint at all — guessing
/// between them would be worse than the honest approximate pin the caller
/// otherwise falls back to.
async fn wien_ogd_district_hint(state: &AppState, normalized: &str, plz: &str) -> Option<String> {
    let simplified = simplify_housenumber(normalized);
    let our_street = text::address_match_key(&text::street_name_only(&simplified));
    let features = wien_ogd_fetch(state, &simplified).await?;
    let mut postcodes: HashSet<String> = HashSet::new();
    for f in features {
        let same_street = f
            .properties
            .street_name
            .as_deref()
            .is_some_and(|s| text::address_match_key(s) == our_street);
        if !same_street {
            continue;
        }
        if let Some(code) = f.properties.postal_code {
            postcodes.insert(code);
        }
    }
    if postcodes.len() != 1 {
        return None;
    }
    let only = postcodes.into_iter().next()?;
    (only != plz).then_some(only)
}

// Nominatim's usage policy: max ~1 request/second from a single client,
// enforced ourselves rather than trusting every call site to remember.
const NOMINATIM_MIN_INTERVAL: Duration = Duration::from_millis(1100);

#[derive(Deserialize)]
struct NominatimHit {
    lat: String,
    lon: String,
    display_name: String,
    #[serde(default)]
    address: Option<NominatimAddress>,
}

#[derive(Deserialize, Default)]
struct NominatimAddress {
    house_number: Option<String>,
    road: Option<String>,
    postcode: Option<String>,
}

/// Serializes calls to Nominatim's public server to at most one every
/// `NOMINATIM_MIN_INTERVAL`, blocking (async) callers rather than letting
/// concurrent geocode requests burst past the usage policy.
async fn nominatim_throttle(state: &AppState) {
    let mut last = state.nominatim_last.lock().await;
    if let Some(prev) = *last {
        let elapsed = prev.elapsed();
        if elapsed < NOMINATIM_MIN_INTERVAL {
            tokio::time::sleep(NOMINATIM_MIN_INTERVAL - elapsed).await;
        }
    }
    *last = Some(Instant::now());
}

/// One throttled Nominatim search, returning the raw top hit (or `None`
/// for no match — not an error). Nominatim's search is fuzzy free-text, so
/// callers that need to trust a *specific* field of the result (like the
/// district fallback below trusting the postal code) must check it
/// themselves — a query that partially fails to match doesn't reliably
/// come back empty, it can come back matching only the parts that did.
async fn nominatim_raw_search(state: &AppState, query: &str) -> Result<Option<NominatimHit>, AppError> {
    nominatim_throttle(state).await;

    // The underlying reqwest error text (connection internals, timeouts,
    // occasionally a local path) is logged for debugging but never handed
    // to the client — it describes our infrastructure, not anything the
    // caller can act on.
    let geocode_unreachable = |e: reqwest::Error| {
        tracing::error!(error = %e, "nominatim unreachable");
        geocode_error_unavailable()
    };
    let resp = state
        .http
        .get(&state.upstreams.nominatim_search)
        .query(&[
            ("q", query),
            ("format", "jsonv2"),
            ("limit", "1"),
            ("addressdetails", "1"),
            ("countrycodes", "at"),
        ])
        // Required by Nominatim's usage policy: identify the calling
        // application so misbehaving clients can be traced/blocked
        // individually instead of the shared server being locked down.
        .header(reqwest::header::USER_AGENT, UPSTREAM_USER_AGENT)
        .send()
        .await
        .map_err(geocode_unreachable)?
        .error_for_status()
        .map_err(geocode_unreachable)?;
    let hits: Vec<NominatimHit> = resp.json().await.map_err(|e| {
        tracing::error!(error = %e, "nominatim response parse failed");
        geocode_error_unavailable()
    })?;
    Ok(hits.into_iter().next())
}

/// Does a Nominatim hit actually describe the address we asked for?
///
/// The Wien-OGD path has always cross-checked the postcode and the street
/// name before trusting a result (see `pick_ogd_feature`), for a reason that
/// applies at least as strongly here: Nominatim's free-text search always
/// returns *something* plausible-looking. Without the same checks, the
/// fallback could — and did — accept:
///   - the right street name in the wrong district. Vienna has a
///     "Hauptstraße" in several of them, and the postcode in the query text
///     is a hint to Nominatim, not a filter, so asking for 1190 and being
///     handed the one in 1140 is a normal outcome. The stop then sits a
///     borough away from the customer, tagged `exact`.
///   - a different street entirely, matched by string similarity —
///     "Gentzstraße" for "Gentzgasse" — which is exactly the confident,
///     precise, wrong answer the OGD check exists to reject.
///
/// A hit that fails either check is treated as *no* hit, so the caller falls
/// through to its next strategy and ultimately to the district centroid,
/// which is honest about being an approximation and shows the driver a "≈"
/// badge rather than a wrong door.
///
/// Absent fields are not failures: a hit with no `road` at all cannot be
/// verified against a street, and is only ever accepted as
/// `Precision::District` anyway.
fn nominatim_hit_matches(hit: &NominatimHit, wanted_street_lower: &str, plz: &str) -> bool {
    if let Some(address) = &hit.address {
        if let Some(postcode) = address.postcode.as_deref() {
            if postcode.trim() != plz {
                tracing::debug!(postcode, plz, "nominatim hit is in a different district, ignoring");
                return false;
            }
        }
        if let Some(road) = address.road.as_deref() {
            let road_key = text::address_match_key(road);
            if road_key != wanted_street_lower {
                tracing::debug!(road, wanted = wanted_street_lower, "nominatim hit is a different street, ignoring");
                return false;
            }
        }
    }
    true
}

async fn nominatim_search_one(
    state: &AppState,
    query: &str,
    wanted_street_lower: &str,
    plz: &str,
) -> Result<Option<(f64, f64, String, Precision)>, AppError> {
    let Some(top) = nominatim_raw_search(state, query).await? else {
        return Ok(None);
    };
    if !nominatim_hit_matches(&top, wanted_street_lower, plz) {
        return Ok(None);
    }
    let (Ok(lat), Ok(lon)) = (top.lat.parse::<f64>(), top.lon.parse::<f64>()) else {
        return Err(AppError::Internal("Geocoding-Dienst: ungültige Koordinaten in der Antwort".into()));
    };
    // Nominatim's free-text search is fuzzy and country-wide (`countrycodes=at`
    // is as narrow as it gets): a Viennese street name that also exists in
    // Graz or Linz can come back as a confident top hit hundreds of
    // kilometres away. Treat anything outside the Vienna bounding box as no
    // match at all, so the caller falls through to its next strategy (the
    // fuller query, then the district centroid) instead of pinning a stop in
    // the wrong federal state.
    //
    // Which box depends on the postcode: a stop filed under 1210 is in Vienna
    // or it is a mistake, and the tight box is what catches that.
    if !is_plausible_for_plz(lat, lon, plz) {
        tracing::warn!(lat, lon, query, "nominatim hit outside the expected area, ignoring");
        return Ok(None);
    }
    let precision = match &top.address {
        Some(a) if a.house_number.is_some() => Precision::Exact,
        Some(a) if a.road.is_some() => Precision::Street,
        _ => Precision::District,
    };
    Ok(Some((lat, lon, top.display_name, precision)))
}

/// Geocode a Wien street/housenumber against Nominatim, OpenStreetMap's own
/// live geocoder — the real global address database, not a one-time local
/// export. Precision is inferred from how much of Nominatim's structured
/// address breakdown came back with the top hit (house number vs. only a
/// street vs. only a coarser area), so an approximate result still gets
/// flagged to the driver instead of silently passed off as exact. Only a
/// genuine no-match falls through to the frontend's manual pin-drop.
/// Where an address is -- or a refusal.
///
/// The middle of a district is not an answer. The lookup behind this can
/// fall back to one when it finds neither the house nor the street, and a
/// stop placed there used to go onto the tour with a small "≈" on its row:
/// easy to miss, and the route then drove to a point where nobody lives,
/// with every stop after it planned around the detour. So that fallback is
/// a failure here, the same as an address nobody knows -- the driver is
/// asked to correct it or to put the pin on the house themselves, before
/// the stop exists. The nearest house number on the right street is still
/// accepted: it is a few doors off, not a few kilometres.
async fn geocode_address(state: &AppState, strasse: &str, plz: &str) -> Result<(f64, f64, String, Precision), AppError> {
    match geocode_address_any(state, strasse, plz).await? {
        (_, _, _, Precision::District) => {
            Err(geocode_error_not_found(&format!("{}, {}", strasse.trim(), place_suffix(plz))))
        }
        found => Ok(found),
    }
}

async fn geocode_address_any(state: &AppState, strasse: &str, plz: &str) -> Result<(f64, f64, String, Precision), AppError> {
    let place = place_suffix(plz);
    let in_vienna = is_valid_vienna_plz(plz);
    let original_query = format!("{}, {place}", strasse.trim());
    // Cache on the *normalized* form, not the raw input: "Hauptstr. 5",
    // "Hauptstrasse 5" and "Hauptstraße  5" are one address written three
    // ways and all resolve identically, so keying on the raw text would pay
    // a throttled round-trip again for each spelling.
    let key = format!("{}, {}", normalize_strasse_text(strasse).to_lowercase(), place.to_lowercase());
    let cached = {
        let conn = state.db()?;
        cache_lookup(&conn, &key)?
    };
    if let Some(hit) = cached {
        return Ok(hit);
    }
    {
        let conn = state.db()?;
        // A recent, definitive "no geocoder has this address" — skip
        // straight to the same error the full lookup would have produced
        // several seconds and four throttled round trips from now.
        if miss_lookup(&conn, &key)? {
            tracing::debug!(key, "geocode miss served from cache");
            return Err(geocode_error_not_found(&original_query));
        }
    }

    // The city's register is only asked about Vienna postcodes; anywhere
    // else in Austria is Nominatim alone.
    //
    // `register_unreachable`: the register could not be asked at all. Then
    // whatever Nominatim answers is only standing in for it -- used, but not
    // remembered: cached as exact it would be served for good, and the
    // register's own Stiege-precise answer never asked for again once it was
    // back up. Nor is "nobody has it" a verdict worth keeping.
    let (ogd_hit, register_unreachable) =
        if in_vienna { wien_ogd_geocode(state, strasse, plz).await } else { (None, false) };
    if let Some(hit) = ogd_hit {
        let conn = state.db()?;
        cache_store(&conn, &key, hit.0, hit.1, &hit.2, hit.3)?;
        miss_clear(&conn, &key)?;
        return Ok(hit);
    }

    let normalized = normalize_strasse_text(strasse);

    // The register didn't have this address in the district it was filed
    // under. Before spending throttled Nominatim calls — and before ending
    // up at a district-centre pin the driver can't explain — ask the
    // register the same question without the district, because by far the
    // likeliest reason it just said no is that the district dropdown is
    // wrong. Naming the right one turns a vague pin into a one-tap fix.
    let district_hint =
        if in_vienna && !register_unreachable { wien_ogd_district_hint(state, &normalized, plz).await } else { None };
    if let Some(actual_plz) = district_hint {
        tracing::info!(strasse = %normalized, given = plz, actual = %actual_plz, "address exists in a different district");
        return Err(geocode_error_wrong_district(strasse.trim(), &actual_plz));
    }

    // Try the "{street} {housenumber}" form first — Viennese addresses are
    // routinely written with a Stiege/Tür/Stock suffix ("Gentzgasse
    // 129/1/2/23") that Nominatim doesn't index and will otherwise just
    // fail to match on. Only fall back to the fuller normalized string
    // (an extra throttled call) if that simplification finds nothing —
    // e.g. for a place name that was never "street + number" to begin
    // with, where simplifying would have mangled it for no reason.
    let simplified = simplify_housenumber(&normalized);
    // The street this lookup is *for*, in the same normalized form the hit's
    // own `road` field gets reduced to — what `nominatim_hit_matches` checks
    // the answer against, so a fuzzy match onto a different street (or the
    // same street in another district) is refused rather than pinned.
    let wanted_street = text::address_match_key(&text::street_name_only(&normalized));
    let query = format!("{simplified}, {place}");
    let mut result = nominatim_search_one(state, &query, &wanted_street, plz).await?;
    if result.is_none() && simplified != normalized {
        let fallback_query = format!("{normalized}, {place}");
        result = nominatim_search_one(state, &fallback_query, &wanted_street, plz).await?;
    }

    // Last resort: the street itself wasn't found at all (typo, or a
    // street too new/obscure for OSM) but the postal code is real — place
    // a coarse district-centroid pin rather than rejecting the address
    // outright. Honest about being coarse (flagged via `Precision`,
    // surfaced to the driver as "double check this one"), but still lets
    // a route with one bad address save instead of blocking the other 29.
    //
    // This only fires for a *genuinely recognized* postal code: Nominatim
    // is a fuzzy free-text search, so "{garbage} Wien, Österreich" doesn't
    // reliably come back empty for a bogus/foreign PLZ — it can match on
    // "Wien" alone and hand back central Vienna, silently. Requiring
    // Nominatim's own structured `postcode` to equal what we asked for is
    // what actually tells a real Vienna PLZ apart from that.
    if result.is_none() {
        let district_query = place.clone();
        if let Some(hit) = nominatim_raw_search(state, &district_query).await? {
            // Trimmed, as `nominatim_hit_matches` compares the same field: the
            // postcode comes as the underlying OSM tag holds it.
            let postcode_matches = hit.address.as_ref().and_then(|a| a.postcode.as_deref()).map(str::trim) == Some(plz);
            if let (true, Ok(lat), Ok(lon)) = (postcode_matches, hit.lat.parse::<f64>(), hit.lon.parse::<f64>()) {
                if is_plausible_for_plz(lat, lon, plz) {
                    result = Some((lat, lon, format!("{plz} (nur Ortsmitte, Adresse unbekannt)"), Precision::District));
                }
            }
        }
    }

    let Some((lat, lon, display_name, precision)) = result else {
        // Every strategy ran and every one of them answered "no such
        // address" — a definitive negative (an unreachable geocoder would
        // have returned `Err` long before here), so it's safe to remember.
        if !register_unreachable {
            let conn = state.db()?;
            miss_store(&conn, &key)?;
        }
        return Err(geocode_error_not_found(&original_query));
    };

    if !register_unreachable {
        let conn = state.db()?;
        cache_store(&conn, &key, lat, lon, &display_name, precision)?;
        miss_clear(&conn, &key)?;
    }
    Ok((lat, lon, display_name, precision))
}

// ---------------------------------------------------------------------
// Routing — OSRM (router.project-osrm.org), the standard open-source
// routing engine (contraction hierarchies), instead of a hand-rolled
// Dijkstra graph + a hand-rolled 2-opt/or-opt solver. Two calls do
// everything the old local code did across three modules:
//   - `osrm_route_through` for the part nothing may reorder (depot ->
//     warehouse, and on through the doors already driven to): just its
//     real distance/duration/geometry.
//   - `osrm_trip` for the last of those -> [customers, order TBD] -> destination:
//     OSRM's own multi-stop trip-optimization endpoint, which solves
//     exactly the ordering problem the old `solve_route_order` was
//     reimplementing (worse, and only for whatever fit in a Vienna-only
//     offline graph).
// ---------------------------------------------------------------------

#[derive(Deserialize)]
struct OsrmGeometry {
    coordinates: Vec<[f64; 2]>, // [lon, lat] per GeoJSON convention
}

#[derive(Deserialize)]
struct OsrmRouteResp {
    code: String,
    routes: Vec<OsrmRouteEntry>,
}

#[derive(Deserialize)]
struct OsrmRouteEntry {
    geometry: OsrmGeometry,
    #[serde(default)]
    legs: Vec<OsrmLeg>,
}

#[derive(Deserialize)]
struct OsrmTripResp {
    code: String,
    trips: Vec<OsrmTripEntry>,
    waypoints: Vec<OsrmWaypoint>,
}

#[derive(Deserialize)]
struct OsrmTripEntry {
    geometry: OsrmGeometry,
    legs: Vec<OsrmLeg>,
}

#[derive(Deserialize)]
struct OsrmLeg {
    distance: f64,
    duration: f64,
}

#[derive(Deserialize)]
struct OsrmWaypoint {
    waypoint_index: usize,
}

fn osrm_unreachable(e: impl std::fmt::Display) -> AppError {
    tracing::error!(error = %e, "osrm unreachable or invalid response");
    AppError::Internal("Routing-Dienst nicht erreichbar.".into())
}

/// "{lon},{lat};{lon},{lat};..." — OSRM's coordinate order is (lon, lat),
/// the opposite of how this app stores/passes coordinates everywhere else.
fn osrm_coord_string(coords: &[(f64, f64)]) -> String {
    coords.iter().map(|(lat, lon)| format!("{lon:.6},{lat:.6}")).collect::<Vec<_>>().join(";")
}

fn geojson_to_polyline(geom: OsrmGeometry) -> Vec<[f64; 2]> {
    geom.coordinates.into_iter().map(|[lon, lat]| [lat, lon]).collect()
}

/// How long a primary-OSRM failure is remembered before the next request
/// tries the primary again. Without this, a persistently-down self-hosted
/// instance would pay a full connect attempt on *every single* route/trip
/// call before falling back — added latency on the one thing a driver waits
/// on interactively. Short enough that a primary coming back (a reboot, a
/// restarted container) is noticed again within about a minute rather than
/// being held down by a stale verdict.
const OSRM_PRIMARY_RETRY_AFTER: Duration = Duration::from_secs(60);

/// How long the primary OSRM gets to answer before the public fallback is
/// tried instead.
///
/// `connect_timeout` on the shared client (see `main`) already caps the
/// common failure — a primary that isn't there at all. This caps the other
/// one: a primary that *accepts* the connection and then stalls (an OSRM
/// container still loading its graph, a half-open connection a sleeping
/// laptop left behind, a captive portal that swallows the request). Without
/// it those cost the client's full 20s before anything else is tried, which
/// is the same "first tap times out, second tap is instant" the connect
/// timeout exists to kill — just reached a different way.
///
/// Generous relative to what a healthy self-hosted OSRM takes for these
/// queries (single-digit to low tens of milliseconds on a LAN, and this is
/// a whole-request budget including the JSON decode), so it never cuts off
/// a primary that is merely busy.
const OSRM_PRIMARY_DEADLINE: Duration = Duration::from_secs(4);

/// One GET+JSON-decode attempt against a single OSRM base — no fallback
/// logic, just the HTTP mechanics `osrm_get` needs to try twice.
async fn osrm_try<T: DeserializeOwned>(client: &reqwest::Client, base: &str, path_and_query: &str) -> Result<T, reqwest::Error> {
    client
        .get(format!("{base}{path_and_query}"))
        .header(reqwest::header::USER_AGENT, UPSTREAM_USER_AGENT)
        .send()
        .await?
        .error_for_status()?
        .json::<T>()
        .await
}

/// GETs `path_and_query` (an OSRM route/trip path plus its query string)
/// against the configured primary OSRM (`upstreams.osrm_base` — self-hosted
/// by default, see `OSRM_BASE_DEFAULT`), falling back to the public demo
/// server (`OSRM_PUBLIC_FALLBACK`) if the primary can't be reached or
/// answers with something that doesn't even parse as OSRM JSON. The point
/// of a self-hosted instance is speed and not sharing the public server's
/// quota, not availability — an outage there shouldn't take routing down
/// entirely when the public server can still answer the same request.
///
/// A primary that just failed is skipped for `OSRM_PRIMARY_RETRY_AFTER`
/// rather than retried on every call — see that constant. This does not
/// apply, and the primary is always tried, when it's already configured to
/// *be* the public fallback (nothing to skip to).
async fn osrm_get<T: DeserializeOwned>(state: &AppState, path_and_query: &str) -> Result<T, AppError> {
    let primary = &state.upstreams.osrm_base;
    // `.lock().ok()` rather than `.unwrap()`, matching how `AppState::db`
    // treats the other std mutex in this file: a poisoned lock here would
    // otherwise panic every OSRM call for the rest of the process's life —
    // turning one unlucky panic into permanently broken routing, when the
    // honest fallback is simply to treat the cooldown as unknown and try
    // the primary.
    let down_since = state.osrm_primary_down_since.lock().ok().and_then(|g| *g);
    let skip_primary = primary != OSRM_PUBLIC_FALLBACK
        && down_since.is_some_and(|since| since.elapsed() < OSRM_PRIMARY_RETRY_AFTER);

    if !skip_primary {
        // Flattened to `Result<T, String>` so the deadline elapsing and a
        // transport error take the same path below: `reqwest::Error` can't
        // be constructed by hand, and every consumer here only ever displays
        // it. Both are "the primary didn't answer", and both must record the
        // cooldown and fall through to the public server.
        let attempt: Result<T, String> = match tokio::time::timeout(
            OSRM_PRIMARY_DEADLINE,
            osrm_try::<T>(&state.http, primary, path_and_query),
        )
        .await
        {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) => Err(e.to_string()),
            Err(_) => Err(format!("no response within {OSRM_PRIMARY_DEADLINE:?}")),
        };
        match attempt {
            Ok(v) => {
                // Recovered (or never down) — clear any earlier verdict so
                // the next failure gets a fresh cooldown, not a leftover one.
                if let Ok(mut down) = state.osrm_primary_down_since.lock() {
                    *down = None;
                }
                return Ok(v);
            }
            Err(e) if primary == OSRM_PUBLIC_FALLBACK => return Err(osrm_unreachable(e)),
            Err(e) => {
                tracing::warn!(error = %e, base = %primary, "primary OSRM unreachable, falling back to public server");
                if let Ok(mut down) = state.osrm_primary_down_since.lock() {
                    *down = Some(Instant::now());
                }
            }
        }
    }

    osrm_try::<T>(&state.http, OSRM_PUBLIC_FALLBACK, path_and_query).await.map_err(osrm_unreachable)
}

/// One `/route` call through every point in the order given: the part of a
/// tour nothing is allowed to reorder -- depot, warehouse, and the doors
/// already driven to. Returns per-leg (distance_m, duration_s) and the
/// geometry of the whole path.
async fn osrm_route_through(state: &AppState, coords: &[(f64, f64)]) -> Result<(Vec<(f64, f64)>, Vec<[f64; 2]>), AppError> {
    let path = format!("/route/v1/driving/{}?overview=full&geometries=geojson", osrm_coord_string(coords));
    let resp: OsrmRouteResp = osrm_get(state, &path).await?;
    if resp.code != "Ok" {
        return Err(AppError::Internal(format!("OSRM route: {}", resp.code)));
    }
    let route = resp.routes.into_iter().next().ok_or_else(|| AppError::Internal("OSRM: keine Route gefunden".into()))?;
    if route.legs.len() + 1 != coords.len() {
        return Err(AppError::Internal("OSRM: unerwartete Anzahl an Teilstrecken".into()));
    }
    let legs = route.legs.iter().map(|l| (l.distance, l.duration)).collect();
    Ok((legs, geojson_to_polyline(route.geometry)))
}

/// Solves the actual multi-stop ordering problem via OSRM's `/trip`
/// endpoint, with every point that isn't pinned free to be reordered
/// however minimizes total travel time.
///
/// `fix_first` pins `coords[0]` as the trip's start (`source=first`) and
/// `fix_last` pins `coords.last()` as its end (`destination=last`); an
/// unpinned end is left open (`any`). At least one of the two must be set:
/// OSRM answers `roundtrip=false` with *both* open as `NotImplemented`, so
/// that combination is a bug in the caller rather than a routing failure to
/// report to the driver -- see `reoptimize_route`, which anchors the first
/// customer when a route has no fixed points left at all.
///
/// Returns (visiting order as indices into `coords`, per-consecutive-leg
/// (distance_m, duration_s) in that visiting order, full route geometry).
async fn osrm_trip(
    state: &AppState,
    coords: &[(f64, f64)],
    fix_first: bool,
    fix_last: bool,
) -> Result<(Vec<usize>, Vec<(f64, f64)>, Vec<[f64; 2]>), AppError> {
    debug_assert!(fix_first || fix_last, "osrm_trip needs at least one pinned end");
    // Callers already skip the trip call for a route with fewer than two
    // points to connect; this makes that a returned error rather than an
    // index panic below if one ever stops doing so.
    if coords.len() < 2 {
        return Err(AppError::Internal("OSRM: Routenabschnitt mit weniger als zwei Punkten".into()));
    }
    // A backstop `add_stop`/`MAX_BULK_STOPS` should already have caught.
    // Counted in waypoints rather than being translated into "customers" by
    // subtracting two fixed points: with the fixed stops skippable, this
    // section carries anywhere from zero to two of them, so that subtraction
    // would quietly under-report the driver's own stop count by up to two.
    if coords.len() > OSRM_MAX_TRIP_COORDS {
        return Err(AppError::BadRequest(format!(
            "Zu viele Stopps für die Routenoptimierung ({} Wegpunkte, max. {OSRM_MAX_TRIP_COORDS}). Bitte die Route auf mehrere Touren aufteilen.",
            coords.len()
        )));
    }
    let path = format!(
        "/trip/v1/driving/{}?source={}&destination={}&roundtrip=false&overview=full&geometries=geojson",
        osrm_coord_string(coords),
        if fix_first { "first" } else { "any" },
        if fix_last { "last" } else { "any" },
    );
    let resp: OsrmTripResp = osrm_get(state, &path).await?;
    if resp.code != "Ok" {
        return Err(AppError::Internal(format!("OSRM trip: {}", resp.code)));
    }
    let trip = resp.trips.into_iter().next().ok_or_else(|| AppError::Internal("OSRM: keine Route gefunden".into()))?;
    if resp.waypoints.len() != coords.len() {
        return Err(AppError::Internal("OSRM: unerwartete Antwort (Stopp-Anzahl stimmt nicht)".into()));
    }

    // `waypoints[i].waypoint_index` is where input point `i` landed in the
    // optimized visiting order — invert it into "order[position] = input
    // index" so the caller can walk the trip in visiting order directly.
    // The result has to be a genuine permutation: anything else (a repeated
    // index, an out-of-range one) would silently produce a route that
    // visits one stop twice and drops another entirely, which is far worse
    // than refusing to reorder at all.
    let mut order = vec![0usize; coords.len()];
    let mut seen = vec![false; coords.len()];
    for (input_idx, wp) in resp.waypoints.iter().enumerate() {
        if wp.waypoint_index >= order.len() || seen[wp.waypoint_index] {
            return Err(AppError::Internal("OSRM: unerwartete Antwort (ungültige Stopp-Reihenfolge)".into()));
        }
        seen[wp.waypoint_index] = true;
        order[wp.waypoint_index] = input_idx;
    }

    // OSRM is asked to pin these ends, but the caller *relies* on it: the
    // first visiting position is the node already written into the route's
    // node list, and the last is the depot the tour has to finish at. A
    // response that quietly reordered either one would be walked as if it
    // hadn't, duplicating one stop and dropping another.
    if fix_first && order[0] != 0 {
        return Err(AppError::Internal("OSRM: unerwartete Antwort (Startpunkt wurde verschoben)".into()));
    }
    if fix_last && order[order.len() - 1] != coords.len() - 1 {
        return Err(AppError::Internal("OSRM: unerwartete Antwort (Zielpunkt wurde verschoben)".into()));
    }

    // A non-roundtrip trip over n waypoints has exactly n-1 legs. Anything
    // else and the caller's `legs[pos - 1]` indexing would silently pair
    // each stop with the wrong leg's distance — a route that looks entirely
    // normal on screen while telling the driver the wrong "x km to the next
    // stop" for every single row.
    if trip.legs.len() + 1 != coords.len() {
        return Err(AppError::Internal("OSRM: unerwartete Antwort (Etappen-Anzahl stimmt nicht)".into()));
    }

    let legs: Vec<(f64, f64)> = trip.legs.iter().map(|l| (l.distance, l.duration)).collect();
    Ok((order, legs, geojson_to_polyline(trip.geometry)))
}

// ---------------------------------------------------------------------
// Row/model types
// ---------------------------------------------------------------------

struct RouteRow {
    id: i64,
    name: String,
    status: String,
    created_at: String,
    completed_at: Option<String>,
    geometry: Option<String>,
    needs_optimize: bool,
    hand_ordered: bool,
    ladeliste_mode: Option<String>,
    departed_at: Option<String>,
}

impl RouteRow {
    fn from_row(r: &rusqlite::Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: r.get("id")?,
            name: r.get("name")?,
            status: r.get("status")?,
            created_at: r.get("created_at")?,
            completed_at: r.get("completed_at")?,
            geometry: r.get("geometry")?,
            needs_optimize: r.get::<_, i64>("needs_optimize")? != 0,
            hand_ordered: r.get::<_, i64>("hand_ordered")? != 0,
            ladeliste_mode: r.get("ladeliste_mode")?,
            departed_at: r.get("departed_at")?,
        })
    }
}

struct StopRow {
    id: i64,
    kind: String,
    kunde: Option<String>,
    strasse: Option<String>,
    plz: Option<String>,
    paket: Option<String>,
    notiz: Option<String>,
    lat: f64,
    lon: f64,
    order_index: i64,
    delivered: bool,
    next_leg_km: Option<f64>,
    next_leg_min: Option<f64>,
    location_precision: Option<String>,
    excluded: bool,
    pinned: bool,
    outcome: Option<String>,
    settled_at: Option<String>,
    telefon: Option<String>,
    paket_count: Option<i64>,
    entrance_lat: Option<f64>,
    entrance_lon: Option<f64>,
}

/// What happened at a door. The raw values are the iOS app's own, so a
/// backup written by one reads in the other.
///
/// Two answers besides the plain tick: `notHome` -- driven to, nobody there,
/// the door stays in the route as a driven one -- and `toLager`, known
/// beforehand, which is not driven to at all. `cancelled` and `neighbour` are
/// no longer offered and only ever arrive in an old backup; they are read so
/// such a stop still counts the way it did.
mod outcome {
    pub const DELIVERED: &str = "delivered";
    pub const NOT_HOME: &str = "notHome";
    pub const TO_LAGER: &str = "toLager";

    /// The outcomes a request may set.
    pub fn is_settable(o: &str) -> bool {
        matches!(o, DELIVERED | NOT_HOME | TO_LAGER)
    }

    /// Whether the meal left the van -- what the `delivered` column means.
    pub fn handed_over(o: &str) -> bool {
        matches!(o, DELIVERED | "neighbour")
    }

    /// The van does not go to this door at all: it is left out of the route,
    /// the counts and the Ladeliste.
    pub fn skips_door(o: &str) -> bool {
        matches!(o, TO_LAGER | "cancelled")
    }
}

/// A stop's outcome as stored, or `delivered` for a row ticked before
/// outcomes existed -- which is exactly what that bit meant.
fn effective_outcome(outcome: Option<String>, delivered: bool) -> Option<String> {
    outcome
        .filter(|o| !o.is_empty())
        .or_else(|| delivered.then(|| outcome::DELIVERED.to_string()))
}

/// SQL for "this customer row is not driven to": the same rule as
/// `outcome::skips_door`, for the queries that count without loading rows.
const SQL_SKIPS_DOOR: &str = "(s.outcome IN ('toLager', 'cancelled'))";

impl StopRow {
    fn from_row(r: &rusqlite::Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: r.get("id")?,
            kind: r.get("kind")?,
            kunde: r.get("kunde")?,
            strasse: r.get("strasse")?,
            plz: r.get("plz")?,
            paket: r.get("paket")?,
            notiz: r.get("notiz")?,
            lat: r.get("lat")?,
            lon: r.get("lon")?,
            order_index: r.get("order_index")?,
            delivered: r.get::<_, i64>("delivered")? != 0,
            next_leg_km: r.get("next_leg_km")?,
            next_leg_min: r.get("next_leg_min")?,
            location_precision: r.get("location_precision")?,
            excluded: r.get::<_, i64>("excluded")? != 0,
            pinned: r.get::<_, i64>("pinned")? != 0,
            outcome: r.get("outcome")?,
            settled_at: r.get("settled_at")?,
            telefon: r.get("telefon")?,
            paket_count: r.get("paket_count")?,
            entrance_lat: r.get("entrance_lat")?,
            entrance_lon: r.get("entrance_lon")?,
        })
    }
}

#[derive(Serialize)]
struct StopOut {
    id: i64,
    kind: String,
    kunde: Option<String>,
    strasse: Option<String>,
    plz: Option<String>,
    paket: Option<String>,
    notiz: Option<String>,
    lat: f64,
    lon: f64,
    order_index: i64,
    delivered: bool,
    next_leg_km: Option<f64>,
    next_leg_min: Option<f64>,
    /// "street" or "district" when the location is only an approximation
    /// (see `Precision` and `geocode_address`); absent for an exact match or
    /// a manually placed pin.
    location_precision: Option<String>,
    /// `true` when this fixed stop was switched off for this route -- see the
    /// `excluded` column in `SCHEMA`. Always `false` for a customer stop.
    excluded: bool,
    /// `true` when the driver placed this pin by hand. Surfaced so the app
    /// can say so, and so a re-check of the route's addresses can leave it
    /// alone -- see `recheck_addresses`.
    pinned: bool,
    /// What happened at the door -- see `mod outcome`. Absent on an open stop.
    outcome: Option<String>,
    /// When that was said, RFC 3339.
    settled_at: Option<String>,
    telefon: Option<String>,
    paket_count: Option<i64>,
    /// The house number's entrance, for navigation -- see `wien_entrance`.
    entrance_lat: Option<f64>,
    entrance_lon: Option<f64>,
}

/// Geometric centre of Vienna — the last-resort position for a stop whose
/// stored coordinates are unusable. See `to_stop_out`.
const VIENNA_CENTER_LAT: f64 = 48.2082;
const VIENNA_CENTER_LON: f64 = 16.3738;

/// A finite number, or `None`.
///
/// JSON has no way to write NaN or Infinity, so `serde_json` *fails* rather
/// than inventing one — and a failure here is a failure to serialize the
/// whole response. One unusable number in one column would therefore take
/// out `GET /api/routes/{id}` entirely, permanently, for that route: the
/// driver could not open their own stop list, and no amount of retrying or
/// reloading would help.
///
/// Nothing this app writes today can produce one (`is_plausible_latlon` and
/// `check_latlon` guard every path into `lat`/`lon`, and OSRM distances
/// arrive as JSON, which has the same restriction). This is about the row
/// that got in some other way — an older build, a hand-edited database, a
/// half-written value from a disk that filled up. The route stays readable,
/// which is what matters at 11am with a van full of meals.
fn finite_or_none(v: Option<f64>) -> Option<f64> {
    v.filter(|n| n.is_finite())
}

fn to_stop_out(r: StopRow) -> StopOut {
    // An unusable position is *not* a reason to hide the stop: the customer
    // and their address are the load-bearing part of the row, and the driver
    // can still read them and navigate by address. It is reported as an
    // approximation so it wears the "≈" badge, keeps its place out of the
    // route optimization's way, and offers the manual pin-drop that fixes it
    // for good.
    let (lat, lon, precision) = if r.lat.is_finite() && r.lon.is_finite() {
        (r.lat, r.lon, r.location_precision)
    } else {
        tracing::warn!(stop_id = r.id, lat = r.lat, lon = r.lon, "stop has unusable coordinates, reporting it as approximate");
        (VIENNA_CENTER_LAT, VIENNA_CENTER_LON, Some(Precision::District.as_str().to_string()))
    };
    StopOut {
        id: r.id,
        kind: r.kind,
        kunde: r.kunde,
        strasse: r.strasse,
        plz: r.plz,
        paket: r.paket,
        notiz: r.notiz,
        lat,
        lon,
        order_index: r.order_index,
        delivered: r.delivered,
        next_leg_km: finite_or_none(r.next_leg_km),
        next_leg_min: finite_or_none(r.next_leg_min),
        location_precision: precision,
        excluded: r.excluded,
        pinned: r.pinned,
        outcome: effective_outcome(r.outcome, r.delivered),
        settled_at: r.settled_at,
        telefon: r.telefon,
        paket_count: r.paket_count,
        entrance_lat: finite_or_none(r.entrance_lat),
        entrance_lon: finite_or_none(r.entrance_lon),
    }
}

#[derive(Serialize)]
struct RouteDetail {
    id: i64,
    name: String,
    status: String,
    created_at: String,
    completed_at: Option<String>,
    stops: Vec<StopOut>,
    geometry: Vec<[f64; 2]>,
    needs_optimize: bool,
    /// The driver has put the stops in an order of their own.
    hand_ordered: bool,
    /// The driver's own pick of VM or TK for this tour, if they made one.
    ladeliste_mode: Option<String>,
    /// When the van left for the Lager today, if the driver started
    /// navigation there.
    departed_at: Option<String>,
    delivered_count: i64,
    customer_count: i64,
    total_km: f64,
    total_min: f64,
}

#[derive(Serialize)]
struct RouteSummary {
    id: i64,
    name: String,
    status: String,
    created_at: String,
    completed_at: Option<String>,
    customer_count: i64,
    delivered_count: i64,
    needs_optimize: bool,
}

/// `Err(NotFound)` if `route_id` doesn't exist, `Ok(())` otherwise. Used by
/// every handler that needs to reject a stale/bogus route id *before* doing
/// slower work (geocoding, a transaction) that a bare foreign-key failure
/// further down would only report as an opaque 500 — this is the one place
/// that "does this route exist" check is written, instead of the same
/// `SELECT 1 FROM routes ...` copy-pasted at every call site.
fn require_route_exists(conn: &Connection, route_id: i64) -> Result<(), AppError> {
    let exists: bool = conn
        .query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(()))
        .optional()?
        .is_some();
    if !exists {
        return Err(AppError::NotFound("Tour nicht gefunden".into()));
    }
    Ok(())
}

/// Length/control-character validation shared by `add_stop` and the bulk
/// JSON import's per-entry loop — both require all four fields present and
/// validate them identically. `update_stop`'s validation is deliberately
/// NOT routed through this: it's a PATCH, so each field is independently
/// optional and Paket/Notiz can be cleared to empty, a shape that doesn't
/// compose cleanly with "these four are all required" without being harder
/// to follow than just writing it out.
fn validate_customer_fields(kunde: &str, strasse: &str, paket: Option<&str>, notiz: Option<&str>) -> Result<(), AppError> {
    check_len(kunde, "Kunde", MAX_KUNDE_LEN)?;
    check_no_control_chars(kunde, "Kunde", false)?;
    check_len(strasse, "Straße", MAX_STRASSE_LEN)?;
    check_no_control_chars(strasse, "Straße", false)?;
    if let Some(p) = paket {
        check_len(p, "Paket", MAX_PAKET_LEN)?;
        check_no_control_chars(p, "Paket", false)?;
    }
    if let Some(n) = notiz {
        check_len(n, "Notiz", MAX_NOTIZ_LEN)?;
        check_no_control_chars(n, "Notiz", true)?;
    }
    Ok(())
}

/// `-0.0` is a perfectly ordinary `f64` that `serde_json` faithfully writes
/// as `-0.0` — and Rust's `Sum` for floats folds from `-0.0`, so summing an
/// empty iterator produces exactly that. A route with no driven legs at all
/// (every fixed stop switched off and no customers entered yet) therefore
/// showed the driver "≈ -0 km · -0 min". Adding zero is the IEEE-defined
/// way to collapse a negative zero to a positive one and leaves every other
/// value, including genuine negatives, untouched.
fn strip_negative_zero(v: f64) -> f64 {
    v + 0.0
}

fn get_route_detail(conn: &Connection, route_id: i64) -> Result<RouteDetail, AppError> {
    let route = conn
        .query_row("SELECT * FROM routes WHERE id = ?1", params![route_id], RouteRow::from_row)
        .optional()?
        .ok_or_else(|| AppError::NotFound("Tour nicht gefunden".into()))?;

    let mut stmt = conn.prepare("SELECT * FROM stops WHERE route_id = ?1 ORDER BY order_index")?;
    let stops: Vec<StopRow> = stmt
        .query_map(params![route_id], StopRow::from_row)?
        .collect::<Result<_, _>>()?;
    drop(stmt);

    let stop_outs: Vec<StopOut> = stops.into_iter().map(to_stop_out).collect();
    // Counted against the meals owed: a door the van does not go to is not
    // a stop of the day, so it is in neither number.
    let customer_stops: Vec<&StopOut> = stop_outs
        .iter()
        .filter(|s| s.kind == "customer" && !s.outcome.as_deref().is_some_and(outcome::skips_door))
        .collect();
    // Summed from the sanitized stops (see `finite_or_none`), so these can
    // only be finite — but a sum of finite values can still overflow to
    // infinity, and infinity is exactly as unserializable as NaN.
    let total_km = finite_or_none(Some(stop_outs.iter().filter_map(|s| s.next_leg_km).sum())).unwrap_or(0.0);
    let total_min = finite_or_none(Some(stop_outs.iter().filter_map(|s| s.next_leg_min).sum())).unwrap_or(0.0);
    // A geometry that no longer parses costs the route line, not the route:
    // `.ok()` degrades to "no line drawn". Non-finite pairs are dropped for
    // the same reason the numbers above are — one of them would make the
    // whole response unserializable.
    let geometry: Vec<[f64; 2]> = route
        .geometry
        .as_deref()
        .and_then(|g| serde_json::from_str::<Vec<[f64; 2]>>(g).ok())
        .unwrap_or_default()
        .into_iter()
        .filter(|p| p[0].is_finite() && p[1].is_finite())
        .collect();

    Ok(RouteDetail {
        id: route.id,
        name: route.name,
        status: route.status,
        created_at: route.created_at,
        completed_at: route.completed_at,
        needs_optimize: route.needs_optimize,
        hand_ordered: route.hand_ordered,
        ladeliste_mode: route.ladeliste_mode,
        departed_at: route.departed_at,
        delivered_count: customer_stops.iter().filter(|s| s.delivered).count() as i64,
        customer_count: customer_stops.len() as i64,
        total_km: strip_negative_zero((total_km * 10.0).round() / 10.0),
        total_min: strip_negative_zero(total_min.round()),
        stops: stop_outs,
        geometry,
    })
}

/// How old a position may be and still be "where I am": ten minutes.
const HERE_MAX_AGE_SECS: i64 = 10 * 60;

#[derive(Clone, Copy)]
struct StopCoord {
    id: i64,
    lat: f64,
    lon: f64,
}

/// One of the three fixed points of a route (depot / warehouse /
/// destination) as stored: where it is, plus whether this particular tour
/// actually drives it.
#[derive(Clone, Copy)]
struct FixedStop {
    coord: StopCoord,
    excluded: bool,
}

impl FixedStop {
    /// The coordinate, but only when this tour drives it. `None` covers
    /// both "the route has no such stop at all" and "switched off for this
    /// tour" — the optimizer plans identically for the two, so this is the
    /// one place that distinction is deliberately collapsed.
    fn active(slot: Option<FixedStop>) -> Option<StopCoord> {
        slot.filter(|f| !f.excluded).map(|f| f.coord)
    }
}

/// Every stop of a route sorted into the roles `reoptimize_route` plans
/// around. The three fixed slots are `Option` because a route can be
/// missing any of them; each also carries its own `excluded` flag, which
/// is what keeps a switched-off stop visible in the list (see
/// `display_order`) while being invisible to the routing calls.
struct RouteNodes {
    start: Option<FixedStop>,
    via: Option<FixedStop>,
    end: Option<FixedStop>,
    customers: Vec<StopCoord>,
    /// The customers the van does not go to ("Ins Lager mitnehmen"), in list
    /// order. Not routed -- going through the door anyway put a detour into
    /// the line, the kilometres and every arrival time after it -- but still
    /// listed, after the doors that are driven.
    skipped: Vec<StopCoord>,
    /// The customers already driven to, in list order, with the one answered
    /// for last at the end: where the van is now. Empty until the first door
    /// of the day, which leaves a fresh tour planned exactly as it always was.
    driven: Vec<StopCoord>,
    /// Where the driver is, from a recent fix -- set only before the first
    /// door, and only consulted when Start is switched off: a driver who
    /// disables the depot is not skipping a start, they are saying "start
    /// from where I am". It carries the Start row's id, so the drive from
    /// here lands on that row and is counted in the kilometres.
    current_location: Option<StopCoord>,
}

impl RouteNodes {
    /// The fixed points that lead the tour, in their fixed order — depot
    /// then warehouse, minus whichever of them this tour skips. Never
    /// handed to the trip optimizer: driving to the warehouse before the
    /// depot isn't a cheaper tour, it's a different one.
    fn head(&self) -> Vec<StopCoord> {
        let start = match self.start {
            Some(f) if f.excluded => self.current_location,
            other => FixedStop::active(other),
        };
        [start, FixedStop::active(self.via)].into_iter().flatten().collect()
    }
}

/// Appends one OSRM leg's geometry to the polyline built so far, dropping
/// the junction point the two segments share — without this every seam
/// between two legs carries a duplicated coordinate.
fn append_geometry(acc: &mut Vec<[f64; 2]>, segment: Vec<[f64; 2]>) {
    if !acc.is_empty() && !segment.is_empty() {
        acc.pop();
    }
    acc.extend(segment);
}

/// The order the route's stops are *shown* in, which is not the order they
/// are driven in: a switched-off fixed stop still belongs where it would
/// have been driven — the depot at the top of the list, the destination at
/// the bottom — rather than flushed to the end, where "Start" would sit
/// underneath the last customer of the day. Only the customers are placed
/// by `routed` (that ordering is the whole point of the optimization).
fn display_order(nodes: &RouteNodes, routed: &[StopCoord]) -> Vec<StopCoord> {
    let customer_ids: HashSet<i64> = nodes.customers.iter().map(|c| c.id).collect();
    let mut out: Vec<StopCoord> = Vec::with_capacity(routed.len() + nodes.skipped.len() + 3);
    out.extend(nodes.start.map(|f| f.coord));
    out.extend(nodes.via.map(|f| f.coord));
    out.extend(routed.iter().copied().filter(|n| customer_ids.contains(&n.id)));
    out.extend(nodes.skipped.iter().copied());
    out.extend(nodes.end.map(|f| f.coord));
    out
}

/// Re-solves stop order + fetches real geometry for a route via OSRM.
///
/// The shape of a tour is: the fixed head (depot -> warehouse) in exactly
/// that order, then the customers in whatever order OSRM finds cheapest,
/// then the fixed destination. Each of those three fixed points can be
/// switched off per route (see the `excluded` column in `SCHEMA`), so none
/// of them is assumed to be there — a tour that starts straight at the
/// warehouse, or ends at its last customer, is planned on exactly the
/// points it actually drives instead of on two legs it never will.
///
/// Structured as read-then-await-then-write, with no connection held across
/// an `.await`: the OSRM calls in the middle take seconds, and a connection
/// spanning them would hold a SQLite handle — inside a transaction, a write
/// lock on the entire database — open for the length of a third-party
/// network request. `PooledConn` is `!Send` precisely so this is a compile
/// error rather than a discipline.
async fn reoptimize_route(state: &AppState, route_id: i64) -> Result<(), AppError> {
    // Serialized per route (see `AppState::route_locks`): the read below and
    // the write at the end are separated by seconds of network calls, so two
    // concurrent optimizations of one route would both plan from the same
    // starting state and the slower one would overwrite the faster one's
    // stop order while keeping its own leg distances.
    let lock = state.route_lock(route_id).await;
    let _guard = lock.lock().await;

    // No route through a stop nobody knows the place of. One whose pin is
    // only the middle of its district (from before such stops were refused,
    // or with coordinates that turned out unusable) would be planned around
    // as if it were a door, and the whole order after it would be wrong
    // without looking wrong. Refused by name, so the fix is obvious; the
    // route stays flagged until it is made.
    {
        let conn = state.db()?;
        let unplaced = unplaced_stops(&conn, route_id)?;
        if !unplaced.is_empty() {
            return Err(AppError::BadRequest(unplaced_message(&unplaced)));
        }
    }

    // What this solution was planned from, checked again at write time —
    // see `planning_fingerprint`.
    let planned_from: Vec<(i64, f64, f64, bool, bool)>;
    // The customers in the order the list shows them, on a tour the driver
    // has sorted by hand; `None` leaves the order to OSRM.
    let hand_order: Option<Vec<StopCoord>>;

    let nodes = {
        let conn = state.db()?;
        let stops = planning_rows(&conn, route_id)?;
        planned_from = planning_fingerprint(&stops);
        let hand_ordered: bool = conn
            .query_row("SELECT hand_ordered FROM routes WHERE id = ?1", params![route_id], |r| r.get::<_, i64>(0))
            .optional()?
            .is_some_and(|v| v != 0);
        hand_order = hand_ordered.then(|| {
            let mut listed: Vec<&PlanningRow> = stops.iter().filter(|s| s.kind == "customer").collect();
            listed.sort_by_key(|s| (s.order_index, s.id));
            listed.iter().map(|s| StopCoord { id: s.id, lat: s.lat, lon: s.lon }).collect()
        });

        let mut nodes = RouteNodes {
            start: None,
            via: None,
            end: None,
            customers: Vec::new(),
            skipped: Vec::new(),
            driven: driven_order(&stops),
            current_location: None,
        };
        let mut skipped: Vec<&PlanningRow> = Vec::new();
        for s in &stops {
            let coord = StopCoord { id: s.id, lat: s.lat, lon: s.lon };
            let fixed = FixedStop { coord, excluded: s.excluded };
            // `excluded` is only ever written to a fixed stop, and a
            // customer row carrying it anyway (a hand-edited database)
            // must not silently disappear from the tour — hence matching
            // on the kind rather than on the flag.
            match s.kind.as_str() {
                "start" => nodes.start = Some(fixed),
                "via" => nodes.via = Some(fixed),
                "end" => nodes.end = Some(fixed),
                _ if s.skips_door() => skipped.push(s),
                _ => nodes.customers.push(coord),
            }
        }
        skipped.sort_by_key(|s| (s.order_index, s.id));
        nodes.skipped = skipped.iter().map(|s| StopCoord { id: s.id, lat: s.lat, lon: s.lon }).collect();
        // Before the first door only: after it the trip starts at the door,
        // and a fix used then would draw the line from wherever the van is
        // now back to the first delivery.
        if let (Some(start), true) = (nodes.start, nodes.driven.is_empty()) {
            let here: Option<(f64, f64, i64)> = conn
                .query_row(
                    "SELECT here_lat, here_lon, here_at FROM routes WHERE id = ?1 AND here_at IS NOT NULL",
                    params![route_id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?;
            if let Some((lat, lon, at)) = here {
                let fresh = chrono::Utc::now().timestamp() - at <= HERE_MAX_AGE_SECS;
                if start.excluded && fresh && is_plausible_latlon(lat, lon) {
                    nodes.current_location = Some(StopCoord { id: start.coord.id, lat, lon });
                }
            }
        }
        nodes
    };

    let head = nodes.head();
    let end = FixedStop::active(nodes.end);

    // `routed` is the driving order and `legs[i]` is the leg from
    // `routed[i]` to `routed[i + 1]`, so `legs.len() + 1 == routed.len()`
    // holds from here to the write below.
    //
    // Depot -> warehouse, and on through the doors already driven to: fixed,
    // never reordered, so routed as listed rather than handed to the trip
    // optimizer. With nothing driven and either fixed point off there is no
    // such leg at all.
    let mut routed: Vec<StopCoord> = head.iter().chain(nodes.driven.iter()).copied().collect();
    let mut legs: Vec<(f64, f64)> = Vec::new();
    let mut geometry: Vec<[f64; 2]> = Vec::new();

    if let Some(listed) = &hand_order {
        // Sorted by hand: the fixed head, the customers exactly as listed,
        // then the destination -- one call for the line on the map and the
        // distance on each row, and nothing for OSRM to choose.
        let skipped: HashSet<i64> = nodes.skipped.iter().map(|n| n.id).collect();
        routed = head.clone();
        routed.extend(listed.iter().copied().filter(|n| !skipped.contains(&n.id)));
        routed.extend(end);
        if routed.len() >= 2 {
            let coords: Vec<(f64, f64)> = routed.iter().map(|n| (n.lat, n.lon)).collect();
            let (path_legs, path_geom) = osrm_route_through(state, &coords).await?;
            legs.extend(path_legs);
            append_geometry(&mut geometry, path_geom);
        }
    } else {
    if routed.len() >= 2 {
        let coords: Vec<(f64, f64)> = routed.iter().map(|n| (n.lat, n.lon)).collect();
        let (path_legs, path_geom) = osrm_route_through(state, &coords).await?;
        legs.extend(path_legs);
        append_geometry(&mut geometry, path_geom);
    }

    // The optimized section runs from the last point already driven through
    // every open customer to the destination. That point is the anchor: it
    // is already in `routed` and goes into this call only to be routed
    // *from*, never to be added a second time.
    //
    // Mid-tour it is the last door answered for, not the warehouse. Planned
    // from the depot every time, one stop added after the fifteenth delivery
    // could land between the third and fourth -- become "next", and send the
    // driver back across town.
    let anchor = routed.last().copied();
    let driven_ids: HashSet<i64> = nodes.driven.iter().map(|n| n.id).collect();
    let mut trip_nodes: Vec<StopCoord> = Vec::new();
    trip_nodes.extend(anchor);
    trip_nodes.extend(nodes.customers.iter().copied().filter(|c| !driven_ids.contains(&c.id)));
    trip_nodes.extend(end);

    if trip_nodes.len() >= 2 {
        // OSRM cannot solve a `roundtrip=false` trip with both ends open
        // (see `osrm_trip`). A tour with depot, warehouse *and* destination
        // all switched off has no fixed point left to anchor to, so the
        // first customer — first by stop id, i.e. the order they were
        // entered — is pinned as the starting point and the tour is left
        // free to end wherever is cheapest. That is a real choice made on
        // the driver's behalf, but it is the only one on offer, and "start
        // where the list starts" is what a hand-entered list already implies.
        let fix_first = anchor.is_some() || end.is_none();
        let fix_last = end.is_some();
        let coords: Vec<(f64, f64)> = trip_nodes.iter().map(|n| (n.lat, n.lon)).collect();
        let (order, trip_legs, trip_geom) = osrm_trip(state, &coords, fix_first, fix_last).await?;

        for &idx in &order {
            if anchor.is_some() && idx == 0 {
                continue; // the anchor, already the last entry of `routed`
            }
            routed.push(trip_nodes[idx]);
        }
        legs.extend(trip_legs);
        append_geometry(&mut geometry, trip_geom);
    } else {
        // At most one point after the head — nothing to optimize, but it
        // still belongs in the driving order.
        routed.extend(trip_nodes.into_iter().skip(anchor.is_some() as usize));
    }

    }

    // `[f64; 2]` pairs can't fail to serialize once finite, but OSRM is an
    // external service — treat a malformed/non-finite value in its
    // response as a normal (logged) error rather than a process-killing
    // unwrap.
    let geometry_json = serde_json::to_string(&geometry).map_err(|e| {
        tracing::error!(error = %e, "route geometry serialization failed");
        AppError::Internal("Routen-Geometrie konnte nicht gespeichert werden.".into())
    })?;

    // Leg distances belong to the driving order; the row they're written
    // onto is found by stop id, so the display order below can differ from
    // it without the two ever drifting apart. A stop that isn't driven at
    // all appears in neither map and has its stale legs cleared to NULL.
    let leg_for: HashMap<i64, (f64, f64)> = routed
        .iter()
        .enumerate()
        .filter_map(|(pos, node)| legs.get(pos).map(|&leg| (node.id, leg)))
        .collect();

    // The new stop order, the per-leg distances and the geometry describe
    // one single solution — committed together so a failure partway
    // through can't leave stops renumbered against a geometry drawn for
    // the old order (which would look plausible on screen and be wrong),
    // and so `needs_optimize` is only ever cleared once all of it landed.
    let mut conn = state.db()?;
    let tx = conn.transaction()?;

    // Did the route change while this solution was being computed?
    //
    // The mutating handlers commit their change and *then* call
    // `reoptimize_best_effort`, which queues on this same per-route lock —
    // so two edits in quick succession produce two optimizations, and the
    // first of them planned from a route that no longer exists by the time
    // it writes. Its stop order and geometry are simply stale, which the
    // second run corrects. What is not self-correcting is
    // `needs_optimize = 0`: the first run clears the flag the second edit
    // had set, and if that second optimization then fails (OSRM
    // unreachable, which is the whole reason `reoptimize_best_effort`
    // exists), the route is left claiming to be current while its geometry
    // is missing a stop. No banner, no retry offered, wrong distances all
    // day.
    //
    // Comparing what was planned from against what is there now, inside the
    // write transaction, is what makes clearing the flag honest. The order
    // and geometry are still written either way — a fresher-than-nothing
    // solution beats leaving the old one — but the flag only clears when
    // this solution actually describes the route on disk.
    let current = planning_fingerprint(&planning_rows(&tx, route_id)?);
    let still_current = current == planned_from;
    if !still_current {
        tracing::info!(
            route_id,
            "route changed while it was being optimized — writing this solution but leaving it flagged for another pass"
        );
    }

    // A hand-sorted tour keeps its own order in the list, the doors that
    // are not driven included, each where the driver left it.
    let shown: Vec<StopCoord> = match &hand_order {
        Some(listed) => nodes
            .start
            .map(|f| f.coord)
            .into_iter()
            .chain(nodes.via.map(|f| f.coord))
            .chain(listed.iter().copied())
            .chain(nodes.end.map(|f| f.coord))
            .collect(),
        None => display_order(&nodes, &routed),
    };
    for (pos, node) in shown.iter().enumerate() {
        let (leg_km, leg_min) = match leg_for.get(&node.id) {
            Some(&(dist, dur)) => (Some(dist / 1000.0), Some(dur / 60.0)),
            None => (None, None),
        };
        tx.execute(
            "UPDATE stops SET order_index = ?1, next_leg_km = ?2, next_leg_min = ?3 WHERE id = ?4",
            params![pos as i64, leg_km, leg_min, node.id],
        )?;
    }
    tx.execute(
        "UPDATE routes SET geometry = ?1, needs_optimize = ?2 WHERE id = ?3",
        params![geometry_json, i64::from(!still_current), route_id],
    )?;
    tx.commit()?;
    Ok(())
}

/// The customers of a route the van is meant to drive to but whose position
/// is only a district's centre, by name.
fn unplaced_stops(conn: &Connection, route_id: i64) -> Result<Vec<String>, AppError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT COALESCE(s.kunde, 'Stopp') FROM stops s WHERE s.route_id = ?1 AND s.kind = 'customer' \
         AND s.location_precision = 'district' AND s.pinned = 0 AND NOT COALESCE({SQL_SKIPS_DOOR}, 0) \
         ORDER BY s.order_index, s.id"
    ))?;
    let names = stmt.query_map(params![route_id], |r| r.get(0))?.collect::<Result<Vec<String>, _>>()?;
    Ok(names)
}

fn unplaced_message(names: &[String]) -> String {
    let shown = names.iter().take(3).map(|n| format!("„{n}“")).collect::<Vec<_>>().join(", ");
    let rest = names.len().saturating_sub(3);
    let who = if rest > 0 { format!("{shown} und {rest} weitere") } else { shown };
    if names.len() == 1 {
        format!("Die Adresse von {who} wurde nicht gefunden. Bitte die Adresse korrigieren — vorher kann die Reihenfolge nicht berechnet werden.")
    } else {
        format!("Die Adressen von {who} wurden nicht gefunden. Bitte die Adressen korrigieren — vorher kann die Reihenfolge nicht berechnet werden.")
    }
}

/// Everything `reoptimize_route` actually plans from, in a form two runs can
/// be compared by: which stops exist, where they are, and which are skipped.
///
/// Deliberately not the whole row — a customer's name or note changing
/// between the read and the write does not make the computed order or
/// geometry wrong, and treating it as if it did would leave routes
/// perpetually flagged for re-optimization over an edited Notiz.
fn planning_fingerprint(stops: &[PlanningRow]) -> Vec<(i64, f64, f64, bool, bool)> {
    stops.iter().map(|s| (s.id, s.lat, s.lon, s.excluded, s.skips_door())).collect()
}

/// One stop as the optimizer reads it.
struct PlanningRow {
    id: i64,
    kind: String,
    lat: f64,
    lon: f64,
    excluded: bool,
    order_index: i64,
    outcome: Option<String>,
    settled_at: Option<String>,
}

impl PlanningRow {
    fn skips_door(&self) -> bool {
        self.kind == "customer" && self.outcome.as_deref().is_some_and(outcome::skips_door)
    }
    /// A door the van has been to: answered for, in any way but one that
    /// says it never goes there.
    fn is_driven(&self) -> bool {
        self.kind == "customer" && self.outcome.is_some() && !self.skips_door()
    }
}

/// Every stop of a route, by id -- "the first customer" means the one
/// entered first, which the no-fixed-points anchor rule relies on.
fn planning_rows(conn: &Connection, route_id: i64) -> Result<Vec<PlanningRow>, AppError> {
    // Not `SELECT *`: this runs on every single add/edit/delete of a stop
    // (via `reoptimize_best_effort`), and none of the text columns are used
    // for planning.
    let mut stmt = conn.prepare(
        "SELECT id, kind, lat, lon, excluded, order_index, outcome, delivered, settled_at \
         FROM stops WHERE route_id = ?1 ORDER BY id",
    )?;
    let rows = stmt
        .query_map(params![route_id], |r| {
            Ok(PlanningRow {
                id: r.get(0)?,
                kind: r.get(1)?,
                lat: r.get(2)?,
                lon: r.get(3)?,
                excluded: r.get::<_, i64>(4)? != 0,
                order_index: r.get(5)?,
                outcome: effective_outcome(r.get(6)?, r.get::<_, i64>(7)? != 0),
                settled_at: r.get(8)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// The doors already answered for, as `RouteNodes::driven` wants them: in
/// list order, with the most recent answer moved to the end.
fn driven_order(stops: &[PlanningRow]) -> Vec<StopCoord> {
    let mut done: Vec<&PlanningRow> = stops.iter().filter(|s| s.is_driven()).collect();
    done.sort_by_key(|s| (s.order_index, s.id));
    // The last of equals, so a tour ticked before timestamps existed keeps
    // its last listed door as where the van is.
    if let Some(last) = (0..done.len()).max_by_key(|&i| (done[i].settled_at.clone().unwrap_or_default(), i)) {
        let row = done.remove(last);
        done.push(row);
    }
    done.iter().map(|s| StopCoord { id: s.id, lat: s.lat, lon: s.lon }).collect()
}

/// `reoptimize_route` for the callers that have *already committed* their
/// change — a stop added, edited, deleted, or a whole route imported.
///
/// For those, a failing OSRM call is not a failed request. The write landed
/// and the route is correctly flagged `needs_optimize`, so the app already
/// has a designed answer for this exact state: the amber "Route nicht
/// aktuell" banner with its one-tap retry. Propagating the error instead
/// hands the driver a red failure toast for an action that demonstrably
/// worked, and the obvious response to that toast — do it again — silently
/// adds the same stop twice. So: log it, leave the flag set, hand back the
/// route as it now genuinely is.
///
/// Only the explicit "Neu optimieren" action still surfaces the error, and
/// it should: there the optimization *is* the request, so failing quietly
/// would mean a tap that appears to do nothing at all.
async fn reoptimize_best_effort(state: &AppState, route_id: i64) {
    if let Err(e) = reoptimize_route(state, route_id).await {
        tracing::warn!(
            route_id,
            error = ?e,
            "route saved but could not be re-optimized — left flagged as needing optimization"
        );
    }
}

// ---------------------------------------------------------------------
// Entrances
//
// Where the register puts an address's house number on the street: the
// entrance, `ogdwien:ZUGANGSADROGD`. This is what a navigation app is sent
// to. A stop's own `lat`/`lon` stay the building or the Stiege, which is
// what the map and the route planning want -- and for a Gemeindebau that
// point can be in a courtyard two streets from the door the van pulls up to.
// ---------------------------------------------------------------------

const WIEN_ENTRANCES_URL: &str = "https://data.wien.gv.at/daten/geo";

#[derive(Deserialize)]
struct EntranceCollection {
    #[serde(default)]
    features: Vec<EntranceFeature>,
}

#[derive(Deserialize)]
struct EntranceFeature {
    geometry: EntranceGeometry,
    properties: EntranceProperties,
}

#[derive(Deserialize)]
struct EntranceGeometry {
    #[serde(default)]
    coordinates: Vec<f64>,
}

#[derive(Deserialize)]
struct EntranceProperties {
    #[serde(rename = "NAME_ONR")]
    number: Option<String>,
    #[serde(rename = "PLZ")]
    plz: Option<String>,
}

fn is_in_vienna(lat: f64, lon: f64) -> bool {
    lat.is_finite() && lon.is_finite() && (47.7..=48.6).contains(&lat) && (15.8..=16.8).contains(&lon)
}

/// "82" out of "82-92", "82/1" and "82 Kindertagesheim"; "12a" out of
/// "12a/3". The part of the number the entrance layer files it under.
fn entrance_number(street_number: &str) -> Option<String> {
    let mut chars = street_number.trim().chars().peekable();
    let mut digits = String::new();
    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
        digits.push(c);
        chars.next();
    }
    if digits.is_empty() {
        return None;
    }
    // One letter straight after the digits belongs to the number -- "12a" --
    // but only if nothing but a separator or the end follows it, so the "K"
    // of "82 Kindertagesheim" is not mistaken for one.
    if let Some(c) = chars.next().filter(|c| c.is_alphabetic()) {
        if matches!(chars.next(), None | Some('/') | Some(' ') | Some('-')) {
            digits.extend(c.to_lowercase());
        }
    }
    Some(digits)
}

/// The entrance whose number is this one -- never "129a" or "1290" for
/// "129", which the prefix query also returns. The layer is not consistent
/// about ranges ("82-92" filed as "82", "31-35" as "31-35"), so a number
/// written exactly as asked wins, and otherwise a range starting with it
/// counts.
fn pick_entrance(features: &[EntranceFeature], number: &str, plz: &str) -> Option<(f64, f64)> {
    let want: String = number.to_lowercase().chars().filter(|c| !c.is_whitespace()).collect();
    let raw = |f: &EntranceFeature| -> String {
        f.properties.number.as_deref().unwrap_or("").to_lowercase().chars().filter(|c| !c.is_whitespace()).collect()
    };
    let here: Vec<&EntranceFeature> = features.iter().filter(|f| f.properties.plz.as_deref() == Some(plz)).collect();
    let hit = here
        .iter()
        .find(|f| raw(f) == want)
        .or_else(|| here.iter().find(|f| entrance_number(&raw(f)).as_deref() == Some(want.as_str())))?;
    let (lon, lat) = match hit.geometry.coordinates.as_slice() {
        [lon, lat] => (*lon, *lat),
        _ => return None,
    };
    is_in_vienna(lat, lon).then_some((lat, lon))
}

/// `None` when the call failed; an empty list when it answered "none".
async fn entrance_fetch(state: &AppState, street: &str, number: &str, plz: &str) -> Option<Vec<EntranceFeature>> {
    // Digits only in the prefix, so "12a" still finds "12A"; the exact
    // number is picked out of what comes back. Quotes doubled, which is how
    // CQL escapes them inside a string.
    let digits: String = number.chars().take_while(char::is_ascii_digit).collect();
    let quoted = |s: &str| s.replace('\'', "''");
    let filter = format!("NAME LIKE '{} {}%' AND PLZ='{}'", quoted(street), digits, quoted(plz));
    let resp = state
        .http
        .get(WIEN_ENTRANCES_URL)
        .query(&[
            ("service", "WFS"),
            ("request", "GetFeature"),
            ("version", "1.1.0"),
            ("typeName", "ogdwien:ZUGANGSADROGD"),
            ("srsName", "EPSG:4326"),
            ("outputFormat", "json"),
            // Generous: the prefix also matches every longer number, and on
            // a long street "1" alone brings back 1, 10-19 and 100-199.
            ("maxFeatures", "500"),
            ("cql_filter", filter.as_str()),
        ])
        .header(reqwest::header::USER_AGENT, UPSTREAM_USER_AGENT)
        .send()
        .await
        .map_err(|e| tracing::warn!(error = %e, "wien entrance lookup failed"))
        .ok()?;
    if !resp.status().is_success() {
        tracing::warn!(status = %resp.status(), "wien entrance lookup error status");
        return None;
    }
    resp.json::<EntranceCollection>()
        .await
        .map(|c| c.features)
        .map_err(|e| tracing::warn!(error = %e, "wien entrance answer did not parse"))
        .ok()
}

/// The answers already had, for as long as the server runs. Only answers:
/// a failed call is not one, and is asked again next time.
static ENTRANCES: once_cell::sync::Lazy<StdMutex<EntranceAnswers>> =
    once_cell::sync::Lazy::new(|| StdMutex::new(HashMap::new()));
/// By address key: the entrance, or `None` where the register has none.
type EntranceAnswers = HashMap<String, Option<(f64, f64)>>;

/// The entrance for an address, or `None` -- outside Vienna, when either
/// lookup fails, and when the register has no entrance for the number.
///
/// Two calls. The address register first, to learn the street the way the
/// city spells it: the entrance layer only matches its own spelling. Then
/// the entrance layer itself, which has one point per house number -- so
/// every Stiege of a Gemeindebau gets the one entrance.
async fn wien_entrance(state: &AppState, strasse: &str, plz: &str) -> Option<(f64, f64)> {
    if !is_valid_vienna_plz(plz) {
        return None;
    }
    let normalized = normalize_strasse_text(strasse);
    let simplified = simplify_housenumber(&normalized);
    // Only for the number that was asked for. For one it does not know, the
    // register answers with the nearest one it does -- and that entrance is
    // a precise point at the wrong house, worse than sending the address.
    let asked = simplified.split(' ').next_back().and_then(entrance_number);
    // "Töllergasse 26 A" is house 26A, whose entrance is its own -- see
    // `asked_numbers`. Tried first, and part of the key.
    let lettered = asked_numbers(asked.as_deref(), &text::sub_address_segments(&normalized)).into_iter().nth(1);
    let key = format!("{}{}|{plz}", text::address_match_key(&simplified), lettered.as_deref().unwrap_or(""));
    if let Some(known) = ENTRANCES.lock().ok().and_then(|m| m.get(&key).copied()) {
        return known;
    }
    let remember = |point: Option<(f64, f64)>| {
        if let Ok(mut m) = ENTRANCES.lock() {
            m.insert(key.clone(), point);
        }
        point
    };
    let Some(asked) = asked else { return remember(None) };

    // An empty answer is as good as none: the register returns nothing at
    // all for a house it does not know, and the entrance layer may still.
    let features = wien_ogd_fetch(state, &simplified).await.unwrap_or_default();
    let street_key = text::address_match_key(&text::street_name_only(&simplified));
    // Picked among the answers carrying that number, not taken as the best
    // answer overall: asked for "Serravagasse 2" the register ranks
    // "Serravagasse 2E" first -- the house next door.
    let same_number: Vec<OgdFeature> = features
        .into_iter()
        .filter(|f| f.properties.street_number.as_deref().and_then(entrance_number).as_deref() == Some(asked.as_str()))
        .collect();
    // The register does not know every house the entrance layer does. Then
    // the entrance layer is asked directly, with the street as typed.
    let street = pick_ogd_feature(&same_number, plz, &street_key, None, &[], &[])
        .filter(|f| ogd_ranking(f) < 1.0)
        .and_then(|f| f.properties.street_name.clone())
        .unwrap_or_else(|| text::street_name_only(&simplified));

    let candidates = entrance_fetch(state, &street, &asked, plz).await?;
    let point = lettered
        .as_deref()
        .and_then(|n| pick_entrance(&candidates, n, plz))
        .or_else(|| pick_entrance(&candidates, &asked, plz));
    remember(point)
}

/// Looks up an entrance for every customer of the route still without one,
/// a few at a time. Best effort: a stop it finds none for is navigated to
/// by its address, as before. Not for a hand-placed pin, which outranks it.
async fn fill_entrances(state: &Arc<AppState>, route_id: i64) {
    let wanted: Vec<(i64, String, String)> = {
        let Ok(conn) = state.db() else { return };
        let Ok(mut stmt) = conn.prepare(
            "SELECT id, strasse, plz FROM stops WHERE route_id = ?1 AND kind = 'customer' AND pinned = 0 \
             AND entrance_lat IS NULL AND strasse IS NOT NULL AND TRIM(strasse) <> '' AND plz IS NOT NULL",
        ) else {
            return;
        };
        let rows = stmt
            .query_map(params![route_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
            .unwrap_or_default();
        rows.into_iter().filter(|(_, _, plz): &(i64, String, String)| is_valid_vienna_plz(plz)).collect()
    };
    if wanted.is_empty() {
        return;
    }
    let semaphore = Arc::new(Semaphore::new(6));
    /// A stop's id, the address its entrance was looked up for, and the point.
    type FoundEntrance = (i64, String, String, f64, f64);
    let mut jobs: JoinSet<Option<FoundEntrance>> = JoinSet::new();
    for (id, strasse, plz) in wanted {
        let state = Arc::clone(state);
        let semaphore = Arc::clone(&semaphore);
        jobs.spawn(async move {
            let _permit = semaphore.acquire().await.ok()?;
            let (lat, lon) = wien_entrance(&state, &strasse, &plz).await?;
            Some((id, strasse, plz, lat, lon))
        });
    }
    let mut found: Vec<FoundEntrance> = Vec::new();
    while let Some(joined) = jobs.join_next().await {
        if let Ok(Some(hit)) = joined {
            found.push(hit);
        }
    }
    let Ok(conn) = state.db() else { return };
    for (id, strasse, plz, lat, lon) in found {
        // Only onto the address it was looked up for. Opening a tour starts
        // one of these in the background, and a stop whose address is
        // corrected while it is out would otherwise be handed the entrance
        // of the address it used to have.
        let _ = conn.execute(
            "UPDATE stops SET entrance_lat = ?1, entrance_lon = ?2 \
             WHERE id = ?3 AND pinned = 0 AND entrance_lat IS NULL AND strasse = ?4 AND plz = ?5",
            params![lat, lon, id, strasse, plz],
        );
    }
}

// ---------------------------------------------------------------------
// Accounts
//
// A driver signs in with a name and a password; a cookie keeps them signed
// in on that phone for a month from the last time they used it. Each one
// has their own tours and their own portal login. One account, the admin,
// also makes, changes and removes the others.
//
// Who owns what is decided in one place, `auth_mw`, from the address of the
// request: a route or a stop that is not the signed-in user's does not
// exist as far as they can tell. The handlers behind it stay written as if
// there were only one driver.
// ---------------------------------------------------------------------

const ADMIN_USERNAME: &str = "admin";
const SESSION_COOKIE: &str = "ear_session";
/// A month, counted from the last request rather than from signing in.
const SESSION_MAX_AGE_SECS: i64 = 30 * 24 * 60 * 60;
const MAX_USERNAME_LEN: usize = 40;
const MIN_PASSWORD_LEN: usize = 6;
const MAX_PASSWORD_LEN: usize = 200;

/// The signed-in user, attached to every request that got past `auth_mw`.
#[derive(Clone)]
struct AuthUser {
    id: i64,
    username: String,
    is_admin: bool,
}

fn hash_password(password: &str) -> Result<String, AppError> {
    use argon2::password_hash::{PasswordHasher, SaltString};
    let salt = SaltString::generate(&mut rand_core::OsRng);
    argon2::Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| {
            tracing::error!(error = %e, "password hashing failed");
            AppError::Internal("Das Passwort konnte nicht gespeichert werden.".into())
        })
}

fn verify_password(password: &str, hash: &str) -> bool {
    use argon2::password_hash::{PasswordHash, PasswordVerifier};
    PasswordHash::new(hash)
        .map(|parsed| argon2::Argon2::default().verify_password(password.as_bytes(), &parsed).is_ok())
        .unwrap_or(false)
}

/// 32 random bytes, in hex: the cookie's value and the session's key.
fn new_session_token() -> String {
    use rand_core::RngCore;
    let mut bytes = [0u8; 32];
    rand_core::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn session_token(headers: &HeaderMap) -> Option<String> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(name, _)| *name == SESSION_COOKIE)
        .map(|(_, value)| value.to_string())
        .filter(|t| t.len() == 64 && t.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// `Secure` whenever the request came in over HTTPS -- which, behind the
/// tunnel this runs behind, the proxy says in a header. Left off on plain
/// HTTP, where a `Secure` cookie would simply never be sent back and nobody
/// could sign in on a laptop at home.
fn session_cookie(headers: &HeaderMap, token: &str, max_age: i64) -> HeaderValue {
    // Also whenever the server is told it sits behind a proxy at all
    // (`EAR_TRUST_PROXY`): that is the public deployment, which is HTTPS
    // only, and the cookie must not depend on the proxy remembering to say
    // so in a header.
    let behind_proxy = matches!(std::env::var("EAR_TRUST_PROXY").as_deref(), Ok("1") | Ok("true") | Ok("yes"));
    let https = headers.get("x-forwarded-proto").and_then(|v| v.to_str().ok()) == Some("https");
    let secure = if https || behind_proxy { "; Secure" } else { "" };
    HeaderValue::from_str(&format!(
        "{SESSION_COOKIE}={token}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Lax{secure}"
    ))
    .unwrap_or_else(|_| HeaderValue::from_static(""))
}

fn user_for_session(conn: &Connection, token: &str) -> Result<Option<AuthUser>, AppError> {
    let now = chrono::Utc::now().timestamp();
    let found = conn
        .query_row(
            "SELECT u.id, u.username, u.is_admin, s.last_seen FROM sessions s JOIN users u ON u.id = s.user_id \
             WHERE s.token = ?1",
            params![token],
            |r| {
                Ok((
                    AuthUser { id: r.get(0)?, username: r.get(1)?, is_admin: r.get::<_, i64>(2)? != 0 },
                    r.get::<_, i64>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((user, last_seen)) = found else { return Ok(None) };
    if now - last_seen > SESSION_MAX_AGE_SECS {
        conn.execute("DELETE FROM sessions WHERE token = ?1", params![token])?;
        return Ok(None);
    }
    // Slid forward at most once an hour: every request would otherwise be a
    // write, on a database with one writer.
    if now - last_seen > 3600 {
        conn.execute("UPDATE sessions SET last_seen = ?1 WHERE token = ?2", params![now, token])?;
    }
    Ok(Some(user))
}

/// Everything under `/api/` needs a signed-in user, except signing in and
/// the health check. `/api/admin/` needs the admin. And a route or a stop
/// named in the address has to be the user's own -- anybody else's answers
/// exactly as one that was never there.
async fn auth_mw(State(state): State<Arc<AppState>>, mut req: Request, next: Next) -> Response {
    let path = req.uri().path().to_string();
    if !path.starts_with("/api/") || path == "/api/login" || path == "/api/health" {
        return next.run(req).await;
    }
    let checked = (|| -> Result<AuthUser, AppError> {
        let token = session_token(req.headers()).ok_or(AppError::Unauthorized)?;
        let conn = state.db()?;
        let user = user_for_session(&conn, &token)?.ok_or(AppError::Unauthorized)?;
        if path.starts_with("/api/admin/") && !user.is_admin {
            return Err(AppError::Forbidden("Nur für den Administrator.".into()));
        }
        let mut parts = path.trim_start_matches("/api/").split('/');
        let owner: Option<Option<i64>> = match (parts.next(), parts.next().and_then(|id| id.parse::<i64>().ok())) {
            (Some("routes"), Some(id)) => Some(
                conn.query_row("SELECT user_id FROM routes WHERE id = ?1", params![id], |r| r.get(0)).optional()?,
            ),
            (Some("stops"), Some(id)) => Some(
                conn.query_row(
                    "SELECT r.user_id FROM stops s JOIN routes r ON r.id = s.route_id WHERE s.id = ?1",
                    params![id],
                    |r| r.get(0),
                )
                .optional()?,
            ),
            _ => None,
        };
        match owner {
            Some(Some(owner)) if owner != user.id => Err(AppError::NotFound("Nicht gefunden".into())),
            _ => Ok(user),
        }
    })();
    match checked {
        Ok(user) => {
            req.extensions_mut().insert(user);
            next.run(req).await
        }
        Err(e) => e.into_response(),
    }
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

fn user_json(user: &AuthUser) -> Value {
    json!({ "id": user.id, "username": user.username, "is_admin": user.is_admin })
}

/// `POST /api/login`. One answer for a wrong name and a wrong password, so
/// the form cannot be used to find out which names exist.
/// A hash of nothing anybody knows, checked against when the name asked for
/// does not exist.
static DUMMY_HASH: once_cell::sync::Lazy<String> =
    once_cell::sync::Lazy::new(|| hash_password(&new_session_token()).unwrap_or_default());

/// Failed sign-ins per address: ten inside ten minutes and that address
/// waits until the oldest of them is ten minutes old. Per address rather
/// than per account, so nobody can lock a driver out of their own tours by
/// guessing at their name.
const LOGIN_MAX_FAILURES: usize = 10;
const LOGIN_FAILURE_WINDOW: Duration = Duration::from_secs(10 * 60);
static LOGIN_FAILURES: once_cell::sync::Lazy<StdMutex<HashMap<IpAddr, Vec<Instant>>>> =
    once_cell::sync::Lazy::new(|| StdMutex::new(HashMap::new()));

fn login_locked(ip: IpAddr) -> bool {
    let Ok(mut map) = LOGIN_FAILURES.lock() else { return false };
    let now = Instant::now();
    map.retain(|_, times| {
        times.retain(|t| now.duration_since(*t) < LOGIN_FAILURE_WINDOW);
        !times.is_empty()
    });
    map.get(&ip).is_some_and(|times| times.len() >= LOGIN_MAX_FAILURES)
}

fn login_failed(ip: IpAddr) {
    if let Ok(mut map) = LOGIN_FAILURES.lock() {
        map.entry(ip).or_default().push(Instant::now());
    }
}

fn login_succeeded(ip: IpAddr) {
    if let Ok(mut map) = LOGIN_FAILURES.lock() {
        map.remove(&ip);
    }
}

async fn login(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(payload): Json<LoginRequest>,
) -> Result<Response, AppError> {
    let username = payload.username.trim().to_string();
    let found: Option<(AuthUser, String)> = {
        let conn = state.db()?;
        conn.query_row(
            "SELECT id, username, is_admin, password_hash FROM users WHERE username = ?1",
            params![username],
            |r| {
                Ok((
                    AuthUser { id: r.get(0)?, username: r.get(1)?, is_admin: r.get::<_, i64>(2)? != 0 },
                    r.get::<_, String>(3)?,
                ))
            },
        )
        .optional()?
    };
    let ip = client_ip(&headers, peer, state.trust_proxy);
    if login_locked(ip) {
        return Err(AppError::BadRequest(
            "Zu viele Fehlversuche. Bitte ein paar Minuten warten und dann noch einmal anmelden.".into(),
        ));
    }
    let password = payload.password;
    // The same work whether the name exists or not, so the answer's timing
    // says nothing about which names do.
    let hash = found.as_ref().map(|(_, h)| h.clone()).unwrap_or_else(|| DUMMY_HASH.clone());
    // Hashing is slow on purpose; kept off the threads that serve requests.
    let ok = tokio::task::spawn_blocking(move || verify_password(&password, &hash)).await.unwrap_or(false);
    let Some((user, _)) = found.filter(|_| ok) else {
        login_failed(ip);
        // A guess costs a second, whichever half of it was wrong.
        tokio::time::sleep(Duration::from_millis(900)).await;
        return Err(AppError::BadRequest("Benutzername oder Passwort stimmt nicht.".into()));
    };
    login_succeeded(ip);
    let token = new_session_token();
    {
        let conn = state.db()?;
        let now = chrono::Utc::now().timestamp();
        conn.execute("DELETE FROM sessions WHERE last_seen < ?1", params![now - SESSION_MAX_AGE_SECS])?;
        conn.execute("INSERT INTO sessions (token, user_id, last_seen) VALUES (?1, ?2, ?3)", params![token, user.id, now])?;
    }
    let mut response = Json(user_json(&user)).into_response();
    response.headers_mut().insert(header::SET_COOKIE, session_cookie(&headers, &token, SESSION_MAX_AGE_SECS));
    Ok(response)
}

async fn logout(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Result<Response, AppError> {
    if let Some(token) = session_token(&headers) {
        let conn = state.db()?;
        conn.execute("DELETE FROM sessions WHERE token = ?1", params![token])?;
    }
    let mut response = Json(json!({ "ok": true })).into_response();
    response.headers_mut().insert(header::SET_COOKIE, session_cookie(&headers, "", 0));
    Ok(response)
}

async fn me(axum::Extension(user): axum::Extension<AuthUser>) -> Json<Value> {
    Json(user_json(&user))
}

fn clean_username(raw: &str) -> Result<String, AppError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(AppError::BadRequest("Bitte einen Benutzernamen eingeben.".into()));
    }
    check_len(name, "Benutzername", MAX_USERNAME_LEN)?;
    check_no_control_chars(name, "Benutzername", false)?;
    Ok(name.to_string())
}

fn check_new_password(password: &str) -> Result<(), AppError> {
    if password.chars().count() < MIN_PASSWORD_LEN {
        return Err(AppError::BadRequest(format!("Das Passwort braucht mindestens {MIN_PASSWORD_LEN} Zeichen.")));
    }
    check_len(password, "Passwort", MAX_PASSWORD_LEN)
}

fn username_taken(e: rusqlite::Error) -> AppError {
    match e {
        rusqlite::Error::SqliteFailure(f, _) if f.code == rusqlite::ErrorCode::ConstraintViolation => {
            AppError::BadRequest("Diesen Benutzernamen gibt es schon.".into())
        }
        other => other.into(),
    }
}

/// `GET /api/admin/users`: everybody, with what the admin wants to see at a
/// glance -- how many tours they have and whether their portal login is in.
async fn admin_list_users(State(state): State<Arc<AppState>>) -> Result<Json<Value>, AppError> {
    let conn = state.db()?;
    let mut stmt = conn.prepare(
        "SELECT u.id, u.username, u.is_admin, u.created_at, u.portal_username, \
                (SELECT COUNT(*) FROM routes r WHERE r.user_id = u.id) \
         FROM users u ORDER BY u.is_admin DESC, u.username COLLATE NOCASE",
    )?;
    let users: Vec<Value> = stmt
        .query_map([], |r| {
            Ok(json!({
                "id": r.get::<_, i64>(0)?,
                "username": r.get::<_, String>(1)?,
                "is_admin": r.get::<_, i64>(2)? != 0,
                "created_at": r.get::<_, String>(3)?,
                "portal_username": r.get::<_, Option<String>>(4)?,
                "route_count": r.get::<_, i64>(5)?,
            }))
        })?
        .collect::<Result<_, _>>()?;
    Ok(Json(json!({ "users": users })))
}

#[derive(Deserialize)]
struct UserCreate {
    username: String,
    password: String,
}

async fn admin_create_user(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UserCreate>,
) -> Result<Json<Value>, AppError> {
    let username = clean_username(&payload.username)?;
    check_new_password(&payload.password)?;
    let hash = hash_password(&payload.password)?;
    let conn = state.db()?;
    conn.execute(
        "INSERT INTO users (username, password_hash, is_admin, created_at) VALUES (?1, ?2, 0, ?3)",
        params![username, hash, now_iso()],
    )
    .map_err(username_taken)?;
    Ok(Json(json!({ "id": conn.last_insert_rowid(), "username": username })))
}

#[derive(Deserialize)]
struct UserUpdate {
    username: Option<String>,
    password: Option<String>,
}

/// `PATCH /api/admin/users/:id`: a new name, a new password, or both. A new
/// password signs that user out everywhere, which is the point of setting
/// one. The admin's own password is set with `EAR_ADMIN_PASSWORD`.
async fn admin_update_user(
    State(state): State<Arc<AppState>>,
    AxPath(user_id): AxPath<i64>,
    Json(payload): Json<UserUpdate>,
) -> Result<Json<Value>, AppError> {
    let username = payload.username.as_deref().map(clean_username).transpose()?;
    if let Some(password) = &payload.password {
        check_new_password(password)?;
    }
    let hash = payload.password.as_deref().map(hash_password).transpose()?;
    let mut conn = state.db()?;
    let tx = conn.transaction()?;
    let is_admin: bool = tx
        .query_row("SELECT is_admin FROM users WHERE id = ?1", params![user_id], |r| r.get::<_, i64>(0))
        .optional()?
        .ok_or_else(|| AppError::NotFound("Benutzer nicht gefunden".into()))?
        != 0;
    if is_admin {
        return Err(AppError::Forbidden("Das Administrator-Konto wird am Server eingestellt und kann hier nicht geändert werden.".into()));
    }
    if let Some(username) = &username {
        tx.execute("UPDATE users SET username = ?1 WHERE id = ?2", params![username, user_id]).map_err(username_taken)?;
    }
    if let Some(hash) = &hash {
        tx.execute("UPDATE users SET password_hash = ?1 WHERE id = ?2", params![hash, user_id])?;
        tx.execute("DELETE FROM sessions WHERE user_id = ?1", params![user_id])?;
    }
    tx.commit()?;
    Ok(Json(json!({ "ok": true })))
}

/// `DELETE /api/admin/users/:id`: the user, their tours and their portal
/// login, all at once (`ON DELETE CASCADE`). Not the admin.
async fn admin_delete_user(
    State(state): State<Arc<AppState>>,
    AxPath(user_id): AxPath<i64>,
) -> Result<Json<Value>, AppError> {
    let conn = state.db()?;
    let is_admin: bool = conn
        .query_row("SELECT is_admin FROM users WHERE id = ?1", params![user_id], |r| r.get::<_, i64>(0))
        .optional()?
        .ok_or_else(|| AppError::NotFound("Benutzer nicht gefunden".into()))?
        != 0;
    if is_admin {
        return Err(AppError::Forbidden("Das Administrator-Konto kann nicht gelöscht werden.".into()));
    }
    conn.execute("DELETE FROM users WHERE id = ?1", params![user_id])?;
    Ok(Json(json!({ "ok": true })))
}

// ---------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------

#[derive(Deserialize, Default)]
struct RouteCreate {
    name: Option<String>,
}

#[derive(Deserialize, Default)]
struct RouteUpdate {
    name: Option<String>,
    status: Option<String>,
    /// "vm" or "tk": which kind of tour the Ladeliste treats this as.
    ladeliste_mode: Option<String>,
}

#[derive(Deserialize)]
struct StopCreate {
    kunde: String,
    strasse: String,
    plz: String,
    paket: Option<String>,
    notiz: Option<String>,
    telefon: Option<String>,
    lat: Option<f64>,
    lon: Option<f64>,
}

#[derive(Deserialize, Default)]
struct StopUpdate {
    kunde: Option<String>,
    strasse: Option<String>,
    plz: Option<String>,
    paket: Option<String>,
    notiz: Option<String>,
    telefon: Option<String>,
    delivered: Option<bool>,
    /// What happened at the door: one of `mod outcome`'s three, or "open"
    /// to take the answer back. `delivered` is the older spelling of the
    /// plain tick and still accepted.
    outcome: Option<String>,
    lat: Option<f64>,
    lon: Option<f64>,
    /// Fixed stops (start/via/end) only -- switch this one out of, or back
    /// into, this route's plan. See the `excluded` column in `SCHEMA`.
    excluded: Option<bool>,
}

// ---------------------------------------------------------------------
// Routes API
// ---------------------------------------------------------------------

async fn list_routes(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
) -> Result<Json<Vec<RouteSummary>>, AppError> {
    let conn = state.db()?;
    // The same two numbers `get_route_detail` reports -- see there.
    let mut stmt = conn.prepare(&format!(
        "SELECT r.id, r.name, r.status, r.created_at, r.completed_at, r.needs_optimize,
                COUNT(CASE WHEN s.kind = 'customer' AND NOT COALESCE({SQL_SKIPS_DOOR}, 0) THEN 1 END) AS customer_count,
                SUM(CASE WHEN s.kind = 'customer' AND s.delivered = 1 AND NOT COALESCE({SQL_SKIPS_DOOR}, 0) THEN 1 ELSE 0 END) AS delivered_count
         FROM routes r LEFT JOIN stops s ON s.route_id = r.id
         WHERE r.user_id = ?1
         GROUP BY r.id ORDER BY r.created_at DESC",
    ))?;
    let rows = stmt
        .query_map(params![user.id], |r| {
            Ok(RouteSummary {
                id: r.get(0)?,
                name: r.get(1)?,
                status: r.get(2)?,
                created_at: r.get(3)?,
                completed_at: r.get(4)?,
                needs_optimize: r.get::<_, i64>(5)? != 0,
                customer_count: r.get::<_, i64>(6)?,
                delivered_count: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(rows))
}

/// Writes a new route and its three fixed stops, flagged for optimizing.
fn insert_route(state: &AppState, user_id: i64, name: &str) -> Result<i64, AppError> {
    // One timestamp for the whole creation, not one per INSERT — the route
    // and its three fixed stops are created in the same instant, and four
    // separate `now_iso()` calls only make that look otherwise.
    let created_at = now_iso();

    // The route row and its 3 fixed stops are one transaction — without
    // this, a crash between the route insert and the stop inserts leaves
    // an orphan route with no stops behind instead of either both existing
    // or neither.
    let mut conn = state.db()?;
    let tx = conn.transaction()?;
    // `needs_optimize = 1` from the very first moment, cleared only by
    // the successful optimization below. A route inserted as "up to
    // date" and then failing to optimize (OSRM briefly unreachable)
    // would sit in the list looking complete while having no geometry
    // and no leg distances at all, with no banner offering to fix it.
    tx.execute(
        "INSERT INTO routes (name, status, created_at, needs_optimize, user_id) VALUES (?1, 'active', ?2, 1, ?3)",
        params![name, created_at, user_id],
    )?;
    let route_id = tx.last_insert_rowid();
    // Fixed points, geocoded once ahead of time (see START_LAT/VIA_LAT)
    // — route creation never needs to resolve these at runtime.
    tx.execute(
        "INSERT INTO stops (route_id, kind, kunde, strasse, plz, lat, lon, order_index, created_at) \
         VALUES (?1, 'start', 'Start', 'Petritschgasse 24', '1210', ?2, ?3, 0, ?4)",
        params![route_id, START_LAT, START_LON, created_at],
    )?;
    tx.execute(
        "INSERT INTO stops (route_id, kind, kunde, strasse, plz, lat, lon, order_index, created_at) \
         VALUES (?1, 'via', 'Lager', 'Oberlaaer Straße 298', '1230', ?2, ?3, 1, ?4)",
        params![route_id, VIA_LAT, VIA_LON, created_at],
    )?;
    tx.execute(
        "INSERT INTO stops (route_id, kind, kunde, strasse, plz, lat, lon, order_index, created_at) \
         VALUES (?1, 'end', 'Ziel', 'Petritschgasse 24', '1210', ?2, ?3, 2, ?4)",
        params![route_id, START_LAT, START_LON, created_at],
    )?;
    tx.commit()?;
    Ok(route_id)
}

async fn create_route(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
    Json(payload): Json<RouteCreate>,
) -> Result<Json<RouteDetail>, AppError> {
    let name = payload
        .name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("Tour {}", chrono::Local::now().format("%d.%m.%Y")));
    check_len(&name, "Name", MAX_ROUTE_NAME_LEN)?;
    check_no_control_chars(&name, "Name", false)?;

    let route_id = insert_route(&state, user.id, &name)?;
    reoptimize_best_effort(&state, route_id).await;
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn get_route(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    // A tour from before entrances existed catches up behind this answer;
    // the next time it is opened they are there.
    let filler = Arc::clone(&state);
    tokio::spawn(async move { fill_entrances(&filler, route_id).await });
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn update_route(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<RouteUpdate>,
) -> Result<Json<RouteDetail>, AppError> {
    let mut conn = state.db()?;
    require_route_exists(&conn, route_id)?;

    // Validate everything before writing anything: a request carrying a
    // good name and a bogus status must change neither, rather than
    // renaming the route and then 400-ing as if it had done nothing.
    let new_name = match payload.name.as_deref().map(str::trim) {
        Some("") => return Err(AppError::BadRequest("Name darf nicht leer sein.".into())),
        Some(name) => {
            check_len(name, "Name", MAX_ROUTE_NAME_LEN)?;
            check_no_control_chars(name, "Name", false)?;
            Some(name.to_string())
        }
        None => None,
    };
    let new_status = match payload.status.as_deref() {
        Some(s) if s != "active" && s != "completed" => {
            return Err(AppError::BadRequest("Ungültiger Status".into()))
        }
        other => other,
    };

    if payload.ladeliste_mode.as_deref().is_some_and(|m| m != "vm" && m != "tk") {
        return Err(AppError::BadRequest("Ungültige Tourart".into()));
    }

    let tx = conn.transaction()?;
    if let Some(name) = &new_name {
        tx.execute("UPDATE routes SET name = ?1 WHERE id = ?2", params![name, route_id])?;
    }
    if let Some(mode) = &payload.ladeliste_mode {
        tx.execute("UPDATE routes SET ladeliste_mode = ?1 WHERE id = ?2", params![mode, route_id])?;
    }
    if let Some(status) = new_status {
        let completed_at = if status == "completed" { Some(now_iso()) } else { None };
        tx.execute(
            "UPDATE routes SET status = ?1, completed_at = ?2 WHERE id = ?3",
            params![status, completed_at, route_id],
        )?;
    }
    tx.commit()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn delete_route(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<Value>, AppError> {
    let conn = state.db()?;
    require_route_exists(&conn, route_id)?;
    // `stops.route_id` has `ON DELETE CASCADE` (and `open_db` turns
    // `PRAGMA foreign_keys` on for every connection), so deleting the route
    // alone already removes its stops atomically — no separate DELETE
    // needed, and no window where the route is gone but its stops linger.
    conn.execute("DELETE FROM routes WHERE id = ?1", params![route_id])?;
    Ok(Json(json!({ "ok": true })))
}

async fn optimize_route(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    {
        let conn = state.db()?;
        require_route_exists(&conn, route_id)?;
        // Asking for the order is asking for a new one: the tour stops
        // being hand-sorted.
        conn.execute("UPDATE routes SET hand_ordered = 0 WHERE id = ?1", params![route_id])?;
    }
    reoptimize_route(&state, route_id).await?;
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

// ---------------------------------------------------------------------
// Pace: what the tours already driven say about the next one
// ---------------------------------------------------------------------

/// How long a door takes, and how long the loading at the Lager does, as
/// measured on the finished tours. Either is absent until there is enough
/// to say. The arrival times themselves are worked out in the app, from
/// these and from the day's own ticks.
#[derive(Serialize, Default, Debug, PartialEq)]
struct PaceHistory {
    door_minutes: Option<f64>,
    lager_minutes: Option<f64>,
    /// `door_minutes` for each tour driven before, by `pace_tour_key`: that
    /// tour's own doors, pulled towards the figure for all of them. A round
    /// is the same customers every week, and the rounds are not alike.
    door_by_tour: HashMap<String, f64>,
    /// Minutes from leaving for the Lager to ticking it: the drive there and
    /// whatever the morning holds before the tick. Absent until two finished
    /// tours carry a departure.
    lead_minutes: Option<f64>,
}

/// One finished tour, as the pace is read from it.
struct PaceTour {
    name: String,
    departed_at: Option<chrono::DateTime<chrono::Utc>>,
    stops: Vec<PaceStop>,
}

/// Minutes from the departure to the Lager's tick. Nothing where the Lager
/// was ticked by the first door rather than by hand, and nothing where the
/// two are further apart than a morning: a stamp from another day.
fn pace_lead(tour: &PaceTour) -> Option<f64> {
    let departed = tour.departed_at?;
    let loaded_at = tour.stops.iter().find(|s| s.kind == "via" && !s.excluded)?.settled_at?;
    let first_door = tour.stops.iter().filter(|s| s.is_driven_door()).filter_map(|s| s.settled_at).min();
    if first_door.is_some_and(|at| at <= loaded_at) {
        return None;
    }
    let minutes = (loaded_at - departed).num_milliseconds() as f64 / 60_000.0;
    (1.0..=180.0).contains(&minutes).then_some(minutes)
}

/// How many doors' worth the figure for all tours weighs against one tour's
/// own: a round driven once has said little yet.
const PACE_TOUR_WEIGHT: f64 = 8.0;

/// What a tour is recognised by from one week to the next: its name,
/// whatever the capitals and the spacing. `tourKey` in index.html is the
/// same rule.
fn pace_tour_key(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// The tours learned from: the most recent, so a change of round or of
/// season is caught up with inside a few weeks.
const PACE_TOURS: i64 = 30;
/// The fewest door times worth calling a history.
const PACE_FEWEST_SAMPLES: usize = 10;
/// No single door counts for more than this many minutes: a lunch break is
/// not a slow customer.
const PACE_CAP_MIN: f64 = 15.0;

/// One stop of a finished tour, in list order, as the pace is read from it.
struct PaceStop {
    kind: String,
    excluded: bool,
    outcome: Option<String>,
    settled_at: Option<chrono::DateTime<chrono::Utc>>,
    next_leg_min: Option<f64>,
}

impl PaceStop {
    fn is_driven_door(&self) -> bool {
        self.kind == "customer" && self.outcome.as_deref().is_some_and(|o| !outcome::skips_door(o))
    }
}

/// What one tour measured: the minutes each door took beyond the drive to
/// it, and the wait at the Lager before the first of them.
fn pace_samples(ordered: &[PaceStop]) -> (Vec<f64>, Option<f64>) {
    // Planned driving minutes up to each stop's arrival. Only the legs
    // actually driven count: every stop not switched off, and a switched-off
    // Start, whose leg is the drive from where the driver was.
    let mut arrivals = Vec::with_capacity(ordered.len());
    let mut minutes = 0.0;
    for s in ordered {
        arrivals.push(minutes);
        if !s.excluded || s.kind == "start" {
            minutes += s.next_leg_min.filter(|m| m.is_finite()).unwrap_or(0.0);
        }
    }

    let mut stamped: Vec<(chrono::DateTime<chrono::Utc>, f64)> = ordered
        .iter()
        .zip(&arrivals)
        .filter(|(s, _)| s.is_driven_door())
        .filter_map(|(s, &arr)| s.settled_at.map(|at| (at, arr)))
        .collect();
    stamped.sort_by_key(|(at, _)| *at);

    let mut doors = Vec::new();
    for pair in stamped.windows(2) {
        let gap = (pair[1].0 - pair[0].0).num_milliseconds() as f64 / 60_000.0;
        let drive = pair[1].1 - pair[0].1;
        // Two ticks in the same breath are one door ticked twice over, and
        // three quarters of an hour is a break; neither is a door time.
        if (0.5..=45.0).contains(&gap) && drive >= 0.3 {
            doors.push((gap - drive).max(0.5));
        }
    }

    // From the Lager's tick to the first door's, less the drive between
    // them. Nothing where that first door is what ticked the Lager (see
    // `record_outcome`): the two stamps are then the same moment.
    let wait = (|| {
        let (lager_idx, lager) = ordered.iter().enumerate().find(|(_, s)| s.kind == "via" && !s.excluded)?;
        let loaded_at = lager.settled_at?;
        let &(first_at, first_arrival) = stamped.first()?;
        let from = arrivals[lager_idx];
        (first_at > loaded_at && first_arrival >= from)
            .then(|| (first_at - loaded_at).num_milliseconds() as f64 / 60_000.0 - (first_arrival - from))
    })();

    (doors, wait)
}

fn learn_pace(tours: &[PaceTour]) -> PaceHistory {
    let mut doors: Vec<f64> = Vec::new();
    let mut waits: Vec<f64> = Vec::new();
    let mut leads: Vec<f64> = Vec::new();
    let mut by_tour: HashMap<String, Vec<f64>> = HashMap::new();
    for tour in tours {
        let (d, w) = pace_samples(&tour.stops);
        by_tour.entry(pace_tour_key(&tour.name)).or_default().extend(&d);
        doors.extend(d);
        waits.extend(w);
        leads.extend(pace_lead(tour));
    }
    if doors.len() < PACE_FEWEST_SAMPLES {
        return PaceHistory::default();
    }
    let door = doors.iter().map(|d| d.min(PACE_CAP_MIN)).sum::<f64>() / doors.len() as f64;
    // What is left of the wait once the first door's own time is taken off
    // it. The median, because one morning spent waiting for the kitchen is
    // not what the next one will be.
    let mut loading: Vec<f64> =
        waits.iter().map(|w| w - door).filter(|l| (-5.0..=90.0).contains(l)).map(|l| l.max(0.0)).collect();
    loading.sort_by(|a, b| a.total_cmp(b));
    let door_by_tour = by_tour
        .into_iter()
        .filter(|(_, own)| !own.is_empty())
        .map(|(key, own)| {
            let sum: f64 = own.iter().map(|d| d.min(PACE_CAP_MIN)).sum();
            let blended = (sum + PACE_TOUR_WEIGHT * door) / (own.len() as f64 + PACE_TOUR_WEIGHT);
            (key, blended.clamp(2.0, PACE_CAP_MIN))
        })
        .collect();
    PaceHistory {
        door_minutes: Some(door.clamp(2.0, PACE_CAP_MIN)),
        lager_minutes: (loading.len() >= 2).then(|| loading[loading.len() / 2]),
        door_by_tour,
        // The median again: one morning in a traffic jam is not the next.
        lead_minutes: {
            leads.sort_by(|a, b| a.total_cmp(b));
            (leads.len() >= 2).then(|| leads[leads.len() / 2])
        },
    }
}

/// `GET /api/pace`. Only finished tours: one still being driven is its own
/// measurement, taken in the app, and must not be counted twice.
async fn pace_history(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
) -> Result<Json<PaceHistory>, AppError> {
    let conn = state.db()?;
    let mut stmt = conn.prepare(
        "SELECT s.route_id, s.kind, s.excluded, s.outcome, s.delivered, s.settled_at, s.next_leg_min, r.name, r.departed_at \
         FROM stops s JOIN (SELECT id, created_at, name, departed_at FROM routes WHERE status = 'completed' AND user_id = ?2 \
                            ORDER BY created_at DESC LIMIT ?1) r ON r.id = s.route_id \
         ORDER BY s.route_id, s.order_index, s.id",
    )?;
    let parse = |t: Option<String>| {
        t.and_then(|t| chrono::DateTime::parse_from_rfc3339(&t).ok()).map(|t| t.with_timezone(&chrono::Utc))
    };
    let rows: Vec<(i64, String, Option<chrono::DateTime<chrono::Utc>>, PaceStop)> = stmt
        .query_map(params![PACE_TOURS, user.id], |r| {
            Ok((
                r.get(0)?,
                r.get::<_, Option<String>>(7)?.unwrap_or_default(),
                parse(r.get(8)?),
                PaceStop {
                    kind: r.get(1)?,
                    excluded: r.get::<_, i64>(2)? != 0,
                    outcome: effective_outcome(r.get(3)?, r.get::<_, i64>(4)? != 0),
                    settled_at: r
                        .get::<_, Option<String>>(5)?
                        .and_then(|t| chrono::DateTime::parse_from_rfc3339(&t).ok())
                        .map(|t| t.with_timezone(&chrono::Utc)),
                    next_leg_min: r.get(6)?,
                },
            ))
        })?
        .collect::<Result<_, _>>()?;
    let mut tours: Vec<PaceTour> = Vec::new();
    let mut last_route = None;
    for (route_id, name, departed_at, stop) in rows {
        if last_route != Some(route_id) {
            tours.push(PaceTour { name, departed_at, stops: Vec::new() });
            last_route = Some(route_id);
        }
        tours.last_mut().expect("pushed above").stops.push(stop);
    }
    Ok(Json(learn_pace(&tours)))
}

#[derive(Deserialize)]
struct StopOrder {
    stop_ids: Vec<i64>,
}

/// `PUT /api/routes/:id/order`: the customers in the driver's own order.
/// Every customer of the route, once each -- a list that has fallen behind
/// the route (a stop added or removed since it was drawn) is refused rather
/// than applied to the stops it happens to still name.
async fn set_stop_order(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<StopOrder>,
) -> Result<Json<RouteDetail>, AppError> {
    // Behind any optimization already running, so its answer cannot land on
    // top of this order a moment later.
    let lock = state.route_lock(route_id).await;
    {
        let _guard = lock.lock().await;
        let mut conn = state.db()?;
        require_route_exists(&conn, route_id)?;
        let tx = conn.transaction()?;
        let mut existing: Vec<i64> = {
            let mut stmt = tx.prepare("SELECT id FROM stops WHERE route_id = ?1 AND kind = 'customer'")?;
            let ids = stmt.query_map(params![route_id], |r| r.get(0))?.collect::<Result<_, _>>()?;
            ids
        };
        let mut wanted = payload.stop_ids.clone();
        existing.sort_unstable();
        wanted.sort_unstable();
        if existing != wanted {
            return Err(AppError::BadRequest(
                "Die Tour hat sich inzwischen geändert. Bitte die Reihenfolge noch einmal öffnen.".into(),
            ));
        }
        // Start and Lager keep 0 and 1; Ziel goes behind the last customer.
        for (pos, id) in payload.stop_ids.iter().enumerate() {
            tx.execute("UPDATE stops SET order_index = ?1 WHERE id = ?2", params![pos as i64 + 2, id])?;
        }
        tx.execute(
            "UPDATE stops SET order_index = ?1 WHERE route_id = ?2 AND kind = 'end'",
            params![payload.stop_ids.len() as i64 + 2, route_id],
        )?;
        tx.execute("UPDATE routes SET hand_ordered = 1, needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        tx.commit()?;
    }
    reoptimize_best_effort(&state, route_id).await;
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

#[derive(Deserialize)]
struct Position {
    lat: f64,
    lon: f64,
}

/// `POST /api/routes/:id/position`: where the driver is right now. Kept
/// for a tour that starts from there rather than from the depot; nothing is
/// planned by this call itself.
async fn set_position(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<Position>,
) -> Result<Json<Value>, AppError> {
    check_latlon(payload.lat, payload.lon)?;
    let conn = state.db()?;
    require_route_exists(&conn, route_id)?;
    conn.execute(
        "UPDATE routes SET here_lat = ?1, here_lon = ?2, here_at = ?3 WHERE id = ?4",
        params![payload.lat, payload.lon, chrono::Utc::now().timestamp(), route_id],
    )?;
    Ok(Json(json!({ "ok": true })))
}

/// A departure older than this is another day's: the tour was not reset, or
/// the tap was made the evening before.
const DEPARTURE_STALE_SECS: i64 = 4 * 3600;

/// `POST /api/routes/:id/departed`: the driver has started navigation to the
/// Lager, which is when the van leaves. The one moment of the day no tick
/// marks -- and so the one stretch nothing could be learned about: what the
/// morning takes before the Lager is ticked (see `learn_pace`).
///
/// Only on a tour that has not begun, with the Lager still open. The first
/// tap stands: a second one on the way is not when the van left.
async fn mark_departed(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<Value>, AppError> {
    let conn = state.db()?;
    require_route_exists(&conn, route_id)?;
    let now = chrono::Utc::now();
    let (status, stamped): (String, Option<String>) =
        conn.query_row("SELECT status, departed_at FROM routes WHERE id = ?1", params![route_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
    let lager_open: bool = conn
        .query_row(
            "SELECT 1 FROM stops WHERE route_id = ?1 AND kind = 'via' AND excluded = 0 \
             AND outcome IS NULL AND delivered = 0 LIMIT 1",
            params![route_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    let under_way: bool = conn
        .query_row(
            &format!(
                "SELECT 1 FROM stops s WHERE s.route_id = ?1 AND s.kind IN ('customer', 'via', 'end') \
                 AND (s.outcome IS NOT NULL OR s.delivered = 1) AND NOT COALESCE({SQL_SKIPS_DOOR}, 0) LIMIT 1"
            ),
            params![route_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    let fresh = stamped
        .as_deref()
        .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
        .is_some_and(|t| {
            let age = (now - t.with_timezone(&chrono::Utc)).num_seconds();
            (0..DEPARTURE_STALE_SECS).contains(&age)
        });
    let departed_at = if status == "active" && lager_open && !under_way && !fresh {
        let at = now.to_rfc3339();
        conn.execute("UPDATE routes SET departed_at = ?1 WHERE id = ?2", params![at, route_id])?;
        Some(at)
    } else {
        stamped
    };
    Ok(Json(json!({ "departed_at": departed_at })))
}

/// What a re-check did, so the app can tell the driver rather than silently
/// moving pins under them.
#[derive(Serialize, Default)]
struct RecheckReport {
    /// Stops whose coordinates actually changed.
    moved: i64,
    /// Stops that came back approximate — the "≈" badge — and are worth a
    /// look before the tour.
    approximate: i64,
    /// Stops the geocoders could not resolve at all, or that are filed under
    /// the wrong district. Left exactly as they were.
    unresolved: Vec<String>,
    /// Hand-placed pins, skipped on purpose.
    skipped_pinned: i64,
}

/// How far a re-resolved point has to land from the stored one before
/// `recheck_addresses` counts the stop as having actually moved: ~1 m,
/// expressed in degrees. Below that the difference is float noise from
/// re-resolving the very same register entry, and reporting it to the driver
/// as a moved pin would cry wolf.
const RECHECK_MOVED_EPSILON_DEG: f64 = 1e-5;

/// What a re-resolve of one stop actually changed, as the two separate
/// questions `recheck_addresses` has to answer about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RecheckChange {
    /// The point moved far enough to matter. This is the only kind of change
    /// that invalidates the route's stop order and geometry, so it alone
    /// drives `needs_optimize` and the follow-up optimization.
    moved: bool,
    /// Something is worth writing back -- a moved point, or a stale
    /// approximation badge, which is a one-column update that must not cost
    /// an OSRM round trip.
    write: bool,
}

/// Compares a stored stop against what the geocoders say about it today.
///
/// The badge comparison is the half that is easy to leave out, and leaving it
/// out is what pinned a stale "~" on a row forever: a stop entered before the
/// resolver could place it exactly carries a stored 'street'/'district' tag,
/// and when the register later answers exactly at the same point there is no
/// coordinate change to notice. It matters in the other direction too -- a
/// stop that used to resolve exactly and now only resolves to the street has
/// to stop claiming to be exact.
fn recheck_change(
    stored: (f64, f64, Option<&str>),
    resolved: (f64, f64, Option<&str>),
) -> RecheckChange {
    let (stored_lat, stored_lon, stored_tag) = stored;
    let (lat, lon, tag) = resolved;
    let moved = (lat - stored_lat).abs() > RECHECK_MOVED_EPSILON_DEG
        || (lon - stored_lon).abs() > RECHECK_MOVED_EPSILON_DEG;
    RecheckChange { moved, write: moved || tag != stored_tag }
}

/// Re-resolves every customer address on a route against the geocoders as
/// they are *today*, and reports what changed.
///
/// This exists because the resolver improves: it learned Stiegen and
/// Kleingarten-Parzellen, and it learned to refuse a confident answer for
/// the wrong street or the wrong district. None of that reaches a stop that
/// was entered before the change — its coordinates were written once and
/// nothing re-examines them — so without this, a route already in the
/// database keeps whatever it was given, including the wrong pins the newer
/// checks exist to prevent.
///
/// Two things it deliberately does not touch:
///   - a stop whose pin the driver placed by hand (`pinned`). They stood in
///     front of the building; no geocoder outranks that.
///   - a stop the geocoders now refuse. Refusing is not the same as knowing
///     better, and replacing a real position with a district centroid would
///     be a downgrade. Those come back in `unresolved` for the driver to
///     look at.
async fn recheck_addresses(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
) -> Result<Json<Value>, AppError> {
    /// One customer stop as stored, ahead of re-resolving it: what to ask the
    /// geocoders with, and what their answer has to be compared against.
    struct StopBefore {
        id: i64,
        kunde: String,
        strasse: String,
        plz: String,
        lat: f64,
        lon: f64,
        /// The stored `location_precision`, so a stop whose badge has become
        /// wrong in *either* direction gets corrected -- see the write-back
        /// decision below.
        precision: Option<String>,
    }

    let stops: Vec<StopBefore> = {
        let conn = state.db()?;
        require_route_exists(&conn, route_id)?;
        let mut stmt = conn.prepare(
            "SELECT id, kunde, strasse, plz, lat, lon, location_precision FROM stops \
             WHERE route_id = ?1 AND kind = 'customer' AND pinned = 0 ORDER BY order_index",
        )?;
        let rows = stmt.query_map(params![route_id], |r| {
            Ok(StopBefore {
                id: r.get(0)?,
                kunde: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                strasse: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                plz: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                lat: r.get(4)?,
                lon: r.get(5)?,
                precision: r.get(6)?,
            })
        })?;
        rows.collect::<Result<_, _>>()?
    };
    let skipped_pinned: i64 = {
        let conn = state.db()?;
        conn.query_row(
            "SELECT COUNT(*) FROM stops WHERE route_id = ?1 AND kind = 'customer' AND pinned = 1",
            params![route_id],
            |r| r.get(0),
        )?
    };

    let mut report = RecheckReport { skipped_pinned, ..Default::default() };
    /// One pending write-back: which stop, where to, the new badge, whether
    /// this counts as a move, and the address it was resolved *from* — see
    /// the guarded UPDATE below for why that last part is carried this far.
    struct Update {
        id: i64,
        lat: f64,
        lon: f64,
        precision: Option<&'static str>,
        moved: bool,
        from_strasse: String,
        from_plz: String,
    }
    let mut updates: Vec<Update> = Vec::new();
    for before in stops {
        // Sequential rather than the bulk import's parallel fan-out: this
        // runs on a route that already exists, nobody is waiting on a form,
        // and being gentle with the register and Nominatim matters more than
        // shaving seconds off a button a driver presses once.
        match geocode_address(&state, &before.strasse, &before.plz).await {
            Ok((lat, lon, _, precision)) => {
                let tag = precision.tag();
                if precision != Precision::Exact {
                    report.approximate += 1;
                }
                let change = recheck_change(
                    (before.lat, before.lon, before.precision.as_deref()),
                    (lat, lon, tag),
                );
                if change.write {
                    updates.push(Update {
                        id: before.id,
                        lat,
                        lon,
                        precision: tag,
                        moved: change.moved,
                        from_strasse: before.strasse.clone(),
                        from_plz: before.plz.clone(),
                    });
                }
            }
            // The reason matters more than the fact: "exists in the 18th
            // district" is a fix the driver can make in ten seconds, while
            // "not found" means looking the address up themselves. Both end
            // up in front of them either way.
            Err(AppError::Geocode { code, message, .. }) if code == "wrong_district" => {
                report.unresolved.push(format!("{}: {message}", before.kunde))
            }
            Err(_) => report
                .unresolved
                .push(format!("{} ({})", before.kunde, before.strasse)),
        }
    }

    // Only a stop that actually *moved* changes the shape of the tour. A
    // badge-only correction rewrites one column and nothing else, so it must
    // not flag the route stale or spend an OSRM round trip arriving back at
    // exactly the order and geometry already stored.
    let mut any_moved = false;
    if !updates.is_empty() {
        let mut conn = state.db()?;
        let tx = conn.transaction()?;
        for u in updates {
            // Guarded on the address it was resolved from, and on the pin
            // still being the geocoder's to move.
            //
            // This handler reads every stop, then spends a throttled second
            // per uncached address against the register — half a minute or
            // more on a full route — and only then writes back. The app
            // stays interactive throughout, by design, so the driver is free
            // to edit a stop or drop a pin in that window, and an
            // `UPDATE ... WHERE id = ?` would happily land the *old*
            // address's coordinates on the row afterwards. That gives a stop
            // whose text says one address and whose pin is at another, with
            // nothing to show for it; land it on a stop the driver has just
            // hand-pinned and it is worse, because `pinned` stays 1 and
            // every future re-check skips the row it just corrupted.
            //
            // Matching the address in the WHERE clause makes the newer
            // action win, which is the right resolution: the driver was
            // looking at the stop more recently than the geocoder was.
            let applied = tx.execute(
                "UPDATE stops SET lat = ?1, lon = ?2, location_precision = ?3 \
                 WHERE id = ?4 AND pinned = 0 AND strasse = ?5 AND plz = ?6",
                params![u.lat, u.lon, u.precision, u.id, u.from_strasse, u.from_plz],
            )?;
            // The report counts what actually landed, not what was intended
            // — telling a driver three pins moved when one of their own
            // edits quietly won the race would send them looking for a
            // change that never happened.
            if applied > 0 {
                if u.moved {
                    report.moved += 1;
                    any_moved = true;
                }
            } else {
                tracing::debug!(stop_id = u.id, "re-check skipped: the stop changed while it was being re-resolved");
            }
        }
        if any_moved {
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        }
        tx.commit()?;
    }
    if any_moved {
        reoptimize_best_effort(&state, route_id).await;
    }

    let conn = state.db()?;
    let route = get_route_detail(&conn, route_id)?;
    Ok(Json(json!({ "route": route, "report": report })))
}

async fn reset_delivered(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    // Opens every stop again -- Lager and Ziel with the doors -- and plans
    // the tour afresh behind itself: the order it had was made for the day it
    // was driven, the doors answered for sitting in front as they were driven
    // and the rest planned from wherever the van was. A finished tour is
    // active again, since it now has doors left.
    let was_driven = {
        let mut conn = state.db()?;
        require_route_exists(&conn, route_id)?;
        let tx = conn.transaction()?;
        let was_driven = tx.execute(
            "UPDATE stops SET outcome = NULL, delivered = 0, settled_at = NULL \
             WHERE route_id = ?1 AND (outcome IS NOT NULL OR delivered = 1)",
            params![route_id],
        )? > 0;
        tx.execute(
            "UPDATE routes SET status = 'active', completed_at = NULL WHERE id = ?1 AND status = 'completed'",
            params![route_id],
        )?;
        // A tour driven again leaves again.
        tx.execute("UPDATE routes SET departed_at = NULL WHERE id = ?1", params![route_id])?;
        if was_driven {
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        }
        tx.commit()?;
        was_driven
    };
    if was_driven {
        reoptimize_best_effort(&state, route_id).await;
    }
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn add_stop(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<StopCreate>,
) -> Result<Json<RouteDetail>, AppError> {
    {
        let conn = state.db()?;
        require_route_exists(&conn, route_id)?;
    }

    let kunde = payload.kunde.trim().to_string();
    let strasse = payload.strasse.trim().to_string();
    let plz = payload.plz.trim().to_string();
    let paket = payload.paket.as_deref().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    let notiz = payload.notiz.as_deref().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    if kunde.is_empty() || strasse.is_empty() || plz.is_empty() {
        return Err(AppError::BadRequest("Kunde, Straße und Postleitzahl dürfen nicht leer sein.".into()));
    }
    validate_customer_fields(&kunde, &strasse, paket.as_deref(), notiz.as_deref())?;
    let telefon = clean_telefon(payload.telefon.as_deref())?;
    check_plz(&plz)?;

    // OSRM's `/trip` endpoint (see `OSRM_MAX_TRIP_COORDS`) caps how many
    // waypoints one optimization call can take — via + customers + end.
    // The bulk JSON import enforces this up front by rejecting an
    // oversized paste (`MAX_BULK_STOPS`), but a route grown one `add_stop`
    // call at a time had no equivalent guard: once the customer count
    // reached the cap, every reoptimize after that silently failed and the
    // route was stuck flagged stale forever, with the only fix being to
    // manually delete stops back under the limit. Checked here, before
    // spending a geocode round-trip on a stop that couldn't be routed
    // anyway.
    {
        let conn = state.db()?;
        let customer_count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM stops WHERE route_id = ?1 AND kind = 'customer'",
            params![route_id],
            |r| r.get(0),
        )?;
        // Expressed with `MAX_BULK_STOPS` rather than open-coded against
        // `OSRM_MAX_TRIP_COORDS`: the old `customer_count + 3 > cap` test
        // accepted routes up to `cap - 2` customers (correctly — a trip is
        // warehouse + customers + destination) while its message named
        // `cap - 3` as the maximum, so a driver who filled a route was told
        // the limit was one below the number of stops they were looking at,
        // and told a different limit than the JSON import enforces for the
        // very same route. One constant, one number, same behaviour.
        if customer_count >= MAX_BULK_STOPS as i64 {
            return Err(AppError::BadRequest(format!(
                "Diese Route hat bereits die maximale Anzahl an Stopps ({MAX_BULK_STOPS}). Bitte eine neue Route anlegen."
            )));
        }
    }

    let manual_pin = payload.lat.is_some() && payload.lon.is_some();
    let (lat, lon, precision) = if let (Some(lat), Some(lon)) = (payload.lat, payload.lon) {
        check_pin(lat, lon, &plz)?;
        (lat, lon, None) // a human placed this pin — that's exact by definition
    } else {
        let (lat, lon, _, precision) = geocode_address(&state, &strasse, &plz).await?;
        (lat, lon, precision.tag())
    };

    {
        let mut conn = state.db()?;
        // Both writes commit together — a crash between them would
        // otherwise either lose the stop entirely or save it without ever
        // flagging the route stale. The MAX(order_index) read belongs
        // inside the transaction too: read outside it, two stops added at
        // the same moment both see the same maximum and land on the same
        // order_index.
        let tx = conn.transaction()?;
        // Re-checked here, not just before the geocode call above: that
        // call (and Nominatim's throttle behind it) can take seconds —
        // long enough for a concurrent `delete_route` to have removed this
        // route in the meantime. Without this, the INSERT below would
        // still fail on the `stops.route_id REFERENCES routes(id)`
        // foreign key, but as an opaque 500 instead of the same "Route
        // nicht gefunden" every other stale-route path already returns.
        require_route_exists(&tx, route_id)?;
        let max_order: i64 = tx.query_row(
            "SELECT COALESCE(MAX(order_index), 0) FROM stops WHERE route_id = ?1",
            params![route_id],
            |r| r.get(0),
        )?;
        tx.execute(
            "INSERT INTO stops (route_id, kind, kunde, strasse, plz, paket, notiz, lat, lon, order_index, location_precision, pinned, created_at, telefon) \
             VALUES (?1, 'customer', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![route_id, kunde, strasse, plz, paket, notiz, lat, lon, max_order + 1, precision, manual_pin as i64, now_iso(), telefon],
        )?;
        // Set *before* attempting the reoptimize below, not just on
        // failure: if OSRM is briefly unreachable, the stop is still
        // saved (retrying the request would just add it twice) but the
        // route correctly stays flagged stale — the amber "Route nicht
        // aktuell" banner and its one-tap retry are the fallback, not a
        // silent-looking route that secretly hasn't accounted for the new
        // stop yet.
        tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        tx.commit()?;
    }
    fill_entrances(&state, route_id).await;
    // OSRM solves this in one fast network round-trip now — no reason to
    // make the driver remember a separate "optimize" tap after every
    // single stop like the old local solver required.
    reoptimize_best_effort(&state, route_id).await;
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

/// What a PATCH asks of a stop's outcome: `None` when the request says
/// nothing about it, `Some(None)` to re-open the stop, `Some(Some(o))` to
/// record `o`.
fn requested_outcome(payload: &StopUpdate) -> Result<Option<Option<&str>>, AppError> {
    match (payload.outcome.as_deref(), payload.delivered) {
        (Some("open"), _) => Ok(Some(None)),
        (Some(o), _) if outcome::is_settable(o) => Ok(Some(Some(o))),
        (Some(_), _) => Err(AppError::BadRequest("Ungültiger Lieferstatus".into())),
        (None, Some(true)) => Ok(Some(Some(outcome::DELIVERED))),
        (None, Some(false)) => Ok(Some(None)),
        (None, None) => Ok(None),
    }
}

/// Records what happened at a stop, or re-opens it with `None`. Returns
/// whether the route has to be planned again.
///
/// The three stored facts -- the outcome, the `delivered` summary and the
/// time -- are written together and only here, so they cannot drift.
///
/// A door answered for means the van has loaded, so an open Lager is ticked
/// along with it: left open it stayed "next" for the whole day and the
/// remaining kilometres were counted from the depot. Taking that door back
/// takes the Lager back too -- but only a Lager ticked *by* that door, the
/// same moment to the stamp, and only while no other door says the van has
/// loaded. One the driver ticked by hand stays as they left it. Not for
/// "Ins Lager mitnehmen": that is usually said in the yard, before anything
/// is loaded.
///
/// Asking for the outcome a stop already has changes nothing, the time
/// included -- the tick is the one request the app resends on a dropped
/// connection, and a second stamp would cut the Lager loose from its door.
fn record_outcome(tx: &Connection, route_id: i64, stop_id: i64, kind: &str, new: Option<&str>) -> Result<bool, AppError> {
    let (prev, prev_at): (Option<String>, Option<String>) = tx.query_row(
        "SELECT outcome, delivered, settled_at FROM stops WHERE id = ?1",
        params![stop_id],
        |r| Ok((effective_outcome(r.get(0)?, r.get::<_, i64>(1)? != 0), r.get(2)?)),
    )?;
    if prev.as_deref() == new {
        return Ok(false);
    }
    let now = now_iso();
    tx.execute(
        "UPDATE stops SET outcome = ?1, delivered = ?2, settled_at = ?3 WHERE id = ?4",
        params![new, new.is_some_and(outcome::handed_over) as i64, new.map(|_| now.as_str()), stop_id],
    )?;
    if kind != "customer" {
        return Ok(false);
    }

    let passes = |o: Option<&str>| o.is_some_and(|o| !outcome::skips_door(o));
    if passes(new) {
        tx.execute(
            "UPDATE stops SET outcome = 'delivered', delivered = 1, settled_at = ?1 \
             WHERE route_id = ?2 AND kind = 'via' AND excluded = 0 AND outcome IS NULL AND delivered = 0",
            params![now, route_id],
        )?;
    } else if passes(prev.as_deref()) {
        if let Some(prev_at) = prev_at {
            tx.execute(
                &format!(
                    "UPDATE stops SET outcome = NULL, delivered = 0, settled_at = NULL \
                     WHERE route_id = ?1 AND kind = 'via' AND settled_at = ?2 AND NOT EXISTS ( \
                         SELECT 1 FROM stops s WHERE s.route_id = ?1 AND s.kind = 'customer' \
                         AND (s.outcome IS NOT NULL OR s.delivered = 1) AND NOT COALESCE({SQL_SKIPS_DOOR}, 0))"
                ),
                params![route_id, prev_at],
            )?;
        }
    }

    // The one answer that changes the route: that door is not driven, so
    // marking it, or taking it back, plans the tour again.
    let skips = |o: Option<&str>| o.is_some_and(outcome::skips_door);
    Ok(skips(prev.as_deref()) != skips(new))
}

async fn update_stop(
    State(state): State<Arc<AppState>>,
    AxPath(stop_id): AxPath<i64>,
    Json(payload): Json<StopUpdate>,
) -> Result<Json<RouteDetail>, AppError> {
    let new_outcome = requested_outcome(&payload)?;
    let (route_id, kind, cur_strasse, cur_plz, cur_excluded, cur_unplaced) = {
        let conn = state.db()?;
        conn.query_row(
            "SELECT route_id, kind, strasse, plz, excluded, \
                    COALESCE(location_precision = 'district' AND pinned = 0, 0) FROM stops WHERE id = ?1",
            params![stop_id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                    r.get::<_, i64>(4)? != 0,
                    r.get::<_, i64>(5)? != 0,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| AppError::NotFound("Stopp nicht gefunden".into()))?
    };

    // Start/Lager/Ziel are fixed points of every route: their address and
    // position are not editable, and the UI never offers to. Rejecting that
    // outright — the way `delete_stop` already rejects deleting them —
    // rather than quietly dropping the address/coordinate fields and
    // returning 200, which would hand a caller that renamed the warehouse a
    // success response describing a change that never happened.
    //
    // The one thing a fixed stop *does* accept is `excluded`: not every
    // tour drives all three, and switching one off is a per-route planning
    // decision rather than an edit to what that stop is. Handled here and
    // returned early — none of the customer-field validation below applies
    // to a request that carries no customer fields.
    if kind != "customer" {
        // Lager and Ziel are ticked off like a door -- loading at the
        // warehouse and getting back are two stops of the shift as much as
        // any customer -- but they are not deliveries: the plain tick and
        // nothing else. Not Start: the driver is standing in it when the
        // tour begins. Not one this tour skips, either.
        if let (Some(outcome), None) = (new_outcome, payload.excluded) {
            let is_checkpoint = (kind == "via" || kind == "end") && !cur_excluded;
            let plain_tick = matches!(outcome, None | Some(outcome::DELIVERED));
            let nothing_else = payload.kunde.is_none()
                && payload.telefon.is_none()
                && payload.strasse.is_none()
                && payload.plz.is_none()
                && payload.paket.is_none()
                && payload.notiz.is_none()
                && payload.lat.is_none()
                && payload.lon.is_none();
            if !is_checkpoint || !plain_tick || !nothing_else {
                return Err(AppError::Forbidden("Nur Lager und Ziel können abgehakt werden".into()));
            }
            let mut conn = state.db()?;
            let tx = conn.transaction()?;
            record_outcome(&tx, route_id, stop_id, &kind, outcome)?;
            tx.commit()?;
            return Ok(Json(get_route_detail(&conn, route_id)?));
        }
        // Where a fixed point is can be changed -- a tour that loads
        // somewhere else, or ends at another depot. What it is cannot: no
        // name, no parcel, no note.
        let moves = payload.strasse.is_some() || payload.plz.is_some() || payload.lat.is_some() || payload.lon.is_some();
        if moves && payload.excluded.is_none() {
            let plain = payload.kunde.is_none()
                && payload.telefon.is_none()
                && payload.paket.is_none()
                && payload.notiz.is_none()
                && new_outcome.is_none();
            if !plain {
                return Err(AppError::Forbidden("An fixen Stopps kann nur die Adresse geändert werden".into()));
            }
            let strasse = payload.strasse.as_deref().map(str::trim).unwrap_or(&cur_strasse).to_string();
            let plz = payload.plz.as_deref().map(str::trim).unwrap_or(&cur_plz).to_string();
            if strasse.is_empty() {
                return Err(AppError::BadRequest("Straße darf nicht leer sein.".into()));
            }
            check_len(&strasse, "Straße", MAX_STRASSE_LEN)?;
            check_no_control_chars(&strasse, "Straße", false)?;
            check_plz(&plz)?;
            let manual_pin = payload.lat.is_some() && payload.lon.is_some();
            let (lat, lon, precision) = if let (Some(lat), Some(lon)) = (payload.lat, payload.lon) {
                check_pin(lat, lon, &plz)?;
                (lat, lon, None)
            } else {
                let (lat, lon, _, precision) = geocode_address(&state, &strasse, &plz).await?;
                (lat, lon, precision.tag())
            };
            {
                let mut conn = state.db()?;
                let tx = conn.transaction()?;
                tx.execute(
                    "UPDATE stops SET strasse = ?1, plz = ?2, lat = ?3, lon = ?4, location_precision = ?5, pinned = ?6 WHERE id = ?7",
                    params![strasse, plz, lat, lon, precision, manual_pin as i64, stop_id],
                )?;
                tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
                tx.commit()?;
            }
            reoptimize_best_effort(&state, route_id).await;
            let conn = state.db()?;
            return Ok(Json(get_route_detail(&conn, route_id)?));
        }
        let Some(excluded) = payload.excluded else {
            return Err(AppError::Forbidden("Fixe Stopps können nicht bearbeitet werden".into()));
        };
        // Ziel stays on every tour: without it the tour ends wherever the
        // optimizer finds cheapest. Its address is changed instead. One
        // switched off before this rule can still be switched back on.
        if kind == "end" && excluded && !cur_excluded {
            return Err(AppError::BadRequest(
                "Das Ziel bleibt in jeder Tour. Stattdessen kann seine Adresse geändert werden.".into(),
            ));
        }
        let only_exclusion = payload.kunde.is_none()
            && payload.telefon.is_none()
            && payload.strasse.is_none()
            && payload.plz.is_none()
            && payload.paket.is_none()
            && payload.notiz.is_none()
            && new_outcome.is_none()
            && payload.lat.is_none()
            && payload.lon.is_none();
        if !only_exclusion {
            return Err(AppError::Forbidden(
                "An fixen Stopps kann nur das Überspringen geändert werden".into(),
            ));
        }

        // Skipping a stop removes a leg the route was planned around, so
        // the stored order/geometry is stale the instant this lands — both
        // written in one transaction so a crash can't leave the route
        // looking up to date against a plan that no longer matches it.
        {
            let mut conn = state.db()?;
            let tx = conn.transaction()?;
            tx.execute(
                "UPDATE stops SET excluded = ?1 WHERE id = ?2",
                params![excluded as i64, stop_id],
            )?;
            // A stop the tour skips is not one it ticks.
            if excluded {
                record_outcome(&tx, route_id, stop_id, &kind, None)?;
            }
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
            tx.commit()?;
        }
        reoptimize_best_effort(&state, route_id).await;
        let conn = state.db()?;
        return Ok(Json(get_route_detail(&conn, route_id)?));
    }

    // A customer stop is removed by deleting it, not by skipping it — and
    // silently accepting the flag here would write an `excluded` a customer
    // row that `reoptimize_route` deliberately ignores, i.e. a setting that
    // appears to save and then does nothing.
    if payload.excluded.is_some() {
        return Err(AppError::BadRequest(
            "Kundenstopps können nicht übersprungen werden — bitte löschen.".into(),
        ));
    }

    if let Some(strasse) = payload.strasse.as_deref() {
        if strasse.trim().is_empty() {
            return Err(AppError::BadRequest("Straße darf nicht leer sein.".into()));
        }
        check_len(strasse.trim(), "Straße", MAX_STRASSE_LEN)?;
        check_no_control_chars(strasse.trim(), "Straße", false)?;
    }
    if let Some(plz) = payload.plz.as_deref() {
        if plz.trim().is_empty() {
            return Err(AppError::BadRequest("Postleitzahl darf nicht leer sein.".into()));
        }
    }
    let kunde = match payload.kunde.as_deref() {
        Some(k) if k.trim().is_empty() => return Err(AppError::BadRequest("Kunde darf nicht leer sein.".into())),
        Some(k) => {
            check_len(k.trim(), "Kunde", MAX_KUNDE_LEN)?;
            check_no_control_chars(k.trim(), "Kunde", false)?;
            Some(k.trim().to_string())
        }
        None => None,
    };
    // `Some(None)` = "the caller sent this field, and it was blank" —
    // stored as SQL NULL, the same as a stop created without it, so an
    // emptied Paket/Notiz disappears from the UI instead of lingering as an
    // empty-string chip (`add_stop` already normalizes it this way).
    let paket = match payload.paket.as_deref().map(str::trim) {
        Some(p) => {
            check_len(p, "Paket", MAX_PAKET_LEN)?;
            check_no_control_chars(p, "Paket", false)?;
            Some((!p.is_empty()).then(|| p.to_string()))
        }
        None => None,
    };
    let notiz = match payload.notiz.as_deref().map(str::trim) {
        Some(n) => {
            check_len(n, "Notiz", MAX_NOTIZ_LEN)?;
            check_no_control_chars(n, "Notiz", true)?;
            Some((!n.is_empty()).then(|| n.to_string()))
        }
        None => None,
    };

    // `Some(None)` clears it, like Paket and Notiz above.
    let telefon = match payload.telefon.as_deref() {
        Some(t) => Some(clean_telefon(Some(t))?),
        None => None,
    };

    let new_strasse = payload.strasse.as_deref().map(str::trim).unwrap_or(&cur_strasse).to_string();
    let new_plz = payload.plz.as_deref().map(str::trim).unwrap_or(&cur_plz).to_string();
    // A stop that was never placed is looked up again whenever its address
    // is sent, changed or not: the driver has just looked at it and said
    // "this is right", and the lookup may know it by now -- or will say
    // once more, in so many words, that it does not.
    //
    // Through `address_match_key`, so re-typing "Hauptstr. 5" as "Hauptstraße
    // 5" is not a move: it is the same door, and a pin the driver placed on
    // it by hand stays where they put it. The text is still written as typed.
    let respelled = payload.strasse.is_some() && new_strasse != cur_strasse;
    let address_changed = (respelled && text::address_match_key(&new_strasse) != text::address_match_key(&cur_strasse))
        || (payload.plz.is_some() && new_plz != cur_plz)
        || (cur_unplaced && (payload.strasse.is_some() || payload.plz.is_some()));
    // A pin the driver placed by hand (the pin-drop sheet) is honored on
    // its own, not only as a side effect of an address edit: re-pinning a
    // stop whose text address stays the same is a legitimate correction,
    // and silently ignoring the coordinates would leave the map showing
    // the position the driver just told us was wrong.
    let manual_pin = payload.lat.is_some() && payload.lon.is_some();

    let mut new_coords: Option<(f64, f64, Option<&'static str>)> = None;
    if address_changed || manual_pin {
        check_plz(&new_plz)?;
        new_coords = Some(if let (Some(lat), Some(lon)) = (payload.lat, payload.lon) {
            check_pin(lat, lon, &new_plz)?;
            (lat, lon, None) // a human placed this pin — that's exact by definition
        } else {
            let (lat, lon, _, precision) = geocode_address(&state, &new_strasse, &new_plz).await?;
            (lat, lon, precision.tag())
        });
    }

    let replan = {
        let mut conn = state.db()?;
        // Up to 6 separate field updates land here depending on what the
        // caller sent — a transaction keeps them atomic, so a crash
        // mid-request can't apply some fields (say, the new address) while
        // dropping others (say, the `needs_optimize` flag that address
        // change should have set).
        let tx = conn.transaction()?;
        let mut replan = new_coords.is_some();
        if let Some(k) = &kunde {
            tx.execute("UPDATE stops SET kunde = ?1 WHERE id = ?2", params![k, stop_id])?;
        }
        if let Some(paket) = &paket {
            tx.execute("UPDATE stops SET paket = ?1 WHERE id = ?2", params![paket, stop_id])?;
        }
        if let Some(notiz) = &notiz {
            tx.execute("UPDATE stops SET notiz = ?1 WHERE id = ?2", params![notiz, stop_id])?;
        }
        if let Some(telefon) = &telefon {
            tx.execute("UPDATE stops SET telefon = ?1 WHERE id = ?2", params![telefon, stop_id])?;
        }
        if address_changed || respelled {
            tx.execute(
                "UPDATE stops SET strasse = ?1, plz = ?2 WHERE id = ?3",
                params![new_strasse, new_plz, stop_id],
            )?;
        }
        if let Some(outcome) = new_outcome {
            // `|=`: an address moved in the same request has already asked.
            replan |= record_outcome(&tx, route_id, stop_id, &kind, outcome)?;
        }
        if let Some((lat, lon, precision)) = new_coords {
            // `pinned` tracks where these coordinates came from, so a later
            // re-check of the route's addresses knows to leave a
            // hand-placed pin alone — and to stop leaving one alone once the
            // driver edits the address and a geocoder answers instead.
            // The entrance belonged to the address the stop had: gone with
            // it, and looked up again below for the new one.
            tx.execute(
                "UPDATE stops SET lat = ?1, lon = ?2, location_precision = ?3, pinned = ?4, \
                 entrance_lat = NULL, entrance_lon = NULL WHERE id = ?5",
                params![lat, lon, precision, manual_pin as i64, stop_id],
            )?;
        }
        // Flagged, not cleared: for a door taken out of the tour the old
        // line still drives past it -- a detour, not a wrong turn -- and it
        // has to last until OSRM can be asked again.
        if replan {
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        }
        tx.commit()?;
        replan
    };

    // Only a moved stop, or a door taken out of the tour or put back into
    // it, changes the route's shape — the plain tick, the note and the
    // package text never touch order/geometry, so there's nothing to
    // re-solve for those.
    if replan {
        fill_entrances(&state, route_id).await;
        reoptimize_best_effort(&state, route_id).await;
    }
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn delete_stop(State(state): State<Arc<AppState>>, AxPath(stop_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    let route_id = {
        let mut conn = state.db()?;
        let (route_id, kind): (i64, String) = conn
            .query_row("SELECT route_id, kind FROM stops WHERE id = ?1", params![stop_id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()?
            .ok_or_else(|| AppError::NotFound("Stopp nicht gefunden".into()))?;
        if kind != "customer" {
            return Err(AppError::Forbidden("Fixe Stopps können nicht gelöscht werden".into()));
        }
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM stops WHERE id = ?1", params![stop_id])?;
        // The stop before the deleted one had a next_leg_km/min pointing
        // at it and the map line traced through its position — both go
        // stale the instant it's gone, not just "eventually out of date".
        // Committed together so a crash can't delete the stop while
        // leaving the route looking falsely up to date.
        tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        tx.commit()?;
        route_id
    };
    reoptimize_best_effort(&state, route_id).await;
    let conn = state.db()?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

/// What every list of stops is loaded through -- today, the portal import. Customer-facing
/// fields only, stops matched by normalized (strasse, plz) and then by
/// customer name, unmatched
/// existing stops deleted (unless something failed to geocode this round
/// — see `deletions_skipped`), new ones geocoded and inserted. Every
/// geocode is a throttled call to a shared public service, so all of them
/// happen up front, before the write transaction is opened — a 300-stop
/// import must never hold a SQLite write lock across minutes of network
/// round-trips.
#[derive(Serialize)]
struct GeocodeFailure {
    kunde: String,
    strasse: String,
    plz: String,
}

#[derive(Serialize)]
struct GeocodeApproximate {
    kunde: String,
    strasse: String,
    plz: String,
    /// "street" (nearest known housenumber) or "district" (PLZ centroid).
    precision: &'static str,
}

#[derive(Serialize)]
struct ValidationFailure {
    /// Best-effort identifier for the offending entry — kunde if present,
    /// else strasse, else plz, else "Eintrag N" (1-based position in the
    /// submitted list) when none of those fields could be read at all
    /// (e.g. the entry wasn't even a JSON object).
    label: String,
    reason: String,
}

#[derive(Serialize)]
struct BulkJsonResult {
    #[serde(flatten)]
    route: RouteDetail,
    /// Entries that failed basic validation (missing required field, over a
    /// length limit, a raw control character) before geocoding was ever
    /// attempted — everything else in the batch still gets saved instead of
    /// one bad entry (a stray character from a pasted spreadsheet, say)
    /// blocking the other 39. Previously any one of these aborted the
    /// entire import with a single terse 400 identifying only the first
    /// offending value, forcing the driver to hunt through however many
    /// JSON objects by hand.
    validation_failures: Vec<ValidationFailure>,
    /// Entries that couldn't be geocoded at all (not even a recognized
    /// PLZ) — everything else in the batch still gets saved. The frontend
    /// surfaces these so the driver can fix them or pin-drop manually.
    geocode_failures: Vec<GeocodeFailure>,
    /// Entries that got a location but not an exact one — nearest known
    /// housenumber on the street, or just the district centroid. Still
    /// saved and usable for routing, but flagged so the driver knows to
    /// double check rather than trust it blindly.
    approximate: Vec<GeocodeApproximate>,
    /// True if stops that looked "removed" (their address wasn't in the
    /// submitted list) were deliberately *not* deleted this round, because
    /// at least one validation or geocode failure made it unsafe to tell a
    /// genuine removal apart from an edited/malformed entry that just
    /// failed to resolve.
    deletions_skipped: bool,
}

/// Which of the stops still unclaimed at one address a submitted entry is,
/// taken out of `bucket` (stop id, name key) if it is one of them.
///
/// The same name at the same address is the same stop, whatever order either
/// side lists them in. Failing that, the first unclaimed one: a customer
/// renamed in place at an address that did not change, which is an edit of
/// that stop and not a new one.
///
/// `exact_only` leaves that second claim out, for a list that is added to
/// the tour rather than replacing it. It leans on the unclaimed stop being
/// dropped otherwise; with nothing dropped, a second household at a door
/// already on the tour overwrote the first one's name and Paket.
fn claim_at_address(bucket: &mut Vec<(i64, String)>, wanted: &str, exact_only: bool) -> Option<i64> {
    let pos = match bucket.iter().position(|(_, name)| name == wanted) {
        Some(pos) => pos,
        None if exact_only || bucket.is_empty() => return None,
        None => 0,
    };
    Some(bucket.remove(pos).0)
}

/// Brings a route's customers in line with a list of entries.
///
/// `keep_unmatched` leaves alone the stops the list does not mention. That
/// is what a list loaded from the portal wants: a stop the driver added by
/// hand is theirs, and a second load must not take it away. The list is
/// then an addition, and an entry is a stop already on the tour only by the
/// same name at the same address -- see `claim_at_address`.
async fn import_entries(
    state: &Arc<AppState>,
    route_id: i64,
    payload: &Value,
    keep_unmatched: bool,
) -> Result<BulkJsonResult, AppError> {
    let stops_in: &Vec<Value> = match payload {
        Value::Array(a) => a,
        Value::Object(o) => match o.get("stops") {
            Some(Value::Array(a)) => a,
            _ => return Err(AppError::BadRequest("Ungültiges JSON: erwarte eine Liste von Kundenstopps.".into())),
        },
        _ => return Err(AppError::BadRequest("Ungültiges JSON: erwarte eine Liste von Kundenstopps.".into())),
    };
    if stops_in.len() > MAX_BULK_STOPS {
        return Err(AppError::BadRequest(format!(
            "Zu viele Stopps auf einmal ({}, max. {MAX_BULK_STOPS}). Bitte in kleineren Gruppen importieren.",
            stops_in.len()
        )));
    }

    /// Matching key for "is this submitted stop the one already stored?".
    /// Normalized, not raw: "Hauptstr. 5" and "Hauptstraße 5" are the same
    /// address, and treating them as different would delete the stored stop
    /// and re-insert an identical one — losing its delivered flag and
    /// burning a geocode round-trip to end up exactly where it started.
    fn addr_key(strasse: &str, plz: &str) -> (String, String) {
        (text::address_match_key(strasse), plz.trim().to_string())
    }

    /// A customer's name in the form two lists are compared in: through
    /// `address_match_key`, the rule the address beside it already follows --
    /// case, spacing and punctuation folded away, ä/ö/ü/ß spelled out. "Fam.
    /// Grüber" and "Fam Grueber" are one household.
    fn name_key(kunde: &str) -> String {
        text::address_match_key(kunde)
    }

    struct ExistingStop {
        id: i64,
        kunde: String,
        strasse: String,
        plz: String,
    }

    /// (kunde, strasse, plz, paket, notiz) — one validated submitted entry.
    type SubmittedStop = (String, String, String, Option<String>, Option<String>);
    /// A `SubmittedStop` plus its resolved (lat, lon) and precision tag.
    type NewStop = (SubmittedStop, f64, f64, Option<&'static str>);

    // Serialized per route (see `AppState::route_locks`, also used by
    // `reoptimize_route`): everything below reads `existing_customers` up
    // front and only writes back minutes later, once every uncached address
    // in the paste has been geocoded through Nominatim's throttle. Without
    // this lock, two overlapping imports for the same route — most
    // realistically the driver's own retry after a client-side timeout on a
    // slow connection, since the frontend's timeout is well short of what a
    // large uncached paste can take server-side — would each plan from the
    // same "before" snapshot and both commit, duplicating every stop that
    // didn't match anything yet. Dropped before the closing
    // `reoptimize_best_effort` call below, which takes this same lock
    // itself and would deadlock if it were still held here.
    let lock = state.route_lock(route_id).await;
    let route_guard = lock.lock().await;

    let existing_customers: Vec<ExistingStop> = {
        let conn = state.db()?;
        require_route_exists(&conn, route_id)?;
        let mut stmt = conn.prepare("SELECT id, kunde, strasse, plz FROM stops WHERE route_id = ?1 AND kind = 'customer'")?;
        let rows: Vec<ExistingStop> = stmt
            .query_map(params![route_id], |r| {
                Ok(ExistingStop {
                    id: r.get(0)?,
                    kunde: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    strasse: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    plz: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                })
            })?
            .collect::<Result<_, _>>()?;
        rows
    };

    // Per-entry, not fatal to the whole request: a single stray control
    // character or over-length field in one of up to 98 pasted stops used
    // to abort the entire import with one generic 400 naming only the
    // first offending value — the driver had to scan however many JSON
    // objects by hand to find it. Collected into `validation_failures`
    // instead, the same shape as `geocode_failures` below, so the rest of
    // a large batch still saves.
    type Extras = (String, (String, String), Option<Option<String>>, Option<Option<i64>>);
    let mut extras: Vec<Extras> = Vec::new();
    let mut normalized: Vec<SubmittedStop> = Vec::new();
    let mut validation_failures: Vec<ValidationFailure> = Vec::new();
    for (idx, entry) in stops_in.iter().enumerate() {
        let Some(obj) = entry.as_object() else {
            validation_failures.push(ValidationFailure {
                label: format!("Eintrag {}", idx + 1),
                reason: "Kein gültiges Objekt.".into(),
            });
            continue;
        };
        let kunde = obj.get("kunde").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let strasse = obj.get("strasse").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let plz = obj.get("plz").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let label = if !kunde.is_empty() {
            kunde.clone()
        } else if !strasse.is_empty() {
            strasse.clone()
        } else if !plz.is_empty() {
            plz.clone()
        } else {
            format!("Eintrag {}", idx + 1)
        };
        if kunde.is_empty() || strasse.is_empty() || plz.is_empty() {
            validation_failures.push(ValidationFailure {
                label,
                reason: "Kunde, Straße und Postleitzahl sind Pflichtfelder.".into(),
            });
            continue;
        }
        let paket = obj.get("paket").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        let notiz = obj.get("notiz").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        // Exhaustively matched, not an `if let Err(AppError::BadRequest(_))`:
        // `validate_customer_fields` is documented to only ever return that
        // one variant, but an `if let` relies on that staying true forever
        // — any *other* future error variant would silently fall through
        // this check as if the entry had passed, pushing unvalidated data
        // into `normalized` with no record in `validation_failures` at all.
        // Propagating anything unexpected via `?` turns a silent validation
        // bypass into a loud 500 instead.
        match validate_customer_fields(&kunde, &strasse, paket.as_deref(), notiz.as_deref()) {
            Ok(()) => {}
            Err(AppError::BadRequest(reason)) => {
                validation_failures.push(ValidationFailure { label, reason });
                continue;
            }
            Err(other) => return Err(other),
        }
        // The two fields a list from the portal carries beyond the five the
        // editor shows. Only when the entry names them: a hand-edited paste
        // that leaves them out must not wipe a number already on the stop.
        // `paketCount` is how the iOS app's own export spells it.
        let count_key = if obj.contains_key("paketCount") { "paketCount" } else { "paket_count" };
        if obj.contains_key("telefon") || obj.contains_key(count_key) {
            let telefon = match obj.get("telefon") {
                Some(v) => match clean_telefon(v.as_str()) {
                    Ok(t) => Some(t),
                    Err(AppError::BadRequest(reason)) => {
                        validation_failures.push(ValidationFailure { label, reason });
                        continue;
                    }
                    Err(other) => return Err(other),
                },
                None => None,
            };
            let paket_count = obj.get(count_key).map(|v| v.as_i64().filter(|n| (0..=9999).contains(n)));
            extras.push((name_key(&kunde), addr_key(&strasse, &plz), telefon, paket_count));
        }
        normalized.push((kunde, strasse, plz, paket, notiz));
    }

    let mut to_update: Vec<(String, Option<String>, Option<String>, i64)> = Vec::new();
    let mut to_insert: Vec<NewStop> = Vec::new();
    let mut to_move: Vec<(SubmittedStop, i64, f64, f64, Option<&'static str>)> = Vec::new();
    let mut matched_ids: HashSet<i64> = HashSet::new();
    // Geocoding failures are collected, not fatal: everything else in the
    // batch still gets saved instead of one bad address blocking all 30.
    let mut failures: Vec<GeocodeFailure> = Vec::new();
    let mut approximate: Vec<GeocodeApproximate> = Vec::new();

    // ----- Pass 1: match on address ------------------------------------
    // The common case, and the cheap one — an unchanged address means an
    // unchanged location, so there's nothing to geocode and nothing to
    // re-route.
    // Each address bucket carries the stop's name alongside its id, because
    // an address is not on its own enough to say *which* stop an entry is.
    //
    // Two customers at one door is a case this app goes out of its way to
    // support (see `sameDoorGroups` in index.html) — one building, two
    // households, two meals. Matching a bucket positionally, which is what
    // this did, silently assumed the paste lists them in the same order the
    // database happens to hold them. Re-paste the same two customers with
    // the rows swapped and each one claimed the *other's* stop id: the names
    // were written over each other, and `delivered` — which lives on the id
    // and is deliberately not in the paste — stayed where it was. A customer
    // who had already had their meal showed as outstanding, and one who had
    // not showed as delivered. Reproduced end to end before this fix.
    //
    // That is the exact failure pass 2 below exists to prevent for a moved
    // customer; it just never got the chance, because pass 1 had already
    // claimed both stops.
    let mut by_key: HashMap<(String, String), Vec<(i64, String)>> = HashMap::new();
    for s in &existing_customers {
        by_key.entry(addr_key(&s.strasse, &s.plz)).or_default().push((s.id, name_key(&s.kunde)));
    }

    // Entries that pass 1 didn't claim, each with the id of the stop it
    // turns out to be an edit of (filled in by pass 2, `None` = new stop).
    let mut unresolved: Vec<(SubmittedStop, Option<i64>)> = Vec::new();

    for entry in normalized {
        let key = addr_key(&entry.1, &entry.2);
        let existing_id = by_key
            .get_mut(&key)
            .and_then(|v| claim_at_address(v, &name_key(&entry.0), keep_unmatched));
        match existing_id {
            Some(id) => {
                matched_ids.insert(id);
                to_update.push((entry.0, entry.3, entry.4, id));
            }
            None => unresolved.push((entry, None)),
        }
    }

    // ----- Pass 2: match the leftovers on customer name ----------------
    // Address matching alone cannot tell "Fam. Gruber moved to a new flat"
    // apart from "Fam. Gruber left the route and someone new joined". It
    // resolved both as a delete plus an insert — which loses everything the
    // stop carried that isn't in the paste, and what it carried is
    // `delivered`. Re-pasting a corrected list at midday would silently
    // un-tick a customer who had already had their meal delivered, and the
    // driver's only clue would be a stop reappearing as outstanding.
    //
    // Matching the leftovers by name recognizes the move for what it is and
    // edits the stop in place. It is deliberately conservative: a name must
    // be unambiguous on *both* sides — exactly one unclaimed existing stop
    // and exactly one unclaimed submitted entry — or the pass declines and
    // the old delete/insert behavior stands. Guessing between two customers
    // called "Fam. Gruber" would be worse than not guessing at all.
    //
    // Not for a list that is added to the tour: with nothing dropped, a
    // namesake is somebody else, and matching them moved a customer already
    // on the tour to the newcomer's address.
    if !keep_unmatched {
        let mut submitted_name_counts: HashMap<String, usize> = HashMap::new();
        for (entry, _) in &unresolved {
            *submitted_name_counts.entry(name_key(&entry.0)).or_insert(0) += 1;
        }
        let mut existing_by_name: HashMap<String, Vec<i64>> = HashMap::new();
        for s in existing_customers.iter().filter(|s| !matched_ids.contains(&s.id)) {
            existing_by_name.entry(name_key(&s.kunde)).or_default().push(s.id);
        }
        for (entry, slot) in unresolved.iter_mut() {
            let key = name_key(&entry.0);
            if submitted_name_counts.get(&key) != Some(&1) {
                continue;
            }
            let Some(ids) = existing_by_name.get(&key) else { continue };
            if ids.len() != 1 {
                continue;
            }
            let id = ids[0];
            matched_ids.insert(id);
            existing_by_name.remove(&key);
            *slot = Some(id);
        }
    }

    // ----- Geocode whatever is left, with bounded concurrency ----------
    // Split out invalid-PLZ entries first — same as before, no network
    // call spent on a PLZ that can't possibly be a Vienna address — so the
    // concurrency below is spent only on entries that actually need a
    // geocoder.
    let mut to_geocode: Vec<(usize, SubmittedStop, Option<i64>)> = Vec::new();
    for (idx, (entry, existing_id)) in unresolved.into_iter().enumerate() {
        if !is_valid_plz(&entry.2) {
            failures.push(GeocodeFailure { kunde: entry.0, strasse: entry.1, plz: entry.2 });
            continue;
        }
        to_geocode.push((idx, entry, existing_id));
    }

    // Wien-OGD (tried first for every address, see `geocode_address`) has
    // no rate limit of its own, so running these fully sequentially — one
    // `.await` per entry in a plain loop, as this used to be — wasted real
    // wall-clock time waiting on network round-trips that could overlap.
    // Nominatim (the fallback, tried only for whatever Wien-OGD didn't
    // resolve) *is* rate-limited, but that limit is enforced centrally by
    // `nominatim_throttle` serializing on `AppState::nominatim_last` — the
    // concurrent callers here just queue up there like any other caller
    // would, so this can't push Nominatim traffic past its policy, only
    // let more Wien-OGD lookups (and DB cache reads) run at once.
    /// One `geocode_address` task's result: its original position in
    /// `unresolved` (for restoring input order once tasks complete
    /// out-of-order), the entry it was for, which existing stop it's an
    /// edit of (if any), and the geocode outcome itself.
    type GeocodeTaskResult = (usize, SubmittedStop, Option<i64>, Result<(f64, f64, String, Precision), AppError>);

    let geocode_semaphore = Arc::new(Semaphore::new(BULK_GEOCODE_CONCURRENCY));
    let mut geocode_tasks: JoinSet<GeocodeTaskResult> = JoinSet::new();
    for (idx, entry, existing_id) in to_geocode {
        let task_state = Arc::clone(state);
        let permit = Arc::clone(&geocode_semaphore);
        geocode_tasks.spawn(async move {
            // Held for the duration of the geocode call, not just the
            // acquire — that's the entire point of a semaphore-gated
            // concurrency limit, not just limiting how many tasks *start*.
            let _permit = permit.acquire_owned().await.expect("semaphore is never closed");
            let result = geocode_address(&task_state, &entry.1, &entry.2).await;
            (idx, entry, existing_id, result)
        });
    }
    // Collected out of completion order (`JoinSet` yields whichever
    // finishes first) and sorted back by original position — the geocode
    // failures/approximate lists that come out of this are user-facing, and
    // reordering the driver's own pasted list in the response for no reason
    // would be a needless surprise.
    let mut geocoded = Vec::with_capacity(geocode_tasks.len());
    while let Some(result) = geocode_tasks.join_next().await {
        // `geocode_address` itself never panics on any of its own error
        // paths (every failure is a returned `Err`) — a panic reaching here
        // is a genuine bug worth crashing loudly on, not one to silently
        // swallow and quietly drop an entry from the import.
        geocoded.push(result.expect("bulk geocode task panicked"));
    }
    geocoded.sort_by_key(|(idx, ..)| *idx);

    for (_, entry, existing_id, result) in geocoded {
        let (kunde, strasse, plz, paket, notiz) = entry;
        match result {
            Ok((lat, lon, _, precision)) => {
                let precision_tag = precision.tag();
                if let Some(p) = precision_tag {
                    approximate.push(GeocodeApproximate { kunde: kunde.clone(), strasse: strasse.clone(), plz: plz.clone(), precision: p });
                }
                let stop = (kunde, strasse, plz, paket, notiz);
                match existing_id {
                    Some(id) => to_move.push((stop, id, lat, lon, precision_tag)),
                    None => to_insert.push((stop, lat, lon, precision_tag)),
                }
            }
            Err(_) => {
                // A name-matched stop whose *new* address won't resolve
                // keeps its old address rather than being dropped: it is
                // still matched, so the deletion pass leaves it alone, and
                // its other edited fields are applied below. The driver
                // gets it back in `geocode_failures` to fix.
                if let Some(id) = existing_id {
                    to_update.push((kunde.clone(), paket, notiz, id));
                }
                failures.push(GeocodeFailure { kunde, strasse, plz });
            }
        }
    }

    // If anything failed to geocode, we can't safely tell "this address was
    // genuinely removed" apart from "this is an edited address that just
    // failed to resolve" (both look like "not in matched_ids"). Skip
    // deletions entirely this round rather than risk silently dropping a
    // customer who was only ever the victim of an unrelated typo elsewhere
    // in the same paste. A validation failure counts here too, not just a
    // geocode one: an entry that never made it past validation never got a
    // chance to match anything either, for exactly the same reason — and
    // without this, a paste that was *entirely* invalid (every entry
    // rejected) would have zero geocode failures, so nothing would skip
    // deletion, and every existing customer stop on the route would be
    // deleted as "no longer present" instead of the import safely no-op'ing.
    let deletions_skipped = !keep_unmatched && (!failures.is_empty() || !validation_failures.is_empty());
    let to_delete: Vec<i64> = if deletions_skipped || keep_unmatched {
        Vec::new()
    } else {
        existing_customers.iter().map(|s| s.id).filter(|id| !matched_ids.contains(id)).collect()
    };

    let changed = {
        let mut conn = state.db()?;
        require_route_exists(&conn, route_id)?;

        // A bulk import can be dozens of updates/inserts/deletes in one
        // request — without a transaction, a crash or panic partway
        // through leaves the route in whatever half-applied state the loop
        // happened to reach, which is exactly the kind of silent data
        // corruption this endpoint's failure-collection (`failures`,
        // `deletions_skipped`) is designed to avoid causing in the first
        // place.
        let tx = conn.transaction()?;

        for (kunde, paket, notiz, stop_id) in &to_update {
            tx.execute(
                "UPDATE stops SET kunde = ?1, paket = ?2, notiz = ?3 WHERE id = ?4",
                params![kunde, paket, notiz, stop_id],
            )?;
        }

        let mut changed = false;

        // Moved stops: everything the paste specifies is overwritten, and
        // the columns it says nothing about — `delivered` above all, but
        // also `order_index` and `created_at` — are left exactly as they
        // are. That is the entire point of recognizing a move: the stop
        // keeps its identity and its delivery state, only its location
        // changes. `needs_optimize` is set because a moved stop is a
        // different route.
        if !to_move.is_empty() {
            for ((kunde, strasse, plz, paket, notiz), id, lat, lon, precision) in &to_move {
                // `pinned = 0` matters as much as the new coordinates do: these
                // came from a geocoder, not from the driver's finger on the
                // map. A stop that had been hand-pinned and has since moved to
                // a different address would otherwise keep the very flag that
                // tells `recheck_addresses` to leave it alone -- so the one stop
                // on the route whose position is now purely a guess would be the
                // one stop no re-check is ever allowed to correct. Same reasoning
                // `update_stop` already applies when an address edit replaces a
                // hand-placed pin.
                tx.execute(
                    "UPDATE stops SET kunde = ?1, strasse = ?2, plz = ?3, paket = ?4, notiz = ?5, \
                     lat = ?6, lon = ?7, location_precision = ?8, pinned = 0, \
                     entrance_lat = NULL, entrance_lon = NULL WHERE id = ?9",
                    params![kunde, strasse, plz, paket, notiz, lat, lon, precision, id],
                )?;
            }
            changed = true;
        }

        if !to_insert.is_empty() {
            let mut max_order: i64 = tx.query_row(
                "SELECT COALESCE(MAX(order_index), 0) FROM stops WHERE route_id = ?1",
                params![route_id],
                |r| r.get(0),
            )?;
            let created_at = now_iso();
            for ((kunde, strasse, plz, paket, notiz), lat, lon, precision) in &to_insert {
                max_order += 1;
                tx.execute(
                    "INSERT INTO stops (route_id, kind, kunde, strasse, plz, paket, notiz, lat, lon, order_index, delivered, location_precision, created_at) \
                     VALUES (?1, 'customer', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10, ?11)",
                    params![route_id, kunde, strasse, plz, paket, notiz, lat, lon, max_order, precision, created_at],
                )?;
            }
            changed = true;
        }

        if !to_delete.is_empty() {
            for id in &to_delete {
                tx.execute("DELETE FROM stops WHERE id = ?1", params![id])?;
            }
            changed = true;
        }

        // Written onto whichever stop the entry ended up as, found the way
        // the import itself matches: same name, same address.
        if !extras.is_empty() {
            let rows: Vec<(i64, String, String, String)> = {
                let mut stmt = tx.prepare(
                    "SELECT id, COALESCE(kunde, ''), COALESCE(strasse, ''), COALESCE(plz, '') \
                     FROM stops WHERE route_id = ?1 AND kind = 'customer'",
                )?;
                let rows = stmt
                    .query_map(params![route_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
                    .collect::<Result<_, _>>()?;
                rows
            };
            for (name, addr, telefon, paket_count) in &extras {
                for (id, kunde, strasse, plz) in &rows {
                    if &name_key(kunde) != name || &addr_key(strasse, plz) != addr {
                        continue;
                    }
                    if let Some(telefon) = telefon {
                        tx.execute("UPDATE stops SET telefon = ?1 WHERE id = ?2", params![telefon, id])?;
                    }
                    if let Some(paket_count) = paket_count {
                        tx.execute("UPDATE stops SET paket_count = ?1 WHERE id = ?2", params![paket_count, id])?;
                    }
                }
            }
        }

        if changed {
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        }
        tx.commit()?;
        changed
    };
    drop(route_guard);

    // Every stop still without an entrance gets one looked up -- which is
    // also how a tour loaded before entrances existed catches up.
    fill_entrances(state, route_id).await;
    if changed {
        reoptimize_best_effort(state, route_id).await;
    }
    let conn = state.db()?;
    Ok(BulkJsonResult {
        route: get_route_detail(&conn, route_id)?,
        validation_failures,
        geocode_failures: failures,
        approximate,
        deletions_skipped,
    })
}

// ---------------------------------------------------------------------
// Zusteller-Portal (odoo.gourmet.at)
//
// Loading a day's tour instead of typing it in. A browser cannot talk to
// the portal itself -- it answers no cross-origin request -- so this server
// does, with a login it keeps in its own database. The app never sees the
// password again once it has been entered.
// ---------------------------------------------------------------------

const PORTAL_BASE: &str = "https://odoo.gourmet.at/api";
/// The deliveries still to be made. A cancelled or finished one is not a
/// stop of today's tour.
const PORTAL_OPEN_STATES: [&str; 4] = ["draft", "waiting", "confirmed", "assigned"];
/// How many delivery details are fetched at once.
const PORTAL_DETAIL_CONCURRENCY: usize = 6;

fn portal_error(status: reqwest::StatusCode) -> AppError {
    match status.as_u16() {
        401 | 403 => AppError::BadRequest(
            "Anmeldung beim Zusteller-Portal fehlgeschlagen. Bitte Benutzername und Passwort prüfen.".into(),
        ),
        other => AppError::Internal(format!("Zusteller-Portal antwortet mit Fehler {other}.")),
    }
}

fn portal_unreachable(e: reqwest::Error) -> AppError {
    tracing::warn!(error = %e, "Zusteller-Portal request failed");
    AppError::Internal("Das Zusteller-Portal ist gerade nicht erreichbar. Bitte später noch einmal versuchen.".into())
}

fn portal_request(state: &AppState, method: reqwest::Method, path: &str, token: Option<&str>) -> reqwest::RequestBuilder {
    let mut req = state
        .http
        .request(method, format!("{PORTAL_BASE}/{path}"))
        .timeout(Duration::from_secs(30))
        .header("Accept", "application/json, text/plain, */*")
        .header("Accept-Language", "de")
        .header("sc-website-key", "5");
    if let Some(token) = token {
        req = req.header("x-authorization", format!("Bearer {token}"));
    }
    req
}

async fn portal_json<T: DeserializeOwned>(req: reqwest::RequestBuilder, what: &str) -> Result<T, AppError> {
    let resp = req.send().await.map_err(portal_unreachable)?;
    if !resp.status().is_success() {
        return Err(portal_error(resp.status()));
    }
    resp.json::<T>().await.map_err(|e| {
        tracing::warn!(error = %e, what, "Zusteller-Portal answer not understood");
        AppError::Internal(format!("{what} des Zusteller-Portals nicht verstanden."))
    })
}

async fn portal_login(state: &AppState, username: &str, password: &str) -> Result<String, AppError> {
    #[derive(Deserialize)]
    struct LoginResponse {
        access_token: String,
    }
    let form = [
        ("username", username),
        ("password", password),
        ("rememberMe", "true"),
        ("host", "https://staging.essen-fuer-daheim.at"),
        ("check_role", "supplier"),
    ];
    let body = form
        .iter()
        .map(|(k, v)| format!("{k}={}", form_encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    let req = portal_request(state, reqwest::Method::POST, "login", None)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body);
    // The portal answers a login it does not accept with 403 -- and with
    // 400 when the name is not even shaped like one of its own. Either way
    // the driver's next move is the same: look at what was typed.
    let resp = req.send().await.map_err(portal_unreachable)?;
    if matches!(resp.status().as_u16(), 400 | 401 | 403) {
        return Err(portal_error(reqwest::StatusCode::FORBIDDEN));
    }
    if !resp.status().is_success() {
        return Err(portal_error(resp.status()));
    }
    let login: LoginResponse = resp.json().await.map_err(|e| {
        tracing::warn!(error = %e, "Zusteller-Portal login answer not understood");
        AppError::Internal("Antwort des Zusteller-Portals nicht verstanden.".into())
    })?;
    Ok(login.access_token)
}

/// Percent-encodes everything but the unreserved characters, so a password
/// with `&`, `+` or `=` in it arrives as the password.
fn form_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A token for the signed-in user's own portal login, or a plain-language refusal
/// when there is none.
async fn portal_token(state: &AppState, user: &AuthUser) -> Result<String, AppError> {
    let (username, password): (Option<String>, Option<String>) = {
        let conn = state.db()?;
        conn.query_row("SELECT portal_username, portal_password FROM users WHERE id = ?1", params![user.id], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?
    };
    let (Some(username), Some(password)) = (username, password) else {
        return Err(AppError::BadRequest("Bitte zuerst beim Zusteller-Portal anmelden.".into()));
    };
    portal_login(state, &username, &password).await
}

#[derive(Deserialize)]
struct PortalCredentials {
    username: String,
    password: String,
}

/// `POST /api/portal/login`. Tried against the portal first: a login is only
/// kept once it has been seen to work.
async fn portal_login_handler(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
    Json(payload): Json<PortalCredentials>,
) -> Result<Json<Value>, AppError> {
    let username = payload.username.trim().to_string();
    if username.is_empty() || payload.password.is_empty() {
        return Err(AppError::BadRequest("Bitte Benutzername und Passwort eingeben.".into()));
    }
    check_len(&username, "Benutzername", 200)?;
    check_len(&payload.password, "Passwort", 200)?;
    portal_login(&state, &username, &payload.password).await?;
    let conn = state.db()?;
    conn.execute(
        "UPDATE users SET portal_username = ?1, portal_password = ?2 WHERE id = ?3",
        params![username, payload.password, user.id],
    )?;
    Ok(Json(json!({ "logged_in": true, "username": username })))
}

async fn portal_status(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
) -> Result<Json<Value>, AppError> {
    let conn = state.db()?;
    let username: Option<String> =
        conn.query_row("SELECT portal_username FROM users WHERE id = ?1", params![user.id], |r| r.get(0))?;
    Ok(Json(json!({ "logged_in": username.is_some(), "username": username })))
}

async fn portal_logout(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
) -> Result<Json<Value>, AppError> {
    let conn = state.db()?;
    conn.execute("UPDATE users SET portal_username = NULL, portal_password = NULL WHERE id = ?1", params![user.id])?;
    Ok(Json(json!({ "logged_in": false })))
}

/// `null` where a list or an object was expected reads as "none". The
/// portal is somebody else's system: a field it leaves empty one day must
/// cost that field, not the whole tour.
fn null_as_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

#[derive(Deserialize)]
struct PortalTour {
    id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    name: String,
    catalogue_type: Option<String>,
    weekday: Option<String>,
    #[serde(default, deserialize_with = "null_as_default")]
    weekdays: Vec<String>,
}

impl PortalTour {
    /// Whether this tour is driven on `day`: a daily-menu tour lists its
    /// weekdays, every other kind names its one.
    fn runs_on(&self, day: &str) -> bool {
        if self.catalogue_type.as_deref() == Some("day") {
            self.weekdays.iter().any(|d| d == day)
        } else {
            self.weekday.as_deref() == Some(day)
        }
    }
}

fn german_weekday(date: chrono::NaiveDate) -> &'static str {
    use chrono::Datelike;
    ["montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag"]
        [date.weekday().num_days_from_monday() as usize]
}

fn parse_portal_date(raw: &str) -> Result<chrono::NaiveDate, AppError> {
    chrono::NaiveDate::parse_from_str(raw.trim(), "%Y-%m-%d")
        .map_err(|_| AppError::BadRequest("Ungültiges Datum.".into()))
}

#[derive(Deserialize)]
struct PortalDateQuery {
    date: String,
}

/// `GET /api/portal/tours?date=YYYY-MM-DD`: the tours driven that day.
async fn portal_tours(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
    axum::extract::Query(q): axum::extract::Query<PortalDateQuery>,
) -> Result<Json<Value>, AppError> {
    let day = german_weekday(parse_portal_date(&q.date)?);
    let token = portal_token(&state, &user).await?;
    let tours: Vec<PortalTour> =
        portal_json(portal_request(&state, reqwest::Method::GET, "supplier/tours", Some(&token)), "Tourenliste").await?;
    let mut today: Vec<&PortalTour> = tours.iter().filter(|t| t.runs_on(day)).collect();
    today.sort_by_key(|t| t.name.to_lowercase());
    Ok(Json(json!({
        "tours": today.iter().map(|t| json!({ "id": t.id, "name": t.name.trim() })).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize, Default)]
struct PortalAddress {
    street: Option<String>,
    street2: Option<String>,
    staircase: Option<String>,
    flat_number: Option<String>,
    zip: Option<String>,
    comment: Option<String>,
}

#[derive(Deserialize, Default)]
struct PortalCustomer {
    firstname: Option<String>,
    lastname: Option<String>,
    comment: Option<String>,
    phone: Option<String>,
}

#[derive(Deserialize)]
struct PortalTourRef {
    id: i64,
}

fn one() -> f64 {
    1.0
}

#[derive(Deserialize)]
struct PortalLine {
    #[serde(default, deserialize_with = "null_as_default")]
    name: String,
    #[serde(default = "one")]
    quantity: f64,
}

#[derive(Deserialize)]
struct PortalBundle {
    #[serde(default, deserialize_with = "null_as_default")]
    delivery_lines: Vec<PortalLine>,
}

#[derive(Deserialize)]
struct PortalDelivery {
    id: i64,
    #[serde(default, deserialize_with = "null_as_default")]
    customer: PortalCustomer,
    #[serde(default, deserialize_with = "null_as_default")]
    delivery_address: PortalAddress,
    #[serde(default, deserialize_with = "null_as_default")]
    tours: Vec<PortalTourRef>,
    delivery_bundles: Option<Vec<PortalBundle>>,
}

#[derive(Deserialize)]
struct PortalDeliveryPage {
    #[serde(default, deserialize_with = "null_as_default")]
    items: Vec<PortalDelivery>,
    #[serde(default = "one_page")]
    total_pages: i64,
}

fn one_page() -> i64 {
    1
}

fn non_empty(s: &Option<String>) -> Option<&str> {
    s.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

impl PortalDelivery {
    fn kunde(&self) -> String {
        [non_empty(&self.customer.firstname), non_empty(&self.customer.lastname)]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// "Gentzgasse 129/1/23": the street, then whatever the portal files
    /// under Zusatz, Stiege and Tür, in the form the geocoder reads.
    fn strasse(&self) -> String {
        let a = &self.delivery_address;
        let mut strasse = non_empty(&a.street).unwrap_or("").to_string();
        let suffixes: Vec<&str> =
            [non_empty(&a.street2), non_empty(&a.staircase), non_empty(&a.flat_number)].into_iter().flatten().collect();
        if !suffixes.is_empty() {
            if !strasse.is_empty() {
                strasse.push('/');
            }
            strasse.push_str(&suffixes.join("/"));
        }
        strasse
    }

    fn plz(&self) -> String {
        non_empty(&self.delivery_address.zip).unwrap_or("").to_string()
    }

    /// What is inside every parcel, as one line: "2x Menü A, Suppe".
    fn paket(&self) -> Option<String> {
        let lines: Vec<&PortalLine> = self.delivery_bundles.iter().flatten().flat_map(|b| &b.delivery_lines).collect();
        if lines.is_empty() {
            return None;
        }
        let parts: Vec<String> = lines
            .iter()
            .map(|l| {
                if l.quantity == 1.0 {
                    l.name.trim().to_string()
                } else if l.quantity.fract() == 0.0 && l.quantity.abs() < 1e15 {
                    format!("{}x {}", l.quantity as i64, l.name.trim())
                } else {
                    format!("{:.2}x {}", l.quantity, l.name.trim())
                }
            })
            .collect();
        Some(clip_chars(&parts.join(", "), MAX_PAKET_LEN))
    }

    /// One entry of the list `import_entries` reads.
    fn entry(&self) -> Value {
        let notiz = non_empty(&self.delivery_address.comment).or(non_empty(&self.customer.comment));
        json!({
            "kunde": clip_chars(&self.kunde(), MAX_KUNDE_LEN),
            "strasse": clip_chars(&self.strasse(), MAX_STRASSE_LEN),
            "plz": self.plz(),
            "paket": self.paket(),
            "notiz": notiz.map(|n| clip_chars(&strip_control(n), MAX_NOTIZ_LEN)),
            "telefon": non_empty(&self.customer.phone).map(|t| clip_chars(t, MAX_TELEFON_LEN)),
            "paket_count": self.delivery_bundles.as_ref().map(Vec::len),
        })
    }
}

/// The office's text is not this app's to refuse: a note longer than a stop
/// holds is shortened rather than costing the driver the whole stop.
fn clip_chars(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

fn strip_control(s: &str) -> String {
    s.chars().filter(|c| !c.is_control() || *c == '\n').collect()
}

/// Every open delivery of one tour on one day, without its parcels: the
/// list answers with who and where, and the contents come per delivery.
async fn portal_deliveries_of(
    state: &AppState,
    token: &str,
    tour_id: i64,
    date: chrono::NaiveDate,
) -> Result<Vec<PortalDelivery>, AppError> {
    let mut all: Vec<PortalDelivery> = Vec::new();
    let mut page = 1;
    loop {
        let mut query: Vec<(&str, String)> = vec![
            ("delivery_date", date.format("%Y-%m-%d").to_string()),
            ("page", page.to_string()),
            ("page_size", "100".into()),
            ("tour_id", tour_id.to_string()),
        ];
        query.extend(PORTAL_OPEN_STATES.iter().map(|s| ("state", s.to_string())));
        let req = portal_request(state, reqwest::Method::GET, "supplier/deliveries", Some(token)).query(&query);
        let result: PortalDeliveryPage = portal_json(req, "Lieferliste").await?;
        let done = page >= result.total_pages || result.items.is_empty();
        all.extend(result.items);
        if done || page > 50 {
            break;
        }
        page += 1;
    }
    // The portal's own filter lets through a customer served on another
    // tour today; only the ones that name this tour are its stops.
    all.retain(|d| d.tours.iter().any(|t| t.id == tour_id));
    Ok(all)
}

#[derive(Deserialize)]
struct PortalDeliveriesQuery {
    tour_id: i64,
    date: String,
}

/// `GET /api/portal/deliveries?tour_id=&date=`: who is on the tour, for the
/// driver to look over before anything is loaded.
async fn portal_deliveries(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
    axum::extract::Query(q): axum::extract::Query<PortalDeliveriesQuery>,
) -> Result<Json<Value>, AppError> {
    let date = parse_portal_date(&q.date)?;
    let token = portal_token(&state, &user).await?;
    let deliveries = portal_deliveries_of(&state, &token, q.tour_id, date).await?;
    Ok(Json(json!({
        "deliveries": deliveries
            .iter()
            .map(|d| json!({ "id": d.id, "kunde": d.kunde(), "strasse": d.strasse(), "plz": d.plz() }))
            .collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
struct PortalEntriesRequest {
    tour_id: i64,
    date: String,
    /// The deliveries to load. Absent loads the whole tour.
    delivery_ids: Option<Vec<i64>>,
    /// Hand the entries back in the order a tour of them is driven, rather
    /// than the portal's -- see `in_driving_order`.
    #[serde(default)]
    driving_order: bool,
}

#[derive(Deserialize)]
struct PortalImport {
    tour_name: String,
    date: String,
    /// The stops to load, as `portal_entries` returned them -- and as the
    /// driver corrected them on the Prüfen screen.
    entries: Vec<Value>,
    /// The route to load into. Absent makes a new one, named for the tour.
    route_id: Option<i64>,
}

/// `POST /api/portal/entries`: the chosen deliveries in full -- name,
/// address, what is in the parcels, the note, the phone number -- for the
/// driver to look over and correct before any of it touches a tour. Nothing
/// is looked up or saved here.
async fn portal_entries(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
    Json(payload): Json<PortalEntriesRequest>,
) -> Result<Json<Value>, AppError> {
    let date = parse_portal_date(&payload.date)?;
    let token = portal_token(&state, &user).await?;
    let mut deliveries = portal_deliveries_of(&state, &token, payload.tour_id, date).await?;
    if let Some(ids) = &payload.delivery_ids {
        // In the order they were picked, not the portal's: the driver ticks
        // them off in the order of the printed list, and Prüfen is read
        // against that list.
        let position: HashMap<i64, usize> = ids.iter().enumerate().map(|(i, id)| (*id, i)).collect();
        deliveries.retain(|d| position.contains_key(&d.id));
        deliveries.sort_by_key(|d| position[&d.id]);
    }
    if deliveries.is_empty() {
        return Err(AppError::BadRequest("Für diese Tour gibt es an diesem Tag keine offenen Lieferungen.".into()));
    }
    if deliveries.len() > MAX_BULK_STOPS {
        return Err(AppError::BadRequest(format!(
            "Diese Tour hat {} Lieferungen, mehr als eine Route fasst ({MAX_BULK_STOPS}). Bitte weniger auswählen.",
            deliveries.len()
        )));
    }

    // The parcels' contents come one delivery at a time.
    let semaphore = Arc::new(Semaphore::new(PORTAL_DETAIL_CONCURRENCY));
    let mut jobs: JoinSet<Result<(usize, Value), AppError>> = JoinSet::new();
    for (index, delivery) in deliveries.iter().enumerate() {
        let state = Arc::clone(&state);
        let token = token.clone();
        let semaphore = Arc::clone(&semaphore);
        let id = delivery.id;
        jobs.spawn(async move {
            let _permit = semaphore.acquire().await.map_err(|_| AppError::Internal("Abgebrochen.".into()))?;
            let req = portal_request(&state, reqwest::Method::GET, &format!("supplier/deliveries/{id}"), Some(&token));
            let detail: PortalDelivery = portal_json(req, "Lieferdaten").await?;
            Ok((index, detail.entry()))
        });
    }
    let mut entries: Vec<Option<Value>> = vec![None; deliveries.len()];
    while let Some(joined) = jobs.join_next().await {
        let (index, entry) = joined.map_err(|_| AppError::Internal("Abgebrochen.".into()))??;
        entries[index] = Some(entry);
    }
    let mut entries: Vec<Value> = entries.into_iter().flatten().collect();
    if payload.driving_order {
        entries = in_driving_order(&state, entries).await?;
    }
    Ok(Json(json!({ "entries": entries })))
}

/// Portal entries in the order a fresh tour of them would be driven: from the
/// Lager, through every door, back to the depot -- the trip `reoptimize_route`
/// asks for on a tour with all three fixed points on. Nothing is stored; this
/// is for the printed list, which is read in the van like the tour is.
///
/// An address nobody can place goes to the end, in the portal's order, rather
/// than costing the whole list.
async fn in_driving_order(state: &Arc<AppState>, entries: Vec<Value>) -> Result<Vec<Value>, AppError> {
    let semaphore = Arc::new(Semaphore::new(PORTAL_DETAIL_CONCURRENCY));
    let mut jobs: JoinSet<(usize, Option<(f64, f64)>)> = JoinSet::new();
    for (index, entry) in entries.iter().enumerate() {
        let strasse = entry["strasse"].as_str().unwrap_or_default().to_string();
        let plz = entry["plz"].as_str().unwrap_or_default().to_string();
        let state = Arc::clone(state);
        let semaphore = Arc::clone(&semaphore);
        jobs.spawn(async move {
            let Ok(_permit) = semaphore.acquire().await else { return (index, None) };
            let point = geocode_address(&state, &strasse, &plz).await.ok().map(|(lat, lon, _, _)| (lat, lon));
            (index, point)
        });
    }
    let mut points: Vec<Option<(f64, f64)>> = vec![None; entries.len()];
    while let Some(joined) = jobs.join_next().await {
        let (index, point) = joined.map_err(|_| AppError::Internal("Abgebrochen.".into()))?;
        points[index] = point;
    }

    let placed: Vec<usize> = (0..entries.len()).filter(|i| points[*i].is_some()).collect();
    let mut order: Vec<usize> = if placed.len() < 2 {
        placed.clone()
    } else {
        let mut coords = vec![(VIA_LAT, VIA_LON)];
        coords.extend(placed.iter().filter_map(|i| points[*i]));
        coords.push((START_LAT, START_LON));
        let (visited, _, _) = osrm_trip(state, &coords, true, true).await?;
        // Without the two ends, which are not deliveries.
        visited.into_iter().filter(|v| (1..=placed.len()).contains(v)).map(|v| placed[v - 1]).collect()
    };
    order.extend((0..entries.len()).filter(|i| points[*i].is_none()));

    let mut slots: Vec<Option<Value>> = entries.into_iter().map(Some).collect();
    Ok(order.into_iter().filter_map(|i| slots[i].take()).collect())
}

/// `POST /api/portal/import`: puts the entries the driver has looked over
/// onto a tour -- a new one, or one that is already there, where stops added
/// by hand are left alone and stops already on it are recognised rather
/// than doubled.
async fn portal_import(
    State(state): State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<AuthUser>,
    Json(payload): Json<PortalImport>,
) -> Result<Json<BulkJsonResult>, AppError> {
    let date = parse_portal_date(&payload.date)?;
    let entries = payload.entries;
    if entries.is_empty() {
        return Err(AppError::BadRequest("Es ist kein Stopp ausgewählt.".into()));
    }

    let created = payload.route_id.is_none();
    let route_id = match payload.route_id {
        Some(id) => {
            let conn = state.db()?;
            // The route arrives in the body, where `auth_mw` cannot see it.
            let owner: Option<Option<i64>> =
                conn.query_row("SELECT user_id FROM routes WHERE id = ?1", params![id], |r| r.get(0)).optional()?;
            if owner != Some(Some(user.id)) {
                return Err(AppError::NotFound("Tour nicht gefunden".into()));
            }
            // Never past what a route can be planned with.
            let have: i64 = conn.query_row(
                "SELECT COUNT(*) FROM stops WHERE route_id = ?1 AND kind = 'customer'",
                params![id],
                |r| r.get(0),
            )?;
            if have as usize + entries.len() > MAX_BULK_STOPS {
                return Err(AppError::BadRequest(format!(
                    "Damit hätte die Route mehr als {MAX_BULK_STOPS} Stopps. Bitte weniger auswählen oder eine neue Route anlegen."
                )));
            }
            id
        }
        None => {
            let name = {
                let conn = state.db()?;
                let base = clip_chars(payload.tour_name.trim(), MAX_ROUTE_NAME_LEN - 12);
                let base = if base.is_empty() { "Tour".to_string() } else { base };
                check_no_control_chars(&base, "Name", false)?;
                // The tour's own name; the day with it once an active route
                // already carries that name.
                let taken: bool = conn
                    .query_row(
                        "SELECT 1 FROM routes WHERE name = ?1 AND status = 'active' AND user_id = ?2",
                        params![base, user.id],
                        |_| Ok(()),
                    )
                    .optional()?
                    .is_some();
                if taken { format!("{base} – {}", date.format("%d.%m.")) } else { base }
            };
            insert_route(&state, user.id, &name)?
        }
    };

    match import_entries(&state, route_id, &Value::Array(entries), true).await {
        Ok(result) => Ok(Json(result)),
        Err(e) => {
            // A route made for this load and left empty by its failure is
            // not one the driver asked for.
            if created {
                if let Ok(conn) = state.db() {
                    let _ = conn.execute("DELETE FROM routes WHERE id = ?1", params![route_id]);
                }
            }
            Err(e)
        }
    }
}

// ---------------------------------------------------------------------
// Root — index.html and sw.js are read from disk on every request (from
// the project directory this was built from — see CARGO_MANIFEST_DIR
// below), not embedded into the binary. Editing either file takes effect
// on the very next request: no rebuild, no restart.
// ---------------------------------------------------------------------

/// Where the three static files live. The project directory this was built
/// from is the right answer during development — it's what makes editing
/// index.html take effect on the next request with no rebuild — but it's a
/// path on the *build* machine, so a binary copied anywhere else would 500
/// on every page load while still happily finding its database next to
/// itself (see `base_dir`). Falling back to the binary's own directory when
/// the build-time path no longer has an index.html in it makes the binary
/// genuinely relocatable: copy it next to the three assets and it works.
/// `EAR_ASSETS_DIR` overrides both for a deployment that keeps them
/// somewhere else entirely.
fn assets_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("EAR_ASSETS_DIR") {
        return PathBuf::from(dir);
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    if manifest.join("index.html").is_file() {
        return manifest;
    }
    base_dir()
}

/// Reads one of the three static files off disk, turning a missing/unreadable
/// file into a logged 500 rather than a panic. `CatchPanicLayer` would keep
/// the server alive through an `.expect()` here either way, but a panic
/// backtrace on every single page load is a terrible way to say "index.html
/// isn't next to the binary".
async fn read_static(state: &AppState, name: &str) -> Result<Vec<u8>, AppError> {
    let path = state.assets.join(name);
    tokio::fs::read(&path).await.map_err(|e| {
        tracing::error!(error = %e, path = %path.display(), "failed to read static file");
        AppError::Internal("Datei konnte nicht geladen werden.".into())
    })
}

/// A strong ETag over the bytes actually being served.
///
/// Content-derived rather than mtime-derived on purpose: these files are
/// edited in place and served straight off disk, and mtime changes when a
/// file is touched, copied or checked out without its content changing at
/// all — which would force a full re-download of a file the browser
/// already has.
fn etag_for(bytes: &[u8]) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    // Length as well as the hash: cheap, and it makes a collision need to
    // agree on both.
    format!("\"{:x}-{:x}\"", hasher.finish(), bytes.len())
}

/// Serves a static file with `no-cache` + ETag revalidation.
///
/// `no-cache` means "always ask before reusing" — necessary, because the
/// app shell is edited in place and a cached copy must never outlive a
/// deploy. On its own, though, it makes every single launch re-download
/// the whole file: index.html is ~93 KB and it has no validator, so the
/// server has nothing to answer the revalidation with except the entire
/// body again. With an ETag the same revalidation becomes a 304 with an
/// empty body whenever nothing has changed, which on a driver's mobile
/// connection is the difference between a page load and a pause.
fn static_response(
    bytes: Vec<u8>,
    content_type: &'static str,
    cache_control: &'static str,
    req_headers: &HeaderMap,
) -> Response {
    let etag = etag_for(&bytes);
    let matches = req_headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        // A cache may send several, comma separated, and a revalidation of
        // a `Content-Encoding`-transformed copy arrives weakened ("W/").
        .is_some_and(|v| v.split(',').any(|c| c.trim().trim_start_matches("W/") == etag));

    let headers = [
        (header::CACHE_CONTROL, cache_control.to_string()),
        (header::ETAG, etag),
    ];
    if matches {
        return (StatusCode::NOT_MODIFIED, headers).into_response();
    }
    ([(header::CONTENT_TYPE, content_type)], headers, bytes).into_response()
}

/// `Cache-Control: no-cache` (not "no-store") so the browser always
/// revalidates before using its cached copy — the app shell is edited in
/// place and served straight off disk, so a stale cached copy would hide a
/// deploy for however long the header allows.
async fn index(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let html = read_static(&state, "index.html").await?;
    Ok(static_response(html, "text/html; charset=utf-8", "no-cache", &headers))
}

/// Same `no-cache` reasoning as `index`, and doubly so here: the whole
/// point of a service worker is to update itself promptly on the next
/// visit, which a long-lived cached /sw.js would defeat.
async fn sw_js(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let js = read_static(&state, "sw.js").await?;
    Ok(static_response(js, "application/javascript; charset=utf-8", "no-cache", &headers))
}

/// The one genuinely static asset (the ASBÖ logo, ~190 KB, reused as
/// favicon/app icon/in-app header image) — worth an actual cache lifetime
/// rather than re-fetching it on every load. The ETag still matters once
/// that lifetime expires: the logo will not have changed, so the daily
/// revalidation costs a 304 instead of 190 KB.
async fn icon_png(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let bytes = read_static(&state, "icon.png").await?;
    Ok(static_response(bytes, "image/png", "public, max-age=86400", &headers))
}

// ---------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------

/// Waits for a shutdown signal so `main` can pass it to
/// `with_graceful_shutdown` —
/// without that, killing the process (a redeploy, a driver's own Ctrl+C)
/// drops every in-flight connection immediately, including one mid-way
/// through a multi-step handler like `import_entries`. Graceful
/// shutdown lets axum stop accepting new connections but finish the ones
/// already in progress first.
async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.expect("failed to install Ctrl+C handler");
    };

    // A service manager (systemd, Docker, a reverse-proxy supervisor) stops
    // a process with SIGTERM, not Ctrl+C — without this arm, the graceful
    // shutdown below only ever runs for a human at a terminal, and every
    // real restart still severs in-flight requests.
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
    tracing::info!("shutdown signal received, draining in-flight requests");
}

fn base_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .filter(|p| p.exists())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// The complete application, assembled from a ready `AppState`.
///
/// Separate from `main` so a test can one day drive the real router — the
/// same routes, the same middleware stack, the same extractors — over a
/// throwaway database, instead of calling handler functions directly and
/// missing everything the layers do (body limits, error shaping, the
/// rejections axum produces before a handler is reached). No test does that
/// yet; the seam is here for when one does.
fn build_router(state: Arc<AppState>) -> Router {
    // Rate-limited, size-capped: only the JSON API a script could actually
    // abuse. Kept as its own router (rather than one global limiter) so a
    // normal page load — several static-asset GETs at once — never counts
    // against the same budget as the API calls a driver's phone makes.
    let api_router = Router::new()
        .route("/api/routes", get(list_routes).post(create_route))
        .route("/api/routes/:id", get(get_route).patch(update_route).delete(delete_route))
        .route("/api/routes/:id/optimize", post(optimize_route))
        .route("/api/routes/:id/position", post(set_position))
        .route("/api/routes/:id/departed", post(mark_departed))
        .route("/api/routes/:id/order", put(set_stop_order))
        .route("/api/routes/:id/reset-delivered", post(reset_delivered))
        .route("/api/routes/:id/recheck-addresses", post(recheck_addresses))
        .route("/api/routes/:id/stops", post(add_stop))
        .route("/api/stops/:id", patch(update_stop).delete(delete_stop))
        // Behind the limiter with everything else: a password guess is a
        // request like any other, and costs a second on top (see `login`).
        .route("/api/login", post(login))
        // Here for the body limit: a full tour's entries, each with a Paket
        // as long as the portal makes it, is more than the default allows.
        .route("/api/portal/import", post(portal_import))
        // Ordering matters here, and it reads bottom-up: the rate limiter
        // is outermost so a flood is rejected before a body is buffered,
        // then the body limit. Error shaping and cache suppression are
        // deliberately *not* here — see `build_router`'s outer stack for why.
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(middleware::from_fn_with_state(state.clone(), rate_limit_mw));

    Router::new()
        .merge(api_router)
        // Deliberately outside the rate limiter: a monitoring check that
        // runs every few seconds must not consume the budget meant for the
        // driver, and must not start failing as a *side effect* of the
        // flood it exists to report.
        .route("/api/logout", post(logout))
        .route("/api/me", get(me))
        .route("/api/admin/users", get(admin_list_users).post(admin_create_user))
        .route("/api/admin/users/:id", patch(admin_update_user).delete(admin_delete_user))
        .route("/api/pace", get(pace_history))
        .route("/api/portal/status", get(portal_status))
        .route("/api/portal/login", post(portal_login_handler))
        .route("/api/portal/logout", post(portal_logout))
        .route("/api/portal/tours", get(portal_tours))
        .route("/api/portal/deliveries", get(portal_deliveries))
        .route("/api/portal/entries", post(portal_entries))
        .route("/api/health", get(health))
        .route("/", get(index))
        .route("/sw.js", get(sw_js))
        .route("/icon.png", get(icon_png))
        .fallback(not_found)
        .layer(middleware::from_fn_with_state(state.clone(), auth_mw))
        .with_state(state)
        // A hung/misbehaving upstream (Nominatim, OSRM, or a stalled TCP
        // connection) shouldn't be able to tie up a handler forever — set
        // well above the largest legitimate request (a full `MAX_BULK_STOPS`
        // import, each uncached entry paying the ~1.1s Nominatim throttle).
        // `tower_http`'s own `TimeoutLayer` (unlike `tower::timeout`)
        // resolves a timeout directly into a 408 response rather than an
        // `Err`, so it attaches straight to the `Router` with no separate
        // error-handling layer needed.
        .layer(TimeoutLayer::new(Duration::from_secs(600)))
        // Turns a panic inside any handler into a 500 response instead of
        // silently dropping the connection — the request that triggered it
        // fails cleanly, the server keeps serving everyone else.
        .layer(CatchPanicLayer::new())
        // Outside both of the above, and that placement is the point: the
        // timeout and the panic catcher answer with plain text of their
        // own, and nested any deeper this would never see either. It leaves
        // non-/api responses untouched.
        .layer(middleware::from_fn(api_error_shape_mw))
        // Outermost of the /api layers, so no response can slip out without
        // it — including the rate limiter's 429 and `/api/health`, both of
        // which are generated above the API router entirely. Also outside
        // the error shaping, so the header is stamped on the final response
        // rather than relying on a reshaped one to carry it across.
        .layer(middleware::from_fn(api_no_store_mw))
        .layer(middleware::from_fn(security_headers_mw))
        .layer(TraceLayer::new_for_http())
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    // `EAR_DATA_DIR` is where the database lives on a server. Without it
    // the file sits next to the binary -- fine on a laptop, and on a host
    // that builds in place it means `target/release/`, which one `cargo
    // clean` empties of every driver's tours.
    let data_dir = std::env::var_os("EAR_DATA_DIR").map(PathBuf::from).unwrap_or_else(base_dir);
    std::fs::create_dir_all(&data_dir).expect("failed to create the data directory");
    let db_path = data_dir.join("rerouter.db");
    init_db(&db_path).expect("failed to initialize database");

    let assets = assets_dir();
    if !assets.join("index.html").is_file() {
        // Not fatal — the JSON API is perfectly usable without the app
        // shell — but silently serving 500s for "/" with no explanation is
        // the single most confusing way this can be misdeployed.
        tracing::warn!(
            dir = %assets.display(),
            "index.html not found in the assets directory — the web app will not load. \
             Set EAR_ASSETS_DIR or put index.html/sw.js/icon.png next to the binary."
        );
    }

    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        // The deadline that actually matters for how this app *feels*.
        //
        // The default primary OSRM is a self-hosted box on a LAN address
        // (`OSRM_BASE_DEFAULT`). When that box is off, moved, or simply not
        // on the network the app is currently attached to, connecting to it
        // does not fail — it hangs until the OS gives up on the SYN, which
        // on Windows is tens of seconds. With only the 20s total `timeout`
        // above to stop it, the *first* route/stop/optimize action after a
        // restart burned the whole 20s inside `osrm_get` before falling
        // back, which is longer than the browser's own 30s budget minus the
        // rest of the work — so the driver watched the progress bar crawl
        // and then got "Zeitüberschreitung". The failure was also what
        // *recorded* the primary as down (`osrm_primary_down_since`), so the
        // very next tap skipped the primary entirely and answered instantly.
        // That is the "it fails, I press it again and it works" the app was
        // reported for, and it is a connect timeout, not a flaky server.
        //
        // 2.5s is far longer than a LAN connect (sub-millisecond) or a
        // public-internet TLS connect (tens of ms) ever legitimately takes,
        // and short enough that discovering a dead primary costs a pause
        // rather than a failed request.
        .connect_timeout(Duration::from_millis(2500))
        // Keep-alive tuned for the traffic this app actually makes: bursts
        // of Nominatim/OSRM calls while a driver builds a route, then long
        // idle stretches. Holding the pool open across those gaps saves a
        // full TLS handshake on the first call of each burst.
        .pool_idle_timeout(Duration::from_secs(90))
        .user_agent(UPSTREAM_USER_AGENT)
        .build()
        .expect("failed to build HTTP client");
    tracing::info!("Geocoding via Wien-OGD with Nominatim fallback, routing via OSRM — all live services, no local dataset.");

    // Off unless explicitly enabled: believing `X-Forwarded-For` from a
    // client that isn't actually behind a trusted proxy hands anyone a way
    // to present a fresh identity per request and walk straight past the
    // rate limiter. See `client_ip`.
    let trust_proxy = matches!(
        std::env::var("EAR_TRUST_PROXY").as_deref(),
        Ok("1") | Ok("true") | Ok("yes")
    );
    if trust_proxy {
        tracing::info!("EAR_TRUST_PROXY set — rate limiting will use the first X-Forwarded-For entry.");
    }

    let state = Arc::new(AppState {
        db_path,
        db_pool: Arc::new(StdMutex::new(Vec::new())),
        assets,
        http,
        nominatim_last: AsyncMutex::new(None),
        rate_limit: AsyncMutex::new(HashMap::new()),
        trust_proxy,
        upstreams: Upstreams::from_env(),
        route_locks: AsyncMutex::new(HashMap::new()),
        osrm_primary_down_since: StdMutex::new(None),
    });

    // Find out whether the self-hosted OSRM is reachable *now*, in the
    // background, instead of letting the driver's first tap find out.
    //
    // Even with `connect_timeout`/`OSRM_PRIMARY_DEADLINE` bounding it, that
    // discovery is a stall on a request someone is watching — and it lands
    // on the very first route, stop or optimize after every restart, which
    // is exactly when the app is being judged. Doing it here means the
    // cooldown in `osrm_primary_down_since` is already recorded by the time
    // anything interactive runs, so the first tap goes straight to the
    // fallback at full speed.
    //
    // Spawned rather than awaited: a slow or dead primary must not delay
    // the port opening. A trivial `/route` between two points a metre apart
    // in Vienna — cheap for any OSRM, and the answer is thrown away; only
    // whether it answered matters, and `osrm_get` records that itself.
    {
        let probe_state = Arc::clone(&state);
        tokio::spawn(async move {
            if probe_state.upstreams.osrm_base == OSRM_PUBLIC_FALLBACK {
                return;
            }
            let path = "/route/v1/driving/16.373800,48.208200;16.373900,48.208300?overview=false";
            match osrm_get::<serde_json::Value>(&probe_state, path).await {
                Ok(_) => tracing::info!(base = %probe_state.upstreams.osrm_base, "primary OSRM reachable"),
                Err(_) => tracing::warn!(
                    base = %probe_state.upstreams.osrm_base,
                    "primary OSRM not reachable at startup — routing will use the public server until it recovers"
                ),
            }
        });
    }

    let app = build_router(state);

    // Port is overridable so a second instance (or a deployment where 8000
    // is already taken) doesn't need a recompile; 8000 stays the default
    // every existing shortcut and launch.json points at.
    // `PORT` is what a hosting panel sets; `EAR_PORT` wins where both are.
    let port: u16 = std::env::var("EAR_PORT")
        .or_else(|_| std::env::var("PORT"))
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8000);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!("EAR Routing listening on http://{addr}");
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .unwrap_or_else(|e| panic!("failed to bind port {port}: {e}"));
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
}

// ---------------------------------------------------------------------
// Tests — the pure, network-free parts: address text normalization (which
// decides what every geocoder query actually looks like) and the input
// validators. These are exactly the pieces that fail silently and wrongly
// rather than loudly: a normalization regression doesn't crash, it just
// starts pinning stops at the wrong address.
// ---------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::text::{normalize_strasse_text, simplify_housenumber, street_name_only};
    use super::*;

    #[test]
    fn normalizes_strasse_spellings() {
        assert_eq!(normalize_strasse_text("Hauptstr. 5"), "Hauptstraße 5");
        assert_eq!(normalize_strasse_text("Hauptstrasse 5"), "Hauptstraße 5");
        assert_eq!(normalize_strasse_text("  Gentzgasse   129  "), "Gentzgasse 129");
        // Already correct spelling passes through untouched.
        assert_eq!(normalize_strasse_text("Gentzgasse 129"), "Gentzgasse 129");
        // A street word on its own keeps its capital.
        assert_eq!(normalize_strasse_text("Währinger Strasse 4"), "Währinger Straße 4");
        assert_eq!(normalize_strasse_text("Mariahilfer Str. 5"), "Mariahilfer Straße 5");
        assert_eq!(normalize_strasse_text("Währinger Straße 4"), "Währinger Straße 4");
    }

    #[test]
    fn strips_stiege_and_tuer_but_keeps_housenumber_ranges() {
        assert_eq!(simplify_housenumber("Gentzgasse 129/1/2/23"), "Gentzgasse 129");
        assert_eq!(
            simplify_housenumber("Dr.-Heinrich-Maier-Straße 28-34/Haus 2/12"),
            "Dr.-Heinrich-Maier-Straße 28-34"
        );
        assert_eq!(simplify_housenumber("Gutzkowplatz 2-5"), "Gutzkowplatz 2-5");
        assert_eq!(simplify_housenumber("Favoritenstraße 45a"), "Favoritenstraße 45a");
        // No housenumber at all (a place name) — left exactly as-is rather
        // than mangled into something that won't geocode.
        assert_eq!(simplify_housenumber("Stephansplatz"), "Stephansplatz");
    }

    #[test]
    fn extracts_street_name_without_housenumber() {
        assert_eq!(street_name_only("Gentzgasse 129/1/2/23"), "Gentzgasse");
        assert_eq!(street_name_only("Am Hof 2"), "Am Hof");
        assert_eq!(street_name_only("Stephansplatz"), "Stephansplatz");
    }

    #[test]
    fn accepts_only_real_vienna_postcodes() {
        assert!(is_valid_vienna_plz("1010"));
        assert!(is_valid_vienna_plz("1230"));
        assert!(!is_valid_vienna_plz("1240")); // no 24th district
        assert!(!is_valid_vienna_plz("8010")); // Graz
        assert!(is_valid_plz("8010"));
        assert!(is_valid_plz("2201"));
        assert!(!is_valid_plz("0123"));
        assert!(!is_valid_plz("12345"));
        assert!(!is_valid_plz("12a4"));
        assert_eq!(place_suffix("1180"), "1180 Wien, Österreich");
        assert_eq!(place_suffix("2201"), "2201, Österreich");
        assert!(!is_valid_vienna_plz(""));
        assert!(!is_valid_vienna_plz("1010 "));
    }

    #[test]
    fn rejects_coordinates_outside_vienna() {
        assert!(is_plausible_latlon(48.2082, 16.3738)); // Stephansplatz
        assert!(!is_plausible_latlon(0.0, 0.0));
        assert!(!is_plausible_latlon(16.3738, 48.2082)); // swapped lat/lon
        assert!(is_plausible_latlon(47.0707, 15.4395)); // Graz: any Austrian address is a stop
        assert!(!is_plausible_latlon(47.4979, 19.0402)); // Budapest
        assert!(!is_plausible_latlon(f64::NAN, 16.3738));
        assert!(!is_plausible_latlon(48.2082, f64::INFINITY));
    }

    fn ogd_feature(street: &str, plz: &str, ranking: f64) -> OgdFeature {
        OgdFeature {
            geometry: OgdGeometry { coordinates: [16.3738, 48.2082] },
            properties: OgdProperties {
                street_name: Some(street.to_string()),
                postal_code: Some(plz.to_string()),
                kategorie: Some("Adresse".to_string()),
                adresse: Some(format!("{street} 1")),
                ranking: Some(ranking),
                street_number: Some("1".to_string()),
                bezirk: None,
            },
        }
    }

    fn street_key(street: &str) -> String {
        text::address_match_key(street)
    }

    /// One answer of the register, spelled out: where it is, and what it
    /// says it is.
    fn ogd(adresse: &str, street: &str, number: &str, plz: Option<&str>, ranking: f64, at: (f64, f64)) -> OgdFeature {
        OgdFeature {
            geometry: OgdGeometry { coordinates: [at.1, at.0] },
            properties: OgdProperties {
                street_name: Some(street.to_string()),
                postal_code: plz.map(str::to_string),
                kategorie: Some("Adresse".to_string()),
                adresse: Some(adresse.to_string()),
                ranking: Some(ranking),
                street_number: Some(number.to_string()),
                bezirk: None,
            },
        }
    }

    const HERE: (f64, f64) = (48.2082, 16.3738);
    /// Some 130 m north of `HERE`.
    const DOWN_THE_LANE: (f64, f64) = (48.2094, 16.3738);

    fn segments(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|p| p.to_string()).collect()
    }

    #[test]
    fn the_register_s_own_spelling_of_a_street_is_the_street_asked_for() {
        // Tolerant on input, canonical on output: hyphens the driver did not
        // type, and umlauts their keyboard did not have.
        let features = vec![ogd("Dr.-Karl-Lueger-Platz 1", "Dr.-Karl-Lueger-Platz", "1", Some("1010"), 0.0, HERE)];
        assert!(pick_ogd_feature(&features, "1010", &street_key("Dr. Karl Lueger-Platz"), None, &[], &[]).is_some());
        let features = vec![ogd("Döblinger Hauptstraße 1", "Döblinger Hauptstraße", "1", Some("1190"), 0.0, HERE)];
        assert!(pick_ogd_feature(&features, "1190", &street_key("Doeblinger Hauptstrasse"), None, &[], &[]).is_some());
        assert_eq!(street_key("Gußhausstraße 25"), street_key("Gusshausstrasse 25"));
        assert_eq!(street_key("Währinger Gürtel"), street_key("Waehringer Guertel"));
    }

    #[test]
    fn one_letter_off_is_a_typo_only_when_the_register_placed_the_house() {
        let key = street_key("Pfenningeldgasse");
        let placed = vec![ogd("Pfenninggeldgasse 9", "Pfenninggeldgasse", "9", Some("1160"), 0.0015, HERE)];
        assert!(pick_ogd_feature(&placed, "1160", &key, None, &[], &[]).is_some());
        // The same street with a number it only guessed at is no answer.
        let guessed = vec![ogd("Pfenninggeldgasse 6-12", "Pfenninggeldgasse", "6-12", Some("1160"), 250.0, HERE)];
        assert!(pick_ogd_feature(&guessed, "1160", &key, None, &[], &[]).is_none());
        // And a short name one letter off is another street.
        let short = vec![ogd("Augasse 1", "Augasse", "1", Some("1090"), 0.0, HERE)];
        assert!(pick_ogd_feature(&short, "1090", &street_key("Aegasse"), None, &[], &[]).is_none());

        assert!(text::is_one_typo_apart("pfenningeldgasse", "pfenninggeldgasse"));
        assert!(text::is_one_typo_apart("gentzgasse", "genzgasse"));
        assert!(text::is_one_typo_apart("gentzgasse", "gentzgosse"));
        assert!(!text::is_one_typo_apart("gentzgasse", "gentzgasse"));
        assert!(!text::is_one_typo_apart("gentzgasse", "genzgosse"));
        assert!(!text::is_one_typo_apart("augasse", "aegasse"));
    }

    #[test]
    fn an_answer_without_a_postcode_counts_by_its_bezirk() {
        let mut haus = ogd("Breitenfurter Straße 390 Haus 2", "Breitenfurter Straße", "390 Haus 2", None, 0.0, HERE);
        haus.properties.bezirk = Some("23".into());
        let features = vec![haus];
        let key = street_key("Breitenfurter Straße");
        assert!(pick_ogd_feature(&features, "1230", &key, None, &[], &[]).is_some());
        assert!(pick_ogd_feature(&features, "1130", &key, None, &[], &[]).is_none());
    }

    #[test]
    fn a_matching_stiege_on_another_house_is_not_the_door() {
        // Number 9 has no Stiege 2; the house across the street, 6-12, does,
        // and the register offers it ranked in the thousands.
        let features = vec![
            ogd("Pfenninggeldgasse 6-12/2", "Pfenninggeldgasse", "6-12/2", Some("1160"), 2000.0, DOWN_THE_LANE),
            ogd("Pfenninggeldgasse 9", "Pfenninggeldgasse", "9", Some("1160"), 0.0, HERE),
        ];
        let key = street_key("Pfenninggeldgasse");
        assert!(pick_ogd_feature(&features, "1160", &key, Some("2"), &segments(&["2", "15"]), &["9".to_string()]).is_none());
    }

    #[test]
    fn a_door_written_without_its_label_is_found_when_it_is_the_only_one() {
        let key = street_key("Mühlweg");
        let numbers = vec!["4".to_string()];
        let features = vec![
            ogd("Mühlweg 4 Gruppe 2 Parz. 5", "Mühlweg", "4 Gruppe 2 Parz. 5", Some("1210"), 0.0, HERE),
            ogd("Mühlweg 4 Gruppe 2 Parz. 6", "Mühlweg", "4 Gruppe 2 Parz. 6", Some("1210"), 0.0, DOWN_THE_LANE),
        ];
        let picked = pick_ogd_feature(&features, "1210", &key, Some("2"), &segments(&["2", "5"]), &numbers).expect("the plot");
        assert_eq!(picked.properties.adresse.as_deref(), Some("Mühlweg 4 Gruppe 2 Parz. 5"));

        // An "Obj. 1" and a "Pav. 1" on one number cannot be told apart from "/1".
        let key = street_key("Wolkersbergenstraße");
        let numbers = vec!["1".to_string()];
        let features = vec![
            ogd("Wolkersbergenstraße 1 Obj. 1", "Wolkersbergenstraße", "1 Obj. 1", Some("1130"), 0.0, HERE),
            ogd("Wolkersbergenstraße 1 Pav. 1", "Wolkersbergenstraße", "1 Pav. 1", Some("1130"), 0.0, DOWN_THE_LANE),
        ];
        assert!(pick_ogd_feature(&features, "1130", &key, Some("1"), &segments(&["1"]), &numbers).is_none());

        // The words that say nothing about which door are no part of the key.
        assert_eq!(text::sub_address_key("Haus A/1"), "a1");
        assert_eq!(text::sub_address_key("Stg. 2"), "2");
        assert_eq!(text::sub_address_tokens("Gruppe F Parz. 7"), vec!["f", "7"]);
        assert_eq!(text::sub_address_tokens("Obj. 62A"), vec!["62a"]);
        assert_eq!(text::sub_address_segments("Promenadegasse 57/A1/1"), vec!["A1", "1"]);
        assert!(text::sub_address_segments("Promenadegasse 57").is_empty());
    }

    #[test]
    fn the_number_asked_for_comes_before_a_neighbour_ranked_above_it() {
        let key = street_key("Rabengasse");
        let numbers = vec!["3".to_string()];
        let features = vec![
            ogd("Rabengasse 3A", "Rabengasse", "3A", Some("1030"), 1e-8, DOWN_THE_LANE),
            ogd("Rabengasse 3-9", "Rabengasse", "3-9", Some("1030"), 0.0009, HERE),
        ];
        let picked = pick_ogd_feature(&features, "1030", &key, None, &[], &numbers).expect("the Rabenhof");
        assert_eq!(picked.properties.adresse.as_deref(), Some("Rabengasse 3-9"));
        // With only the neighbour on offer it is still taken, and then shown as "≈".
        let picked = pick_ogd_feature(&features[..1], "1030", &key, None, &[], &numbers).expect("the neighbour");
        assert!(is_uncertain_door(picked, &features[..1], &key, &numbers, false, true));

        // "Doningasse 8": "8B" first, and number 8 itself an Obj. 1 with a
        // Stiege 3 sixty metres away. Nobody said which, so it stays "≈".
        let key = street_key("Doningasse");
        let numbers = vec!["8".to_string()];
        let features = vec![
            ogd("Doningasse 8B", "Doningasse", "8B", Some("1220"), 1e-8, (48.25116, 16.44276)),
            ogd("Doningasse 8 Obj. 1", "Doningasse", "8 Obj. 1", Some("1220"), 0.0001, (48.25066, 16.44225)),
            ogd("Doningasse 8/3", "Doningasse", "8/3", Some("1220"), 0.0003, (48.25121, 16.44257)),
        ];
        let picked = pick_ogd_feature(&features, "1220", &key, None, &[], &numbers).expect("number 8");
        assert_eq!(picked.properties.adresse.as_deref(), Some("Doningasse 8 Obj. 1"));
        assert!(is_uncertain_door(picked, &features, &key, &numbers, false, true));
        // One building of the number, and it is the house.
        assert!(!is_uncertain_door(picked, &features[..2], &key, &numbers, false, true));
        // A door the driver did name is the door, whatever ranks above it.
        assert!(!is_uncertain_door(&features[2], &features, &key, &numbers, false, false));
    }

    #[test]
    fn a_letter_typed_apart_from_the_number_may_belong_to_it() {
        let seg = segments;
        assert_eq!(asked_numbers(Some("26"), &seg(&["A"])), vec!["26", "26a"]);
        assert_eq!(asked_numbers(Some("26"), &seg(&["B", "3"])), vec!["26", "26b"]);
        assert_eq!(asked_numbers(Some("26"), &seg(&["12"])), vec!["26"]);
        assert_eq!(asked_numbers(Some("26"), &seg(&["Haus 2"])), vec!["26"]);
        assert_eq!(asked_numbers(Some("26a"), &seg(&["B"])), vec!["26a"]);
        assert!(asked_numbers(None, &seg(&["A"])).is_empty());
    }

    #[test]
    fn an_answer_that_is_not_provably_the_door_is_only_approximate() {
        let key = street_key("Doningasse");
        // A neighbouring number, ranked as a match.
        let neighbour = ogd("Doningasse 8B", "Doningasse", "8B", Some("1220"), 0.00000001, HERE);
        assert!(is_uncertain_door(&neighbour, &[], &key, &["8".to_string()], false, true));
        let own = ogd("Doningasse 8", "Doningasse", "8", Some("1220"), 0.0, HERE);
        assert!(!is_uncertain_door(&own, &[], &key, &["8".to_string()], false, true));

        // The bare number, where the door asked for is one of several
        // buildings far apart -- and where it is a Stiege of the one house.
        let key = street_key("Wolkersbergenstraße");
        let bare = ogd("Wolkersbergenstraße 1", "Wolkersbergenstraße", "1", Some("1130"), 0.0, HERE);
        let far = vec![ogd("Wolkersbergenstraße 1 Pav. 1", "Wolkersbergenstraße", "1 Pav. 1", Some("1130"), 0.0, DOWN_THE_LANE)];
        assert!(is_uncertain_door(&bare, &far, &key, &["1".to_string()], true, false));
        assert!(!is_uncertain_door(&bare, &far, &key, &["1".to_string()], false, true));
        let near = vec![ogd("Wolkersbergenstraße 1/2", "Wolkersbergenstraße", "1/2", Some("1130"), 0.0, (48.20835, 16.3738))];
        assert!(!is_uncertain_door(&bare, &near, &key, &["1".to_string()], true, false));
    }

    #[test]
    fn only_exact_answers_are_remembered() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        cache_store(&conn, "gentzgasse 129, 1180 wien", 48.23, 16.33, "Gentzgasse 129", Precision::Exact).unwrap();
        cache_store(&conn, "nirgendgasse 1, 1180 wien", 48.23, 16.33, "Nirgendgasse", Precision::Street).unwrap();
        assert!(cache_lookup(&conn, "gentzgasse 129, 1180 wien").unwrap().is_some());
        assert!(cache_lookup(&conn, "nirgendgasse 1, 1180 wien").unwrap().is_none());
        // A row from before the rule is not served either.
        conn.execute(
            "INSERT INTO geocode_cache (query, lat, lon, display_name, precision, cached_at) VALUES ('alt', 48.2, 16.3, 'Alt', 'street', 0)",
            [],
        )
        .unwrap();
        assert!(cache_lookup(&conn, "alt").unwrap().is_none());
    }

    #[test]
    fn a_pin_has_to_be_near_the_postcode_it_is_filed_under() {
        assert!(check_pin(48.2301, 16.3201, "1180").is_ok());
        assert!(check_pin(47.0707, 15.4395, "1180").is_err()); // Graz, filed under Währing
        assert!(check_pin(47.0707, 15.4395, "8010").is_ok());
        assert!(check_pin(0.0, 0.0, "8010").is_err());
    }

    #[test]
    fn ogd_pick_filters_before_ranking() {
        // The regression this guards: the best-*ranked* feature is in the
        // wrong district, but a correct one for the requested district is
        // right there in the same response. Ranking first threw the whole
        // response away and reported "address not found".
        let features = vec![
            ogd_feature("Hauptstraße", "1140", 0.1),
            ogd_feature("Hauptstraße", "1190", 0.4),
        ];
        let picked = pick_ogd_feature(&features, "1190", &street_key("Hauptstraße"), None, &[], &[]).expect("1190 hit");
        assert_eq!(picked.properties.postal_code.as_deref(), Some("1190"));
    }

    #[test]
    fn ogd_pick_takes_best_ranked_among_valid_candidates() {
        let features = vec![
            ogd_feature("Gentzgasse", "1180", 250.0),
            ogd_feature("Gentzgasse", "1180", 0.2),
            ogd_feature("Gentzgasse", "1180", 12.0),
        ];
        let picked = pick_ogd_feature(&features, "1180", "gentzgasse", None, &[], &[]).expect("hit");
        assert_eq!(picked.properties.ranking, Some(0.2));
    }

    #[test]
    fn ogd_pick_rejects_a_different_street_however_well_ranked() {
        // A fuzzy match onto a similarly-spelled but different street is
        // exactly the confident-but-wrong result the street check exists
        // for — a low Ranking must not rescue it.
        let features = vec![ogd_feature("Gentzgasse", "1180", 0.0)];
        assert!(pick_ogd_feature(&features, "1180", &street_key("Gentzstraße"), None, &[], &[]).is_none());
        let features = vec![ogd_feature("Anton-Baumann-Park", "1180", 0.0)];
        assert!(pick_ogd_feature(&features, "1180", &street_key("Anton-Baumann-Gasse"), None, &[], &[]).is_none());
        // Case and surrounding whitespace are not a real difference.
        let features = vec![ogd_feature("  Gentzgasse  ", "1180", 0.0)];
        assert!(pick_ogd_feature(&features, "1180", "gentzgasse", None, &[], &[]).is_some());
    }

    #[test]
    fn ogd_pick_handles_an_empty_response() {
        assert!(pick_ogd_feature(&[], "1180", "gentzgasse", None, &[], &[]).is_none());
    }

    /// Same as `ogd_feature`, but with the register's own `Adresse`
    /// spelling — which is where the matched Stiege is carried.
    fn ogd_feature_adresse(street: &str, plz: &str, ranking: f64, adresse: &str) -> OgdFeature {
        OgdFeature {
            geometry: OgdGeometry { coordinates: [16.3738, 48.2082] },
            properties: OgdProperties {
                street_name: Some(street.to_string()),
                postal_code: Some(plz.to_string()),
                kategorie: Some("Adresse".to_string()),
                adresse: Some(adresse.to_string()),
                ranking: Some(ranking),
                street_number: Some("1".to_string()),
                bezirk: None,
            },
        }
    }

    #[test]
    fn sub_address_query_is_only_built_when_there_is_one() {
        let sub = text::housenumber_with_sub;
        // Stiege, with Tür/Stock past it discarded.
        assert_eq!(
            sub("Gentzgasse 129/1/2/23"),
            Some(("Gentzgasse 129/1".to_string(), "1".to_string()))
        );
        // Kleingarten plot, written the way a driver's list writes it.
        assert_eq!(
            sub("Großfeldstraße 9/Parz.68"),
            Some(("Großfeldstraße 9/Parz.68".to_string(), "parz68".to_string()))
        );
        // Same plot, space-separated — the register's own spelling, and a
        // form that used to fall through to the bare housenumber.
        assert_eq!(
            sub("Großfeldstraße 9 Parz. 68"),
            Some(("Großfeldstraße 9/Parz. 68".to_string(), "parz68".to_string()))
        );
        // Ranges stay whole, same as in `simplify_housenumber`.
        assert_eq!(
            sub("Gutzkowplatz 2-5/3/14"),
            Some(("Gutzkowplatz 2-5/3".to_string(), "3".to_string()))
        );
        // Nothing to ask for.
        assert_eq!(sub("Gentzgasse 129"), None);
        assert_eq!(sub("Gentzgasse 129/"), None);
        assert_eq!(sub("Stephansplatz"), None);
    }

    fn stop_row(lat: f64, lon: f64, km: Option<f64>) -> StopRow {
        StopRow {
            id: 7,
            kind: "customer".into(),
            kunde: Some("Fam. Gruber".into()),
            strasse: Some("Gentzgasse 129".into()),
            plz: Some("1180".into()),
            paket: None,
            notiz: None,
            lat,
            lon,
            order_index: 3,
            delivered: false,
            next_leg_km: km,
            next_leg_min: km,
            location_precision: None,
            excluded: false,
            pinned: false,
            outcome: None,
            settled_at: None,
            telefon: None,
            paket_count: None,
            entrance_lat: None,
            entrance_lon: None,
        }
    }

    /// A route with Start, Lager, Ziel and `n` customers, in memory.
    fn outcome_db(n: i64) -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        conn.execute("INSERT INTO routes (id, name, created_at) VALUES (1, 'T', 'x')", []).unwrap();
        for (id, kind) in [(1, "start"), (2, "via"), (3, "end")] {
            conn.execute(
                "INSERT INTO stops (id, route_id, kind, lat, lon, order_index, created_at) VALUES (?1, 1, ?2, 48.2, 16.3, ?1, 'x')",
                params![id, kind],
            )
            .unwrap();
        }
        for i in 0..n {
            conn.execute(
                "INSERT INTO stops (id, route_id, kind, lat, lon, order_index, created_at) VALUES (?1, 1, 'customer', 48.2, 16.3, ?1, 'x')",
                params![10 + i],
            )
            .unwrap();
        }
        conn
    }

    fn outcome_of(conn: &Connection, id: i64) -> Option<String> {
        conn.query_row("SELECT outcome FROM stops WHERE id = ?1", params![id], |r| r.get(0)).unwrap()
    }

    #[test]
    fn first_door_ticks_the_lager_and_taking_it_back_reopens_it() {
        let conn = outcome_db(2);
        assert!(!record_outcome(&conn, 1, 10, "customer", Some(outcome::DELIVERED)).unwrap());
        assert_eq!(outcome_of(&conn, 2).as_deref(), Some("delivered"));
        record_outcome(&conn, 1, 10, "customer", None).unwrap();
        assert_eq!(outcome_of(&conn, 2), None);
    }

    #[test]
    fn lager_stays_ticked_while_another_door_says_the_van_has_loaded() {
        let conn = outcome_db(2);
        record_outcome(&conn, 1, 10, "customer", Some(outcome::DELIVERED)).unwrap();
        record_outcome(&conn, 1, 11, "customer", Some(outcome::NOT_HOME)).unwrap();
        record_outcome(&conn, 1, 10, "customer", None).unwrap();
        assert_eq!(outcome_of(&conn, 2).as_deref(), Some("delivered"));
    }

    #[test]
    fn a_lager_ticked_by_hand_is_left_alone() {
        let conn = outcome_db(1);
        record_outcome(&conn, 1, 2, "via", Some(outcome::DELIVERED)).unwrap();
        conn.execute("UPDATE stops SET settled_at = 'earlier' WHERE id = 2", []).unwrap();
        record_outcome(&conn, 1, 10, "customer", Some(outcome::DELIVERED)).unwrap();
        record_outcome(&conn, 1, 10, "customer", None).unwrap();
        assert_eq!(outcome_of(&conn, 2).as_deref(), Some("delivered"));
    }

    #[test]
    fn ins_lager_replans_and_does_not_tick_the_lager() {
        let conn = outcome_db(1);
        assert!(record_outcome(&conn, 1, 10, "customer", Some(outcome::TO_LAGER)).unwrap());
        assert_eq!(outcome_of(&conn, 2), None);
        let delivered: i64 = conn.query_row("SELECT delivered FROM stops WHERE id = 10", [], |r| r.get(0)).unwrap();
        assert_eq!(delivered, 0);
        // Taking it back puts the door into the tour again.
        assert!(record_outcome(&conn, 1, 10, "customer", None).unwrap());
    }

    #[test]
    fn a_repeated_tick_keeps_its_first_time() {
        let conn = outcome_db(1);
        record_outcome(&conn, 1, 10, "customer", Some(outcome::DELIVERED)).unwrap();
        conn.execute("UPDATE stops SET settled_at = 'first' WHERE id = 10", []).unwrap();
        record_outcome(&conn, 1, 10, "customer", Some(outcome::DELIVERED)).unwrap();
        let at: String = conn.query_row("SELECT settled_at FROM stops WHERE id = 10", [], |r| r.get(0)).unwrap();
        assert_eq!(at, "first");
    }

    #[test]
    fn driven_doors_end_on_the_one_answered_last_and_leave_ins_lager_out() {
        let conn = outcome_db(4);
        for (id, o, at) in [(10, "delivered", "3"), (11, "notHome", "1"), (12, "toLager", "9"), (13, "delivered", "2")] {
            conn.execute("UPDATE stops SET outcome = ?1, settled_at = ?2 WHERE id = ?3", params![o, at, id]).unwrap();
        }
        let rows = planning_rows(&conn, 1).unwrap();
        let ids: Vec<i64> = driven_order(&rows).iter().map(|c| c.id).collect();
        assert_eq!(ids, vec![11, 13, 10]);
        assert!(rows.iter().find(|r| r.id == 12).unwrap().skips_door());
    }

    fn pace_stop(kind: &str, outcome: Option<&str>, at_min: Option<i64>, leg: f64) -> PaceStop {
        let base = chrono::DateTime::parse_from_rfc3339("2026-10-05T08:00:00Z").unwrap().with_timezone(&chrono::Utc);
        PaceStop {
            kind: kind.into(),
            excluded: false,
            outcome: outcome.map(str::to_string),
            settled_at: at_min.map(|m| base + chrono::Duration::minutes(m)),
            next_leg_min: Some(leg),
        }
    }

    fn named(name: &str, stops: Vec<PaceStop>) -> PaceTour {
        PaceTour { name: name.into(), departed_at: None, stops }
    }

    #[test]
    fn finished_tours_teach_the_morning_before_the_lager() {
        // Left at 08:00 on the test clock; the Lager ticked so many minutes
        // later, the doors from an hour in.
        let tour = |lager_at: i64| -> PaceTour {
            let mut stops = vec![pace_stop("via", Some("delivered"), Some(lager_at), 10.0)];
            stops.extend((0..12).map(|i| pace_stop("customer", Some("delivered"), Some(60 + i * 9), 3.0)));
            let departed_at = stops[0].settled_at.map(|t| t - chrono::Duration::minutes(lager_at));
            PaceTour { name: "A".into(), departed_at, stops }
        };
        assert_eq!(learn_pace(&[tour(30), tour(50), tour(40)]).lead_minutes, Some(40.0));
        // One morning is not a history, and neither is a tour nobody stamped.
        assert_eq!(learn_pace(&[tour(30)]).lead_minutes, None);
        let unstamped = |t: PaceTour| PaceTour { departed_at: None, ..t };
        assert_eq!(learn_pace(&[unstamped(tour(30)), unstamped(tour(50))]).lead_minutes, None);
        // A Lager ticked by the first door measures nothing.
        assert_eq!(learn_pace(&[tour(60), tour(60)]).lead_minutes, None);
    }

    #[test]
    fn a_door_takes_the_gap_between_ticks_less_the_drive() {
        // Lager ticked at 0, ten minutes' drive, doors at 25 and 37 with a
        // five-minute drive between them: the second took 12 - 5 = 7, and
        // the loading was 25 - 10 = 15 before the first door's own time.
        let tour = vec![
            pace_stop("start", None, None, 20.0),
            pace_stop("via", Some("delivered"), Some(0), 10.0),
            pace_stop("customer", Some("delivered"), Some(25), 5.0),
            pace_stop("customer", Some("notHome"), Some(37), 5.0),
            pace_stop("customer", Some("toLager"), Some(1), 0.0),
            pace_stop("end", None, None, 0.0),
        ];
        let (doors, wait) = pace_samples(&tour);
        assert_eq!(doors, vec![7.0]);
        assert_eq!(wait, Some(15.0));
    }

    #[test]
    fn pace_needs_enough_doors_to_be_a_history() {
        let tour = |n: i64| -> Vec<PaceStop> {
            (0..n).map(|i| pace_stop("customer", Some("delivered"), Some(i * 9), 3.0)).collect()
        };
        assert_eq!(learn_pace(&[named("A", tour(5))]), PaceHistory::default());
        let learned = learn_pace(&[named("A", tour(12))]);
        assert_eq!(learned.door_minutes, Some(6.0));
        assert_eq!(learned.lager_minutes, None);
    }

    #[test]
    fn a_tour_driven_before_starts_from_its_own_doors() {
        // Eleven doors each: six minutes on one round, twelve on the other,
        // nine across both. Each round's own figure sits between its doors
        // and that nine, and nearer its doors.
        let tour = |every: i64| -> Vec<PaceStop> {
            (0..12).map(|i| pace_stop("customer", Some("delivered"), Some(i * every), 3.0)).collect()
        };
        let learned = learn_pace(&[named("VM 5  FR", tour(9)), named("TK 1 MO", tour(15))]);
        assert_eq!(learned.door_minutes, Some(9.0));
        let quick = learned.door_by_tour["vm 5 fr"];
        let slow = learned.door_by_tour["tk 1 mo"];
        assert!((quick - (11.0 * 6.0 + 8.0 * 9.0) / 19.0).abs() < 1e-9);
        assert!((slow - (11.0 * 12.0 + 8.0 * 9.0) / 19.0).abs() < 1e-9);
    }

    #[test]
    fn entrance_numbers_are_read_the_way_the_layer_files_them() {
        assert_eq!(entrance_number("82-92").as_deref(), Some("82"));
        assert_eq!(entrance_number("82/1").as_deref(), Some("82"));
        assert_eq!(entrance_number("82 Kindertagesheim").as_deref(), Some("82"));
        assert_eq!(entrance_number("12a/3").as_deref(), Some("12a"));
        assert_eq!(entrance_number("12A").as_deref(), Some("12a"));
        assert_eq!(entrance_number("Stiege 2"), None);
    }

    #[test]
    fn the_entrance_picked_is_the_number_asked_for_and_no_neighbour() {
        let f = |number: &str, plz: &str| EntranceFeature {
            geometry: EntranceGeometry { coordinates: vec![16.34, 48.23] },
            properties: EntranceProperties { number: Some(number.into()), plz: Some(plz.into()) },
        };
        let all = vec![f("1290", "1180"), f("129A", "1180"), f("129", "1190"), f("129", "1180"), f("31-35", "1180")];
        assert_eq!(pick_entrance(&all, "129", "1180"), Some((48.23, 16.34)));
        assert_eq!(pick_entrance(&all[..3], "129", "1180"), None);
        assert_eq!(pick_entrance(&all, "129a", "1180"), Some((48.23, 16.34)));
        // A range filed under its own spelling still answers to its first number.
        assert_eq!(pick_entrance(&all, "31", "1180"), Some((48.23, 16.34)));
    }

    #[test]
    fn a_stop_at_a_district_centre_is_named_until_it_is_pinned_or_left_out() {
        let conn = outcome_db(3);
        conn.execute("UPDATE stops SET kunde = 'Frau A', location_precision = 'district' WHERE id = 10", []).unwrap();
        conn.execute("UPDATE stops SET kunde = 'Herr B', location_precision = 'street' WHERE id = 11", []).unwrap();
        conn.execute("UPDATE stops SET kunde = 'Fam. C', location_precision = 'district', outcome = 'toLager' WHERE id = 12", []).unwrap();
        assert_eq!(unplaced_stops(&conn, 1).unwrap(), vec!["Frau A".to_string()]);
        assert!(unplaced_message(&["Frau A".into()]).contains("„Frau A“"));
        // A pin the driver placed is a place, whatever the lookup once said.
        conn.execute("UPDATE stops SET pinned = 1 WHERE id = 10", []).unwrap();
        assert!(unplaced_stops(&conn, 1).unwrap().is_empty());
    }

    #[test]
    fn a_portal_answer_with_nulls_and_gaps_still_reads() {
        let tours: Vec<PortalTour> = serde_json::from_str(
            r#"[{"id":1,"name":"TGM 3","catalogue_type":"day","weekday":null,"weekdays":["montag"]},
                {"id":2,"name":"Tk1","weekday":"montag","weekdays":null}]"#,
        )
        .unwrap();
        assert!(tours[0].runs_on("montag") && !tours[0].runs_on("dienstag"));
        assert!(tours[1].runs_on("montag"));

        let d: PortalDelivery = serde_json::from_str(
            r#"{"id":7,"state":"confirmed",
                "customer":{"firstname":"Maria","lastname":" Gruber ","comment":null,"phone":"0664 1"},
                "delivery_address":{"street":"Gentzgasse 129","street2":null,"staircase":"1","flat_number":"23","zip":"1180","comment":"2x läuten"},
                "tours":null,
                "delivery_bundles":[{"delivery_lines":[{"name":"Vitalmenü EP TGM5","quantity":2.0},{"name":"Suppe","quantity":1}]},{"delivery_lines":null}]}"#,
        )
        .unwrap();
        let e = d.entry();
        assert_eq!(e["kunde"], "Maria Gruber");
        assert_eq!(e["strasse"], "Gentzgasse 129/1/23");
        assert_eq!(e["plz"], "1180");
        assert_eq!(e["paket"], "2x Vitalmenü EP TGM5, Suppe");
        assert_eq!(e["notiz"], "2x läuten");
        assert_eq!(e["telefon"], "0664 1");
        assert_eq!(e["paket_count"], 2);
    }

    fn nominatim_hit(road: Option<&str>, postcode: Option<&str>, house_number: Option<&str>) -> NominatimHit {
        NominatimHit {
            lat: "48.2082".into(),
            lon: "16.3738".into(),
            display_name: "irgendwo".into(),
            address: Some(NominatimAddress {
                house_number: house_number.map(str::to_string),
                road: road.map(str::to_string),
                postcode: postcode.map(str::to_string),
            }),
        }
    }

    #[test]
    fn nominatim_hits_must_be_the_street_and_district_that_was_asked_for() {
        let wanted = text::address_match_key("Gentzgasse");
        // The answer we want.
        assert!(nominatim_hit_matches(&nominatim_hit(Some("Gentzgasse"), Some("1180"), Some("129")), &wanted, "1180"));
        // Right street, wrong district — Vienna has streets of the same name
        // in several, and the postcode in the query is only a hint to
        // Nominatim. This is the one that put stops a borough away.
        assert!(!nominatim_hit_matches(&nominatim_hit(Some("Gentzgasse"), Some("1140"), Some("129")), &wanted, "1180"));
        // A different street that merely looks similar.
        assert!(!nominatim_hit_matches(&nominatim_hit(Some("Gentzstraße"), Some("1180"), Some("129")), &wanted, "1180"));
        // Spelling differences that are not real differences.
        let wanted_str = text::address_match_key("Hauptstraße");
        assert!(nominatim_hit_matches(&nominatim_hit(Some("Hauptstrasse"), Some("1140"), None), &wanted_str, "1140"));
        assert!(nominatim_hit_matches(&nominatim_hit(Some("  Hauptstraße  "), Some("1140"), None), &wanted_str, "1140"));
        // Nothing to check against: a hit with no structured address at all,
        // or no road, is only ever accepted as a district-level guess
        // elsewhere — it must not be rejected here.
        assert!(nominatim_hit_matches(&nominatim_hit(None, Some("1180"), None), &wanted, "1180"));
        assert!(nominatim_hit_matches(&NominatimHit { lat: "48.2".into(), lon: "16.3".into(), display_name: "x".into(), address: None }, &wanted, "1180"));
        // A hit with no postcode is judged on its street alone.
        assert!(nominatim_hit_matches(&nominatim_hit(Some("Gentzgasse"), None, Some("129")), &wanted, "1180"));
        assert!(!nominatim_hit_matches(&nominatim_hit(Some("Anderegasse"), None, Some("129")), &wanted, "1180"));
    }

    #[test]
    fn a_stop_with_unusable_numbers_stays_serializable() {
        // The failure this prevents: `serde_json` cannot write NaN or
        // Infinity, so one bad column would fail the *whole* response and
        // leave the driver unable to open that route at all, permanently.
        for (lat, lon) in [(f64::NAN, 16.33), (48.23, f64::INFINITY), (f64::NEG_INFINITY, f64::NAN)] {
            let out = to_stop_out(stop_row(lat, lon, Some(f64::NAN)));
            assert!(out.lat.is_finite() && out.lon.is_finite(), "coordinates repaired");
            // Reported as an approximation, so the row wears the "≈" badge
            // and offers the manual pin-drop instead of quietly lying.
            assert_eq!(out.location_precision.as_deref(), Some("district"));
            assert_eq!(out.next_leg_km, None);
            assert!(serde_json::to_string(&out).is_ok(), "response must serialize");
            // The part the driver actually needs is untouched.
            assert_eq!(out.kunde.as_deref(), Some("Fam. Gruber"));
            assert_eq!(out.strasse.as_deref(), Some("Gentzgasse 129"));
        }
        // A healthy row passes through unchanged, precision included.
        let ok = to_stop_out(stop_row(48.230569, 16.330485, Some(1.5)));
        assert_eq!(ok.lat, 48.230569);
        assert_eq!(ok.next_leg_km, Some(1.5));
        assert_eq!(ok.location_precision, None);
    }

    #[test]
    fn addresses_match_across_punctuation_spellings() {
        let k = text::address_match_key;
        // The same door, exported by three different systems.
        assert_eq!(k("Großfeldstraße 9/Parz.68"), k("Großfeldstraße 9 Parz. 68"));
        assert_eq!(k("Großfeldstraße 9/Parz.68"), k("Großfeldstraße 9 / Parz. 68"));
        assert_eq!(k("Gentzgasse 129/1"), k("Gentzgasse 129 / 1"));
        // The "straße" spellings `normalize_strasse_text` already handled.
        assert_eq!(k("Hauptstr. 5"), k("Hauptstrasse 5"));
        // Separators collapse to a space rather than vanishing — deleting
        // them would make these two the same address.
        assert_ne!(k("Gentzgasse 129/1"), k("Gentzgasse 12/91"));
        assert_ne!(k("Gentzgasse 9"), k("Gentzgasse 9a"));
        // No leading/trailing filler, whatever the input looked like.
        assert_eq!(k("  Gentzgasse 129.  "), "gentzgasse 129");
        assert_eq!(k(""), "");
        assert_eq!(k("///"), "");
    }

    #[test]
    fn sub_addresses_compare_across_spellings() {
        // The whole point: driver's "9/Parz.68" and the register's
        // "Großfeldstraße 9 Parz. 68" are the same plot.
        assert_eq!(text::sub_address_of("Großfeldstraße 9 Parz. 68").as_deref(), Some("parz68"));
        assert_eq!(text::sub_address_key("Parz.68"), "parz68");
        assert_eq!(text::sub_address_key("Parz. 68"), "parz68");
        // Stiege.
        assert_eq!(text::sub_address_of("Gentzgasse 129/1").as_deref(), Some("1"));
        // A bare housenumber has no sub-address — not an empty one.
        assert_eq!(text::sub_address_of("Gentzgasse 129"), None);
        assert_eq!(text::sub_address_of("Gentzgasse 129/"), None);
        // Different plots must not compare equal.
        assert_ne!(
            text::sub_address_of("Großfeldstraße 9 Parz. 8"),
            text::sub_address_of("Großfeldstraße 9 Parz. 68")
        );
    }

    #[test]
    fn ogd_pick_requires_the_sub_address_it_was_asked_for() {
        // The register's answer to a plot it doesn't have: a neighbouring
        // one at a near-zero Ranking. Accepting it would put the pin at the
        // wrong garden gate and still call it exact.
        let features = vec![
            ogd_feature_adresse("Großfeldstraße", "1210", 0.0008, "Großfeldstraße 9 Parz. 8"),
            ogd_feature_adresse("Großfeldstraße", "1210", 0.0009, "Großfeldstraße 9 Parz. 8A"),
        ];
        assert!(pick_ogd_feature(&features, "1210", &street_key("Großfeldstraße"), Some("parz68"), &[], &[]).is_none());

        // The regression that put a pin 130 m off: the register spells the
        // plot with a space and an abbreviation dot, and matching on raw
        // text rejected the *correct* hit.
        let features = vec![ogd_feature_adresse("Großfeldstraße", "1210", 0.0068, "Großfeldstraße 9 Parz. 68")];
        let picked = pick_ogd_feature(&features, "1210", &street_key("Großfeldstraße"), Some("parz68"), &[], &[]).expect("parz 68");
        assert_eq!(picked.properties.adresse.as_deref(), Some("Großfeldstraße 9 Parz. 68"));

        // Stiege, with a better-ranked sibling in the same response.
        let features = vec![
            ogd_feature_adresse("Gentzgasse", "1180", 0.0001, "Gentzgasse 129/2"),
            ogd_feature_adresse("Gentzgasse", "1180", 0.0022, "Gentzgasse 129/1"),
        ];
        let picked = pick_ogd_feature(&features, "1180", "gentzgasse", Some("1"), &[], &[]).expect("stiege 1");
        assert_eq!(picked.properties.adresse.as_deref(), Some("Gentzgasse 129/1"));

        // Without a requirement the plain building point is still pickable —
        // that's the fallback the check above falls through to.
        let features = vec![ogd_feature_adresse("Gentzgasse", "1180", 0.0003, "Gentzgasse 129")];
        assert!(pick_ogd_feature(&features, "1180", "gentzgasse", None, &[], &[]).is_some());
    }

    #[test]
    fn a_neighbouring_sub_address_is_reported_as_approximate() {
        // Asked for plot 68, register offers plot 8: same street, same
        // housenumber, someone else's gate. Must not read as "exact".
        assert!(SubCheck::Downgrade("parz68").is_wrong_neighbour(Some("Großfeldstraße 9 Parz. 8")));
        // Asked for plot 68 and got it.
        assert!(!SubCheck::Downgrade("parz68").is_wrong_neighbour(Some("Großfeldstraße 9 Parz. 68")));
        // The building's own point, no sub-address at all: the honest answer
        // for a Stiege the register doesn't list, and still exact for the
        // building it does list.
        assert!(!SubCheck::Downgrade("1").is_wrong_neighbour(Some("Gentzgasse 129")));
        // An address with no sub-address never downgrades anything.
        assert!(!SubCheck::Absent.is_wrong_neighbour(Some("Gentzgasse 129/2")));
        assert!(!SubCheck::Require("1").is_wrong_neighbour(Some("Gentzgasse 129/2")));
    }

    #[test]
    fn client_ip_ignores_forwarded_header_unless_proxy_is_trusted() {
        let peer: SocketAddr = "203.0.113.9:51000".parse().unwrap();
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", HeaderValue::from_static("198.51.100.7, 10.0.0.1"));

        // Untrusted: the header is attacker-controlled and must not be able
        // to hand a flooder a fresh rate-limit bucket per request.
        assert_eq!(client_ip(&headers, peer, false), peer.ip());
        // Trusted: the first entry is the real client behind the proxy.
        assert_eq!(client_ip(&headers, peer, true).to_string(), "198.51.100.7");
    }

    #[test]
    fn client_ip_tolerates_proxies_that_append_a_port_or_garbage() {
        let peer: SocketAddr = "203.0.113.9:51000".parse().unwrap();
        let mut headers = HeaderMap::new();

        headers.insert("x-forwarded-for", HeaderValue::from_static("198.51.100.7:1234"));
        assert_eq!(client_ip(&headers, peer, true).to_string(), "198.51.100.7");

        headers.insert("x-forwarded-for", HeaderValue::from_static("[2001:db8::1]:443"));
        assert_eq!(client_ip(&headers, peer, true).to_string(), "2001:db8::1");

        // Unparseable: fall back to the one address that can't be forged.
        headers.insert("x-forwarded-for", HeaderValue::from_static("not-an-ip"));
        assert_eq!(client_ip(&headers, peer, true), peer.ip());
    }

    #[test]
    fn a_recheck_writes_back_a_stale_badge_even_when_nothing_moved() {
        let here = (48.230569, 16.330485);
        // The regression this guards: the register now knows the exact
        // housenumber and answers at the same point the coarse fallback had.
        // Nothing moved, so the old code wrote nothing -- and the row wore a
        // "~ Strasse" warning for an address the app knew precisely, and kept
        // handing navigation the address text instead of the point.
        let c = recheck_change((here.0, here.1, Some("street")), (here.0, here.1, None));
        assert_eq!(c, RecheckChange { moved: false, write: true });

        // The other direction: an address that used to resolve exactly and
        // now only resolves to the street has to stop claiming to be exact.
        let c = recheck_change((here.0, here.1, None), (here.0, here.1, Some("street")));
        assert_eq!(c, RecheckChange { moved: false, write: true });

        // Nothing changed at all -- no write, and above all no optimization.
        let c = recheck_change((here.0, here.1, Some("district")), (here.0, here.1, Some("district")));
        assert_eq!(c, RecheckChange { moved: false, write: false });

        // Float noise from re-resolving the same register entry is not a
        // moved pin, and must not be reported to the driver as one.
        let c = recheck_change((here.0, here.1, None), (here.0 + 1e-9, here.1 - 1e-9, None));
        assert_eq!(c, RecheckChange { moved: false, write: false });

        // A genuine correction: moved, written back, and the only case that
        // may re-solve the route.
        let c = recheck_change((here.0, here.1, Some("district")), (48.21, 16.37, None));
        assert_eq!(c, RecheckChange { moved: true, write: true });
    }

    /// The body of an `AppError`, as the frontend's `api()` helper sees it.
    async fn error_body(err: AppError) -> (StatusCode, Value) {
        let res = err.into_response();
        let status = res.status();
        let bytes = axum::body::to_bytes(res.into_body(), 64 * 1024).await.expect("body");
        (status, serde_json::from_slice(&bytes).expect("json body"))
    }

    #[tokio::test]
    async fn a_wrong_district_error_names_the_district_as_data_not_only_as_prose() {
        // The frontend pre-selects this district in the form so the fix is one
        // tap (see `sendStop` in index.html). It used to recover the postcode
        // by running a regex over the German sentence, which quietly made the
        // wording of a user-facing message load-bearing.
        let (status, body) = error_body(geocode_error_wrong_district("Hauptstrasse 5", "1140")).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body["detail"]["code"], "wrong_district");
        assert_eq!(body["detail"]["plz"], "1140");
        assert!(body["detail"]["message"].as_str().unwrap().contains("14. Bezirk"));

        // The codes that have no district carry no field at all, so the app
        // can treat "absent" and "not this error" the same way.
        let (status, body) = error_body(geocode_error_not_found("Nirgendgasse 1, 1010 Wien")).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body["detail"]["code"], "address_not_found");
        assert!(body["detail"].get("plz").is_none());

        let (status, body) = error_body(geocode_error_unavailable()).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["detail"]["code"], "geocode_unavailable");
        assert!(body["detail"].get("plz").is_none());

        // A postcode this app would never produce must not become a panic or
        // a nonsense "0. Bezirk" -- it falls back to naming the code itself.
        let (_, body) = error_body(geocode_error_wrong_district("Irgendwo 1", "AT")).await;
        assert!(body["detail"]["message"].as_str().unwrap().contains("AT"));
    }

    #[test]
    fn an_added_list_takes_a_stop_only_by_its_own_name() {
        let door = || vec![(1, "fam. gruber".to_string()), (2, "fam. novak".to_string())];

        // The same name at the same address is that stop, wherever it sits.
        let mut bucket = door();
        assert_eq!(claim_at_address(&mut bucket, "fam. novak", true), Some(2));
        assert_eq!(bucket, vec![(1, "fam. gruber".to_string())]);

        // A third household at the door is a stop of its own when the list
        // is added to the tour...
        let mut bucket = door();
        assert_eq!(claim_at_address(&mut bucket, "fr. berger", true), None);
        assert_eq!(bucket.len(), 2);

        // ...and a rename of the first unclaimed one when it replaces it.
        let mut bucket = door();
        assert_eq!(claim_at_address(&mut bucket, "fr. berger", false), Some(1));

        assert_eq!(claim_at_address(&mut Vec::new(), "fr. berger", false), None);
    }

    #[test]
    fn rejects_oversized_and_control_char_fields() {
        assert!(check_len("ok", "Kunde", 10).is_ok());
        assert!(check_len(&"ä".repeat(11), "Kunde", 10).is_err()); // counted in chars, not bytes
        assert!(check_no_control_chars("Fam. Gruber", "Kunde", false).is_ok());
        assert!(check_no_control_chars("Fam.\u{0}Gruber", "Kunde", false).is_err());
        assert!(check_no_control_chars("Zeile 1\nZeile 2", "Notiz", false).is_err());
        assert!(check_no_control_chars("Zeile 1\nZeile 2", "Notiz", true).is_ok());
    }
}
