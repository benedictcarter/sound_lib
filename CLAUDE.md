# CLAUDE.md — Sound Library

Searchable catalog + audition tool for the Sonniss GDC Game Audio Bundles.
See [README.md](README.md) for usage. See [LESSONS_LEARNT.md](LESSONS_LEARNT.md)
for non-obvious gotchas.

## Layout
- `indexer/index.py` — Python scanner → `app/index.json`. Parses WAV headers
  (fmt/data/bext) + per-bundle tracklists (CSV/XLSX). Incremental via size+mtime.
- `app/` — Godot 4.6 project. `main.gd` builds the entire UI in code from a
  minimal `main.tscn` (root Control + AudioStreamPlayer).
- `library.cfg` — JSON pointing at the audio library root.

## Key facts
- **Audio is OUTSIDE the repo** in `S:\code\sound_lib_data`. Repo = code only.
  `.gitignore` also excludes audio extensions as a safeguard.
- `index.json` is generated (gitignored); it carries `library_root`, so the
  Godot app needs no separate config.
- ~7,000 files; all get library/supplier (tracklist, else folder-name fallback).
  ~6,250 match a tracklist (have URL); ~5,488 carry a `bext` description.
- **User data** (rating + play count + tags) lives in `app/userdata.json` (keyed
  by relative path, gitignored), NOT in index.json — survives re-indexing.
  Plays increment on the player's `finished` signal (end reached, not Stop).
  Rating is set by clicking stars in the Rating cell (`item_mouse_selected` +
  `get_item_area_rect`); right-click clears. Tags ("My Keywords") are an inline-
  editable column (`item_edited`), space/comma separated, and feed the search.
  `_last_click_col` gates double-click playback so editing Rating/Tags ≠ play.
  Star click maps via `_star_at` (glyph-width based, exact); `_update_rating_hover`
  shows a gold preview. Columns are resizable (`_on_tree_gui_input` drags header
  dividers — Tree has no native resize); `_col_w`/`COL_DEFAULT_W` hold widths.
- **Keyword panel** computed in-app at load (`_build_keywords`): tokens from
  filename + library, de-duped per library; frequency = #libraries containing
  the token. Click appends the token to the search box (AND quick-filter).
  Tune the `STOPWORDS` set in main.gd to filter noise words.
- Godot tooling: `S:\code\godot\Godot_v4.6.3-stable_win64_console.exe` (console
  build prints to stdout — use for headless validation).

## Gap analysis (sound counting + future chopping)
- `indexer/gaps.py` — core detection (RMS-dBFS envelope; gap = run below
  `silence_db` for >= `min_gap_s`; sounds = segments between gaps). Reads via
  soundfile (handles 24-bit). Defaults from exploration: -60 dBFS, 1.5s gap.
- `indexer/envelope.py <audio> <out.json>` — one-file envelope + per-file
  suggested threshold (histogram valley); the Godot analyser calls this in a
  Thread, caches the envelope, and re-detects live in GDScript (`_gd_find_segments`
  mirrors gaps.py) as the sliders move. WaveGraph (inner class) draws it.
- `indexer/analyze.py` — batch counts -> `app/analysis.json` (Sounds column).
  Incremental; reads all audio (~217 GB) so a full run takes a while.
- KEY finding: an ABSOLUTE -60 dBFS floor generalises far better than a
  peak-relative threshold (a loud transient lifts a relative threshold into the
  ambient bed and explodes false-gap counts). See LESSONS_LEARNT.md.
- Next (phase 2): `indexer/chop.py` to split at gaps into `name_chop_NNN.wav`
  and delete the original.

## Common commands
- Build index: `py indexer/index.py`  (`--full` to ignore cache)
- Tune detection on sample files: `py indexer/explore_gaps.py`
- Batch sound counts: `py indexer/analyze.py`
- Validate project headlessly: `Godot..._console.exe --headless --editor --quit-after 5`
- Run app: `Godot..._win64.exe --path app`
