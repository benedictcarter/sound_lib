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
  play/pause, stop, seek and volume. **Space** toggles play/pause from anywhere
  (except while typing in a text field). Tick **Loop** to replay the current
  track seamlessly. "Open folder" reveals the file on disk.
- **Rate** — click the stars directly in the **Rating** column (left-click a
  star to set 1-5, right-click to clear). Hovering the cell shows a gold preview
  of the rating that a click will apply. The "Rate selected" bar at the bottom
  also works on the selected row. Sortable. (Clicking the Rating cell does not
  play the file.)
- **Resize columns** — drag the divider between column headers. The horizontal-
  resize cursor appears when you hover a divider.

### Gap analysis / "Sounds" (how many sounds are in a file)
Long files often contain several sounds separated by silence. The analyser
counts them and previews where it would chop.

- **Just click a row** — it auto-analyses and draws the picture (no button
  press). The graph paints the kept **sounds in green**, the **dead space that
  would be chopped out in black**, the **chop start/stop of each piece in blue**,
  the silence threshold (orange line, labelled with its **dB** value) and a white
  playback cursor. (The **Analyse selected** button still works.)
- **Click or drag on the graph** to set the silence threshold to that level —
  the chop pieces recompute live and the file's chop columns update.
- Tune live: **Silence** (what counts as silence, default −60 dBFS), **Min gap**
  (how long a silence must be, default 1.5 s) and **Min sound** (ignore blips).
  **Suggest** picks a threshold from the file's own loudness histogram.
  Changing Silence/gap on the analysed file saves to its chop columns.
- **Save count** writes the result to the **Sounds** column.
- To fill the column for the whole library at once:
  `py indexer/analyze.py` (reads all audio; incremental on re-runs).

### Chop suggestions ("Chop dB" / "Chop gap" columns)
- Click **Suggest missing chops** (in the analyser bar) to fill the columns for
  every file that has no chop config yet — it runs the analyser over those files
  in the background and the columns fill in live as it goes. (Equivalent CLI:
  `py indexer/suggest_chops.py`.) Both write `chopping.json` beside the audio.
- Files it judges **continuous** get no settings (blank columns — nothing to
  chop).
- **Chop dB** / **Chop gap** / **Min snd** are **editable**: double-click to
  refine the silence threshold, min-gap, or min-sound for a file (the same three
  knobs as the analyser sliders). **Chop pieces** (read-only) shows how many
  pieces the file chops into at those settings (continuous = 1; blank until
  analysed). Editing the file currently in the analyser recounts live.

### Auditioning and chopping
- **Play chops** plays each detected piece in turn with **1 second of silence
  between them**, so the chop boundaries are audibly obvious.
- **Chop to files** writes each piece as `<name>_chopped_NNN.wav` **next to the
  original** (the original is **kept**), preserving bit depth. It chops exactly
  the pieces shown (the blue boundaries), then **adds the new files to the
  library immediately** (incrementally — no full re-scan, no restart). They
  inherit the parent's bundle/library/supplier **and your tags**, so you can
  play, rate, retag, and even chop *them* straight away like any other file.

Detection lives in `indexer/gaps.py` and is mirrored in the app (GDScript) so
the sliders respond instantly. `analysis.json` / `chopping.json` (in the library
root) store the counts and chop params.
- **Tags** — your own keywords per file. Double-click the cell to edit;
  separate keywords with spaces or commas. Stored with your other data and
  included in the search box, so you can find files by your own tags.
  Spreadsheet-style selection + editing works on the **Tags** and **Vol×**
  columns (whichever your selected cells are in): **drag** to select a range;
  **Shift+drag** adds another range; **Ctrl+drag** (or Ctrl+click) toggles cells
  (Ctrl over an already-selected cell deselects it). Then **Ctrl+C** copies /
  **Ctrl+V** pastes (via the OS clipboard, so Excel works too); **Del** clears;
  and just **start typing** to overwrite all selected cells at once — **Enter**
  or click away to apply (and deselect), **Esc** to cancel.
- **Plays** — auto-increments each time a track plays through to the end
  ("finished listening"); stopping early does not count. Sortable.
- **Vol×** — a per-track playback gain multiplier (double-click to edit; must be
  > 0, e.g. `0.1` to quieten or `10` to boost). It multiplies that track's
  volume on top of the global **Vol** slider (which stays a plain 0–1 control and
  is unaffected). Blank = 1 (unchanged). Stored with your user data.
- **Keyword panel** (right side) — keywords mined from filenames + library
  names, sorted by frequency. The count is the number of distinct **libraries**
  a keyword appears in (tokens are de-duped within each library, so a big
  library can't inflate a word). Click a keyword to add it to the search box as
  an AND term (a quick filter); use "find keyword" to search the list itself.

### Your data (ratings + play counts + keywords)
Stored in **`<library_root>/userdata.json`** (e.g.
`S:\code\sound_lib_data\userdata.json`) — i.e. **with the audio, outside this
code repo** — keyed by each file's relative path. So it **survives re-indexing,
lives alongside the library it describes, and is never touched by repo cleanup**.
The location is taken from `library_root` in `library.cfg`, so it follows the
library if you move it. (`analysis.json`, the Sounds-column data, sits next to it.) It's
gitignored by default (personal data); remove the `/app/userdata.json` line from
`.gitignore` if you'd rather version it.

> Preview supports WAV (the other 4 files are `.aif`); for those, use "Open
> folder".
