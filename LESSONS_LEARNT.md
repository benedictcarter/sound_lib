# LESSONS_LEARNT — Sound Library

Non-obvious gotchas hit while building this. Append as you learn more.

## Godot JSON parses every number as float
`JSON.parse_string` returns `24.0` / `2.0` for integers like bit depth and
channel count, so `str(rec["bit_depth"])` printed "24.0" in the table.
**Fix:** wrap integer fields in `str(int(value))` on display. (Mechanism: GDScript
JSON has no int/float distinction on parse — everything numeric is a float.)
Cost: a wrong-looking column on the first screenshot.

## Godot Tree `expand` columns push trailing fixed columns off-screen
With `set_column_expand(filename, true)`, the expand column grew to consume
nearly the whole viewport, shoving the 5 trailing fixed-width numeric columns
into an invisible horizontal-scroll region. Setting `custom_minimum_width` on the
fixed columns did NOT reserve their space against the expand calc.
**Fix:** for a fits-on-screen table, give ALL columns fixed widths whose sum is
< the window width (no expand). Deterministic and every column stays visible.

## Screenshotting a Godot window when another app overlaps it
`CopyFromScreen` grabs whatever pixels are on screen, and `SetForegroundWindow`
is often refused by Windows (foreground-lock), so a covered window can't be
raised reliably. Capturing the planet-sim app instead of ours wasted two tries.
**Fix:** use Win32 `PrintWindow(hwnd, hdc, 2)` (`PW_RENDERFULLCONTENT`) — it
renders the target window's own surface regardless of z-order/occlusion.

## Tracklist files are mislabeled by extension
The 2016 bundle ships `Tracklist.csv.xls` files that are actually plain CSV
(they start with `FILENAME,...`, not the ZIP `PK` signature of real XLSX).
**Fix:** detect format by content — first 2 bytes `PK` ⇒ real XLSX (openpyxl),
otherwise parse as CSV — never trust the extension. Also skip the 2016
"Complete Catalog" file: it's library-level, has no per-file FILENAME column.

## WAV indexing must not read the audio payload
Naively reading whole files would mean touching 217 GB. Instead walk RIFF chunks
and `seek()` past the `data` chunk (`csize` bytes, word-aligned to even). Only
`fmt `, `bext`, and the `data` size are read. Result: full 7,000-file index in
~6.5 s. Remember RIFF chunks are 2-byte aligned — skip a pad byte when `csize` is
odd or chunk parsing desyncs.
