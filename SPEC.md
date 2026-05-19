# Apple Photos Exporter Specification

The goal of this project is to develop a CLI tool to export photos and videos from the Apple Photos library into individual files. The initial use case is doing backups. We are going to use the word asset to refer collectively to photos and videos.

The application will be a command line tool developed in Swift (currently version 6.2.3) targeting macOS 12 or later, using the PhotoKit Framework.

## Input parameters

The CLI will be run as follows:

```
<program name> [options] <date spec 1> [<date spec 2>]
```

Where `<date spec>` can be:
- `YYYY`: A year
- `YYYYMM`: A year and a month
- `YYYYMMDD`: A year month and a day.

If only `<date spec 1>` is provided, it means we want to export the assets on that year / month / day.
If both `<date spec 1>` and `<date spec 2>` the following validations are performed:
* They are both of the same resolution (e.g. year, month or day)
* `<date spec 2>` is higher or equal than `<date spec 1>`

If any of the validation fails and error is shown and the program exits. If the validations are correct, it means that the user wants to export every asset between the two dates, extremes inclusive.

### Options

The available options are:
* `--output <folder>`: Output folder. If not provided the current folder will be used as the output folder. The folder will be created if it does not exist.
* `--dry-run`: Shows the operation that would be performed, but does not write any file or create any folder.
* `--skip-existing`: If an output file already exists, skip it and log a message. This is the default behavior.
* `--overwrite`: If an output file already exists, overwrite it. Mutually exclusive with `--skip-existing`.
* `--max-concurrency <n>`: Maximum number of assets exported concurrently. Defaults to `4`.
* `--burst-all`: Export all frames in a burst sequence. By default only the key photo (the user or auto selected pick) is exported.
* `--utc`: Interpret date specifications in UTC instead of the local timezone.
* `--local-only`: Skip assets whose full-size original is not already stored locally, instead of downloading it from iCloud. Skipped assets are logged and counted in the final summary.

### Examples

**Export assets from a single year:**
```bash
aph-export 2023
```
*Result: Exports all assets from 2023 into `2023/2023MM/2023MMDD/` folders.*

**Export assets from a specific month to a custom folder:**
```bash
aph-export --output ~/Backups/Photos 202310
```
*Result: Exports all assets from October 2023 into `~/Backups/Photos/2023/202310/202310DD/` folders.*

**Export a range of days (dry run):**
```bash
aph-export --dry-run 20231027 20231029
```
*Result: Logs the planned export of assets from Oct 27, 28, and 29, 2023, without writing any files.*

**Invalid usage (mismatched resolution):**
```bash
aph-export 2023 202312
```
*Result: Program exits with an error because resolutions (Year vs Month) do not match.*

## Process

The goal of the program is to iterate through the assets included in the time specification provided and store them in a files inside a folder named `YYYY/YYYYMM/YYYYMMDD` relative to the output folder (creating folders as needed) where `YYYY`, `MM` and `DD` are respectiveley the year, month and day of the asset.

Date specifications are interpreted in the **local timezone** by default. Use `--utc` to interpret them in UTC instead. Note that PhotoKit stores asset timestamps internally as UTC, so the tool converts the date boundaries accordingly before filtering.

## Implementation Details

### Library Selection
The tool will interface with the **System Photo Library**. Support for other libraries (via path) is not required for the initial version.

### Concurrency Model
PhotoKit relies on asynchronous callbacks that require an active run loop. The tool must keep the main run loop alive (or use Swift structured concurrency via `async/await`) until all export operations have completed before exiting.

### Logging & Progress
The tool will provide verbose output to `stdout`:
- Every asset being processed will be logged with its source date and target path.
- Errors for individual assets will be logged but should not necessarily stop the entire process (best effort).
- A final summary of successful exports and errors will be shown at the end.

### Permissions
Since this is a macOS CLI tool using PhotoKit, it will require the user to grant "Photos" access. The tool should handle the authorization request gracefully or inform the user if access is denied.

If the user has granted **Limited** access, the tool will operate only on the assets it has been given permission to see. At startup, the tool will print a warning indicating that limited access is in effect, and the final summary will note that results may not include all assets in the specified date range.

### iCloud Downloads
When the local Photos library stores only an optimized (reduced-size) version of an asset, the tool will download the full-size original from iCloud before exporting. This is the default behavior in order to preserve full backup fidelity. Use `--local-only` to disable network access and skip any asset whose full-size original is not already stored locally.

### Formats
The tool will prioritize preservation and compatibility by exporting:
1.  **The Original:** The exact file as stored in the library (e.g., HEIC, ProRAW, MOV).
2.  **A Transcoded JPEG (for images):** If the original image is not a JPEG (e.g., HEIC or RAW), the tool will also export a transcoded JPEG version. This ensures the content can be viewed on devices or software that do not support modern or proprietary formats.

Transcoded JPEGs will follow the same naming convention but will have `.jpg` as the extension. Whether transcoding is needed is determined by the asset's uniform type identifier (UTI) as reported by `PHAssetResource`: if the UTI is `public.jpeg`, only the original is exported; otherwise a JPEG transcode is also produced.

Videos will be exported in their **original format only** (e.g., MOV, MP4) without transcoding.

### Burst Photos
For burst sequences, only the key photo is exported by default. The key photo is the frame marked as the user's pick, or the auto-selected pick if no user pick exists. Use `--burst-all` to export every frame in a burst sequence.

### Live Photos
Live Photos will be exported as two separate files:
1. The static image (typically HEIC or JPEG).
2. The associated video component (typically MOV).

Both files will share the same timestamped filename (see below) but retain their respective extensions.

### File Naming
To ensure uniqueness and chronological sorting, files will be named using the following pattern:
`YYYYMMDD_HHMMSS_<Original Filename>`

Example: `20231027_143005_IMG_1234.JPG`

If a collision occurs (unlikely with this naming scheme), the tool will append a numeric suffix **after the original filename part but before the extension** (e.g., `20231027_143005_IMG_1234_1.JPG`).

## Exit Codes

The tool exits with one of the following codes:

| Code | Meaning |
|------|---------|
| `0`  | All assets exported successfully. |
| `1`  | Export completed but one or more assets failed (best-effort run). |
| `2`  | Fatal error — no assets were exported (e.g., authorization denied, invalid arguments, output folder not writable). |
