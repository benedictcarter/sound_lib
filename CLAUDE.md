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
- **Top library row**: "Choose library folder" (`_on_choose_library` -> FileDialog
  dir picker -> writes `library.cfg`, rewires the userdata/chopping/loudness paths,
  then re-indexes in a thread `_reindex_library`/`_reindex_finished` and reloads) +
  "Rescan library" (`_rescan_btn`, runs the whole update pipeline — see below) + the
  library path + status. The row right-click's "Open folder" (`_on_reveal`) handles a
  single track.
- **"Rescan library" = the ONE end-to-end update pipeline** (`_start_rescan` ->
  `_build_pipeline`/`_pipe_advance`/`_pipe_run`/`_pipe_step_finished`/`_pipe_all_done`,
  polled by `_rescan_tick`). Runs these steps SEQUENTIALLY, each in a Thread so the app
  stays usable, each incremental (`--only-missing`): `index.py --progress` (rescan) ->
  `analyse_audio.py` (chops+loudness, `--renames`) -> `fingerprint.py` -> `embed.py` ->
  `clap_embed.py` (appended ONLY if `_clap_model_present()` = models/clap/onnx/
  audio_model.onnx exists). Fires at startup (`call_deferred` in `_ready`) AND on the
  Rescan button. The button shows per-step progress ("Updating i/N: <label> M/K"); each
  script writes its own progress file (`index.py`'s `_write_progress` -> `{scanned,new,
  done,changed}`; the rest -> `{analysed,total}`). `_pipe_all_done` reloads chopping/
  loudness always, and the full `_load_index` (re-selecting the prior row) ONLY if the
  index step reported `changed`, then `_recompute_targets` + `_report_renames`, and
  drains `_pa_pending` (chops/loops queued mid-run). All jobs run through `_exec_tool`
  (so they work in the frozen standalone too — the old Analyse-Audio button used raw
  `py`, which was broken there) -> `_run_proc` (`OS.create_process` + poll, NOT the
  blocking pid-less `OS.execute` — see Shutdown below; nothing reads the children's
  stdout, every result comes back via a JSON file). The separate **Update semantic index / Update
  fingerprints / Build CLAP index / Analyse Audio buttons were REMOVED** — folded into
  this pipeline. **Download CLAP stays** (one-time model fetch; Rescan then builds the
  CLAP index). Guards vs `_reindex_library` (both write index.json non-atomically);
  `_on_choose_library` defers if the pipeline is mid-flight (`_pipe_busy`). index step
  is fast (header-only, ~1 s incremental on 7k files); analyse/fingerprint/CLAP read
  audio so a fresh library fills in over minutes.
- **Non-WAV audio (mp3/ogg/flac/aiff…)**: the app is WAV-centric (Godot playback +
  in-memory PCM slicing for chop/loop/preview). `index.parse_audio` reads non-WAV
  tech metadata via soundfile (so the row shows duration/rate/ch; bit_depth None for
  lossy). To USE one, **decode it to a sibling `<stem>.wav`**: `indexer/to_wav.py`
  (PCM_16, peak-normalised so MP3 intersample overshoot >1.0 doesn't clip; inherits
  the source's bundle/library/supplier; adds to index, no re-scan). In-app: the row
  right-click has **Convert to WAV**, and the loop/chop actions auto-decode first
  (`_ctx_run` -> `_sibling_wav_rec` reuse, else `_convert_to_wav`/`_convert_finished`,
  then re-run on the WAV). `_play_selected` auditions **mp3 directly** via
  `AudioStreamMP3` (loop via its `.loop`); WAV plays directly; **any OTHER format
  auto-decodes to a sibling WAV on Play** (`_convert_to_wav` with the `"__play__"`
  action; reuses an existing sibling via `_sibling_wav_rec`, else decodes then plays
  the result in `_convert_finished`).
- **24-bit / EXTENSIBLE WAV playback fallback**: Godot's runtime `AudioStreamWAV.
  load_from_file` loads plain PCM 24-bit + float fine (downconverts) but REJECTS
  WAVE_FORMAT_EXTENSIBLE ("not PCM", audio_stream_wav.cpp:737) — common for 24-bit
  files. So bit depth is NOT the tell (see LESSONS_LEARNT). When `load_from_file`
  returns null for a WAV, `_play_selected` makes a 16-bit sibling `<stem>_16bit.wav`
  (`_convert_to_16bit` -> `indexer/to_16bit.py`, soundfile reads EXTENSIBLE) and plays
  it; reuses one via `_sibling_16bit_rec`. `_convert_to_wav`/`_convert_to_16bit` share
  `_convert_audio(rec, script, status_fmt, then)`; `_convert_finished` takes the out
  path from `d.out` (to_wav) or `records[0].path` (to_16bit). NOT flagged red (would
  tint ~93% of the library) — the fallback is silent/on-demand.
- **Unsupported-file highlight**: `_is_playable(rec)` = mp3, or WAV with <=2 ch.
  Rows that FAIL this are tinted red (`UNSUPPORTED_BG`/`_ODD`, whole row, over the
  zebra/edit tint) in `_populate_tree` with a "Convert to WAV / press Play to decode"
  tooltip on the filename cell. (Non-WAV auto-decodes on Play; a >2-ch WAV still
  can't preview.)
- **Playing-row highlight**: a yellow border is drawn over the row whose TRACK is
  playing (or paused) via a mouse-ignored `RowHighlight` Control child of the Tree
  (Tree has no row-border API — see LESSONS_LEARNT), driven from `_process` off
  `_playing_item`. Not shown for chops/loop previews (`_playing_chops`).
- **Three parallel transport rows** — Track (`_play_btn`), Loop (`_loop_play_btn`),
  Chops (`_chops_play_btn`) — each owns ONE play button that acts on and reflects ONLY
  its own kind. `_play_kind` ("track"|"loop"|"chops"|"") is what the player is/was last
  loaded with; **only one kind plays at a time** (starting one supersedes the others).
  The single helper `_update_play_btn()` labels each button "Pause X" iff `_player.
  playing and _play_kind==X`, else "Play X" (it is the ONLY writer of the three texts).
  Each button (`_on_play_track_pressed`/`_on_play_loop`/`_on_play_chops_btn`): if its
  kind is LIVE (`_is_active()` = playing or paused) -> `_toggle_pause()`; else start its
  kind fresh. The Track row NEVER shows loop/chops state (and vice-versa). `_play_chops
  (kind)` sets `_play_kind` — "loop" from the Loop button/Suggest loop, "chops" from the
  Chops button/Suggest chops, "" (kept) for internal re-previews (region re-drag). Loop
  vs chops is thus decided by the BUTTON pressed, not by piece count. **Space**
  (`_on_play_pressed` -> `_toggle_pause`) toggles the LAST-USED row = the loaded stream.
  `_process` resets stale "Pause X" -> "Play X" on finish by checking all three labels
  (the label is no longer a fixed "Pause" state flag).
- **Shutdown (X / Alt-F4) is intercepted** — `auto_accept_quit = false` in `_ready`,
  so a close request goes to `_begin_quit` (`_notification` on
  `NOTIFICATION_WM_CLOSE_REQUEST` AND the `close_requested` signal — with
  auto-accept off, a missed request would make the window unclosable). It saves
  prefs/chopping, stops the player, and if any worker thread is alive writes the
  **cancel flag** (`user://cancel.flag`, path passed to the children as
  `SOUNDLIB_CANCEL`), then `_process` -> `_quit_tick` polls: quit as soon as
  `_jobs_running()` is false, kill the child process TREE at `QUIT_GRACE_MS`
  (2.5 s, `_kill_children` -> `taskkill /T /F` — `py.exe` spawns the real
  `python.exe`, so killing one pid orphans the worker), self-terminate at
  `QUIT_HARD_MS` (8 s) as a backstop. `_quitting` also makes every job starter
  return early so nothing new (or chained, e.g. `_pipe_advance`) begins. `_exit_tree`
  is reached only when no thread is alive so its joins are instant; on a HARD quit
  (`--quit-after`, editor stop) it flags + kills first. Python side: `indexer/
  cancel.py` `stop_requested()` (env `SOUNDLIB_CANCEL`), polled between files by
  analyse_audio/loudness/suggest_chops/fingerprint/embed/clap_embed — they save what
  they have (~40 ms) and exit; **index.py instead aborts WITHOUT writing** (a partial
  scan would drop every unvisited file from index.json). index.json and the .npz
  writes are now atomic (temp + `os.replace`) so a killed job can't truncate them —
  note `np.load` must be closed (`with`) before replacing that same path on Windows.
  DON'T reintroduce `OS.execute` on a worker thread: it blocks uninterruptibly and
  returns no pid, which is exactly what made close hang (see LESSONS_LEARNT).
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
  **Times are shown to the MILLISECOND** — `_fmt_time` renders `m:ss.mmm` (Duration
  column, the transport position/length, the region status line); `_fmt_time(v, false)`
  is the compact `m:ss` kept for the Duration filter slider's cramped ticks/knobs.
  Chop gap / Min snd (cells + slider labels + filter) are 3-dp seconds. Audio is
  edited in ms (loop points, chop boundaries, crossfades) so a rounded second lies.
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
  **Every width goes through `_apply_col(c)`** (`_apply_all_cols` for the lot) —
  the ONLY writer of a column's width + title. A Tree floors a column at its TITLE
  text width (+8px) whatever `set_column_custom_minimum_width` says, per-title and
  wider again with the sort arrow, so `_apply_col` ELIDES the title ("Chop pieces"
  -> "Chop p…" -> "…") until the drawn width is EXACTLY `_col_w[c]` (measured by
  asking the Tree: custom min 1 -> `get_column_width` = the floor, live, same
  frame). Keeps stored == drawn, so a drag never jumps; the resize also starts from
  the drawn width. Called from `_ready` (after the Tree is in the scene), prefs
  load, sort click and the live drag in `_process`. Filter controls must be able to
  shrink with the column too (`clip_text` on Buttons, `minimum_character_width` 0
  on LineEdits — a Control's `set_size` is clamped by its minimum size). Golden
  test: `tests/test_column_widths.gd` (see LESSONS_LEARNT).
  **Columns are also REORDERABLE — drag a header title sideways.** Tree has no
  reorder API, so there is a LOGICAL id <-> SLOT indirection: `_col_order`
  (slot -> logical) and `_col_slot` (logical -> slot), kept as exact mutual
  inverses by `_set_col_order` (the ONLY writer; it de-dupes, drops out-of-range
  ids and appends anything a stale/short saved order left out, so a bad prefs
  file can never lose a column). **The whole app speaks LOGICAL ids** (`_sort_col`,
  `EDITABLE_COLS`, `_colfilters`, `_last_click_col`, …); ONLY the Tree boundary
  converts — every `TreeItem`/`Tree` call passes `_col_slot[COL_X]`, and anything
  the Tree hands BACK (`get_column_at_position`, `get_edited_column`,
  `column_title_clicked`) comes back through `_lcol(slot)` (which maps -1 to -1).
  Note `_drag_base`/`_drag_base_col` deliberately hold SLOTS (snapshotted as drawn).
  Input: a press on a title arms `_drag_hdr_col` and TAKES OVER the click
  (`accept_event`), so the outcome never depends on when the Tree emits
  `column_title_clicked`; moving `HDR_DRAG_START` (6) px promotes it to a move
  (`_hdr_moving`, CURSOR_MOVE, gold insertion line + ghost label drawn by the
  `ColDropMark` overlay at `_drop_index_x(_hdr_drop_slot)`); a release that never
  dragged is a sort click (`_sort_by_col`). `_drop_index_at_x` returns an INSERT
  index 0..COL_COUNT by column midpoints; `_order_after_move` (pure, tested) does
  the lift-and-insert arithmetic (the index shifts down by one when moving right);
  `_move_column` then re-applies widths, **re-populates the tree** (cells must be
  rewritten into their new slots) and re-lays the filter header. `_end_hdr_drag`
  clears the state, and `_process` calls it if the button came up outside the Tree
  (no release event reaches us then). Persisted as `col_order` in prefs, restored
  in `_apply_view_prefs` BEFORE `_apply_all_cols`. Golden test:
  `tests/test_column_order.gd`.
  **Directory** column (`COL_DIRECTORY`, index 1, after Filename) = the file's full
  ABSOLUTE directory (`_directory_of` = `_abs_path` minus the filename); read-only,
  sortable, text-filterable (`STRING_FILTER_COLS`), tooltip = full path. Adding it
  renumbered every COL_* after Filename — all refs use the named constants + the
  parallel `COL_TITLES`/`COL_FIELD`/`COL_DEFAULT_W` arrays, so keep those aligned.
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
  **Convert to 16-bit** -> `_convert_16bit_selected` (BULK, over the whole tree
  selection) -> `indexer/to_16bit.py --spec <list>` writes a `<stem>_16bit.wav` COPY
  each (PCM_16, SAME sample rate; original kept). Skips files that are <= 16-bit OR
  already have a `_16bit.wav` (checked both in `_by_path` and on disk, and again in
  the script) — no-op for those. Threaded + polled (`_to16_*`), merges, per-file tag
  inherit, auto-analyses the copies. Chops + loops are ALWAYS 16-bit now
  (`chop.py`/`loopify.py` force `subtype="PCM_16"`).
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
- **Content-based similarity** (search by SOUND, not text): `indexer/fingerprint.py`
  extracts a ~48-dim acoustic feature vector per file (MFCC mean/std + spectral
  centroid/bandwidth/rolloff + ZCR + RMS; resampled to 22050 for comparability,
  no big model — just soundfile+numpy+scipy) -> `fingerprints.npz` in the LIBRARY
  ROOT. Incremental `--only-missing` (+`--progress`); built as a step of the Rescan
  pipeline (no separate button). Right-click a row -> **Find
  similar sounds** runs `indexer/similar.py "<rel>" <out> 500` (`_find_similar`/
  `_similar_finished`): standardises (z-score) the fingerprints, ranks by euclidean
  distance to the query, returns paths + a 0..1 similarity score. Results REUSE the
  semantic display pipeline via `_apply_ranked_results` (sets `_sem_ranked`/
  `_sem_scores`, Score column, sort desc; text Filter still narrows). The **Semantic
  keyword panel** (`_skw_*`, left of Keywords) clicks a token into a semantic
  (meaning) search; Keywords clicks into text filter.
- **CLAP (optional, much stronger similarity) — via ONNX, NO PyTorch**:
  `indexer/clap_embed.py` runs the community ONNX export `Xenova/clap-htsat-unfused`
  on **onnxruntime** (audio encoder ~118 MB, text ~502 MB), downloaded on demand into
  `<repo>/models/clap` (gitignored). Mel features are built in numpy with
  `transformers.audio_utils` matching `ClapFeatureExtractor`'s rand_trunc/repeatpad
  EXACTLY (deterministic first-10s crop, slaney mel; `_extract_mel`); input
  `input_features (1,1,1001,64)` -> `audio_embeds (512)`. `_session` prefers a GPU
  build (CUDA/`DmlExecutionProvider`) then CPU — DirectML gives GPU accel on any DX12
  card with zero CUDA setup (`onnxruntime-directml`). `similar.py` auto-prefers
  `clap.npz` (cosine) over `fingerprints.npz`, so **Find similar upgrades to CLAP**
  transparently once built. App: **Download CLAP** button (`_clap_dl_*` ->
  `--download`); the CLAP index (`--only-missing`) is then built as the last step of
  the Rescan pipeline (no separate Build button). Deps in
  `requirements-clap.txt` (onnxruntime[+gpu/directml], transformers, huggingface_hub —
  no torch). Throughput: `_extract_mel` is VECTORISED (strided frames + one batched
  rfft; releases the GIL, ~2x the audio_utils Python loop, bit-identical ~4e-6), the
  build loop extracts mels in a ThreadPool and runs ONE batched GPU forward per
  `CLAP_BATCH` (32) files -> ~62 ms/file (~7 min full lib on a 5080 via DirectML;
  was ~240 ms single/CPU). Validated: minigun -> machine-guns/explosions (cos ~0.6).
- **CLAP text->audio search** (search by SOUND from words): `indexer/clap_search.py
  "<query>" <out> 500` embeds the query with the CLAP TEXT encoder (`clap_embed.
  embed_text` via `text_model.onnx`) and ranks `clap.npz` by cosine -> paths+scores,
  shown through `_apply_ranked_results` (same as semantic/find-similar). Its OWN
  search box `_clap_edit` on a SEPARATE row below the semantic `_sem_edit` (the two
  are mutually exclusive — submitting one clears the other; both feed `_sem_ranked`).
  `_on_clap_submitted`/`_run_clap_search`/`_clap_search_finished`. Validated: "machine
  gun firing"->MP40/miniguns, "rain and thunder storm"->rain+thunder, "a monster
  growling"->zombie vocalisations.
- **ONE Keywords panel** (right column) with a **Filter/Semantic/CLAP radio**
  (`_kw_mode`, `_set_kw_mode`) that picks what a keyword CLICK does — add to the text
  Filter, run a Semantic (meaning) search, or a CLAP (sound) search (`_on_keyword_
  clicked` dispatches on `_kw_mode`). Same token list for all three (they share the
  mined `_keywords`), so the old separate "Semantic" panel was collapsed into this.
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
  (`COL_SCORE`, read-only) shows cosine; default sort is Score desc. The embeddings
  are built by `embed.py --only-missing` as a step of the Rescan pipeline (no separate
  Update-index button). `_by_path` maps rel_path->record. ~1.1s/query (model load each
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
  Each yellow edge has a **drag HANDLE** — an arrow tab drawn inside the region
  (`_draw_handle`), grabbed by pressing within `HANDLE_GRAB` (8) px of the edge
  (`_edge_at`, nearest edge wins). `_edge_drag` (0/1/2) makes the press move THAT
  end only instead of starting a new selection, clamped so it can't cross the other
  end (`MIN_SEL`); hovering one sets the HSIZE cursor (`_set_edge_hover`) and
  brightens the tab. Release commits like any region drag, so a playing preview
  follows. The DETECTOR's blue **chop boundaries drag the same way** (so one piece
  can be nudged without re-tuning the sliders for the whole file): `_seg_edge_at`
  finds the nearest boundary within `HANDLE_GRAB`, `_seg_drag`/`_seg_hover` are
  `Vector2i(segment, edge)` (edge 0=start, 1=end; x<0 = none), and `_drag_seg_edge`
  clamps each edge between its own partner (`SEG_MIN_FRAMES`) and the neighbouring
  piece so pieces stay ordered and non-empty. It mutates `_graph.segments` IN PLACE,
  which is exactly what `_effective_segments()` returns, so Make chops / Play chops
  follow with no extra plumbing (both already take float frames). Signals
  `segments_edited(i)` (live -> `_on_segments_edited` status line) /
  `segments_committed` (-> `_on_segments_committed`, re-previews). Boundary tabs are
  blue (`_draw_handle`'s `tint`) and drawn on every boundary up to `SEG_HANDLE_MAX`,
  else only on the hovered one. NOT persisted (chopping.json holds detector PARAMS);
  a slider move re-detects and discards them, which `_on_param_changed` says out loud
  via `_chop_edited`. A manual region hides the boundaries, so the two never fight.
  Golden-tested headlessly (28 assertions):
  `Godot..._console.exe --headless --path app --script tests/test_wavegraph_handles.gd`.
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
  **The crossfaded ends are SHADED violet** on the graph whenever Crossfade is on
  and one region is selected: `_update_xfade_overlay` pushes `xfade_frac` (crossfade
  as a fraction of the whole file, clamped to half the region exactly as the bakers
  do) + `xfade_label` into the WaveGraph, which tints BOTH ends — the head that
  fades in and the tail that is folded back over it — so you can see how much of the
  region is blended rather than heard in place. Called from `_on_xfade_changed`, the
  live region drag, `_sl_finished`, and every place the selection is cleared
  (`_an_finished`, `_apply_suggested`, ctx "suggest_chops").
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
  **Min loop s** (`_minloop_edit`, next to Xfade ms; 0 = off) sets a MINIMUM length
  for the suggestion: `_suggest_loop` passes `--min-s N` to loopfind, where PERIODIC
  content grows by WHOLE cycles (`ceil(need/period)` — a part-cycle would land the
  wrap off-beat) and TEXTURE widens its plateau cap (`max(2.5, min_s)`), then
  `_enforce_min` extends the end (pulling the start back only if the file runs out)
  and re-snaps the end to a zero crossing only when that still meets the minimum.
  A file shorter than the minimum returns the longest loop it can with `short: true`
  — reported in the status line, never an error.
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
  Left-clicking a row (`_on_tree_mouse_selected`, non-editable cell, not ranging):
  Autoplay ON -> `_play_selected()` (new track replaces old); Autoplay OFF but a
  DIFFERENT row is playing/paused -> `_on_stop_pressed()` (selecting a new track
  stops the old track/preview rather than leaving it playing).

## Standalone build (no Python for end users)
- `indexer/tool.py` is a single dispatcher: `tool <cmd> [args]` runs any indexer
  script (via `runpy`, exact CLI preserved). **PyInstaller** freezes it into one
  `tool/tool.exe` (onedir) bundling Python + deps. The app's `_exec_tool` runs
  `tool/tool.exe <cmd> <args>` when that exe exists (checked at `res://../tool/`),
  else falls back to `py <script>.py` (dev). **STALENESS GUARD**: tool.exe is a
  frozen SNAPSHOT of `indexer/*.py`, so `_tool_exe()` returns "" (-> `py`) when any
  `indexer/*.py` is NEWER than the exe (`_indexer_newest_mtime`, cached) — otherwise
  a dev edit is silently shadowed by the old build and the feature "doesn't work"
  in the app while working from the CLI (see LESSONS_LEARNT). A shipped standalone
  has no `indexer/` dir, so it always uses the exe. The app sets `SOUNDLIB_REPO` (=
  `res://..`) so the (relocated/frozen) scripts resolve `app/index.json` +
  `library.cfg` — every script's `REPO`/`INDEX` honours that env var.
- `_load_index` reads `index.json` from the globalized DISK path (not `res://`,
  which is the read-only pack in an export).
- Build the tool: `py -m PyInstaller --noconfirm --name tool --console
  --distpath . --collect-all fastembed --collect-all onnxruntime
  --collect-binaries soundfile --collect-data soundfile
  --collect-submodules scipy._external.array_api_compat
  --collect-submodules scipy._lib.array_api_compat
  --exclude-module transformers --exclude-module torch indexer/tool.py`
  (scipy needs the `array_api_compat` submodules; soundfile needs its libsndfile
  DLL). Export the app: Godot `--export-release "Windows Desktop"
  app/SoundLibrary.exe`. Ship `app/SoundLibrary.exe` + `tool/` + `library.cfg`.
- v1 standalone bundles core + SEMANTIC (fastembed). CLAP is EXCLUDED from the
  freeze (transformers too heavy/fragile for PyInstaller) — it degrades gracefully.
  To bundle CLAP later: drop the `transformers` dep from `clap_embed` (inline the
  mel_filter_bank/window/power_to_db, use `tokenizers` directly) so only onnxruntime
  is needed, then include it in the freeze.

## Common commands
- Build index: `py indexer/index.py`  (`--full` to ignore cache)
- Tune detection on sample files: `py indexer/explore_gaps.py`
- Combined analysis (what the app runs): `py indexer/analyse_audio.py`  (chops + loudness, one read/file)
- Batch chop suggestions only: `py indexer/suggest_chops.py`  (-> chopping.json)
- Batch loudness only: `py indexer/loudness.py`  (-> loudness.json; rms+peak dBFS)
- Decode a non-WAV (mp3/…) to a sibling WAV: `py indexer/to_wav.py <src> <result.json>`
- Suggest a loop region for one file: `py indexer/loopfind.py <audio> [out.json] [--min-s N]`
- Bake a seamless loop: `py indexer/loopify.py <audio> <spec.json> <result.json>`
- Build/update semantic index: `py indexer/embed.py [--only-missing]`  (-> library_root/embeddings.npz)
- Build/update audio fingerprints: `py indexer/fingerprint.py [--only-missing]`  (-> library_root/fingerprints.npz)
- Find files that SOUND similar: `py indexer/similar.py "<rel_path>" <out.json> [topn]`
- Run the Python tests: `py -m pytest`  (golden tests in `indexer/tests/`)
- Validate a script change by RUNNING the project (catches parse/runtime errors the
  editor pass misses — see LESSONS_LEARNT):
  `Godot..._console.exe --path app --quit-after 150` then grep stdout for "error".
  (`--headless --editor --quit-after 5` only checks import; a clean export is NOT
  proof the script loads — the exe can still blank-window.)
- Run app: `Godot..._win64.exe --path app`
