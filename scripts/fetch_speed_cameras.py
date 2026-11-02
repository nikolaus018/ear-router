#!/usr/bin/env python3
"""Writes ios/EarRouter/Resources/Blitzer.json: the fixed speed cameras and
section-control points OpenStreetMap knows around Vienna, as [[lat, lon,
limit_kmh_or_null], ...]. The in-app guidance warns before them.

    python3 scripts/fetch_speed_cameras.py
"""
import json, os, time, urllib.parse, urllib.request

UA = {"User-Agent": "EAR-Router-iOS/1.0 (local delivery route planner)"}
Q = ('[out:json][timeout:90];(node["highway"="speed_camera"](48.0,16.0,48.5,16.8);'
     'node["enforcement"="maxspeed"](48.0,16.0,48.5,16.8););out body;')
OUT = os.path.join(os.path.dirname(__file__), "..", "ios", "EarRouter", "Resources", "Blitzer.json")

for attempt in range(6):
    try:
        req = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                     data=("data=" + urllib.parse.quote(Q, safe="")).encode(), headers=UA)
        els = json.loads(urllib.request.urlopen(req, timeout=120).read())["elements"]
        break
    except Exception as ex:
        print("attempt", attempt + 1, "failed:", ex)
        time.sleep(10 * (attempt + 1))
else:
    raise SystemExit("Overpass did not answer")

rows = {}
for e in els:
    raw = e.get("tags", {}).get("maxspeed", "")
    kmh = int(raw) if raw.isdigit() and 0 < int(raw) <= 200 else None
    rows[e["id"]] = [round(e["lat"], 6), round(e["lon"], 6), kmh]
json.dump(sorted(rows.values()), open(OUT, "w"), separators=(",", ":"))
print(len(rows), "cameras ->", OUT)
