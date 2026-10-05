# Tools

`MakeAppIcon.swift` draws the app mark — the indigo ground and the white route
ending in a pin — straight from CoreGraphics, so the icon is source rather than
a binary someone has to re-open in a drawing program to change:

```bash
swift Tools/MakeAppIcon.swift EarRouter/Assets.xcassets/AppIcon.appiconset/AppIcon.png
swift Tools/MakeAppIcon.swift EarRouter/Assets.xcassets/AppMark.imageset/AppMark.png
```

Both files are the same 1024×1024 image: the app icon, and the copy the "Über"
screen shows.

`MakeRestrooms.py` builds the list of public toilets the map can show, from Vienna's open data (Stadt Wien — data.wien.gv.at, CC BY 4.0) and
the list behind öKlo's map (oeklo.at/map). Run it again to pick up toilets
that have been added or closed:

```bash
python3 Tools/MakeRestrooms.py EarRouter/Resources/Restrooms.json
```
