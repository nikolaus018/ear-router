"""Deployt den Split-Server (split-server/) auf Venvy als App „ear-split-api“, Port 3003.

    python3 scripts/ship_split.py                  deployen (legt die App beim ersten Mal an)
    python3 scripts/ship_split.py publish          unter ear-split-api.ringtwo.win veröffentlichen
    python3 scripts/ship_split.py admin-password   Admin-Passwort setzen (wird abgefragt, nie gespeichert)

Nutzt die Venvy-Sitzung und den Client aus scripts/ship.py (dort: `login`).
"""
import argparse
import getpass
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ship  # noqa: E402

PORT = 3003
HOSTNAME = "ear-split-api.ringtwo.win"

ship.ROOT = ship.REPO / "split-server"
ship.APP_NAME = "ear-split-api"
ship.SKIP = ("data/",)


def app_env(app: dict, port: int) -> dict:
    return {
        "PORT": str(port),
        "EAR_SPLIT_DATA_DIR": f"{app['app_dir']}/data",
        "EAR_SPLIT_TRUST_PROXY": "1",
    }


def create_app(v: "ship.Venvy", port: int | None) -> dict:
    print(f"• App „{ship.APP_NAME}“ gibt es noch nicht – wird angelegt …")
    res = v.call("POST", "/api/apps/upload", form={
        "name": ship.APP_NAME, "runtime": "python", "entrypoint": "server.py",
        "start_on_boot": "true", "restart_policy": "on-failure",
    }, files=[("requirements", "requirements.txt", (ship.ROOT / "requirements.txt").read_bytes())])
    app = v.job(res["job_id"], "App anlegen")
    port = port or PORT
    v.call("PUT", f"/api/apps/{app['id']}", {
        "port": port, "manual_ports": [port], "entrypoint": "server.py", "env_vars": app_env(app, port)})
    print(f"  angelegt (id {app['id']}, Port {port}).")
    return ship.find_app(v)


ship.app_env = app_env
ship.create_app = create_app


def session() -> "ship.Venvy":
    v = ship.Venvy()
    if not v.load() or not v.call("GET", "/api/auth/status").get("authenticated"):
        sys.exit("✗ Nicht bei Venvy angemeldet. Einmal ausführen:  python3 scripts/ship.py login")
    return v


def admin_password() -> None:
    v = session()
    app = ship.find_app(v)
    if not app:
        sys.exit("✗ Die App gibt es noch nicht – zuerst deployen:  python3 scripts/ship_split.py")
    if app.get("env_unreadable"):
        sys.exit("✗ Umgebungsvariablen der App sind nicht lesbar (Venvy-Schlüssel) – bitte im Panel prüfen.")
    password = getpass.getpass("Neues Admin-Passwort für den Split-Server: ")
    if len(password) < 10 or password != getpass.getpass("Noch einmal: "):
        sys.exit("✗ Zu kurz (mindestens 10 Zeichen) oder die beiden Eingaben stimmen nicht überein.")
    env = json.loads(app.get("env_json") or "{}")
    v.call("PUT", f"/api/apps/{app['id']}", {"env_vars": {**env, "EAR_SPLIT_ADMIN_PASSWORD": password}})
    ship.restart(v, ship.find_app(v))
    print(f"✓ Gesetzt. Anmelden unter https://{HOSTNAME} als „admin“.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="EAR Split API auf Venvy deployen")
    ap.add_argument("command", nargs="?", default="deploy", choices=["deploy", "publish", "admin-password"])
    args = ap.parse_args()
    try:
        if args.command == "publish":
            ship.publish(HOSTNAME)
        elif args.command == "admin-password":
            admin_password()
        else:
            ship.deploy(PORT)
    except ship.ApiError as e:
        sys.exit(f"✗ {e}")
