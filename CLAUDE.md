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
- **User data** (rating + play count + tags + `vol_mult`) lives in `<library_root>/userdata.json`
  (e.g. S:\code\sound_lib_data\userdata.json), keyed by relative path — OUTSIDE
  the repo, with the audio. Path resolved in `_data_dir()` from library.cfg.
  `chopping.json` AND `loudness.json` sit beside it. NEVER `rm` these from repo
  cleanup (a past bug deleted a user's tags when they were in app/). Not in
  index.json -> survives re-indexing.
  Plays increment on the player's `finished` signal (end reached, not Stop).
  Rating is set by clicking stars in the Rating cell (`item_mouse_selected` +
  `get_item_area_rect`); right-click clears. Tags (the "Tags" column) are an
  inline-editable column (`item_edited`), space/comma separated, feed the search.
  `_last_click_col` gates double-click playback so editing Rating/Tags/Chop ≠ play.
  **Gain dB** column (`COL_GAIN_DB`, userdata `gain_db`, editable, clamped
  [-80,24]) is a per-track playback gain in dB for level-balancing sounds against
  each other (explosion 0, gunfire -10, zombie -20 — negatives attenuate cleanly,
  no clipping). Final player gain = `linear_to_db(global Vol)` + this dB
  (`_apply_volume` from `_global_vol` + `_play_gain_db`; set in `_play_selected`/
  `_play_chops`, live on edit). Does NOT move the 0..1 global slider. `_get_gain_db`
  migrates a legacy linear `vol_mult` entry to dB on read. (NOTE: there is no
  digital headroom above 0 dBFS — a positive Gain dB boosts past the file's level
  and clips; that's physics, not a bug. Balance with <=0 values.)
  **orig dB** column (`COL_LOUDNESS`, read-only) = measured integrated RMS in
  dBFS from `loudness.json`. **final dB** (`COL_FINAL_DB`, read-only) = orig dB +
  Gain dB = the resulting playback loudness (`_final_db`/`_apply_final_cell`,
  refreshed wherever Gain dB changes). Loudness is filled by the COMBINED
  "Analyse audio (chops + loudness)" button (`indexer/analyse_audio.py`, one read
  per file does chops + loudness; `_sg_*` job reloads both, polled progress).
  Column order: Tags | tgt vol/Level | orig dB | Gain dB | final dB.
  **Level** column (`COL_LEVEL`, userdata `level`, editable) = a 0-10 PERCEPTUAL
  loudness dial: 10 = `LEVEL_TOP_DBFS` (-10 dBFS), 0 = silence, halving the number
  = half perceived loudness = -10 dB (`_level_to_dbfs` = top + 10·log2(level/10),
  built on "+10 dB ≈ twice as loud"). It auto-drives **Gain dB**:
  `_apply_target_to_gain` sets `gain_db = clamp(level_to_dbfs(level) − rms, .,
  −peak)` (capped at −peak so it never clips) on edit (`_on_level_edited`),
  bulk-type, "Set Level on selection" (`_normalize_selection`), or re-measure
  (`_recompute_targets` in `_lm_finished`). `_target_gain` returns [gain, capped].
  Same Level = equally LOUD (loudness, not peak — equal peak ≠ equal loudness).
  Migrates a legacy dBFS `target_db` to a level via `_dbfs_to_level` on read.
  dBFS (digital, ceiling 0) ≠ dB SPL (acoustic, set by amp/speakers).
  **Loop** toggle (`_loop_chk`/`_loop_on`) sets the WAV's native
  `loop_mode = LOOP_FORWARD` (`_set_stream_loop`; seamless, and a looping stream
  emits no `finished` so loops don't count as plays). **Space** toggles play/pause
  globally via `_input` -> `_on_play_pressed`, suppressed when a `LineEdit`/
  `TextEdit` is focused or a tag type-over is active.
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
- `indexer/suggest_chops.py` — batch "optimal chop" suggester -> `chopping.json`
  in the LIBRARY ROOT (beside the audio, NOT app/ — that's where the app reads
  it). Per file: histogram-suggested silence_db + chop count. chops<=1 ->
  `{"continuous": true}` (blank chop columns, nothing to chop). Incremental by
  size+params. Reads all audio so a full run is slow. NEVER auto-chops.
- App: clicking a row auto-runs the analyser (`_an_debounce` -> `_auto_analyse`)
  and shows the picture. WaveGraph paints the KEPT sounds (detected segments)
  GREEN and the bits being CHOPPED AWAY (gaps) GREY (still drawn, so you see what's
  removed) — colour by segment membership, not by threshold; per-piece chop
  boundaries BLUE, threshold dB by the orange line. The graph is
  also the seek surface: LEFT-click = seek (`seek_requested` -> `_on_graph_seek`)
  AND set the chop dB (`threshold_picked` -> `_on_graph_threshold_picked`);
  LEFT-drag = scrub only; RIGHT-click/drag = set chop dB only. Play dot rides the
  foot of the white cursor line (same x => aligned). `_db_at_y`/`_frac_at_x`.
  A thin `SeekBar` strip (`_seekbar`) sits directly under the graph (both full
  width in the same VBox, handle at `pos*width` = graph's `playhead*width`, so
  exactly aligned); drag it to seek WITHOUT touching the chop dB. `_process`
  drives both from the same fraction; both seek via `_on_graph_seek`.
  Chop columns: "Chop dB"/"Chop gap"/"Min snd" editable (mirror the three
  analyser sliders), "Chop pieces" read-only (= stored `chops`; continuous files
  show 1). `_apply_chop_cells`/`_on_chop_edited`. A USER param change persists to
  `chopping.json` for the analysed file via `_on_user_param_changed` ->
  `_persist_analysed_chop` (disk write debounced by `_chop_save_debounce`);
  auto-load uses `_on_param_changed` and does NOT persist (browsing ≠ writing).
  "Suggest missing chops" button runs `suggest_chops.py --only-missing` in a
  Thread (`_suggest_missing_chops`), polling `user://chop_progress.json`
  (`_sg_poll`/`_sg_tick`) and repainting cells as the script checkpoints.
- KEY finding: an ABSOLUTE -60 dBFS floor generalises far better than a
  peak-relative threshold (a loud transient lifts a relative threshold into the
  ambient bed and explodes false-gap counts). See LESSONS_LEARNT.md.
- `indexer/chop.py <audio> <spec.json> <result.json>` — writes each piece (given
  as `segments_s` in seconds + parent metadata) as `<stem>_chopped_NNN<ext>`
  BESIDE the original via soundfile (keeps 24-bit/subtype). NEVER deletes the
  original. It then ADDS only the new chops to `app/index.json` incrementally
  (reuses `index.parse_wav`, inherits parent bundle/library/supplier/url; no
  re-scan) and returns the new records. App "Chop to files" button
  (`_chop_selected`) chops the analysed file at the exact segments shown (blue
  lines) in a thread; `_chop_finished` merges the returned records into `_all`
  via `_merge_new_records` so the chops appear immediately (no restart, no
  re-scan). "Play chops" (`_play_chops`/`_build_chops_stream`) auditions the
  pieces with 1 s silence between them as one in-memory AudioStreamWAV (8/16-bit).
- Chops are first-class files at once (play, tag, re-chop) and INHERIT the
  parent's tags (`_inherit_tags_to` writes userdata for each new path before the
  merge/refresh). Never auto-chop.
- Tags column is spreadsheet-like: Tree is `SELECT_MULTI`. Selection by click,
  or **click-drag** a range — all hand-rolled in `_on_tree_gui_input` (`_drag_*`
  state) because SELECT_MULTI has no native drag. Modes: plain drag = replace;
  **Shift = additive** (keep prior selection + add region); **Ctrl = toggle**
  (flip the region's cells; Ctrl on an already-selected cell deselects). For a
  modifier press we snapshot the prior selection (`_snapshot_selection`) and
  `accept_event` (the `gui_input` signal runs before Tree's own handler, so
  native modifier behaviour is suppressed) then `_apply_drag_range` rebuilds:
  deselect_all -> restore base -> add/toggle `_rows_between(a,b)`. Plain drag
  doesn't accept on press, so a normal click still single-selects/plays.
  Multi-cell editing is GENERIC over the selected editable column (`SEL_EDIT_COLS`
  = Tags, Vol×), NOT hard-wired to Tags — `_selected_edit_col` picks the column
  your selected cells are in, and `_cell_get`/`_cell_set` are the per-column
  value adapters (Vol× validates >0, lives in userdata; easy to add more cols).
  Ctrl+C copies the active cell (`_copy_selected_cells`), Ctrl+V pastes onto every
  selected cell (`_paste_to_selection`), Del clears (`_clear_selected_cells`), and
  a printable key starts a live "type over the selection" edit (`_begin_cell_edit`
  /`_cell_edit_live`/`_commit_cell_edit`/`_cancel_cell_edit` using `event.unicode`,
  `_cell_edit_col` tracks the target column) — Enter/click/`focus_exited` commits +
  deselects, Esc cancels. All keys handled in `_on_tree_gui_input`. (Chop columns
  stay single-cell double-click edits, not in SEL_EDIT_COLS.) Editable cells
  (`EDITABLE_COLS`: Rating, Chop dB/gap/snd, Tags, Vol×) are tinted slightly
  lighter (`EDIT_CELL_BG`, `set_custom_bg_color` in `_populate_tree`) so they
  stand out from read-only metadata.
  `multi_selected` drives per-selection refresh (item_selected doesn't fire in
  SELECT_MULTI); autoplay is suppressed while Shift/Ctrl is held.

## Common commands
- Build index: `py indexer/index.py`  (`--full` to ignore cache)
- Tune detection on sample files: `py indexer/explore_gaps.py`
- Combined analysis (what the app runs): `py indexer/analyse_audio.py`  (chops + loudness, one read/file)
- Batch chop suggestions only: `py indexer/suggest_chops.py`  (-> chopping.json)
- Batch loudness only: `py indexer/loudness.py`  (-> loudness.json; rms+peak dBFS)
- Validate project headlessly: `Godot..._console.exe --headless --editor --quit-after 5`
- Run app: `Godot..._win64.exe --path app`
