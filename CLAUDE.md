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
- **User data** (star rating + play count) lives in `app/userdata.json` (keyed
  by relative path, gitignored), NOT in index.json — survives re-indexing.
  Plays increment on the player's `finished` signal (end reached, not Stop).
- Godot tooling: `S:\code\godot\Godot_v4.6.3-stable_win64_console.exe` (console
  build prints to stdout — use for headless validation).

## Common commands
- Build index: `py indexer/index.py`  (`--full` to ignore cache)
- Validate project headlessly: `Godot..._console.exe --headless --editor --quit-after 5`
- Run app: `Godot..._win64.exe --path app`
