# EAR Split API

Keeps the parts of a split tour ("Tour aufteilen" in the iOS app): one phone sends a person's part ("An Server senden"), and another driver's phone loads it as its tour ("Vom Server laden"). Live at `https://ear-split-api.ringtwo.win`. It runs on Venvy as the app `ear-split-api` on port 3003.

## Access

- **API** (`/api/...`): every call needs an API key, sent as the header `X-Api-Key: <key>`. `Authorization: Bearer <key>` also works. Without a key, or with a wrong one, the server answers `401`.
- **Admin web UI** (`/`): sign in as `admin` with the password from `EAR_SPLIT_ADMIN_PASSWORD`. There you make and remove API keys, and look at or delete any part that was sent (from the list, or on the part's own page). A new key is shown only once, right after it is made; the server keeps only its hash. A removed key stops working at once.

After 10 failed sign-ins from one address within 15 minutes, sign-in is locked for that address for a quarter of an hour. A session lasts 12 hours.

## The part

The JSON the app sends: one person's stops, in the order they are driven.

```
{
"tour" : "VM 4 DO Vormittag",
"date" : "2026-11-06",
"persons" : [
  {
    "person" : 2,
    "stops" : [
      { "name" : "Fam. Gruber", "address" : "Gentzgasse 129/1", "plz" : "1180", "stockwerk" : "2", "notiz" : "Hund bellt",
        "paket" : "1x Menü A", "pakete" : 1, "telefon" : "+43 660 1234567", "lieferhinweis" : "Bitte läuten" },
      { "name" : "Herr Maier", "address" : "Hauptstraße 5", "plz" : "1210" }
    ]
  }
]
}
```

- `tour` (required): the portal tour's name.
- `date`: the day of the tour, `YYYY-MM-DD`. When missing, the server uses today in Vienna.
- `persons` (required): usually exactly one person. `person` counts from 1.
- `stops` (required, at least one): each stop needs `name` and `address`. `plz` is the postcode.
- `stockwerk` and `notiz` are the customer's **Globale Infos** (floor and standing note), included only when the sending phone has them. The receiving phone keeps them as its own Globale Infos for customers it knows nothing about yet.
- `paket`, `pakete` (number of parcels), `telefon` and `lieferhinweis` (the day's delivery note) are today's delivery, each only when known. The receiving phone puts them on the tour, so its Ladeliste and "Anrufen" work.

Limits: at most 400 stops, 1 MB per request, 2000 characters per text field.

## Endpoints

### GET /health

No key needed. Answers `{"ok": true}`.

### POST /api/parts

Stores a part (body: the part above). Answers `201` with its summary:

```
{ "id": 12, "tour": "VM 4 DO Vormittag", "date": "2026-11-06", "person": 2, "stops": 14, "created_at": "2026-11-06T06:41:03+00:00" }
```

`person` is `null` when the part holds more than one person. `created_at` is UTC.

### GET /api/parts

Lists summaries, newest first, at most 500.

- `?date=2026-11-06`: the parts of that day.
- `?days=30`: the parts of the last N days, today included (default 30, at most 400).

```
{ "parts": [ { "id": 12, "tour": "…", "date": "2026-11-06", "person": 2, "stops": 14, "created_at": "…" } ] }
```

### GET /api/parts/{id}

One part: its summary plus the part exactly as it was sent, under `part`.

```
{ "id": 12, "tour": "…", "date": "…", "person": 2, "stops": 14, "created_at": "…", "part": { "tour": "…", "date": "…", "persons": [ … ] } }
```

### DELETE /api/parts/{id}

Deletes a part. Answers `{"ok": true}`.

### Errors

Every error is JSON, with German text a driver can read: `{"detail": "…"}`.

- `400`: the part is not valid (the detail says why)
- `401`: no API key, or a wrong one
- `404`: no such part
- `413`: the body is larger than 1 MB

## Example

```
curl -H "X-Api-Key: $KEY" "https://ear-split-api.ringtwo.win/api/parts?date=2026-11-06"
```

## Running it

Standard library only (Python 3.11 or newer).

```
EAR_SPLIT_ADMIN_PASSWORD=… python3 server.py
```

- `PORT`: default 3003
- `EAR_SPLIT_ADMIN_PASSWORD`: without it, nobody can sign in to the web UI
- `EAR_SPLIT_DATA_DIR`: where `parts.db` lives (default `data/` next to the server)
- `EAR_SPLIT_TRUST_PROXY=1`: behind cloudflared, so the client address is read from `X-Forwarded-For` and the session cookie is marked Secure

Deploy from the repository root with `python3 scripts/ship_split.py`. Publish once with `python3 scripts/ship_split.py publish`. Set the admin password with `python3 scripts/ship_split.py admin-password`, which asks for it, so it is never written to a file.
