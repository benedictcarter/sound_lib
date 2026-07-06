# LESSONS_LEARNT — Sound Library

Non-obvious gotchas hit while building this. Append as you learn more.

## Godot JSON parses every number as float
`JSON.parse_string` returns `24.0` / `2.0` for integers like bit depth and
channel count, so `str(rec["bit_depth"])` printed "24.0" in the table.
**Fix:** wrap integer fields in `str(int(value))` on display. (Mechanism: GDScript
JSON has no int/float distinction on parse — everything numeric is a float.)
Cost: a wrong-looking column on the first screenshot.

## Godot `JSON.stringify` writes raw control chars — invalid for strict parsers
A WAV `bext` description contained a raw `\x13` (DC3). Python's `json.dumps` escapes
it to ``, so index.py's output was valid. But the app's `_save_index` (added
for delete-persist) re-serialised via **`JSON.stringify`, which emits control chars
(< 0x20) RAW**, producing an index.json that Godot's own lenient parser reads back
fine but **Python's strict `json.loads` rejects** ("Invalid control character").
Symptom: the app looked normal, but `analyse_audio.py` (which `json.loads` the
index) silently failed for the whole run, so a file's loudness never filled in.
**Fixes:** (1) strip control chars at the source — `index.py` sanitises bext
descriptions; (2) `_save_index` scrubs control chars from strings before
`JSON.stringify`. Lesson: never assume a JSON string round-trips across two
libraries — Godot↔Python disagree on control-char escaping. Cost: a confusing
"analyse didn't update the table" report that looked like a loudness bug.

