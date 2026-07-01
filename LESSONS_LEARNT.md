# LESSONS_LEARNT — Sound Library

Non-obvious gotchas hit while building this. Append as you learn more.

## Godot JSON parses every number as float
`JSON.parse_string` returns `24.0` / `2.0` for integers like bit depth and
channel count, so `str(rec["bit_depth"])` printed "24.0" in the table.
**Fix:** wrap integer fields in `str(int(value))` on display. (Mechanism: GDScript
JSON has no int/float distinction on parse — everything numeric is a float.)
Cost: a wrong-looking column on the first screenshot.

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
