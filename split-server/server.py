"""EAR Split API — keeps the parts of a split tour ("Tour aufteilen") so that
another driver's phone can pick their part up.

One phone sends a person's part, in the JSON the iOS app writes for it;
another lists the parts of a day and loads one as its tour. The API is in
README.md and, on a running server, at /docs.

Two kinds of access:

* the JSON API under /api, with an API key in `X-Api-Key`;
* the admin web UI at /, signed in as `admin` with EAR_SPLIT_ADMIN_PASSWORD.
  The admin makes and removes the API keys and can look at and delete parts.

Keys are stored as SHA-256 hashes; a new key is shown once, when it is made.

Environment:
    PORT                      default 3003
    EAR_SPLIT_ADMIN_PASSWORD  the admin password; without it nobody can sign in
    EAR_SPLIT_DATA_DIR        default ./data next to this file
    EAR_SPLIT_TRUST_PROXY     "1" behind cloudflared: the client is X-Forwarded-For

Standard library only, so Venvy installs nothing.
"""
import datetime
import hashlib
import hmac
import html
import json
import logging
import os
import re
import secrets
import sqlite3
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

PORT = int(os.getenv("PORT") or 3003)
ADMIN_USER = "admin"
ADMIN_PASSWORD = os.getenv("EAR_SPLIT_ADMIN_PASSWORD", "")
DATA_DIR = Path(os.getenv("EAR_SPLIT_DATA_DIR") or Path(__file__).resolve().parent / "data")
TRUST_PROXY = os.getenv("EAR_SPLIT_TRUST_PROXY") == "1"
README = Path(__file__).resolve().parent / "README.md"
VIENNA = ZoneInfo("Europe/Vienna")

MAX_BODY = 1_000_000          # a whole tour with notes is a few tens of KB
MAX_FORM = 10_000
MAX_STOPS = 400
MAX_TEXT = 2000               # any one string in a stop
MAX_DAYS = 400
SESSION_HOURS = 12
LOGIN_WINDOW = 15 * 60        # failed sign-ins counted per address over this many seconds
LOGIN_MAX_FAILS = 10
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

log = logging.getLogger("ear-split")
_write_lock = threading.Lock()
_login_fails: dict[str, list[float]] = {}
_login_lock = threading.Lock()


# ================================================================ storage