## `allow_rmb_select = true` COLLAPSES a multi-selection on right-click
Enabling `allow_rmb_select` (needed so right-click fires `item_mouse_selected`)
also makes the Tree SELECT the clicked row on right-press — which, in `SELECT_MULTI`,
collapses your whole multi-selection to just that one row. So a "convert/delete the
selection" context action only saw the single right-clicked file. A snapshot-then-
restore-in-`item_mouse_selected` fix did NOT work — the Tree re-settles the selection
after emitting the signal, undoing the restore. **What works:** handle the right-
click entirely in the `gui_input` signal (which runs BEFORE the Tree's own handler),
open the menu there, and `accept_event()` so the Tree never processes the rmb-select
at all — the selection is never collapsed. Let only the column you still want the
Tree to handle (here, Rating's right-click-clear) fall through without accepting.

## Godot Tree right-click is dead unless `allow_rmb_select = true`
`Tree.item_mouse_selected(pos, button_index)` — the signal you hook for a row
context menu (and it's the ONLY place you learn which mouse button was used) — is
NOT emitted on right-click by default, because `allow_rmb_select` defaults to
`false`. Symptom: right-click does absolutely nothing (no menu, no rating-clear),
with no error. **Fix:** `_tree.allow_rmb_select = true`. (It also makes rmb select
the row, so a menu handler can act on the clicked row.) Cost: shipped a context
menu + rating right-click-clear that both silently no-op'd until a user reported
"right-click does nothing."

## Godot Tree `expand` columns push trailing fixed columns off-screen
With `set_column_expand(filename, true)`, the expand column grew to consume
nearly the whole viewport, shoving the 5 trailing fixed-width numeric columns
into an invisible horizontal-scroll region. Setting `custom_minimum_width` on the
fixed columns did NOT reserve their space against the expand calc.
**Fix:** for a fits-on-screen table, give ALL columns fixed widths whose sum is
< the window width (no expand). Deterministic and every column stays visible.

## Same expand trap in HBoxContainer: put the EXPAND_FILL child LAST
A `SIZE_EXPAND_FILL` slider/label in the *middle* of an HBox grew and pushed the
siblings after it (volume slider, Open-folder button, star buttons) clean off the
right edge — invisible the entire time across several screenshots before I caught
it. Same shape as the Tree-column quirk: the expanding child grabs space without
reserving room for trailing siblings.
**Fix:** order bars so the expanding element is the *last* child (seek slider at
the end of the transport bar; the expanding "now playing" label after the star
buttons). Then there's nothing behind it to displace. Verify bottom bars in a
real window capture — they're the easiest thing to silently lose off-screen.

## Screenshotting a Godot window when another app overlaps it
`CopyFromScreen` grabs whatever pixels are on screen, and `SetForegroundWindow`
is often refused by Windows (foreground-lock), so a covered window can't be
raised reliably. Capturing the planet-sim app instead of ours wasted two tries.
**Fix:** use Win32 `PrintWindow(hwnd, hdc, 2)` (`PW_RENDERFULLCONTENT`) — it
renders the target window's own surface regardless of z-order/occlusion.

## A Tree's column-width sum is its minimum width — it crowds out HSplit siblings
Putting the table in an `HSplitContainer` next to a 250px keyword panel, the
panel rendered mostly off the right edge. Cause: the Tree's minimum width is the
SUM of its fixed column widths (~1393px here); with a 1500px window that left
only ~100px for the panel, and the split overflowed. **Fix:** size the window
(and/or trim columns) so `sum(column widths) + panel_min + handle < window`.
Lesson: an HSplit pane can't shrink a Tree below its total column width.

## Godot Tree has no native column resizing — and no per-star click mapping
Two related in-cell interactions had to be hand-rolled on Tree:
* **Click-a-star rating:** mapping the click x across the *full cell width* in
  fifths is wrong — the star glyphs are narrower than the cell and left-aligned,
  so the cursor landed ~one star right of what applied. Fix: measure the star
  glyph width (`font.get_string_size("★")`), take `x0 = cell_rect.x +
  inner_item_margin_left`, and `star = floor((x - x0)/glyph_w) + 1`. Drive a live
  hover preview with the *same* function so it's WYSIWYG.
* **Column resizing:** Tree has no draggable column dividers. Implement via the
  `gui_input` signal: detect a press within `RESIZE_GRAB` px of a column's right
  edge *inside the header band* (header height = first row's
  `get_item_area_rect().position.y`), then adjust `set_column_custom_minimum_width`
  on drag. A drag also fires `column_title_clicked` (sort) on release — set a
  `_suppress_title_click` flag during the drag and consume it in the sort handler.
  Account for `get_scroll().x` when computing divider x positions.

Verifying both via screenshots is unreliable: injected `SetCursorPos` motion
isn't fed to Godot's input on a backgrounded window, so `get_local_mouse_position`
never updates and hover/drag never trigger. Instead drive synthetic `InputEvent`
objects into the handlers from a windowed `--script` test (needs a real window so
`get_item_area_rect` returns valid layout; `--headless` gives zero-size rects).

## Tracklist files are mislabeled by extension
The 2016 bundle ships `Tracklist.csv.xls` files that are actually plain CSV
(they start with `FILENAME,...`, not the ZIP `PK` signature of real XLSX).
**Fix:** detect format by content — first 2 bytes `PK` ⇒ real XLSX (openpyxl),
otherwise parse as CSV — never trust the extension. Also skip the 2016
"Complete Catalog" file: it's library-level, has no per-file FILENAME column.

## Gap detection: an ABSOLUTE silence floor beats a peak-relative threshold
Detecting "sounds separated by silence" across a heterogeneous library, the
obvious idea — silence = peak − N dB — is actively worse than a fixed floor.
A single loud transient (e.g. a bus horn in a field recording) raises the peak,
so peak−30 lands *inside* the ambient bed and shatters a continuous recording
into 100+ false gaps. A fixed **−60 dBFS** floor instead returns 1 ("don't
chop") for every continuous recording tested (ambiences, room tones, onboard
driving) and 2–3 only where there's genuine near-silence. −55 was already too
high (cut into a −50 forest bed). Min-gap length is the real granularity knob.
Mechanism: files are leveled to wildly different absolute loudnesses, but true
silence sits near the same low floor regardless — so an absolute floor is the
stable reference, not the per-file peak. Verified with `explore_gaps.py`.

## Very long files make gaps visually tiny — and need streamed envelopes
A 1 s gap in an 827 s file is ~0.1% of the graph width (~2 px), so dead-zone
shading is invisible on huge files even when detection is correct — don't read a
blank-looking graph as "broken". Also: never load a long file's samples whole
(the 1935 s Hellcat is ~740 MB as float32). Stream a per-frame RMS envelope with
`soundfile.blocks`, and cap envelope resolution (~8000 frames) so the JSON the
app draws stays small.

## Generated user-side JSON must be written to the LIBRARY ROOT, not app/
The app reads `userdata.json`, `analysis.json` and `chopping.json` from
`_data_dir()` = the library root (beside the audio), so they survive moving the
library and repo cleanup. But `analyze.py` still writes `app/analysis.json`
(a leftover from before the data move) — a path the app no longer reads. When
adding `suggest_chops.py` I made it resolve `chopping.json` from
`index.json["library_root"]` so the writer and the Godot reader agree.
**Lesson:** any batch script that produces data the app consumes must target the
library root, mirroring `_data_dir()` — don't copy analyze.py's `REPO/app/...`
output path (it's the odd one out and effectively dead). Cost: would have been a
silently-empty Chop column with the file written to the wrong place.

## WAV indexing must not read the audio payload
Naively reading whole files would mean touching 217 GB. Instead walk RIFF chunks
and `seek()` past the `data` chunk (`csize` bytes, word-aligned to even). Only
`fmt `, `bext`, and the `data` size are read. Result: full 7,000-file index in
~6.5 s. Remember RIFF chunks are 2-byte aligned — skip a pad byte when `csize` is
odd or chunk parsing desyncs.

## Godot Tree has no per-row border/highlight API — overlay a Control on top
Wanting a "yellow border around the playing row", the Tree offers only
`set_custom_bg_color` (a fill, per cell), no border. **Fix:** add a mouse-ignored
`Control` child of the Tree, anchored full-rect, that in `_draw` queries
`tree.get_item_area_rect(item)` (row rect, follows scroll) and draws a
`draw_rect(..., filled=false, width=2)`. Drive it from `_process`: set the item,
clip the top against the header height (`get_item_area_rect` y can slide UNDER the
header when scrolled — clamp `top = maxf(rect.y, header_h)`), and `queue_redraw`
each frame so it tracks scrolling. Because the overlay is a later child it draws
ABOVE the Tree's own cell content. Guard with `is_instance_valid(item)` — the
TreeItem is freed on every `_populate_tree` (re-filter/sort), so a stale ref must
not crash. Cost: knowing Tree can't do borders at all before reaching for an overlay.

## `--headless --editor` validation can MISS GDScript parse errors the game catches
A `:=` type-inference error (`var loc := 0.0 if cond else (f - e[0])/span`, where
`e[0]` is a Variant Array element so the type can't be inferred) passed a
`Godot --headless --editor --quit-after 5 --path app` check with ZERO reported
errors — then the EXPORT succeeded and shipped a broken exe that opened a blank
window. Running the project instead (`Godot --path app --quit-after 150`) reported
it immediately: "Parse Error: Cannot infer the type of 'local' variable ... Failed
to load script res://main.gd". Mechanism: the editor import path parses/reports
scripts differently (and may reuse a cached `.gdc`) from the runtime GDScript
loader, so an `--editor` pass is NOT a substitute for actually loading the game.
**Always validate a main.gd change by RUNNING the project, not just opening the
editor headless.** And a clean export is NOT proof the script parses — the exe can
still blank-window at load. Fix for the inference error itself: give the var an
explicit type or `float()`-cast the Variant operands. Cost: shipped a blank-window
exe to the user and needed a second round-trip.

## Godot's runtime WAV loader rejects WAVE_FORMAT_EXTENSIBLE (not the bit depth)
A 24-bit stereo WAV (`01_Campana_Iglesia.wav`) wouldn't play: `AudioStreamWAV.
load_from_file` returned null with "Format not supported for WAVE file (not PCM)"
(audio_stream_wav.cpp:737). The instinct — "Godot can't do 24-bit" — is WRONG:
tested empirically, Godot 4.6 loads plain PCM_24 AND IEEE FLOAT fine (downconverts
to FORMAT_16_BITS). What it CAN'T read is the WAVE_FORMAT_EXTENSIBLE container
(compression tag 0xFFFE), which many 24-bit tools emit. So bit depth is NOT the
discriminator (93% of this library is 24-bit and most plays), and you CAN'T tell
EXTENSIBLE from the index (it only stores bit_depth) without re-reading each fmt
chunk. **Fix:** don't pre-flag by bit depth (would red-tint 6,700 good files) —
instead, on the ACTUAL `load_from_file` == null, decode that one file to a 16-bit
sibling (`<stem>_16bit.wav`, via soundfile which reads EXTENSIBLE) and play that;
reuse the sibling next time. Same on-demand pattern as the non-WAV mp3/ogg decode.
Cost: chased "24-bit unsupported" before testing that plain 24-bit actually loads.
