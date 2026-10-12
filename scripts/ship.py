"""Deployt die Web-Version (legacy-web/) auf Venvy: legt die App beim ersten Mal an, danach
Dateien hochladen + Neustart. Venvy baut das Rust-Projekt auf dem Server selbst.

    python3 scripts/ship.py login     einmalig anmelden (Passwort wird abgefragt, nie gespeichert)
    python3 scripts/ship.py           deployen
    python3 scripts/ship.py publish ear.ringtwo.win    öffentlich erreichbar machen (Cloudflare-Tunnel)
    python3 scripts/ship.py admin-password             Passwort des admin-Kontos setzen (wird abgefragt)
    python3 scripts/ship.py logout

Gespeichert wird nur die Venvy-Sitzung (30 Tage, verlängert sich bei Nutzung) in ~/.config/venvy/.
Nur Standardbibliothek – läuft ohne .venv.
"""
import argparse
import getpass
import http.cookiejar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / "legacy-web"          # das, was auf den Server kommt
BASE = os.getenv("VENVY_URL", "https://venvy.ringtwo.win").rstrip("/")
APP_NAME = os.getenv("VENVY_APP", "ear-router")
SESSION_FILE = Path.home() / ".config" / "venvy" / (urllib.parse.urlparse(BASE).netloc.replace(":", "_") + ".json")

# Was nicht auf den Server gehört (alles andere = `git ls-files`).
SKIP = ("input.css", "tailwind.config.js")
UPLOAD_BATCH = 15


class ApiError(Exception):
    def __init__(self, status: int, detail):
        super().__init__(f"HTTP {status}: {detail}")
        self.status, self.detail = status, detail


class Venvy:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.auth_key = None

    # ---- Sitzung

    def cookie(self, name: str) -> str | None:
        return next((c.value for c in self.jar if c.name == name), None)

    def set_cookie(self, name: str, value: str) -> None:
        host = urllib.parse.urlparse(BASE).hostname
        self.jar.set_cookie(http.cookiejar.Cookie(
            0, name, value, None, False, host, False, False, "/", True,
            BASE.startswith("https"), None, False, None, None, {}))

    def save(self) -> None:
        SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
        SESSION_FILE.touch(mode=0o600, exist_ok=True)
        SESSION_FILE.chmod(0o600)
        SESSION_FILE.write_text(json.dumps({"session": self.cookie("session"), "auth_key": self.auth_key}))

    def load(self) -> bool:
        try:
            data = json.loads(SESSION_FILE.read_text())
        except (OSError, ValueError):
            return False
        if not data.get("session") or not data.get("auth_key"):
            return False
        self.set_cookie("session", data["session"])
        self.auth_key = data["auth_key"]
        return True

    # ---- HTTP

    def call(self, method: str, path: str, body=None, form: dict | None = None, files: list | None = None):
        """body = JSON; form/files = multipart (files: [(feld, dateiname, bytes)])."""
        headers = {"Accept": "application/json", "User-Agent": "ear-router-ship"}
        data = None
        if form is not None or files is not None:
            boundary = uuid.uuid4().hex
            parts = []
            for k, v in (form or {}).items():
                parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
            for field, filename, content in files or []:
                parts.append(
                    f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
                    f"Content-Type: application/octet-stream\r\n\r\n".encode() + content + b"\r\n")
            data = b"".join(parts) + f"--{boundary}--\r\n".encode()
            headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if self.auth_key:
            headers["X-Venvy-Key"] = self.auth_key
        if method != "GET":
            if not self.cookie("csrf_token"):
                self.call("GET", "/api/health")          # setzt das csrf_token-Cookie
            headers["X-CSRF-Token"] = self.cookie("csrf_token") or ""
        req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
        try:
            with self.http.open(req, timeout=120) as res:
                raw = res.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                detail = json.loads(raw).get("detail")
            except (ValueError, AttributeError):
                detail = raw[:300].decode("utf-8", "replace")
            if e.status == 429 and e.headers.get("X-Retry-After"):
                wait = int(float(e.headers["X-Retry-After"])) + 1
                if wait <= 70 and path != "/api/auth/login":
                    print(f"  Rate-Limit, warte {wait}s …")
                    time.sleep(wait)
                    return self.call(method, path, body, form, files)
            raise ApiError(e.status, detail) from None
        return json.loads(raw) if raw else None

    def job(self, job_id: str, what: str, timeout: int = 900):
        """Hintergrund-Job abwarten und dessen Ergebnis zurückgeben."""
        end = time.time() + timeout
        while time.time() < end:
            j = self.call("GET", f"/api/jobs/{job_id}")
            if j["status"] == "done":
                return j.get("result")
            if j["status"] == "error":
                sys.exit(f"✗ {what} fehlgeschlagen: {j.get('error')}")
            time.sleep(2)
        sys.exit(f"✗ {what}: Zeitüberschreitung.")


# ---------------------------------------------------------------- Befehle