def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DATA_DIR / "parts.db", timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS parts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tour TEXT NOT NULL,
                day TEXT NOT NULL,
                person INTEGER,
                stops INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                key_id INTEGER,
                body TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS parts_day ON parts (day, created_at);
            CREATE TABLE IF NOT EXISTS api_keys (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                hash TEXT NOT NULL UNIQUE,
                prefix TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_used_at TEXT
            );
            CREATE TABLE IF NOT EXISTS sessions (
                hash TEXT PRIMARY KEY,
                csrf TEXT NOT NULL,
                expires_at REAL NOT NULL
            );
        """)
        conn.execute("DELETE FROM sessions WHERE expires_at < ?", (time.time(),))


def now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def today() -> str:
    return datetime.datetime.now(VIENNA).date().isoformat()


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def summary(row: sqlite3.Row) -> dict:
    return {"id": row["id"], "tour": row["tour"], "date": row["day"], "person": row["person"],
            "stops": row["stops"], "created_at": row["created_at"]}


def list_parts(day: str | None = None, days: int = 30) -> list[sqlite3.Row]:
    with db() as conn:
        if day:
            return conn.execute(
                "SELECT * FROM parts WHERE day = ? ORDER BY created_at DESC, id DESC", (day,)).fetchall()
        since = (datetime.datetime.now(VIENNA).date() - datetime.timedelta(days=days - 1)).isoformat()
        return conn.execute(
            "SELECT * FROM parts WHERE day >= ? ORDER BY day DESC, created_at DESC, id DESC LIMIT 500",
            (since,)).fetchall()


def get_part(part_id: int) -> sqlite3.Row | None:
    with db() as conn:
        return conn.execute("SELECT * FROM parts WHERE id = ?", (part_id,)).fetchone()


def delete_part(part_id: int) -> bool:
    with _write_lock, db() as conn:
        return conn.execute("DELETE FROM parts WHERE id = ?", (part_id,)).rowcount > 0


# ---------------------------------------------------------------- API keys

def create_key(name: str) -> str:
    key = "ears_" + secrets.token_urlsafe(24)
    with _write_lock, db() as conn:
        conn.execute("INSERT INTO api_keys (name, hash, prefix, created_at) VALUES (?, ?, ?, ?)",
                     (name, sha256(key), key[:9], now_utc()))
    log.info("api key created: %s", name)
    return key


def delete_key(key_id: int) -> None:
    with _write_lock, db() as conn:
        conn.execute("DELETE FROM api_keys WHERE id = ?", (key_id,))
    log.info("api key %s removed", key_id)


def list_keys() -> list[sqlite3.Row]:
    with db() as conn:
        return conn.execute("SELECT * FROM api_keys ORDER BY created_at DESC, id DESC").fetchall()


def key_id_for(key: str) -> int | None:
    if not key:
        return None
    with db() as conn:
        row = conn.execute("SELECT id, last_used_at FROM api_keys WHERE hash = ?", (sha256(key),)).fetchone()
        if not row:
            return None
        # At most once a minute: a list and a load are not worth two writes.
        stamp = now_utc()
        if (row["last_used_at"] or "")[:16] != stamp[:16]:
            conn.execute("UPDATE api_keys SET last_used_at = ? WHERE id = ?", (stamp, row["id"]))
        return row["id"]


# ---------------------------------------------------------------- admin sessions

def create_session() -> tuple[str, str]:
    token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(16)
    with _write_lock, db() as conn:
        conn.execute("INSERT INTO sessions (hash, csrf, expires_at) VALUES (?, ?, ?)",
                     (sha256(token), csrf, time.time() + SESSION_HOURS * 3600))
    return token, csrf


def session_csrf(token: str | None) -> str | None:
    """The session's CSRF token, or None when the cookie is no (live) session."""
    if not token:
        return None
    with db() as conn:
        row = conn.execute("SELECT csrf, expires_at FROM sessions WHERE hash = ?", (sha256(token),)).fetchone()
    return row["csrf"] if row and row["expires_at"] > time.time() else None


def end_session(token: str | None) -> None:
    if token:
        with _write_lock, db() as conn:
            conn.execute("DELETE FROM sessions WHERE hash = ?", (sha256(token),))


def login_blocked(ip: str) -> bool:
    with _login_lock:
        recent = [t for t in _login_fails.get(ip, []) if t > time.time() - LOGIN_WINDOW]
        _login_fails[ip] = recent
        return len(recent) >= LOGIN_MAX_FAILS


def login_failed(ip: str) -> None:
    with _login_lock:
        _login_fails.setdefault(ip, []).append(time.time())


# ================================================================ validation

class BadRequest(Exception):
    pass


def check_part(part) -> tuple[str, str, int | None, int]:
    """The part's tour, day, person and stop count — or BadRequest."""
    if not isinstance(part, dict):
        raise BadRequest("Ein JSON-Objekt erwartet.")
    tour = part.get("tour")
    if not isinstance(tour, str) or not tour.strip() or len(tour) > 200:
        raise BadRequest("„tour“ fehlt.")
    day = part.get("date") or today()
    if not isinstance(day, str) or not DATE_RE.match(day):
        raise BadRequest("„date“ muss JJJJ-MM-TT sein.")
    try:
        datetime.date.fromisoformat(day)
    except ValueError:
        raise BadRequest("„date“ ist kein gültiges Datum.") from None
    persons = part.get("persons")
    if not isinstance(persons, list) or not persons:
        raise BadRequest("„persons“ fehlt.")
    count = 0
    for p in persons:
        if not isinstance(p, dict) or not isinstance(p.get("stops"), list):
            raise BadRequest("Jede Person braucht „stops“.")
        for s in p["stops"]:
            if not isinstance(s, dict) or not isinstance(s.get("name"), str) or not isinstance(s.get("address"), str):
                raise BadRequest("Jeder Stopp braucht „name“ und „address“.")
            for v in s.values():
                if v is not None and not isinstance(v, (str, int, float, bool)):
                    raise BadRequest("Stopps enthalten nur Text und Zahlen.")
                if isinstance(v, str) and len(v) > MAX_TEXT:
                    raise BadRequest("Ein Eintrag ist zu lang.")
            count += 1
    if count == 0:
        raise BadRequest("Der Teil hat keine Stopps.")
    if count > MAX_STOPS:
        raise BadRequest("Zu viele Stopps.")
    person = persons[0].get("person") if len(persons) == 1 else None
    if not isinstance(person, int) or isinstance(person, bool):
        person = None
    return tour.strip(), day, person, count


