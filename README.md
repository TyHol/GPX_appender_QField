# Experimental

# GPX Appender — QField Plugin

A [QField](https://qfield.org) plugin for importing GPX files into existing project layers and exporting layers back to GPX.

---

## Features

### Import
- **Recursive project folder scan** — all `.gpx` files in the project home and every sub-folder are listed in a dropdown automatically when the dialog opens
- **Browse** (Windows/desktop) — standard file picker as an alternative
- **Paste from clipboard** — paste raw GPX XML directly
- **Smart layer filtering** — only layers matching the GPX content type are offered:
  - Waypoints (`<wpt>`) → point layers
  - Tracks (`<trkseg>`) and routes (`<rte>`) → line layers
  - Attempting a mismatched import shows a clear message rather than silently creating wrong data
- **Field mapping** — choose which GPX tag populates each layer field; auto-matched by name, fully editable per import. Special sources **filename** and **foldername** let you stamp the GPX file name or its parent folder into any field
- **Elevation (Z)** — preserved from `<ele>` into Z-geometry layers; M (measure) values are correctly identified and not misread as elevation
- **CRS reprojection** — all coordinates are reprojected from WGS 84 to the destination layer CRS

### Export
- **Feature checklist** — choose which features to export; tick All or None at once
- **Label field** — pick which layer field is used as the checklist label
- **Saves to project GPX folder** — type a filename and the file is written to `<project>/GPX/<name>.gpx`; a project-root fallback is tried automatically if the GPX sub-folder does not exist
- **Optional specific location** — a file picker lets you save anywhere (note: locations outside the project folder may not be accessible on all devices)
- **Elevation (Z)** — written as `<ele>` for both waypoints and track points
- **XML-safe output** — attribute values containing `< > & "` are properly escaped

---

## Installation
<img width="543" height="532" alt="image" src="https://github.com/user-attachments/assets/4530c3b8-9579-4bd9-b8a3-f0c24461dc9c" />


## Usage

Tap the **GPX Appender** button in the plugins toolbar to open the dialog.

### Import

The dialog opens on the **File** tab. Three tabs organise the workflow:

| Tab | Purpose |
|---|---|
| **File** | Pick a file from the project folder dropdown, browse for one, or paste from clipboard |
| **Content** | View / edit the raw GPX XML; scroll to check what was loaded |
| **Field Map** | Assign a GPX source to each layer field; auto-populated from field names |

1. Select the **Destination layer**
2. On the **File** tab, choose a GPX file from the dropdown (refreshed automatically on open) or browse/paste
3. Review the **Field Map** tab and adjust any mappings
4. Tap **Import** (available on every tab)

#### GPX type → layer type rules

| GPX contains | Use layer type | Notes |
|---|---|---|
| `<wpt>` waypoints | Point | Each waypoint → one point feature |
| `<trk>` tracks | Line | Each track segment → one line feature |
| `<rte>` routes | Line | Each route → one line feature |
| Tracks + waypoints | Line | Waypoints are skipped (noted in status) |
| Tracks into point layer | — | Blocked — would create one point per vertex |
| Waypoints into line layer | — | Blocked — no geometry to build a line |

### Export

Tap **Export** at the top of the dialog.

1. Pick the **Layer to export**
2. Choose the **Label field** for the feature checklist (or leave on `(auto)`)
3. Tick the features to include; use **All** / **None** to select quickly
4. Enter a **File name** — saved to `<project>/GPX/<name>.gpx`
5. Optionally tap **Choose…** to save to a specific location
6. Tap **Export**

---

## Field mapping sources

| Source | Description |
|---|---|
| `(ignore)` | Field is left blank |
| `name` | `<name>` tag |
| `time` | `<time>` tag (ISO 8601) |
| `desc` | `<desc>` tag |
| `cmt` | `<cmt>` tag |
| `ele` | `<ele>` elevation in metres |
| `sat` | `<sat>` satellite count |
| `hdop` / `vdop` / `pdop` | Dilution of precision values |
| `sym` | `<sym>` waypoint symbol |
| `type` | `<type>` feature type |
| `fix` | `<fix>` fix type |
| `speed` | `<speed>` |
| `course` | `<course>` |
| `magvar` | `<magvar>` magnetic variation |
| `filename` | Name of the GPX file (without extension) |
| `foldername` | Name of the folder containing the GPX file |

---

## Requirements

- QField 3.x
- An open QGIS project with at least one editable Point or Line vector layer

---

## Known limitations

- Multi-polygon and polygon layers are not supported (GPX has no area geometry)
- M (measure) values cannot be represented in GPX and are discarded on export
- Saving to locations outside the project folder may not work on Android due to file-system sandboxing

---

## License

GPLv3

## Author

Tony Holmes — [github.com/TyHol](https://github.com/TyHol)