def login() -> None:
    v = Venvy()
    print(f"Anmelden bei {BASE}")
    body = {"username": input("Benutzer: ").strip(), "password": getpass.getpass("Passwort: ")}
    try:
        try:
            res = v.call("POST", "/api/auth/login", body)
        except ApiError as e:
            if e.status != 403 or e.detail != "totp_required":
                raise
            res = v.call("POST", "/api/auth/login", {**body, "totp_code": input("2FA-Code: ").strip()})
    except ApiError as e:
        sys.exit(f"✗ Anmeldung fehlgeschlagen ({e})")
    v.auth_key = res["auth_key"]
    v.save()
    print(f"✓ Angemeldet als {res['username']} ({res['role']}). Sitzung gespeichert in {SESSION_FILE}")


def logout() -> None:
    v = Venvy()
    if v.load():
        try:
            v.call("POST", "/api/auth/logout")
        except ApiError:
            pass
    SESSION_FILE.unlink(missing_ok=True)
    print("✓ Abgemeldet.")


def tracked_files() -> list[str]:
    out = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True)   # relativ zu legacy-web/
    return [f for f in out.splitlines() if not f.startswith(SKIP) and (ROOT / f).is_file()]


def pick_port(v: Venvy) -> int | None:
    """Freien Port aus /api/system/ports (Form der Antwort ist nicht dokumentiert → tolerant lesen)."""
    try:
        ports = v.call("GET", "/api/system/ports")
    except ApiError:
        return None
    if isinstance(ports, dict):
        for key, value in ports.items():
            if "recommend" in key.lower() or "free" in key.lower() or "suggest" in key.lower():
                nums = [p for p in (value if isinstance(value, list) else [value]) if isinstance(p, int)]
                if nums:
                    return nums[0]
    return None


def find_app(v: Venvy) -> dict | None:
    return next((a for a in v.call("GET", "/api/apps") if a["name"] == APP_NAME or a["slug"] == APP_NAME), None)


# Was die App auf dem Server braucht. Nur beim Anlegen gesetzt – spätere Deploys fassen die
# Umgebungsvariablen nicht mehr an.
def app_env(app: dict, port: int) -> dict:
    return {
        "PORT": str(port),
        "EAR_PORT": str(port),
        # Die Datenbank neben dem Code, nicht im Build-Ordner: Uploads löschen nie etwas,
        # ein `cargo clean` schon.
        "EAR_DATA_DIR": f"{app['app_dir']}/data",
        # Der OSRM-Server ist von überall über den Tunnel erreichbar.
        "EAR_OSRM_URL": "https://osrm.ringtwo.win",
        # Hinter cloudflared: die Adresse des Fahrers steht im X-Forwarded-For.
        "EAR_TRUST_PROXY": "1",
    }


def create_app(v: Venvy, port: int | None) -> dict:
    print(f"• App „{APP_NAME}“ gibt es noch nicht – wird angelegt …")
    res = v.call("POST", "/api/apps/upload", form={
        "name": APP_NAME, "runtime": "rust", "entrypoint": "",
        "start_on_boot": "true", "restart_policy": "on-failure",
    }, files=[("requirements", "Cargo.toml", (ROOT / "Cargo.toml").read_bytes())])
    app = v.job(res["job_id"], "App anlegen")
    port = port or app.get("port") or pick_port(v)
    if not port:
        sys.exit("✗ Kein freier Port ermittelbar – bitte mit --port angeben (App ist angelegt, einfach nochmal starten).")
    v.call("PUT", f"/api/apps/{app['id']}", {"port": port, "manual_ports": [port], "env_vars": app_env(app, port)})
    print(f"  angelegt (id {app['id']}, Port {port}).")
    return find_app(v)


def ensure_port(v: Venvy, app: dict, port: int | None) -> None:
    """Falls ein früherer Lauf nach dem Anlegen abgebrochen ist: Port/PORT nachtragen."""
    if app.get("port") and not port:
        return
    port = port or pick_port(v)
    if not port:
        sys.exit("✗ Die App hat noch keinen Port – bitte mit --port angeben.")
    if app.get("env_unreadable"):
        sys.exit("✗ Umgebungsvariablen der App sind nicht lesbar (Venvy-Schlüssel) – bitte im Panel prüfen.")
    env = json.loads(app.get("env_json") or "{}")
    v.call("PUT", f"/api/apps/{app['id']}", {"port": port, "manual_ports": [port], "env_vars": {**app_env(app, port), **env, "PORT": str(port), "EAR_PORT": str(port)}})
    print(f"• Port {port} gesetzt.")


def upload(v: Venvy, app_id: int) -> None:
    files = tracked_files()
    print(f"• Lade {len(files)} Dateien hoch …")
    for i in range(0, len(files), UPLOAD_BATCH):
        batch = [("files", f, (ROOT / f).read_bytes()) for f in files[i:i + UPLOAD_BATCH]]
        res = v.call("POST", f"/api/apps/{app_id}/files/upload", form={"path": ""}, files=batch)
        if res.get("skipped"):
            sys.exit(f"✗ Nicht hochgeladen: {res['skipped']}")