# ================================================================ HTML

STYLE = """
:root { color-scheme: light dark; --bg:#F2F2F7; --card:#fff; --text:#000; --muted:rgba(60,60,67,.6);
        --line:rgba(60,60,67,.18); --accent:#007AFF; --danger:#FF3B30; --ok:#34C759; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#000; --card:#1C1C1E; --text:#fff; --muted:rgba(235,235,245,.6);
          --line:rgba(84,84,88,.6); --accent:#0A84FF; --danger:#FF453A; --ok:#30D158; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text);
       font:15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
main { max-width: 860px; margin: 0 auto; padding: 24px 16px 64px; }
header { display:flex; align-items:center; gap:12px; margin-bottom: 20px; }
header h1 { font-size: 24px; margin: 0; flex: 1; }
nav a { color: var(--accent); text-decoration: none; margin-left: 14px; font-weight: 500; }
h2 { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em;
     color: var(--muted); margin: 28px 4px 8px; }
.card { background: var(--card); border-radius: 14px; padding: 4px 16px; }
.card.pad { padding: 16px; }
.row { display:flex; align-items:center; gap:12px; padding: 12px 0; border-top: 1px solid var(--line); }
.row:first-child { border-top: 0; }
.row .main { flex: 1; min-width: 0; }
.muted { color: var(--muted); font-size: 13px; }
.empty { color: var(--muted); padding: 14px 0; }
code, pre { font: 13px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
pre { background: var(--bg); border-radius: 10px; padding: 12px; overflow-x: auto; white-space: pre-wrap; }
input[type=text], input[type=password] { width:100%; font: inherit; padding: 10px 12px; border-radius: 10px;
     border: 1px solid var(--line); background: var(--bg); color: var(--text); }
button, .btn { font: inherit; font-weight: 600; border: 0; border-radius: 10px; padding: 10px 16px;
     background: var(--accent); color: #fff; cursor: pointer; text-decoration: none; display: inline-block; }
button.quiet { background: transparent; color: var(--danger); padding: 6px 8px; }
form.inline { display: inline; margin: 0; }
.flex { display:flex; gap: 10px; }
.notice { border-radius: 12px; padding: 12px 16px; margin-bottom: 16px; }
.notice.ok { background: rgba(52,199,89,.15); }
.notice.err { background: rgba(255,59,48,.14); }
.key { font-size: 15px; word-break: break-all; user-select: all; }
.login { max-width: 360px; margin: 12vh auto 0; }
.login .card { display: grid; gap: 12px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 8px 6px; border-top: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 500; font-size: 13px; border-top: 0; }
.docs h3 { margin: 22px 0 6px; font-size: 16px; }
.docs p { margin: 6px 0; }
"""


def esc(value) -> str:
    return html.escape("" if value is None else str(value))


def page(title: str, body: str, nav: bool = True) -> str:
    links = ('<nav><a href="/">Übersicht</a><a href="/docs">API</a>'
             '<form class="inline" method="post" action="/logout">{csrf}'
             '<button class="quiet" style="color:var(--accent)">Abmelden</button></form></nav>') if nav else ""
    return (f'<!doctype html><html lang="de"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>{esc(title)} · EAR Split</title><style>{STYLE}</style></head>'
            f'<body><main><header><h1>{esc(title)}</h1>{links}</header>{body}</main></body></html>')


