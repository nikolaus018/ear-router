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
