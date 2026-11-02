#!/usr/bin/env python3
"""Builds ios/EarRouter/Resources/WienTempolimits.deflate: the posted speed
limit of every Viennese road OpenStreetMap has a number for, which the in-app
guidance draws as a sign.

Reads a Vienna extract rather than asking Overpass, which is too slow and too
flaky for 50 000 roads (502s, 40 s per small tile). Needs pyosmium
(`pip install osmium`) and the extract:

    curl -O https://download.bbbike.org/osm/bbbike/Wien/Wien.osm.pbf
    python3 scripts/fetch_speed_limits.py Wien.osm.pbf

Format (raw DEFLATE of compact JSON): [[forward_kmh, backward_kmh, [lat, lon,
lat, lon, ...]], ...] with five decimals; null where a direction has no number.
"""
import json, os, sys, zlib
import osmium

OUT = os.path.join(os.path.dirname(__file__), "..", "ios", "EarRouter", "Resources",
                   "WienTempolimits.deflate")


def kmh(raw):
    if raw is None:
        return None
    raw = raw.strip().lower()
    named = {"at:urban": 50, "at:rural": 100, "at:motorway": 130}
    if raw in named:
        return named[raw]
    parts = raw.split()
    try:
        n = int(parts[0])
    except (ValueError, IndexError):
        return None
    if not 0 < n <= 200:
        return None
    return round(n * 1.609) if len(parts) > 1 and parts[1] == "mph" else n


class Roads(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.out = []

    def way(self, w):
        t = w.tags
        if "highway" not in t:
            return
        base = kmh(t.get("maxspeed"))
        f = kmh(t.get("maxspeed:forward")) or base
        b = kmh(t.get("maxspeed:backward")) or base
        if f is None and b is None:
            return
        flat = []
        for n in w.nodes:
            if not n.location.valid():
                return
            flat += [round(n.location.lat, 5), round(n.location.lon, 5)]
        if len(flat) >= 4:
            self.out.append([f, b, flat])


if len(sys.argv) != 2:
    sys.exit(__doc__)
roads = Roads()
roads.apply_file(sys.argv[1], locations=True)
raw = json.dumps(roads.out, separators=(",", ":")).encode()
z = zlib.compressobj(9, zlib.DEFLATED, -15)
packed = z.compress(raw) + z.flush()
open(OUT, "wb").write(packed)
print(f"{len(roads.out)} roads, {len(raw) // 1024} KB -> {len(packed) // 1024} KB at {OUT}")
