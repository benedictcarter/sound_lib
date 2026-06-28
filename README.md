# Sound Library

A searchable, browsable catalog + audition tool for the **Sonniss GDC Game Audio
Bundles** (~7,000 WAV files, ~217 GB across 8 yearly bundles).

The audio itself lives **outside** this repo in `S:\code\sound_lib_data` (path is
configurable). The repo holds only the indexer and the Godot browser app.

```
sound_lib/
├─ indexer/index.py    Python — scans the library, builds app/index.json
├─ indexer/requirements.txt
├─ app/                Godot 4.6 project (the GUI)
│   ├─ main.gd         all UI + search/filter/sort/playback logic
│   ├─ main.tscn  project.godot  icon.svg
│   └─ index.json      GENERATED catalog (gitignored)
├─ library.cfg         path to the audio library root
└─ .gitignore          excludes audio + generated index
```

## 1. Configure the library location

Edit `library.cfg`:

```json
{ "library_root": "S:/code/sound_lib_data" }
```

If you move the audio (e.g. to an external drive), just update this path and
re-run the indexer — nothing else changes.

## 2. Build the index

```sh
py -m pip install -r indexer/requirements.txt   # one-time: openpyxl
py indexer/index.py                              # writes app/index.json
py indexer/index.py --full                       # ignore cache, re-parse all
```

What it captures per file:

| Field | Source |
|-------|--------|
| filename, path, bundle, size | filesystem |
| sample rate, bit depth, channels, duration | WAV `fmt`/`data` chunks |
| description | WAV `bext` (BWF) chunk, when present |
| library, supplier, url | per-bundle tracklist CSV/XLSX (folder names as fallback) |

Re-runs are incremental (unchanged files reuse the cached record), so a re-index
of the full library takes a few seconds.

## 3. Browse

Open `app/` in Godot 4.6 (`S:\code\godot\Godot_v4.6.3-stable_win64.exe`) and run,
or:

```sh
"S:/code/godot/Godot_v4.6.3-stable_win64.exe" --path app
```

- **Search** — type words; space-separated terms are AND-matched against
  filename, library, supplier and description.
- **Filter** — Bundle / Supplier / Library / Type dropdowns.
- **Sort** — click any column header (click again to reverse).
- **Audition** — select a row (autoplay) or double-click; transport bar has
  play/pause, stop, seek and volume. "Open folder" reveals the file on disk.
- **Rate** — click the stars directly in the **Rating** column (left-click a
  star to set 1-5, right-click to clear). The "Rate selected" bar at the bottom
  also works on the selected row. Sortable. (Clicking the Rating cell does not
  play the file.)
- **My Keywords** — your own tags per file. Double-click the cell to edit;
  separate keywords with spaces or commas. Stored with your other data and
  included in the search box, so you can find files by your own tags.
- **Plays** — auto-increments each time a track plays through to the end
  ("finished listening"); stopping early does not count. Sortable.
- **Keyword panel** (right side) — keywords mined from filenames + library
  names, sorted by frequency. The count is the number of distinct **libraries**
  a keyword appears in (tokens are de-duped within each library, so a big
  library can't inflate a word). Click a keyword to add it to the search box as
  an AND term (a quick filter); use "find keyword" to search the list itself.

### Your data (ratings + play counts + keywords)
Stored separately from the index in `app/userdata.json`, keyed by each file's
relative path — so it **survives re-indexing** and library moves. It's
gitignored by default (personal data); remove the `/app/userdata.json` line from
`.gitignore` if you'd rather version it.

> Preview supports WAV (the other 4 files are `.aif`); for those, use "Open
> folder".
