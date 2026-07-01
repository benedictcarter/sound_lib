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
- **Non-WAV audio (mp3/ogg/flac/aiff…)**: the app is WAV-centric (Godot playback +
  in-memory PCM slicing for chop/loop/preview). `index.parse_audio` reads non-WAV
  tech metadata via soundfile (so the row shows duration/rate/ch; bit_depth None for
  lossy). To USE one, **decode it to a sibling `<stem>.wav`**: `indexer/to_wav.py`
  (PCM_16, peak-normalised so MP3 intersample overshoot >1.0 doesn't clip; inherits
  the source's bundle/library/supplier; adds to index, no re-scan). In-app: the row
  right-click has **Convert to WAV**, and the loop/chop actions auto-decode first
  (`_ctx_run` -> `_sibling_wav_rec` reuse, else `_convert_to_wav`/`_convert_finished`,
  then re-run on the WAV). `_play_selected` auditions **mp3 directly** via
  `AudioStreamMP3` (loop via its `.loop`); everything else uses the decoded WAV.
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
  **orig dB** column (`COL_LOUDNESS`, read-only) = measured integrated LUFS
  (ITU-R BS.1770 via pyloudnorm; RMS dBFS fallback for <400 ms or huge files —
  `indexer/loud.py` `analyse_file`) from `loudness.json` key `lufs` (legacy
  `rms_db` still read). **final dB** (`COL_FINAL_DB`, read-only) = orig dB +
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
  emits no `finished` so loops don't count as plays). `loop_end` is the EXACT PCM
  frame count (`_wav_frame_count` = data bytes / frame bytes), NOT
  `get_length()*mix_rate` whose rounding overshoots into a sliver of silence (an
  audible gap at the wrap). The chops/region preview pads 1 s BETWEEN pieces only
  (no leading/trailing pad) so a single manual region loops with no gap. **Space** toggles play/pause
  globally via `_input` -> `_on_play_pressed`, suppressed when a `LineEdit`/
  `TextEdit` is focused or a tag type-over is active.
  Star click maps via `_star_at` (glyph-width based, exact); `_update_rating_hover`
  shows a gold preview. Columns are resizable (`_on_tree_gui_input` drags header
  dividers — Tree has no native resize); `_col_w`/`COL_DEFAULT_W` hold widths.
- **Row right-click menu** (`_ctx_menu`, opened from `_on_tree_mouse_selected` on a
  RIGHT-click of any non-Rating cell — Rating right-click still clears the rating):
  Open folder (`_on_reveal`), Copy path (`DisplayServer.clipboard_set`), Suggest
  loop / Suggest chops (audition), Make loop / Make chops. `_on_ctx_menu` -> `_ctx_run`
  which, if the row isn't the analysed file yet, sets `_pending_ctx` and analyses it;
  `_an_finished` then dispatches (`_dispatch_ctx`) — captured/cleared up front so a
  failed analysis drops it. Suggest loop -> `_suggest_loop` (auto-previews looped);
  Suggest chops -> `_apply_suggested` + `_play_chops` on Loop; Make loop chains
  `_suggest_loop` -> `_ctx_after_suggest` -> `_make_loop` (bakes in `_sl_finished`);
  Make chops -> `_chop_selected`. Convert to WAV -> `_convert_to_wav`. For a non-WAV
  row the loop/chop/suggest actions auto-decode to a sibling WAV first, then continue.
  **Delete** (menu item OR the **Del** key when the selection is NOT editable cells —
  editable-cell Del still clears them): `_confirm_delete_selected` shows a Yes/No
  `ConfirmationDialog`; `_do_delete_confirmed` moves the selected files to the
  **Recycle Bin** (`OS.move_to_trash`, recoverable), erases their userdata, drops
  them from `_all`/`_by_path`, stops playback/analyser if they pointed at a deleted
  file, and persists via `_save_index` (rewrites `res://index.json` atomically from
  `_all`, preserving `_index_generated`) so they don't reappear on restart.
- **Keyword panel** computed in-app at load (`_build_keywords`): tokens from
  filename + library, de-duped per library; frequency = #libraries containing
  the token. Click appends the token to the search box (AND quick-filter).
  Tune the `STOPWORDS` set in main.gd to filter noise words.
- **Semantic search** (meaning-based, NOT an LLM): `indexer/embed.py` embeds each
  file's text (filename+description+library+supplier) with a small local ONNX
  sentence model (fastembed, BAAI bge-small, 384-dim) -> `embeddings.npz` in the
  LIBRARY ROOT (beside userdata, with the audio). Incremental: `--only-missing`
  (+`--progress`) embeds only files with no vector yet (new chops). The app has
  its OWN search bar ABOVE the text Filter (`_sem_edit`): Enter runs
  `indexer/search.py "<query>" <out> 500` in a thread (`_run_semantic`/`_sem_*`),
  which embeds the query (bge `query_embed`), ranks by cosine, and returns paths +
  scores. `_sem_finished` builds the ranked BASE set `_sem_ranked` + `_sem_scores`;
  the text **Filter** then narrows that base (`_apply` iterates `_sem_ranked` when
  `_sem_active`, keeping cosine rank — no column sort). The **Score** column
  (`COL_SCORE`, read-only) shows cosine; default sort is Score desc. "Update index"
  button (`_update_embeddings`/`_emb_*`) runs `embed.py --only-missing` threaded
  with progress. `_by_path` maps rel_path->record. ~1.1s/query (model load each
  call; fine on Enter, no daemon).
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
  boundaries BLUE, threshold dB by the orange line. The Y axis is PERCEPTUAL, not
  linear dB: height ∝ loudness `2^(dB/10)` (the app's +10 dB≈2× model), normalised
  BOT→0 TOP→1 (`WaveGraph._loud_frac`/`_yfor`, `_db_at_y` is the exact inverse so
  right-drag set-height still maps), so each 10 dB halves the height and quiet
  reads quiet. Detection/threshold still operate in raw dB. The graph is
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
  A single piece chops fine (trims surrounding silence -> one `_chopped_001`).
  **Manual region** is always-on (no toggle): **left-click-drag** on the graph
  selects ONE region (`sel_a`/`sel_b` fractions; `region_selected` live,
  `region_committed` on release; a plain left-click clears back to the detector).
  **Right-click-drag** sets the height (silence threshold). Seek is on the strip
  below (the graph no longer seeks). `_graph.has_manual_sel()` gates everything:
  `_effective_segments()` returns the region (one frame pair) when a selection is
  active, else `_graph.segments`; both `_chop_selected` and `_build_chops_stream`
  go through it (WYSIWYG with the green). Draw: inside-region green / outside grey,
  edges yellow (else detector segments green + blue boundaries); threshold line
  always shown. While a preview is auditioning (`_playing_chops`), committing a new
  region re-runs `_play_chops` (`_on_region_committed`) so a LOOPING preview follows
  the new selection live.
- **Make loop** (`_loop_btn`/`_make_loop`): bakes a SEAMLESS loop of the selected
  region (green) as `<stem>_loop<ext>` beside the original via `indexer/loopify.py`
  (equal-power overlap-add crossfade: tail blended back over head so the file wraps
  with no click/seam; `crossfade_loop()` is golden-tested — exact sample-adjacent
  wrap seam + constant power). Crossfade length is the `_xfade_edit` ms field
  (default 100). Output length = region − crossfade. Keeps 24-bit subtype; reuses
  `chop._add_to_index` (no re-scan); `_loop_finished` merges + inherits tags like
  chops. Threaded `py loopify.py <audio> <spec.json> <result.json>` (spec:
  start_s/end_s/crossfade_ms/curve/parent). Industry-standard primitive; an
  autocorrelation/zero-cross "Suggest loop" analyser is the planned next layer.
  **Crossfade preview** (`_xfade_chk` + `_xfade_edit`): with it on, Play chops on a
  SINGLE region builds the crossfaded loop IN MEMORY (`_build_xfade_loop_stream`,
  the same equal-power overlap-add as loopify, per-sample over the L overlap via
  `decode_s16`/`encode_s16`, middle is a byte slice) — audition with Loop on, no
  file written. `_on_xfade_changed` (toggle / Xfade-ms Enter) and region re-drag
  rebuild the live preview. Preview == what Make loop bakes (same xfade + curve).
  **Suggest loop** (`_suggest_loop_btn`/`_suggest_loop` -> `indexer/loopfind.py`):
  picks a good loop region by content type. PERIODIC (gunfire/engines): envelope
  autocorrelation finds the cycle; loops a whole number of cycles bounded to the
  REGULAR onset run (never spills into the tail -> rhythm uninterrupted), short
  xfade. TEXTURE (flame/rain): the steady sustain PLATEAU (loudest 90th-pct band,
  longest contiguous run, onset/tail trimmed), generous (~200 ms) xfade. Both snap
  ends to a rising zero crossing and refine the length by window SSD. `_sl_finished`
  sets the green region + Xfade, ticks Crossfade + Loop, and auto-previews. Golden-
  tested (find_period periodic vs texture, suggest_loop region validity).
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
- Decode a non-WAV (mp3/…) to a sibling WAV: `py indexer/to_wav.py <src> <result.json>`
- Suggest a loop region for one file: `py indexer/loopfind.py <audio> [out.json]`
- Bake a seamless loop: `py indexer/loopify.py <audio> <spec.json> <result.json>`
- Build/update semantic index: `py indexer/embed.py [--only-missing]`  (-> library_root/embeddings.npz)
- Run the Python tests: `py -m pytest`  (golden tests in `indexer/tests/`)
- Validate project headlessly: `Godot..._console.exe --headless --editor --quit-after 5`
- Run app: `Godot..._win64.exe --path app`
