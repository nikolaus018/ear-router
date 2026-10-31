#!/usr/bin/env python3
"""Builds EarRouter/Resources/WienAdressen.deflate: Vienna's address register
and its entrance points, for the geocoder to fall back on when the city's
address service cannot be reached.

    python3 Tools/MakeAddressPack.py EarRouter/Resources/WienAdressen.deflate

Source: "Adressen Standorte Wien" (ogdwien:ADRESSENOGD) and "Zugangsadressen
Standorte Wien" (ogdwien:ZUGANGSADROGD), Stadt Wien — data.wien.gv.at
(CC BY 4.0). Both are fetched whole, in one request each.

The file is UTF-8 text, raw-deflated (what `NSData.decompressed(using: .zlib)`
reads), one tab-separated record per line:

    #   WienAdressen  1  <date fetched>
    A   <street>  <number as the register writes it>  <plz>  <lat>  <lon>
    E   <street>  <number as the entrance layer writes it>  <plz>  <lat>  <lon>

"A" rows are the register's own addresses, one per Stiege, Haus or Parzelle
where it has them ("129/1", "17 Haus 1", "9 Parz. 68"). "E" rows are the one
entrance point per house number. Run it again before a release to pick up
new buildings.
"""
import datetime
import json
import sys
import urllib.request
import zlib

WFS = ("https://data.wien.gv.at/daten/geo?service=WFS&request=GetFeature&version=1.1.0"
       "&srsName=EPSG:4326&outputFormat=json&typeName=ogdwien:")


def fetch(layer, fields=None):
    url = WFS + layer + (f"&propertyName={','.join(fields)}" if fields else "")
    req = urllib.request.Request(url, headers={"User-Agent": "EarRouter-Tools"})
    with urllib.request.urlopen(req, timeout=300) as r:
        data = json.load(r)
    features = data["features"]
    # The service says how many it has; a shorter answer is a cut-off
    # download, not a city that lost its houses.
    total = data.get("numberMatched") or data.get("totalFeatures")
    if total is not None and len(features) != total:
        sys.exit(f"{layer}: got {len(features)} of {total} features")
    return features


def clean(s):
    return " ".join((s or "").split())


def point(feature):
    lon, lat = feature["geometry"]["coordinates"]
    return f"{lat:.6f}", f"{lon:.6f}"


def main(out):
    rows = []
    for f in fetch("ADRESSENOGD", ["NAME_STR", "NAME_ONR_BST_GEB", "PLZ", "SHAPE"]):
        p = f["properties"]
        street, number, plz = clean(p["NAME_STR"]), clean(p["NAME_ONR_BST_GEB"]), clean(p["PLZ"])
        if street and number and plz:
            rows.append(("A", street, number, plz, *point(f)))
    addresses = len(rows)

    for f in fetch("ZUGANGSADROGD"):
        p = f["properties"]
        name, number, plz = clean(p["NAME"]), clean(p["NAME_ONR"]), clean(p["PLZ"])
        # "Riedelgasse gegenüber 22" with the number "gegenüber 22": the
        # street is what comes before the number.
        if not (name and number and plz and name.endswith(" " + number)):
            continue
        rows.append(("E", name[: -len(number)].strip(), number, plz, *point(f)))
    entrances = len(rows) - addresses

    # Half a register is a service having a bad day.
    if addresses < 250_000 or entrances < 130_000:
        sys.exit(f"implausibly short: {addresses} addresses, {entrances} entrances")

    rows.sort(key=lambda r: (r[1], r[3], r[0], r[2]))
    text = f"#\tWienAdressen\t1\t{datetime.date.today().isoformat()}\n"
    text += "".join("\t".join(r) + "\n" for r in rows)
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    blob = packer.compress(text.encode()) + packer.flush()
    with open(out, "wb") as fh:
        fh.write(blob)
    print(f"{addresses} addresses, {entrances} entrances, {len(blob) / 1e6:.1f} MB → {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "EarRouter/Resources/WienAdressen.deflate")