def restart(v: Venvy, app: dict) -> dict:
    action = "restart" if app["status"] in ("running", "starting") else "start"
    print(f"• {action} …")
    v.call("POST", f"/api/apps/{app['id']}/control?action={action}")
    started = time.time()
    end = time.time() + 1200                    # der erste Build auf dem Server dauert Minuten
    while time.time() < end:
        time.sleep(4)
        app = find_app(v)
        if app["status"] == "running":
            time.sleep(4)                       # stürzt es direkt wieder ab?
            app = find_app(v)
            if app["status"] == "running":
                return app
        # Ein Build, der scheitert, lässt die App nach dem Start wieder auf „stopped“ fallen.
        if app["status"] == "error" or (app["status"] == "stopped" and time.time() > started + 30):
            break
    logs = v.call("GET", f"/api/apps/{app['id']}/logs?lines=40")["content"]
    sys.exit(f"✗ App läuft nicht (Status: {app['status']}). Letzte Log-Zeilen:\n{logs}")


def deploy(port: int | None) -> None:
    v = Venvy()
    if not v.load() or not v.call("GET", "/api/auth/status").get("authenticated"):
        sys.exit("✗ Nicht bei Venvy angemeldet. Einmal ausführen:  python3 scripts/ship.py login")
    v.save()
    app = find_app(v)
    if app and app["status"] == "installing":
        sys.exit("✗ Die App wird gerade noch installiert – gleich nochmal versuchen.")
    if not app:
        app = create_app(v, port)
    else:
        ensure_port(v, app, port)
    upload(v, app["id"])
    app = restart(v, app)
    print(f"✓ Läuft: {app.get('access_url') or app.get('local_url')}  (Venvy-App #{app['id']}, {BASE})")


def publish(hostname: str | None) -> None:
    """App über den Cloudflare-Tunnel unter `hostname` veröffentlichen (HTTPS)."""
    if not hostname:
        sys.exit("✗ Hostname fehlt:  python3 scripts/ship.py publish beispiel.de")
    v = Venvy()
    if not v.load() or not v.call("GET", "/api/auth/status").get("authenticated"):
        sys.exit("✗ Nicht bei Venvy angemeldet. Einmal ausführen:  python3 scripts/ship.py login")
    app = find_app(v)
    if not app or not app.get("port"):
        sys.exit("✗ Die App gibt es noch nicht – zuerst deployen:  python3 scripts/ship.py")
    query = urllib.parse.urlencode({"hostname": hostname, "local_port": app["port"]})
    print(f"• Prüfe {hostname} → Port {app['port']}: {v.call('GET', f'/api/apps/{app['id']}/tunnel/check?{query}')}")
    res = v.call("POST", f"/api/apps/{app['id']}/tunnel/publish", {"hostname": hostname, "local_port": app["port"]})
    v.call("PUT", f"/api/apps/{app['id']}", {"url_source_pref": "public"})
    print(f"✓ Veröffentlicht: {res.get('url') or 'https://' + hostname}")


def admin_password() -> None:
    """Setzt EAR_ADMIN_PASSWORD auf Venvy und startet die App neu. Das Passwort wird abgefragt,
    steht also in keiner Datei und in keiner Shell-History."""
    v = Venvy()
    if not v.load() or not v.call("GET", "/api/auth/status").get("authenticated"):
        sys.exit("✗ Nicht bei Venvy angemeldet. Einmal ausführen:  python3 scripts/ship.py login")
    app = find_app(v)
    if not app:
        sys.exit("✗ Die App gibt es noch nicht – zuerst deployen:  python3 scripts/ship.py")
    if app.get("env_unreadable"):
        sys.exit("✗ Umgebungsvariablen der App sind nicht lesbar (Venvy-Schlüssel) – bitte im Panel prüfen.")
    password = getpass.getpass("Neues Passwort für das admin-Konto der App: ")
    if len(password) < 6 or password != getpass.getpass("Noch einmal: "):
        sys.exit("✗ Zu kurz (mindestens 6 Zeichen) oder die beiden Eingaben stimmen nicht überein.")
    env = json.loads(app.get("env_json") or "{}")
    v.call("PUT", f"/api/apps/{app['id']}", {"env_vars": {**env, "EAR_ADMIN_PASSWORD": password}})
    restart(v, find_app(v))
    print("✓ Gesetzt. Die App übernimmt es beim Start.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="EAR Router (Web) auf Venvy deployen")
    ap.add_argument("command", nargs="?", default="deploy", choices=["deploy", "login", "logout", "publish", "admin-password"])
    ap.add_argument("hostname", nargs="?", help="nur für publish")
    ap.add_argument("--port", type=int, help="Port der App (nur nötig, wenn Venvy keinen vorschlägt)")
    args = ap.parse_args()
    try:
        {"login": login, "logout": logout, "publish": lambda: publish(args.hostname), "admin-password": admin_password}.get(args.command, lambda: deploy(args.port))()
    except ApiError as e:
        if e.status == 401:
            sys.exit("✗ Venvy-Sitzung abgelaufen. Neu anmelden:  python3 scripts/ship.py login")
        sys.exit(f"✗ Venvy: {e}")
    except urllib.error.URLError as e:
        sys.exit(f"✗ Venvy nicht erreichbar: {e.reason}")
