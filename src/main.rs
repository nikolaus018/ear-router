//! EAR Routing (Essen auf Rädern Routing) — delivery route planner.
//!
//! Serves a single self-contained `index.html` at `/` (Tailwind CDN +
//! MapLibre GL JS/OpenFreeMap UI, ASBÖ-branded, PWA-ready — no separate JS/
//! CSS build) and a matching `/sw.js` service worker for offline app-shell
//! caching, both embedded into the binary at compile time via
//! `include_str!` — see `INDEX_HTML`/`SW_JS` below. The JSON API is
//! otherwise the main interface. Axum backend, SQLite storage. Geocoding
//! and routing both run against real, actively-maintained open services
//! instead of a hand-rolled local dataset/algorithm that can only ever be a
//! stale, incomplete snapshot:
//!   - Geocoding calls Nominatim (nominatim.openstreetmap.org), the
//!     official OpenStreetMap geocoder — the live, global address
//!     database, not a one-time Vienna export. An address it genuinely
//!     can't find falls through to manual pin-drop handling (`lat`/`lon`
//!     supplied directly in the request) rather than an API call.
//!   - Route distances/durations and stop-order optimization both come
//!     from OSRM (router.project-osrm.org) — the standard open-source
//!     routing engine (contraction hierarchies), used in production by a
//!     lot of real routing software. Its `/trip` endpoint solves the
//!     actual multi-stop ordering problem; there's no reason to hand-roll
//!     a weaker 2-opt/or-opt solver when a well-tested one is a request
//!     away. See `osrm_route_leg`/`osrm_trip` below.
//! Both Nominatim and OSRM's public servers are free to use but shared —
//! Nominatim's usage policy caps at ~1 request/second, enforced here via
//! `nominatim_throttle` (see `AppState::nominatim_last`) rather than
//! trusting callers not to hammer it.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{
    extract::{ConnectInfo, DefaultBodyLimit, Path as AxPath, Request, State},
    http::{header, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, patch, post, put},
    Json, Router,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use text::{normalize_strasse_text, simplify_housenumber};
use tokio::sync::Mutex as AsyncMutex;
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
    static STR_ABBR_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)str\.(\s|$|\d)").unwrap());
    static STRASSE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)strasse\b").unwrap());
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

    pub fn normalize_strasse_text(strasse: &str) -> String {
        let s = WHITESPACE_RE.replace_all(strasse.trim(), " ").to_string();
        let s = STR_ABBR_RE.replace_all(&s, "straße$1").to_string();
        STRASSE_RE.replace_all(&s, "straße").to_string()
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

fn check_plz(plz: &str) -> Result<(), AppError> {
    if !is_valid_vienna_plz(plz) {
        return Err(AppError::BadRequest(format!("Ungültiger Bezirk (PLZ): {plz}")));
    }
    Ok(())
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
const MAX_PAKET_LEN: usize = 200;
const MAX_NOTIZ_LEN: usize = 1000;
const MAX_ROUTE_NAME_LEN: usize = 200;
/// Upper bound on stops accepted in one bulk "Route als JSON" paste.
/// Uncached entries each cost a throttled ~1.1s Nominatim round-trip
/// (see `NOMINATIM_MIN_INTERVAL`), so an unbounded list turns one HTTP
/// request into an effectively unbounded amount of work tying up a
/// handler and hammering a shared public service.
const MAX_BULK_STOPS: usize = 300;

/// A generous bounding box around Vienna and its immediate surroundings
/// (well outside the city limits in every direction) — just enough to
/// reject obviously-wrong input (NaN/Infinity smuggled in as an
/// out-of-range JSON number literal, `0,0`, a swapped lat/lon, a
/// fat-fingered extra digit) before it's ever stored or handed to OSRM.
const LAT_MIN: f64 = 47.7;
const LAT_MAX: f64 = 48.6;
const LON_MIN: f64 = 15.8;
const LON_MAX: f64 = 16.8;

fn check_latlon(lat: f64, lon: f64) -> Result<(), AppError> {
    if !lat.is_finite() || !lon.is_finite() || !(LAT_MIN..=LAT_MAX).contains(&lat) || !(LON_MIN..=LON_MAX).contains(&lon) {
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
    Geocode { status: u16, code: String, message: String },
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, body) = match self {
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, json!({ "detail": msg })),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, json!({ "detail": msg })),
            AppError::Forbidden(msg) => (StatusCode::FORBIDDEN, json!({ "detail": msg })),
            AppError::Geocode { status, code, message } => (
                StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
                json!({ "detail": { "message": message, "code": code } }),
            ),
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
    http: reqwest::Client,
    // Timestamp of the last outbound Nominatim request, gating
    // `nominatim_throttle` so concurrent geocode calls still serialize to
    // Nominatim's ~1 req/s public usage policy instead of bursting past it.
    nominatim_last: AsyncMutex<Option<Instant>>,
    // Per-client-IP request counters backing `rate_limit_mw` — see there
    // for why this exists at all (there's no authentication in this app).
    rate_limit: AsyncMutex<HashMap<IpAddr, (Instant, u32)>>,
}

// ---------------------------------------------------------------------
// Rate limiting — this app has no authentication whatsoever (see the
// module doc comment: it's a small self-hosted single-tenant tool), so
// every `/api/*` route is reachable by anyone who can reach the port.
// Without a cap, a script (or just a buggy retry loop) hitting `/api`
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

async fn rate_limit_mw(
    State(state): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let ip = addr.ip();
    let now = Instant::now();
    let over_limit = {
        let mut map = state.rate_limit.lock().await;
        // Opportunistic cleanup so this map can't grow without bound if
        // many distinct IPs ever hit the server.
        map.retain(|_, (start, _)| now.duration_since(*start) < RATE_LIMIT_WINDOW * 4);
        let entry = map.entry(ip).or_insert((now, 0));
        if now.duration_since(entry.0) >= RATE_LIMIT_WINDOW {
            *entry = (now, 0);
        }
        entry.1 += 1;
        entry.1 > RATE_LIMIT_MAX_REQUESTS
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
    res
}


fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339()
}

// ---------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------

fn open_db(path: &FsPath) -> Result<Connection, AppError> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 10000;",
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
    needs_optimize INTEGER NOT NULL DEFAULT 0
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
    -- NULL = exact match (or a human placed the pin). 'street'/'district'
    -- mean geocoding only found an approximate fallback location — see
    -- the `addresses` module above. Surfaced in the UI so a driver knows to
    -- double check before setting off, instead of an approximation silently
    -- pretending to be precise.
    location_precision TEXT
);