def fmt_time(iso: str | None) -> str:
    if not iso:
        return "nie"
    try:
        return datetime.datetime.fromisoformat(iso).astimezone(VIENNA).strftime("%d.%m.%Y %H:%M")
    except ValueError:
        return iso


def fmt_day(day: str) -> str:
    try:
        return datetime.date.fromisoformat(day).strftime("%d.%m.%Y")
    except ValueError:
        return day


# ================================================================ HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "EarSplit/2"

    def log_message(self, fmt, *args):
        log.info("%s %s", self.client_ip(), fmt % args)

    # ---- plumbing

    def client_ip(self) -> str:
        if TRUST_PROXY:
            forwarded = self.headers.get("X-Forwarded-For", "")
            if forwarded:
                return forwarded.split(",")[0].strip()
        return self.client_address[0]

    def path_only(self) -> str:
        return urlparse(self.path).path.rstrip("/") or "/"

    def query(self) -> dict:
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}

    def send(self, status: int, body: bytes, content_type: str, headers: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status: int, body) -> None:
        self.send(status, json.dumps(body, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def json_error(self, status: int, detail: str) -> None:
        self.send_json(status, {"detail": detail})

    def send_html(self, status: int, text: str, headers: dict | None = None) -> None:
        self.send(status, text.encode(), "text/html; charset=utf-8", {
            "X-Frame-Options": "DENY",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'",
            "Referrer-Policy": "no-referrer",
            **(headers or {}),
        })

    def redirect(self, to: str, headers: dict | None = None) -> None:
        self.send(303, b"", "text/plain", {"Location": to, **(headers or {})})

    def read_body(self, limit: int) -> bytes | None:
        """The request body, or None after an error answer was sent."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0:
            self.json_error(400, "Content-Length fehlt.")
            return None
        if length > limit:
            self.json_error(413, "Zu groß.")
            return None
        return self.rfile.read(length) if length else b""

    def cookie(self, name: str) -> str | None:
        jar = SimpleCookie(self.headers.get("Cookie", ""))
        return jar[name].value if name in jar else None

    def session_cookie(self, token: str, max_age: int) -> str:
        secure = "; Secure" if TRUST_PROXY else ""
        return f"ear_split_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age}{secure}"

    # ---- dispatch

    def do_GET(self):
        self.dispatch("GET")

    def do_HEAD(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def dispatch(self, method: str) -> None:
        path = self.path_only()
        try:
            if path == "/health":
                return self.send_json(200, {"ok": True})
            if path == "/api" or path.startswith("/api/"):
                return self.api(method, path)
            return self.web(method, path)
        except BrokenPipeError:
            pass
        except Exception:
            log.exception("request failed: %s %s", method, path)
            if path.startswith("/api"):
                self.json_error(500, "Interner Fehler.")
            else:
                self.send_html(500, page("Fehler", '<div class="notice err">Interner Fehler.</div>', nav=False))

    # ================================================================ JSON API

    def api(self, method: str, path: str) -> None:
        given = self.headers.get("X-Api-Key", "")
        if not given and self.headers.get("Authorization", "").startswith("Bearer "):
            given = self.headers["Authorization"][7:].strip()
        key_id = key_id_for(given)
        if key_id is None:
            return self.json_error(401, "Fehlender oder falscher API-Schlüssel.")

        m = re.fullmatch(r"/api/parts/(\d+)", path)
        if m:
            part_id = int(m.group(1))
            if method == "GET":
                row = get_part(part_id)
                if not row:
                    return self.json_error(404, "Diesen Teil gibt es nicht.")
                return self.send_json(200, {**summary(row), "part": json.loads(row["body"])})
            if method == "DELETE":
                if not delete_part(part_id):
                    return self.json_error(404, "Diesen Teil gibt es nicht.")
                log.info("part %s deleted by key %s", part_id, key_id)
                return self.send_json(200, {"ok": True})
            return self.json_error(405, "Methode nicht erlaubt.")

        if path == "/api/parts":
            if method == "GET":
                return self.api_list()
            if method == "POST":
                return self.api_store(key_id)
            return self.json_error(405, "Methode nicht erlaubt.")
        self.json_error(404, "Nicht gefunden.")

    def api_list(self) -> None:
        q = self.query()
        day = q.get("date")
        if day and not DATE_RE.match(day):
            return self.json_error(400, "„date“ muss JJJJ-MM-TT sein.")
        try:
            days = max(1, min(MAX_DAYS, int(q.get("days") or 30)))
        except ValueError:
            return self.json_error(400, "„days“ muss eine Zahl sein.")
        self.send_json(200, {"parts": [summary(r) for r in list_parts(day, days)]})

    def api_store(self, key_id: int) -> None:
        raw = self.read_body(MAX_BODY)
        if raw is None:
            return
        try:
            part = json.loads(raw)
            tour, day, person, count = check_part(part)
        except (ValueError, UnicodeDecodeError):
            return self.json_error(400, "Kein gültiges JSON.")
        except BadRequest as e:
            return self.json_error(400, str(e))
        part["date"] = day
        with _write_lock, db() as conn:
            cur = conn.execute(
                "INSERT INTO parts (tour, day, person, stops, created_at, key_id, body) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (tour, day, person, count, now_utc(), key_id, json.dumps(part, ensure_ascii=False)))
            row = conn.execute("SELECT * FROM parts WHERE id = ?", (cur.lastrowid,)).fetchone()
        log.info("part %s stored by key %s: %s, %s, person %s, %s stops", row["id"], key_id, tour, day, person, count)
        self.send_json(201, summary(row))

    # ================================================================ admin web UI

    def web(self, method: str, path: str) -> None:
        if path == "/login":
            return self.login_page() if method == "GET" else self.login_submit()
        token = self.cookie("ear_split_session")
        csrf = session_csrf(token)
        if csrf is None:
            return self.redirect("/login")

        form = {}
        if method == "POST":
            raw = self.read_body(MAX_FORM)
            if raw is None:
                return
            form = {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace")).items()}
            if not hmac.compare_digest(form.get("csrf", ""), csrf):
                return self.send_html(403, page("Abgelehnt", '<div class="notice err">Formular abgelaufen — Seite neu laden.</div>', nav=False))

        if path == "/logout" and method == "POST":
            end_session(token)
            return self.redirect("/login", {"Set-Cookie": self.session_cookie("", 0)})
        if path == "/" and method == "GET":
            return self.dashboard(csrf)
        if path == "/docs" and method == "GET":
            return self.docs(csrf)
        if path == "/keys" and method == "POST":
            name = " ".join(form.get("name", "").split())[:80]
            if not name:
                return self.dashboard(csrf, error="Bitte einen Namen für den Schlüssel angeben.")
            return self.dashboard(csrf, new_key=(name, create_key(name)))
        m = re.fullmatch(r"/keys/(\d+)/delete", path)
        if m and method == "POST":
            delete_key(int(m.group(1)))
            return self.redirect("/?msg=key-removed")
        m = re.fullmatch(r"/parts/(\d+)", path)
        if m and method == "GET":
            return self.part_page(int(m.group(1)), csrf)
        m = re.fullmatch(r"/parts/(\d+)/delete", path)
        if m and method == "POST":
            delete_part(int(m.group(1)))
            return self.redirect("/?msg=part-removed")
        self.render("Nicht gefunden", '<div class="notice err">Diese Seite gibt es nicht.</div>', csrf, 404)

    def render(self, title: str, body: str, csrf: str, status: int = 200) -> None:
        hidden = f'<input type="hidden" name="csrf" value="{esc(csrf)}">'
        self.send_html(status, page(title, body).replace("{csrf}", hidden))

    # ---- sign-in

    def login_page(self, error: str = "", status: int = 200) -> None:
        if not ADMIN_PASSWORD:
            note = '<div class="notice err">EAR_SPLIT_ADMIN_PASSWORD ist nicht gesetzt — Anmelden ist gesperrt.</div>'
        else:
            note = f'<div class="notice err">{esc(error)}</div>' if error else ""
        body = f"""
        <div class="login">{note}
          <form class="card pad" method="post" action="/login">
            <input type="text" name="username" value="{ADMIN_USER}" autocomplete="username" aria-label="Benutzer">
            <input type="password" name="password" autocomplete="current-password" placeholder="Passwort" aria-label="Passwort" autofocus>
            <button>Anmelden</button>
          </form>
        </div>"""
        self.send_html(status, page("EAR Split", body, nav=False))

    def login_submit(self) -> None:
        ip = self.client_ip()
        if login_blocked(ip):
            return self.login_page("Zu viele Versuche — in einer Viertelstunde wieder.", 429)
        raw = self.read_body(MAX_FORM)
        if raw is None:
            return
        form = {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace")).items()}
        user_ok = hmac.compare_digest(form.get("username", "").strip().encode(), ADMIN_USER.encode())
        pass_ok = bool(ADMIN_PASSWORD) and hmac.compare_digest(form.get("password", "").encode(), ADMIN_PASSWORD.encode())
        if not (user_ok and pass_ok):
            login_failed(ip)
            log.warning("failed admin sign-in from %s", ip)
            time.sleep(1)
            return self.login_page("Benutzer oder Passwort falsch.", 401)
        token, _ = create_session()
        log.info("admin signed in from %s", ip)
        self.redirect("/", {"Set-Cookie": self.session_cookie(token, SESSION_HOURS * 3600)})

    # ---- pages

    def dashboard(self, csrf: str, new_key: tuple[str, str] | None = None, error: str = "") -> None:
        hidden = f'<input type="hidden" name="csrf" value="{esc(csrf)}">'
        msg = {"key-removed": "Schlüssel entfernt — er gilt ab sofort nicht mehr.",
               "part-removed": "Teil gelöscht."}.get(self.query().get("msg", ""))
        notices = ""
        if msg:
            notices += f'<div class="notice ok">{esc(msg)}</div>'
        if error:
            notices += f'<div class="notice err">{esc(error)}</div>'
        if new_key:
            notices += (f'<div class="notice ok"><b>Neuer Schlüssel „{esc(new_key[0])}“</b> — nur jetzt sichtbar, '
                        f'gleich in die App eintragen:<div class="key"><code>{esc(new_key[1])}</code></div></div>')

        keys = list_keys()
        key_rows = "".join(f"""
            <div class="row"><div class="main"><b>{esc(k['name'])}</b>
              <div class="muted"><code>{esc(k['prefix'])}…</code> · angelegt {fmt_time(k['created_at'])}
              · zuletzt benutzt {fmt_time(k['last_used_at'])}</div></div>
              <form class="inline" method="post" action="/keys/{k['id']}/delete">{hidden}
                <button class="quiet" onclick="return confirm('Schlüssel entfernen?')">Entfernen</button></form>
            </div>""" for k in keys) or '<div class="empty">Noch kein Schlüssel — ohne Schlüssel kann die App nichts senden oder laden.</div>'

        parts = list_parts(days=MAX_DAYS)
        part_rows = "".join(f"""
            <tr><td>{fmt_day(p['day'])}</td>
              <td><a href="/parts/{p['id']}" style="color:var(--accent)">{esc(p['tour'])}</a></td>
              <td>{'P' + str(p['person']) if p['person'] else '–'}</td>
              <td>{p['stops']}</td><td class="muted">{fmt_time(p['created_at'])}</td></tr>""" for p in parts)
        parts_html = (f'<table><tr><th>Tag</th><th>Tour</th><th>Person</th><th>Stopps</th><th>Gesendet</th></tr>{part_rows}</table>'
                      if parts else '<div class="empty">Noch nichts gesendet.</div>')

        body = f"""{notices}
        <h2>API-Schlüssel</h2>
        <div class="card">{key_rows}</div>
        <form class="card pad flex" method="post" action="/keys" style="margin-top:10px">{hidden}
          <input type="text" name="name" placeholder="Name, z. B. iPhone privat" maxlength="80" required>
          <button>Anlegen</button>
        </form>
        <h2>Gesendete Teile · {len(parts)}</h2>
        <div class="card pad">{parts_html}</div>"""
        self.render("EAR Split", body, csrf)

    def part_page(self, part_id: int, csrf: str) -> None:
        row = get_part(part_id)
        if not row:
            return self.render("Nicht gefunden", '<div class="notice err">Diesen Teil gibt es nicht.</div>', csrf, 404)
        hidden = f'<input type="hidden" name="csrf" value="{esc(csrf)}">'
        part = json.loads(row["body"])
        stops = [s for p in part.get("persons", []) for s in p.get("stops", [])]
        lines = "".join(f"""
            <tr><td>{i}</td><td><b>{esc(s.get('name'))}</b></td>
              <td>{esc(s.get('address'))}{', ' + esc(s.get('plz')) if s.get('plz') else ''}</td>
              <td>{esc(s.get('stockwerk') or '')}</td><td>{esc(s.get('notiz') or '')}</td></tr>"""
                        for i, s in enumerate(stops, 1))
        title = f"{row['tour']}" + (f" · P{row['person']}" if row["person"] else "")
        body = f"""
        <p class="muted">{fmt_day(row['day'])} · {row['stops']} Stopps · gesendet {fmt_time(row['created_at'])} · ID {row['id']}</p>
        <div class="card pad"><table><tr><th>#</th><th>Kunde</th><th>Adresse</th><th>Stock</th><th>Notiz</th></tr>{lines}</table></div>
        <h2>JSON</h2>
        <pre>{esc(json.dumps(part, ensure_ascii=False, indent=2))}</pre>
        <form method="post" action="/parts/{row['id']}/delete" style="margin-top:16px">{hidden}
          <button style="background:var(--danger)" onclick="return confirm('Teil löschen?')">Teil löschen</button></form>"""
        self.render(title, body, csrf)

    def docs(self, csrf: str) -> None:
        try:
            text = README.read_text(encoding="utf-8")
        except OSError:
            text = "README.md fehlt."
        self.render("API", f'<div class="card pad docs">{markdown(text)}</div>', csrf)


def markdown(text: str) -> str:
    """Just enough Markdown for README.md: headings, paragraphs, lists, code."""
    out, para, in_code, in_list = [], [], False, False

    def inline(s: str) -> str:
        s = esc(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)

    def flush():
        nonlocal in_list
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()
        if in_list:
            out.append("</ul>")
            in_list = False

    code: list[str] = []
    for line in text.splitlines():
        if line.startswith("```"):
            if in_code:
                out.append("<pre>" + esc("\n".join(code)) + "</pre>")
                code, in_code = [], False
            else:
                flush()
                in_code = True
            continue
        if in_code:
            code.append(line)
        elif m := re.match(r"^(#{1,3}) (.*)", line):
            flush()
            level = {1: 3, 2: 3, 3: 4}[len(m.group(1))]
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
        elif m := re.match(r"^[-*] (.*)", line):
            if para:
                out.append("<p>" + inline(" ".join(para)) + "</p>")
                para.clear()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(m.group(1))}</li>")
        elif not line.strip():
            flush()
        else:
            para.append(line.strip())
    flush()
    return "\n".join(out)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not ADMIN_PASSWORD:
        log.warning("EAR_SPLIT_ADMIN_PASSWORD is not set — the admin UI cannot be signed in to.")
    init_db()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log.info("EAR Split API on port %s, data in %s", PORT, DATA_DIR)
    server.serve_forever()


if __name__ == "__main__":
    main()
