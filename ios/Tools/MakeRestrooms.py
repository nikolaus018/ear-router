#!/usr/bin/env python3
"""Builds EarRouter/Resources/Restrooms.json: the city's toilets and öKlo's.

    python3 Tools/MakeRestrooms.py EarRouter/Resources/Restrooms.json

Sources: "Öffentliche WC-Anlagen Standorte Wien", Stadt Wien — data.wien.gv.at
(CC BY 4.0), and the list behind öKlo's own map at oeklo.at/map, which covers
all of Austria and carries no opening hours: a compost toilet on a pavement
has no door to lock. Three things are done to the city's list on the way in,
and the second of them to öKlo's as well:

  * Opening hours, which the city writes as free text, become a table of
    minutes per weekday. A toilet whose hours cannot be read that way — a
    seasonal timetable, "Lokalöffnungszeiten", "Gesperrt" — is left out: a
    driver sent to a locked door is worse off than one sent 300 m further.
  * Each toilet is snapped to the nearest road a car may use (OSRM `nearest`)
    and the distance kept as `walk`. That is what tells a toilet on the kerb
    from one in the middle of the Donauinsel.
  * Pissoirs are left out. The driver does not want to be sent to one.
  * Everything the app does not read is dropped.
"""
import json
import re
import sys
import urllib.request

WFS = ("https://data.wien.gv.at/daten/geo?service=WFS&request=GetFeature&version=1.1.0"
       "&typeName=ogdwien:WCANLAGEOGD&srsName=EPSG:4326&outputFormat=json")
OEKLO = "https://d90ejx0yw4gor.cloudfront.net/public-toilet-map/toilets.json"
OSRM = ["https://osrm.ringtwo.win", "https://router.project-osrm.org"]
DAYS = {"mo": 0, "di": 1, "mi": 2, "do": 3, "fr": 4, "sa": 5, "so": 6}
PART = re.compile(
    r"(mo|di|mi|do|fr|sa|so)(?:\s*-\s*(mo|di|mi|do|fr|sa|so))?\s*:?\s*"
    r"(\d{1,2})(?:[.:](\d{2}))?\s*-\s*(\d{1,2})(?:[.:](\d{2}))?")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "EarRouter-Tools"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def hours(text):
    """(table, winter_closed), or None when the text is not a plain timetable.

    The table is seven [open, close] pairs in minutes, Monday first, `None` on
    a closed day — or `None` altogether for a toilet that never closes.
    """
    t = " ".join(text.lower().split())
    winter = "wintersperre" in t
    t = t.split("/")[0].replace("uhr", " ").strip()
    if re.search(r"jan|feb|mär|apr|mai|jun|jul|aug|sep|okt|nov|dez", t):
        return None
    table = [None] * 7
    rest = t
    for m in PART.finditer(t):
        a, b = DAYS[m[1]], DAYS[m[2] or m[1]]
        span = [int(m[3]) * 60 + int(m[4] or 0), int(m[5]) * 60 + int(m[6] or 0)]
        for d in range(a, b + 1):
            table[d] = span
        rest = rest.replace(m[0], "")
    if not any(table) or re.sub(r"[\s,+]", "", rest):
        return None
    if all(s == [0, 1440] for s in table):
        table = None
    return table, winter


def walk(lat, lon):
    for base in OSRM:
        try:
            r = fetch(f"{base}/nearest/v1/driving/{lon:.6f},{lat:.6f}?number=1")
            return round(r["waypoints"][0]["distance"])
        except Exception:
            continue
    raise SystemExit(f"no OSRM answered for {lat},{lon}")


def main(out):
    rows, skipped = [], []
    for f in fetch(WFS)["features"]:
        p = f["properties"]
        lon, lat = f["geometry"]["coordinates"]
        if p["KATEGORIE"] == "Pissoir":
            continue
        parsed = hours(p["OEFFNUNGSZEIT"] or "")
        if parsed is None:
            skipped.append(p["OEFFNUNGSZEIT"])
            continue
        table, winter = parsed
        name = " ".join(" ".join(str(x) for x in [p["STRASSE"], p["ONR"]] if x).split())
        row = {"name": name, "lat": round(lat, 6), "lon": round(lon, 6),
               "walk": walk(lat, lon)}
        if table:
            row["hours"] = table
        if winter:
            row["winterClosed"] = True
        rows.append(row)
    city = len(rows)
    for f in fetch(OEKLO)["features"]:
        lon, lat = f["geometry"]["coordinates"]
        name = re.sub(r",\s*Wien$", "", " ".join(f["properties"]["address"].split()))
        rows.append({"name": name, "lat": round(lat, 6), "lon": round(lon, 6),
                     "walk": walk(lat, lon), "oeklo": True})
    print(f"{city} from the city, {len(rows) - city} from öKlo")
    rows.sort(key=lambda r: (r["name"], r["lat"]))
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, ensure_ascii=False, separators=(",", ":"))
        fh.write("\n")
    print(f"{len(rows)} written, {len(skipped)} left out:")
    for s in sorted(set(skipped)):
        print("  ", repr(s))


if __name__ == "__main__":
    main(sys.argv[1])