CREATE TABLE IF NOT EXISTS geocode_cache (
    query TEXT PRIMARY KEY,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    display_name TEXT,
    precision TEXT NOT NULL DEFAULT 'exact'
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
    let cache_cols: HashSet<String> = conn
        .prepare("PRAGMA table_info(geocode_cache)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<Result<_, _>>()?;
    if !cache_cols.contains("precision") {
        conn.execute("ALTER TABLE geocode_cache ADD COLUMN precision TEXT NOT NULL DEFAULT 'exact'", [])?;
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Geocoding — Nominatim (nominatim.openstreetmap.org), OpenStreetMap's own
// geocoder. Real, live, global address data instead of a static export
// that's stale the day it's built and was never going to cover every
// address anyway.
// ---------------------------------------------------------------------

fn geocode_error_not_found(query: &str) -> AppError {
    AppError::Geocode {
        status: 422,
        code: "address_not_found".into(),
        message: format!("Adresse nicht automatisch gefunden: {}.", query),
    }
}

fn cache_lookup(conn: &Connection, key: &str) -> Result<Option<(f64, f64, String, Precision)>, AppError> {
    Ok(conn
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
        .optional()?)
}

fn cache_store(conn: &Connection, key: &str, lat: f64, lon: f64, display_name: &str, precision: Precision) -> Result<(), AppError> {
    conn.execute(
        "INSERT OR REPLACE INTO geocode_cache (query, lat, lon, display_name, precision) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![key, lat, lon, display_name, precision.as_str()],
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
const WIEN_OGD_URL: &str = "https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo";

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
}

/// One Vienna OGD address lookup. Returns `None` — never an error — for
/// anything short of a confident, verified hit: an unreachable/erroring
/// service, an empty body (the service's actual response to zero matches;
/// see below), a body that doesn't parse, or a top hit that doesn't
/// survive the postcode/street-name cross-check. That "always fall
/// through cleanly" contract is what lets `geocode_address` treat this as
/// a first attempt rather than a hard dependency — a Wien-OGD outage the
/// night before a route is due degrades to the existing Nominatim
/// pipeline, not a failure.
async fn wien_ogd_search_one(state: &AppState, query: &str, plz: &str) -> Option<(f64, f64, String, Precision)> {
    let resp = state
        .http
        .get(WIEN_OGD_URL)
        .query(&[("Address", query), ("crs", "EPSG:4326")])
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    // A query with zero matches comes back as an HTTP 200 with a
    // completely empty body (not `{"features":[]}`) — has to be checked
    // before handing an empty string to the JSON parser.
    let body = resp.text().await.ok()?;
    if body.trim().is_empty() {
        return None;
    }
    let parsed: OgdFeatureCollection = serde_json::from_str(&body).ok()?;

    // Lower `Ranking` is a better match, but its scale isn't uniform
    // across match types (an exact hit is ~0, "same street/wrong
    // housenumber" jumps to the hundreds, and a fuzzy match onto a
    // *different* street entirely can still come back deceptively low) —
    // so `Ranking` alone never decides a match, it only picks the best
    // candidate among features that already passed the checks below.
    let best = parsed.features.into_iter().min_by(|a, b| {
        let ra = a.properties.ranking.unwrap_or(f64::MAX);
        let rb = b.properties.ranking.unwrap_or(f64::MAX);
        ra.partial_cmp(&rb).unwrap_or(std::cmp::Ordering::Equal)
    })?;
    let props = best.properties;

    // Postcode must match exactly, and the returned street name must be
    // the street we actually asked for (case/whitespace aside) — without
    // this, a street name with no real match at all (typo, or genuinely
    // unmapped) can still come back with a low-looking `Ranking` for the
    // closest *different* street by string similarity, which would
    // otherwise get accepted as a confident but wrong location.
    if props.postal_code.as_deref() != Some(plz) {
        return None;
    }
    let their_street = props.street_name.as_deref().unwrap_or("").trim().to_lowercase();
    let our_street = text::street_name_only(query).to_lowercase();
    if their_street != our_street {
        return None;
    }

    let ranking = props.ranking.unwrap_or(f64::MAX);
    let precision = if props.kategorie.as_deref() == Some("Straßenname") {
        Precision::Street
    } else if ranking < 1.0 {
        // Genuine housenumber (and usually Stiege/Tür) match.
        Precision::Exact
    } else {
        // Real street, but the exact housenumber wasn't registered —
        // matched to the nearest one instead.
        Precision::Street
    };
    let [lon, lat] = best.geometry.coordinates;
    let display_name = props.adresse.map(|a| format!("{a}, {plz} Wien")).unwrap_or_else(|| format!("{query}, {plz} Wien"));
    Some((lat, lon, display_name, precision))
}

/// Tries the simplified "{street} {housenumber}" form first (see
/// `simplify_housenumber`), falling back to the fuller normalized string
/// only if that finds nothing — same two-tier shape as the Nominatim path
/// below, for the same reason: the simplification is usually right and
/// saves a round-trip, but shouldn't be the only thing tried.
async fn wien_ogd_geocode(state: &AppState, strasse: &str, plz: &str) -> Option<(f64, f64, String, Precision)> {
    let normalized = normalize_strasse_text(strasse);
    let simplified = simplify_housenumber(&normalized);
    if let Some(hit) = wien_ogd_search_one(state, &simplified, plz).await {
        return Some(hit);
    }
    if simplified != normalized {
        if let Some(hit) = wien_ogd_search_one(state, &normalized, plz).await {
            return Some(hit);
        }
    }
    None
}

const NOMINATIM_URL: &str = "https://nominatim.openstreetmap.org/search";
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
        AppError::Internal("Geocoding-Dienst nicht erreichbar.".into())
    };
    let resp = state
        .http
        .get(NOMINATIM_URL)
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
        .header(reqwest::header::USER_AGENT, "EAR-Routing/1.0 (local delivery route planner)")
        .send()
        .await
        .map_err(geocode_unreachable)?
        .error_for_status()
        .map_err(geocode_unreachable)?;
    let hits: Vec<NominatimHit> = resp.json().await.map_err(|e| {
        tracing::error!(error = %e, "nominatim response parse failed");
        AppError::Internal("Geocoding-Dienst: ungültige Antwort.".into())
    })?;
    Ok(hits.into_iter().next())
}

async fn nominatim_search_one(state: &AppState, query: &str) -> Result<Option<(f64, f64, String, Precision)>, AppError> {
    let Some(top) = nominatim_raw_search(state, query).await? else {
        return Ok(None);
    };
    let (Ok(lat), Ok(lon)) = (top.lat.parse::<f64>(), top.lon.parse::<f64>()) else {
        return Err(AppError::Internal("Geocoding-Dienst: ungültige Koordinaten in der Antwort".into()));
    };
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
async fn geocode_address(state: &AppState, strasse: &str, plz: &str) -> Result<(f64, f64, String, Precision), AppError> {
    let original_query = format!("{}, {} Wien, Österreich", strasse.trim(), plz);
    let key = original_query.trim().to_lowercase();
    {
        let conn = open_db(&state.db_path)?;
        if let Some(hit) = cache_lookup(&conn, &key)? {
            return Ok(hit);
        }
    }

    if let Some(hit) = wien_ogd_geocode(state, strasse, plz).await {
        let conn = open_db(&state.db_path)?;
        cache_store(&conn, &key, hit.0, hit.1, &hit.2, hit.3)?;
        return Ok(hit);
    }

    let normalized = normalize_strasse_text(strasse);
    // Try the "{street} {housenumber}" form first — Viennese addresses are
    // routinely written with a Stiege/Tür/Stock suffix ("Gentzgasse
    // 129/1/2/23") that Nominatim doesn't index and will otherwise just
    // fail to match on. Only fall back to the fuller normalized string
    // (an extra throttled call) if that simplification finds nothing —
    // e.g. for a place name that was never "street + number" to begin
    // with, where simplifying would have mangled it for no reason.
    let simplified = simplify_housenumber(&normalized);
    let query = format!("{}, {} Wien, Österreich", simplified, plz);
    let mut result = nominatim_search_one(state, &query).await?;
    if result.is_none() && simplified != normalized {
        let fallback_query = format!("{}, {} Wien, Österreich", normalized, plz);
        result = nominatim_search_one(state, &fallback_query).await?;
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
        let district_query = format!("{plz} Wien, Österreich");
        if let Some(hit) = nominatim_raw_search(state, &district_query).await? {
            let postcode_matches = hit.address.as_ref().and_then(|a| a.postcode.as_deref()) == Some(plz);
            if let (true, Ok(lat), Ok(lon)) = (postcode_matches, hit.lat.parse::<f64>(), hit.lon.parse::<f64>()) {
                result = Some((lat, lon, format!("{plz} Wien (nur Bezirk, Adresse unbekannt)"), Precision::District));
            }
        }
    }

    let Some((lat, lon, display_name, precision)) = result else {
        return Err(geocode_error_not_found(&original_query));
    };

    let conn = open_db(&state.db_path)?;
    cache_store(&conn, &key, lat, lon, &display_name, precision)?;
    Ok((lat, lon, display_name, precision))
}

// ---------------------------------------------------------------------
// Routing — OSRM (router.project-osrm.org), the standard open-source
// routing engine (contraction hierarchies), instead of a hand-rolled
// Dijkstra graph + a hand-rolled 2-opt/or-opt solver. Two calls do
// everything the old local code did across three modules:
//   - `osrm_route_leg` for the one fixed leg (depot -> warehouse) that
//     never needs reordering, just its real distance/duration/geometry.
//   - `osrm_trip` for warehouse -> [customers, order TBD] -> destination:
//     OSRM's own multi-stop trip-optimization endpoint, which solves
//     exactly the ordering problem the old `solve_route_order` was
//     reimplementing (worse, and only for whatever fit in a Vienna-only
//     offline graph).
// ---------------------------------------------------------------------

const OSRM_BASE: &str = "https://router.project-osrm.org";

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
    distance: f64,
    duration: f64,
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

/// Real distance/duration/geometry for a single fixed leg (no ordering
/// choice involved) — used for the depot -> warehouse leg, which is
/// always first and never reordered.
async fn osrm_route_leg(client: &reqwest::Client, a: (f64, f64), b: (f64, f64)) -> Result<(f64, f64, Vec<[f64; 2]>), AppError> {
    let url = format!(
        "{OSRM_BASE}/route/v1/driving/{}?overview=full&geometries=geojson",
        osrm_coord_string(&[a, b])
    );
    let resp: OsrmRouteResp = client
        .get(&url)
        .send()
        .await
        .map_err(osrm_unreachable)?
        .error_for_status()
        .map_err(osrm_unreachable)?
        .json()
        .await
        .map_err(osrm_unreachable)?;
    if resp.code != "Ok" {
        return Err(AppError::Internal(format!("OSRM route: {}", resp.code)));
    }
    let route = resp.routes.into_iter().next().ok_or_else(|| AppError::Internal("OSRM: keine Route gefunden".into()))?;
    Ok((route.distance, route.duration, geojson_to_polyline(route.geometry)))
}

/// Solves the actual multi-stop ordering problem via OSRM's `/trip`
/// endpoint: `coords[0]` is pinned as the trip's start (`source=first`)
/// and `coords.last()` as its end (`destination=last`), with every point
/// in between free to be reordered however minimizes total travel time.
/// Returns (visiting order as indices into `coords`, per-consecutive-leg
/// (distance_m, duration_s) in that visiting order, full route geometry).
async fn osrm_trip(client: &reqwest::Client, coords: &[(f64, f64)]) -> Result<(Vec<usize>, Vec<(f64, f64)>, Vec<[f64; 2]>), AppError> {
    let url = format!(
        "{OSRM_BASE}/trip/v1/driving/{}?source=first&destination=last&roundtrip=false&overview=full&geometries=geojson",
        osrm_coord_string(coords)
    );
    let resp: OsrmTripResp = client
        .get(&url)
        .send()
        .await
        .map_err(osrm_unreachable)?
        .error_for_status()
        .map_err(osrm_unreachable)?
        .json()
        .await
        .map_err(osrm_unreachable)?;
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
    let mut order = vec![0usize; coords.len()];
    for (input_idx, wp) in resp.waypoints.iter().enumerate() {
        if wp.waypoint_index >= order.len() {
            return Err(AppError::Internal("OSRM: unerwartete Antwort (Wegpunkt-Index außerhalb des Bereichs)".into()));
        }
        order[wp.waypoint_index] = input_idx;
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
}

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
    /// (see the `addresses` module above); absent for an exact match or a
    /// manually placed pin.
    location_precision: Option<String>,
}

fn to_stop_out(r: &StopRow) -> StopOut {
    StopOut {
        id: r.id,
        kind: r.kind.clone(),
        kunde: r.kunde.clone(),
        strasse: r.strasse.clone(),
        plz: r.plz.clone(),
        paket: r.paket.clone(),
        notiz: r.notiz.clone(),
        lat: r.lat,
        lon: r.lon,
        order_index: r.order_index,
        delivered: r.delivered,
        next_leg_km: r.next_leg_km,
        next_leg_min: r.next_leg_min,
        location_precision: r.location_precision.clone(),
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

fn get_route_detail(conn: &Connection, route_id: i64) -> Result<RouteDetail, AppError> {
    let route = conn
        .query_row("SELECT * FROM routes WHERE id = ?1", params![route_id], RouteRow::from_row)
        .optional()?
        .ok_or_else(|| AppError::NotFound("Route nicht gefunden".into()))?;

    let mut stmt = conn.prepare("SELECT * FROM stops WHERE route_id = ?1 ORDER BY order_index")?;
    let stops: Vec<StopRow> = stmt
        .query_map(params![route_id], StopRow::from_row)?
        .collect::<Result<_, _>>()?;
    drop(stmt);

    let stop_outs: Vec<StopOut> = stops.iter().map(to_stop_out).collect();
    let customer_stops: Vec<&StopOut> = stop_outs.iter().filter(|s| s.kind == "customer").collect();
    let total_km: f64 = stop_outs.iter().filter_map(|s| s.next_leg_km).sum();
    let total_min: f64 = stop_outs.iter().filter_map(|s| s.next_leg_min).sum();
    let geometry: Vec<[f64; 2]> = route
        .geometry
        .as_deref()
        .and_then(|g| serde_json::from_str(g).ok())
        .unwrap_or_default();

    Ok(RouteDetail {
        id: route.id,
        name: route.name,
        status: route.status,
        created_at: route.created_at,
        completed_at: route.completed_at,
        needs_optimize: route.needs_optimize,
        delivered_count: customer_stops.iter().filter(|s| s.delivered).count() as i64,
        customer_count: customer_stops.len() as i64,
        total_km: (total_km * 10.0).round() / 10.0,
        total_min: total_min.round(),
        stops: stop_outs,
        geometry,
    })
}

struct StopCoord {
    id: i64,
    lat: f64,
    lon: f64,
}

/// Re-solves stop order + fetches real geometry for a route via OSRM.
/// Structured as read-then-await-then-write with no `Connection` held
/// across an `.await` point — rusqlite's `Connection` isn't `Sync`, so
/// holding one across an await would make the enclosing future non-`Send`,
/// which axum's handler trait requires on a multi-threaded runtime.
async fn reoptimize_route(state: &AppState, route_id: i64) -> Result<(), AppError> {
    let (start, via, end, customers) = {
        let conn = open_db(&state.db_path)?;
        let mut stmt = conn.prepare("SELECT * FROM stops WHERE route_id = ?1 ORDER BY id")?;
        let stops: Vec<StopRow> = stmt.query_map(params![route_id], StopRow::from_row)?.collect::<Result<_, _>>()?;
        drop(stmt);

        let to_coord = |s: &StopRow| StopCoord { id: s.id, lat: s.lat, lon: s.lon };
        let start = stops
            .iter()
            .find(|s| s.kind == "start")
            .map(to_coord)
            .ok_or_else(|| AppError::Internal("Route hat keinen Start-Stopp".into()))?;
        let via = stops
            .iter()
            .find(|s| s.kind == "via")
            .map(to_coord)
            .ok_or_else(|| AppError::Internal("Route hat keinen Lager-Stopp".into()))?;
        let end = stops
            .iter()
            .find(|s| s.kind == "end")
            .map(to_coord)
            .ok_or_else(|| AppError::Internal("Route hat keinen Ziel-Stopp".into()))?;
        let customers: Vec<StopCoord> = stops.iter().filter(|s| s.kind == "customer").map(to_coord).collect();
        (start, via, end, customers)
    };

    // Leg 1: depot -> warehouse. Always first, never reordered — a plain
    // point-to-point call, no trip optimization involved.
    let (start_dist, start_dur, start_geom) = osrm_route_leg(&state.http, (start.lat, start.lon), (via.lat, via.lon)).await?;

    // Warehouse -> [customers, order chosen by OSRM] -> destination. OSRM's
    // `/trip` solves the actual ordering problem here.
    let mut sub_coords: Vec<(f64, f64)> = vec![(via.lat, via.lon)];
    sub_coords.extend(customers.iter().map(|c| (c.lat, c.lon)));
    sub_coords.push((end.lat, end.lon));
    let (order, legs, trip_geom) = osrm_trip(&state.http, &sub_coords).await?;

    // `order[position]` is an index into `sub_coords` (0 = warehouse,
    // 1..=n = customers[i-1], last = destination) — walk it to lay out the
    // full stop sequence in the order OSRM actually chose.
    let last_sub_idx = sub_coords.len() - 1;
    let mut nodes: Vec<&StopCoord> = vec![&start];
    for &idx in &order {
        if idx == 0 {
            nodes.push(&via);
        } else if idx == last_sub_idx {
            nodes.push(&end);
        } else {
            nodes.push(&customers[idx - 1]);
        }
    }

    let conn = open_db(&state.db_path)?;
    for (pos, node) in nodes.iter().enumerate() {
        let (leg_km, leg_min) = if pos == 0 {
            (Some(start_dist / 1000.0), Some(start_dur / 60.0))
        } else if pos - 1 < legs.len() {
            let (d, t) = legs[pos - 1];
            (Some(d / 1000.0), Some(t / 60.0))
        } else {
            (None, None) // last stop — no next leg
        };
        conn.execute(
            "UPDATE stops SET order_index = ?1, next_leg_km = ?2, next_leg_min = ?3 WHERE id = ?4",
            params![pos as i64, leg_km, leg_min, node.id],
        )?;
    }

    let mut geometry = start_geom;
    if !geometry.is_empty() && !trip_geom.is_empty() {
        geometry.pop(); // drop the warehouse point duplicated between the two legs
    }
    geometry.extend(trip_geom);
    // `[f64; 2]` pairs can't fail to serialize once finite, but OSRM is an
    // external service — treat a malformed/non-finite value in its
    // response as a normal (logged) error rather than a process-killing
    // unwrap.
    let geometry_json = serde_json::to_string(&geometry).map_err(|e| {
        tracing::error!(error = %e, "route geometry serialization failed");
        AppError::Internal("Routen-Geometrie konnte nicht gespeichert werden.".into())
    })?;
    conn.execute(
        "UPDATE routes SET geometry = ?1, needs_optimize = 0 WHERE id = ?2",
        params![geometry_json, route_id],
    )?;
    Ok(())
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
}

#[derive(Deserialize)]
struct StopCreate {
    kunde: String,
    strasse: String,
    plz: String,
    paket: Option<String>,
    notiz: Option<String>,
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
    delivered: Option<bool>,
    lat: Option<f64>,
    lon: Option<f64>,
}

// ---------------------------------------------------------------------
// Routes API
// ---------------------------------------------------------------------

async fn list_routes(State(state): State<Arc<AppState>>) -> Result<Json<Vec<RouteSummary>>, AppError> {
    let conn = open_db(&state.db_path)?;
    let mut stmt = conn.prepare(
        "SELECT r.id, r.name, r.status, r.created_at, r.completed_at, r.needs_optimize,
                COUNT(CASE WHEN s.kind = 'customer' THEN 1 END) AS customer_count,
                SUM(CASE WHEN s.kind = 'customer' AND s.delivered = 1 THEN 1 ELSE 0 END) AS delivered_count
         FROM routes r LEFT JOIN stops s ON s.route_id = r.id
         GROUP BY r.id ORDER BY r.created_at DESC",
    )?;
    let rows = stmt
        .query_map([], |r| {
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

async fn create_route(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RouteCreate>,
) -> Result<Json<RouteDetail>, AppError> {
    let name = payload
        .name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("Route {}", chrono::Local::now().format("%d.%m.%Y")));
    check_len(&name, "Name", MAX_ROUTE_NAME_LEN)?;
    check_no_control_chars(&name, "Name", false)?;

    // Fixed points, looked up once ahead of time — no geocoding needed at all.
    let (start_lat, start_lon) = (START_LAT, START_LON);
    let (via_lat, via_lon) = (VIA_LAT, VIA_LON);

    // The route row and its 3 fixed stops are one transaction — without
    // this, a crash between the route insert and the stop inserts leaves
    // an orphan route with no stops behind instead of either both existing
    // or neither.
    let route_id = {
        let mut conn = open_db(&state.db_path)?;
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO routes (name, status, created_at) VALUES (?1, 'active', ?2)",
            params![name, now_iso()],
        )?;
        let route_id = tx.last_insert_rowid();
        tx.execute(
            "INSERT INTO stops (route_id, kind, kunde, strasse, plz, lat, lon, order_index, created_at) \
             VALUES (?1, 'start', 'Start', 'Petritschgasse 24', '1210', ?2, ?3, 0, ?4)",
            params![route_id, start_lat, start_lon, now_iso()],
        )?;
        tx.execute(
            "INSERT INTO stops (route_id, kind, kunde, strasse, plz, lat, lon, order_index, created_at) \
             VALUES (?1, 'via', 'Lager', 'Oberlaa Straße 298', '1230', ?2, ?3, 1, ?4)",
            params![route_id, via_lat, via_lon, now_iso()],
        )?;
        tx.execute(
            "INSERT INTO stops (route_id, kind, kunde, strasse, plz, lat, lon, order_index, created_at) \
             VALUES (?1, 'end', 'Ziel', 'Petritschgasse 24', '1210', ?2, ?3, 2, ?4)",
            params![route_id, start_lat, start_lon, now_iso()],
        )?;
        tx.commit()?;
        route_id
    };
    reoptimize_route(&state, route_id).await?;
    let conn = open_db(&state.db_path)?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn get_route(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    let conn = open_db(&state.db_path)?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn update_route(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<RouteUpdate>,
) -> Result<Json<RouteDetail>, AppError> {
    let conn = open_db(&state.db_path)?;
    let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
    if !exists {
        return Err(AppError::NotFound("Route nicht gefunden".into()));
    }

    if let Some(name) = payload.name.as_deref() {
        let new_name = name.trim();
        if new_name.is_empty() {
            return Err(AppError::BadRequest("Name darf nicht leer sein.".into()));
        }
        check_len(new_name, "Name", MAX_ROUTE_NAME_LEN)?;
        check_no_control_chars(new_name, "Name", false)?;
        conn.execute("UPDATE routes SET name = ?1 WHERE id = ?2", params![new_name, route_id])?;
    }
    if let Some(status) = payload.status.as_deref() {
        if status != "active" && status != "completed" {
            return Err(AppError::BadRequest("Ungültiger Status".into()));
        }
        let completed_at = if status == "completed" { Some(now_iso()) } else { None };
        conn.execute(
            "UPDATE routes SET status = ?1, completed_at = ?2 WHERE id = ?3",
            params![status, completed_at, route_id],
        )?;
    }
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn delete_route(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<Value>, AppError> {
    let conn = open_db(&state.db_path)?;
    let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
    if !exists {
        return Err(AppError::NotFound("Route nicht gefunden".into()));
    }
    // `stops.route_id` has `ON DELETE CASCADE` (and `open_db` turns
    // `PRAGMA foreign_keys` on for every connection), so deleting the route
    // alone already removes its stops atomically — no separate DELETE
    // needed, and no window where the route is gone but its stops linger.
    conn.execute("DELETE FROM routes WHERE id = ?1", params![route_id])?;
    Ok(Json(json!({ "ok": true })))
}

async fn optimize_route(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    {
        let conn = open_db(&state.db_path)?;
        let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
        if !exists {
            return Err(AppError::NotFound("Route nicht gefunden".into()));
        }
    }
    reoptimize_route(&state, route_id).await?;
    let conn = open_db(&state.db_path)?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn reset_delivered(State(state): State<Arc<AppState>>, AxPath(route_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    let conn = open_db(&state.db_path)?;
    let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
    if !exists {
        return Err(AppError::NotFound("Route nicht gefunden".into()));
    }
    conn.execute(
        "UPDATE stops SET delivered = 0 WHERE route_id = ?1 AND kind = 'customer'",
        params![route_id],
    )?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn add_stop(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<StopCreate>,
) -> Result<Json<RouteDetail>, AppError> {
    {
        let conn = open_db(&state.db_path)?;
        let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
        if !exists {
            return Err(AppError::NotFound("Route nicht gefunden".into()));
        }
    }

    let kunde = payload.kunde.trim().to_string();
    let strasse = payload.strasse.trim().to_string();
    let plz = payload.plz.trim().to_string();
    let paket = payload.paket.as_deref().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    let notiz = payload.notiz.as_deref().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    if kunde.is_empty() || strasse.is_empty() || plz.is_empty() {
        return Err(AppError::BadRequest("Kunde, Straße und Bezirk dürfen nicht leer sein.".into()));
    }
    check_len(&kunde, "Kunde", MAX_KUNDE_LEN)?;
    check_no_control_chars(&kunde, "Kunde", false)?;
    check_len(&strasse, "Straße", MAX_STRASSE_LEN)?;
    check_no_control_chars(&strasse, "Straße", false)?;
    if let Some(p) = &paket {
        check_len(p, "Paket", MAX_PAKET_LEN)?;
        check_no_control_chars(p, "Paket", false)?;
    }
    if let Some(n) = &notiz {
        check_len(n, "Notiz", MAX_NOTIZ_LEN)?;
        check_no_control_chars(n, "Notiz", true)?;
    }
    check_plz(&plz)?;

    let (lat, lon, precision) = if let (Some(lat), Some(lon)) = (payload.lat, payload.lon) {
        check_latlon(lat, lon)?;
        (lat, lon, None) // a human placed this pin — that's exact by definition
    } else {
        let (lat, lon, _, precision) = geocode_address(&state, &strasse, &plz).await?;
        (lat, lon, (precision != Precision::Exact).then(|| precision.as_str()))
    };

    {
        let mut conn = open_db(&state.db_path)?;
        let max_order: i64 = conn.query_row(
            "SELECT COALESCE(MAX(order_index), 0) FROM stops WHERE route_id = ?1",
            params![route_id],
            |r| r.get(0),
        )?;
        // Both writes commit together — a crash between them would
        // otherwise either lose the stop entirely or save it without ever
        // flagging the route stale.
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO stops (route_id, kind, kunde, strasse, plz, paket, notiz, lat, lon, order_index, location_precision, created_at) \
             VALUES (?1, 'customer', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![route_id, kunde, strasse, plz, paket, notiz, lat, lon, max_order + 1, precision, now_iso()],
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
    // OSRM solves this in one fast network round-trip now — no reason to
    // make the driver remember a separate "optimize" tap after every
    // single stop like the old local solver required.
    reoptimize_route(&state, route_id).await?;
    let conn = open_db(&state.db_path)?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn update_stop(
    State(state): State<Arc<AppState>>,
    AxPath(stop_id): AxPath<i64>,
    Json(payload): Json<StopUpdate>,
) -> Result<Json<RouteDetail>, AppError> {
    let (route_id, kind, cur_strasse, cur_plz) = {
        let conn = open_db(&state.db_path)?;
        conn.query_row(
            "SELECT route_id, kind, strasse, plz FROM stops WHERE id = ?1",
            params![stop_id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                ))
            },
        )
        .optional()?
        .ok_or_else(|| AppError::NotFound("Stopp nicht gefunden".into()))?
    };

    if let Some(strasse) = payload.strasse.as_deref() {
        if strasse.trim().is_empty() {
            return Err(AppError::BadRequest("Straße darf nicht leer sein.".into()));
        }
        check_len(strasse.trim(), "Straße", MAX_STRASSE_LEN)?;
        check_no_control_chars(strasse.trim(), "Straße", false)?;
    }
    if let Some(plz) = payload.plz.as_deref() {
        if plz.trim().is_empty() {
            return Err(AppError::BadRequest("Bezirk darf nicht leer sein.".into()));
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
    if let Some(paket) = payload.paket.as_deref() {
        check_len(paket.trim(), "Paket", MAX_PAKET_LEN)?;
        check_no_control_chars(paket.trim(), "Paket", false)?;
    }
    if let Some(notiz) = payload.notiz.as_deref() {
        check_len(notiz.trim(), "Notiz", MAX_NOTIZ_LEN)?;
        check_no_control_chars(notiz.trim(), "Notiz", true)?;
    }

    let new_strasse = payload.strasse.as_deref().map(str::trim).unwrap_or(&cur_strasse).to_string();
    let new_plz = payload.plz.as_deref().map(str::trim).unwrap_or(&cur_plz).to_string();
    let address_changed = kind == "customer"
        && ((payload.strasse.is_some() && new_strasse != cur_strasse) || (payload.plz.is_some() && new_plz != cur_plz));

    let mut new_coords: Option<(f64, f64, Option<&'static str>)> = None;
    if address_changed {
        check_plz(&new_plz)?;
        new_coords = Some(if let (Some(lat), Some(lon)) = (payload.lat, payload.lon) {
            check_latlon(lat, lon)?;
            (lat, lon, None)
        } else {
            let (lat, lon, _, precision) = geocode_address(&state, &new_strasse, &new_plz).await?;
            (lat, lon, (precision != Precision::Exact).then(|| precision.as_str()))
        });
    }

    {
        let mut conn = open_db(&state.db_path)?;
        // Up to 6 separate field updates land here depending on what the
        // caller sent — a transaction keeps them atomic, so a crash
        // mid-request can't apply some fields (say, the new address) while
        // dropping others (say, the `needs_optimize` flag that address
        // change should have set).
        let tx = conn.transaction()?;
        if let Some(k) = &kunde {
            tx.execute("UPDATE stops SET kunde = ?1 WHERE id = ?2", params![k, stop_id])?;
        }
        if let Some(paket) = &payload.paket {
            tx.execute("UPDATE stops SET paket = ?1 WHERE id = ?2", params![paket.trim(), stop_id])?;
        }
        if let Some(notiz) = &payload.notiz {
            tx.execute("UPDATE stops SET notiz = ?1 WHERE id = ?2", params![notiz.trim(), stop_id])?;
        }
        if address_changed {
            tx.execute(
                "UPDATE stops SET strasse = ?1, plz = ?2 WHERE id = ?3",
                params![new_strasse, new_plz, stop_id],
            )?;
        }
        if let Some(delivered) = payload.delivered {
            tx.execute(
                "UPDATE stops SET delivered = ?1 WHERE id = ?2",
                params![delivered as i64, stop_id],
            )?;
        }
        if let Some((lat, lon, precision)) = new_coords {
            tx.execute(
                "UPDATE stops SET lat = ?1, lon = ?2, location_precision = ?3 WHERE id = ?4",
                params![lat, lon, precision, stop_id],
            )?;
        }
        if address_changed {
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        }
        tx.commit()?;
    }

    // Only a real address change moves the stop's position in the route —
    // marking delivered, editing the note/package text etc. never touch
    // order/geometry, so there's nothing to re-solve for those.
    if address_changed {
        reoptimize_route(&state, route_id).await?;
    }
    let conn = open_db(&state.db_path)?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

async fn delete_stop(State(state): State<Arc<AppState>>, AxPath(stop_id): AxPath<i64>) -> Result<Json<RouteDetail>, AppError> {
    let route_id = {
        let mut conn = open_db(&state.db_path)?;
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
    reoptimize_route(&state, route_id).await?;
    let conn = open_db(&state.db_path)?;
    Ok(Json(get_route_detail(&conn, route_id)?))
}

/// Bulk-edit endpoint backing the "Route als JSON" editor. Customer-facing
/// fields only, stops matched by normalized (strasse, plz), unmatched
/// existing stops deleted (unless something failed to geocode this round
/// — see `deletions_skipped`), new ones geocoded and inserted. Geocoding
/// is local (no network, no rate limit) but still runs outside the write
/// transaction, matching the original design's separation of concerns.
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
struct BulkJsonResult {
    #[serde(flatten)]
    route: RouteDetail,
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
    /// at least one geocode failure made it unsafe to tell a genuine
    /// removal apart from an edited address that just failed to resolve.
    deletions_skipped: bool,
}

async fn update_route_from_json(
    State(state): State<Arc<AppState>>,
    AxPath(route_id): AxPath<i64>,
    Json(payload): Json<Value>,
) -> Result<Json<BulkJsonResult>, AppError> {
    let stops_in: Vec<Value> = match &payload {
        Value::Array(a) => a.clone(),
        Value::Object(o) => match o.get("stops") {
            Some(Value::Array(a)) => a.clone(),
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

    fn addr_key(strasse: &str, plz: &str) -> (String, String) {
        (strasse.trim().to_lowercase(), plz.trim().to_string())
    }

    struct ExistingStop {
        id: i64,
        strasse: String,
        plz: String,
    }

    let existing_customers: Vec<ExistingStop> = {
        let conn = open_db(&state.db_path)?;
        let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
        if !exists {
            return Err(AppError::NotFound("Route nicht gefunden".into()));
        }
        let mut stmt = conn.prepare("SELECT id, strasse, plz FROM stops WHERE route_id = ?1 AND kind = 'customer'")?;
        let rows: Vec<ExistingStop> = stmt
            .query_map(params![route_id], |r| {
                Ok(ExistingStop {
                    id: r.get(0)?,
                    strasse: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    plz: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                })
            })?
            .collect::<Result<_, _>>()?;
        rows
    };

    let mut normalized: Vec<(String, String, String, Option<String>, Option<String>)> = Vec::new();
    for entry in &stops_in {
        let obj = entry
            .as_object()
            .ok_or_else(|| AppError::BadRequest("Ungültiger Eintrag in der Liste (kein Objekt).".into()))?;
        let kunde = obj.get("kunde").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let strasse = obj.get("strasse").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let plz = obj.get("plz").and_then(Value::as_str).unwrap_or("").trim().to_string();
        if kunde.is_empty() || strasse.is_empty() || plz.is_empty() {
            let label = if !kunde.is_empty() { &kunde } else if !strasse.is_empty() { &strasse } else if !plz.is_empty() { &plz } else { "?" };
            return Err(AppError::BadRequest(format!(
                "Ungültiger Stopp ({}): Kunde, Straße und Bezirk sind Pflichtfelder.",
                label
            )));
        }
        let paket = obj.get("paket").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        let notiz = obj.get("notiz").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        check_len(&kunde, "Kunde", MAX_KUNDE_LEN)?;
        check_no_control_chars(&kunde, "Kunde", false)?;
        check_len(&strasse, "Straße", MAX_STRASSE_LEN)?;
        check_no_control_chars(&strasse, "Straße", false)?;
        if let Some(p) = &paket {
            check_len(p, "Paket", MAX_PAKET_LEN)?;
            check_no_control_chars(p, "Paket", false)?;
        }
        if let Some(n) = &notiz {
            check_len(n, "Notiz", MAX_NOTIZ_LEN)?;
            check_no_control_chars(n, "Notiz", true)?;
        }
        normalized.push((kunde, strasse, plz, paket, notiz));
    }

    let mut by_key: std::collections::HashMap<(String, String), Vec<i64>> = std::collections::HashMap::new();
    for s in &existing_customers {
        by_key.entry(addr_key(&s.strasse, &s.plz)).or_default().push(s.id);
    }

    let mut to_update: Vec<(String, Option<String>, Option<String>, i64)> = Vec::new();
    let mut to_insert: Vec<(String, String, String, Option<String>, Option<String>, f64, f64, Option<&'static str>)> = Vec::new();
    let mut matched_ids: HashSet<i64> = HashSet::new();
    // Geocoding failures are collected, not fatal: everything else in the
    // batch still gets saved instead of one bad address blocking all 30.
    let mut failures: Vec<GeocodeFailure> = Vec::new();
    let mut approximate: Vec<GeocodeApproximate> = Vec::new();

    for (kunde, strasse, plz, paket, notiz) in normalized {
        let key = addr_key(&strasse, &plz);
        let existing_id = by_key.get_mut(&key).and_then(|v| if v.is_empty() { None } else { Some(v.remove(0)) });
        if let Some(id) = existing_id {
            to_update.push((kunde, paket, notiz, id));
            matched_ids.insert(id);
        } else if !is_valid_vienna_plz(&plz) {
            // Skip the external geocode round-trip entirely for a PLZ that
            // can't possibly be a Vienna address — same outcome as it
            // failing geocoding, just without spending a Nominatim/OSGD
            // call (and its share of the shared rate limit) on it.
            failures.push(GeocodeFailure { kunde, strasse, plz });
        } else {
            match geocode_address(&state, &strasse, &plz).await {
                Ok((lat, lon, _, precision)) => {
                    let precision_tag = (precision != Precision::Exact).then(|| precision.as_str());
                    if let Some(p) = precision_tag {
                        approximate.push(GeocodeApproximate { kunde: kunde.clone(), strasse: strasse.clone(), plz: plz.clone(), precision: p });
                    }
                    to_insert.push((kunde, strasse, plz, paket, notiz, lat, lon, precision_tag));
                }
                Err(_) => failures.push(GeocodeFailure { kunde, strasse, plz }),
            }
        }
    }

    // If anything failed to geocode, we can't safely tell "this address was
    // genuinely removed" apart from "this is an edited address that just
    // failed to resolve" (both look like "not in matched_ids"). Skip
    // deletions entirely this round rather than risk silently dropping a
    // customer who was only ever the victim of an unrelated typo elsewhere
    // in the same paste.
    let deletions_skipped = !failures.is_empty();
    let to_delete: Vec<i64> = if deletions_skipped {
        Vec::new()
    } else {
        existing_customers.iter().map(|s| s.id).filter(|id| !matched_ids.contains(id)).collect()
    };

    let changed = {
        let mut conn = open_db(&state.db_path)?;
        let exists: bool = conn.query_row("SELECT 1 FROM routes WHERE id = ?1", params![route_id], |_| Ok(())).optional()?.is_some();
        if !exists {
            return Err(AppError::NotFound("Route nicht gefunden".into()));
        }

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
        if !to_insert.is_empty() {
            let mut max_order: i64 = tx.query_row(
                "SELECT COALESCE(MAX(order_index), 0) FROM stops WHERE route_id = ?1",
                params![route_id],
                |r| r.get(0),
            )?;
            for (kunde, strasse, plz, paket, notiz, lat, lon, precision) in &to_insert {
                max_order += 1;
                tx.execute(
                    "INSERT INTO stops (route_id, kind, kunde, strasse, plz, paket, notiz, lat, lon, order_index, delivered, location_precision, created_at) \
                     VALUES (?1, 'customer', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10, ?11)",
                    params![route_id, kunde, strasse, plz, paket, notiz, lat, lon, max_order, precision, now_iso()],
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

        if changed {
            tx.execute("UPDATE routes SET needs_optimize = 1 WHERE id = ?1", params![route_id])?;
        }
        tx.commit()?;
        changed
    };

    if changed {
        reoptimize_route(&state, route_id).await?;
    }
    let conn = open_db(&state.db_path)?;
    Ok(Json(BulkJsonResult {
        route: get_route_detail(&conn, route_id)?,
        geocode_failures: failures,
        approximate,
        deletions_skipped,
    }))
}

// ---------------------------------------------------------------------
// Root — a minimal placeholder page (see module doc comment) embedded into
// the binary at compile time, same as the rest of this app's assets used
// to be, so the server stays a single self-contained executable with no
// runtime dependency on files sitting next to it.
// ---------------------------------------------------------------------

const INDEX_HTML: &str = include_str!("../index.html");
const SW_JS: &str = include_str!("../sw.js");

async fn index() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], INDEX_HTML)
}

/// `Cache-Control: no-cache` (not "no-store") so the browser always
/// revalidates before using its cached copy — the whole point of a service
/// worker is to update itself promptly on the next visit, and a long-lived
/// cached /sw.js would defeat that for however long the header allows.
async fn sw_js() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "application/javascript; charset=utf-8"), (header::CACHE_CONTROL, "no-cache")],
        SW_JS,
    )
}

// ---------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------

/// Waits for Ctrl+C so `main` can pass it to `with_graceful_shutdown` —
/// without that, killing the process (a redeploy, a driver's own Ctrl+C)
/// drops every in-flight connection immediately, including one mid-way
/// through a multi-step handler like `update_route_from_json`. Graceful
/// shutdown lets axum stop accepting new connections but finish the ones
/// already in progress first.
async fn shutdown_signal() {
    tokio::signal::ctrl_c().await.expect("failed to install Ctrl+C handler");
    tracing::info!("shutdown signal received, draining in-flight requests");
}

fn base_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .filter(|p| p.exists())
        .unwrap_or_else(|| PathBuf::from("."))
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let db_path = base_dir().join("rerouter.db");
    init_db(&db_path).expect("failed to initialize database");

    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .expect("failed to build HTTP client");
    tracing::info!("Geocoding via Nominatim, routing via OSRM — both live services, no local dataset.");

    let state = Arc::new(AppState {
        db_path,
        http,
        nominatim_last: AsyncMutex::new(None),
        rate_limit: AsyncMutex::new(HashMap::new()),
    });

    // Every JSON body this app accepts is a handful of short text fields
    // for a handful of stops — 256 KiB is already generous headroom over
    // `MAX_BULK_STOPS` worth of the largest single field, and rejecting
    // anything past that stops a giant/garbage body from ever being
    // buffered into memory at all.
    const MAX_BODY_BYTES: usize = 256 * 1024;

    // Rate-limited, size-capped: only the JSON API a script could actually
    // abuse. Kept as its own router (rather than one global limiter) so a
    // normal page load — several static-asset GETs at once — never counts
    // against the same budget as the API calls a driver's phone makes.
    let api_router = Router::new()
        .route("/api/routes", get(list_routes).post(create_route))
        .route("/api/routes/:id", get(get_route).patch(update_route).delete(delete_route))
        .route("/api/routes/:id/optimize", post(optimize_route))
        .route("/api/routes/:id/json", put(update_route_from_json))
        .route("/api/routes/:id/reset-delivered", post(reset_delivered))
        .route("/api/routes/:id/stops", post(add_stop))
        .route("/api/stops/:id", patch(update_stop).delete(delete_stop))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(middleware::from_fn_with_state(state.clone(), rate_limit_mw));

    let app = Router::new()
        .merge(api_router)
        .route("/", get(index))
        .route("/sw.js", get(sw_js))
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
        .layer(middleware::from_fn(security_headers_mw))
        .layer(TraceLayer::new_for_http());

    let addr = SocketAddr::from(([0, 0, 0, 0], 8000));
    tracing::info!("EAR Routing listening on http://{addr}");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("failed to bind port 8000");
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
}
