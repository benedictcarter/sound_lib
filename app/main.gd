extends Control
## Sound Library browser.
## Loads res://index.json (produced by indexer/index.py), shows an Excel-like
## sortable/filterable table, and auditions the original WAV files on demand.

# ----- column layout -------------------------------------------------------
const COL_FILENAME := 0
const COL_DIRECTORY := 1 # full directory path (excludes the filename); derived from "path"
const COL_SCORE := 2    # semantic-search cosine similarity (read-only; blank otherwise)
const COL_LIBRARY := 3
const COL_SUPPLIER := 4
const COL_BUNDLE := 5
const COL_DURATION := 6
const COL_RATE := 7
const COL_BIT := 8
const COL_CH := 9
const COL_SIZE := 10
const COL_RATING := 11  # user data (userdata.json)
const COL_PLAYS := 12   # user data (auto-incremented on finished playback)
const COL_CHOP_DB := 13 # suggested/edited chop silence threshold (chopping.json)
const COL_CHOP_GAP := 14 # suggested/edited chop min-gap seconds (chopping.json)
const COL_CHOP_SND := 15 # suggested/edited chop min-sound seconds (chopping.json)
const COL_CHOP_N := 16  # resulting chop pieces at those settings (chopping.json)
const COL_TAGS := 17    # user data (your own keywords; editable inline)
const COL_LEVEL := 18   # user data: desired loudness on a 0-10 perceptual scale; -> Gain dB
const COL_LOUDNESS := 19 # measured integrated loudness "orig dB", LUFS (loudness.json; read-only)
const COL_GAIN_DB := 20 # user data: per-track applied playback gain in dB
const COL_FINAL_DB := 21 # read-only: resulting loudness = orig dB + Gain dB
const COL_COUNT := 22

const COL_TITLES := [
	"Filename", "Directory", "Score", "Library", "Supplier", "Bundle",
	"Duration", "Rate", "Bit", "Ch", "Size", "Rating", "Plays",
	"Chop dB", "Chop gap", "Min snd", "Chop pieces", "Tags",
	"tgt vol/Level", "orig dB", "Gain dB", "final dB",
]
# Which record field each column sorts/reads. Directory, Score, Bundle, Rating,
# Plays, Chop dB/gap/snd/pieces, Tags, Level, orig dB, Gain dB, final dB are special-cased.
const COL_FIELD := [
	"filename", "", "", "library", "supplier", "bundle",
	"duration", "sample_rate", "bit_depth", "channels", "size", "", "", "", "", "", "", "", "", "", "", "",
]
const NUMERIC_COLS := [COL_SCORE, COL_DURATION, COL_RATE, COL_BIT, COL_CH, COL_SIZE,
	COL_RATING, COL_PLAYS, COL_CHOP_DB, COL_CHOP_GAP, COL_CHOP_SND, COL_CHOP_N,
	COL_LEVEL, COL_LOUDNESS, COL_GAIN_DB, COL_FINAL_DB]
# Columns that support spreadsheet-style multi-cell editing (copy/paste/Del/type
# across a selection). Driven by the SELECTED column, not hard-wired to Tags.
const SEL_EDIT_COLS := [COL_TAGS, COL_LEVEL, COL_GAIN_DB]
# Columns you can edit (inline or by clicking) — tinted a touch lighter so the
# editable cells stand out from the read-only metadata.
const EDITABLE_COLS := [COL_RATING, COL_CHOP_DB, COL_CHOP_GAP, COL_CHOP_SND,
	COL_TAGS, COL_LEVEL, COL_GAIN_DB]
const EDIT_CELL_BG := Color(1, 1, 1, 0.08)   # subtle lighter overlay on editable cells
const ZEBRA_BG := Color(1, 1, 1, 0.035)      # odd-row stripe (easier to track a row)
const EDIT_CELL_BG_ODD := Color(1, 1, 1, 0.115)  # editable cell on an odd (striped) row
const UNSUPPORTED_BG := Color(0.80, 0.14, 0.14, 0.22)      # row the player can't play directly
const UNSUPPORTED_BG_ODD := Color(0.80, 0.14, 0.14, 0.30)  # same, on an odd (striped) row

# Tokens ignored by the keyword analysis: English filler + audio/file-format
# noise (channel layouts, formats, mic patterns) that would otherwise dominate.
const STOPWORDS := {
	"the": true, "and": true, "for": true, "with": true, "from": true,
	"into": true, "out": true, "off": true, "this": true, "that": true,
	"are": true, "was": true, "has": true, "its": true, "you": true,
	# short grammatical noise (prepositions / pronouns / articles)
	"by": true, "on": true, "in": true, "at": true, "or": true, "of": true,
	"an": true, "as": true, "no": true, "to": true, "is": true, "it": true,
	"my": true, "be": true, "we": true, "up": true, "so": true, "re": true,
	# file-format / channel / mic-pattern noise
	"wav": true, "wave": true, "aif": true, "aiff": true, "flac": true,
	"mp3": true, "ogg": true, "stereo": true, "mono": true, "ortf": true,
	"xy": true, "ab": true, "ms": true, "db": true, "hz": true, "khz": true,
	"bit": true, "bits": true, "ch": true, "mix": true, "master": true,
	"final": true, "take": true, "ver": true, "version": true,
}
const KW_MAX_SHOWN := 500   # cap rows in the panel for responsiveness

const HELP_TEXT := "[b]Sound Library — what everything does[/b]

[b]Library[/b]
• [b]Choose library folder[/b] (top-left): pick the folder holding your sounds. It updates library.cfg, re-indexes that folder and reloads. The current path + index date show next to it.
• [b]Rescan library[/b]: updates EVERYTHING end-to-end (index → audio analysis → fingerprints → semantic index → CLAP index if downloaded). Runs automatically at startup and in the background; click it any time you've added/moved files. New chops/loops you make are auto-analysed on their own.

[b]Searching & filtering[/b]
• [b]Semantic search[/b] (first search line): describe a sound in words and press Enter. Ranks by the MEANING of the text (filename/description/library), not word-match — a small local model. Clearing the box (or its ✕) unsearches.
• [b]CLAP sound search[/b] (second search line): describe a sound and press Enter — ranks by the actual SOUND (e.g. \"creepy metallic scrape\" finds files that sound like that, whatever they're named). Needs Download CLAP, then Rescan library (it builds the CLAP index). The two search boxes are exclusive; the [i]Score[/i] column shows the match on either.
• [b]Filter[/b] box: quick text filter over filename / library / supplier / description / tags (space = AND). It narrows the semantic results too.
• [b]Per-column filters[/b] (row above the table): text box, tick-boxes, or a min–max range depending on the column. [b]Clear filters[/b] resets everything (and the semantic box).
• [b]Sort[/b]: click a column header (again to reverse).

[b]Columns you can edit[/b] (lighter-tinted cells)
• [b]Rating[/b]: click the stars (right-click clears), or use Rate on the Track row.
• [b]Tags[/b]: your own keywords (space/comma separated); feed the search.
• [b]Level[/b] (0–10 perceptual loudness dial): set it and [b]Gain dB[/b] auto-adjusts so equal Level = equally loud (capped so nothing clips). 10 ≈ loudest, halving = half as loud.
• [b]Gain dB[/b]: per-track playback gain for balancing sounds. [i]orig dB[/i] = measured loudness (LUFS); [i]final dB[/i] = orig + Gain.
• [b]Chop dB / gap / Min snd[/b]: the three detector knobs per file.
[i]Spreadsheet editing:[/i] drag to select a range, Shift/Ctrl to extend, Ctrl+C / Ctrl+V, Del to clear, or just start typing to overwrite the selection.

[b]Playing (Track row)[/b]
• [b]Play Track[/b] / [b]Stop[/b], [b]Autoplay[/b] (play on select), [b]Loop[/b] (seamless), [b]Vol[/b]. [b]Space[/b] toggles play/pause anywhere (except while typing). MP3s play directly; other formats decode to WAV on demand.

[b]Visualiser (bottom)[/b]
Click a row to auto-analyse and see it. Kept sound = [b]green[/b], removed = grey, chop boundaries = blue, threshold = orange line. Height is perceptual (each 10 dB halves it).
• [b]Left-drag[/b] = select a region. [b]Right-drag[/b] = set the height (threshold) and return to auto-detect. Seek on the thin strip below.

[b]Loop row[/b]
• [b]Suggest loop[/b]: auto-picks a good seamless-loop region (whole cycles for rhythmic sounds, steady sustain for textures) and auditions it.
• [b]Crossfade[/b] + [b]Xfade ms[/b]: preview the region as a seamless crossfaded loop in memory (nothing written). [b]Play Loop[/b] auditions it.
• [b]Make loop[/b]: bakes it to name_loop.wav next to the original (original kept).

[b]Chops row[/b]
• [b]Suggest Chops[/b]: sets the threshold from the file's loudness. Tune [b]Silence / Min gap / Min sound[/b].
• [b]Play chops[/b]: auditions the pieces with gaps. [b]Make chops[/b]: writes each piece as name_chopped_NNN.wav (original kept).

[b]Right-click a row[/b]
Open folder · Copy path · [b]Find similar sounds[/b] · Suggest loop / chops (audition) · Make loop / chops · Convert to WAV · [b]Convert to 16-bit[/b] (copies the WHOLE selection, same rate; skips ones already 16-bit or done) · Delete. (Chops + loops you make are always 16-bit.)

[b]Three ways to find a sound[/b]
• [b]Semantic[/b] (words → text): search line 1 — matches the meaning of the metadata.
• [b]CLAP[/b] (words → sound): search line 2 — matches the actual audio. Needs CLAP built.
• [b]Find similar[/b] (sound → sound): right-click a file → ranks the library by how it SOUNDS. Uses the fingerprints built by Rescan (tiny, no extra deps) or CLAP if downloaded (much stronger, auto-preferred).
[i]CLAP setup:[/i] click [b]Download CLAP[/b], then [b]Rescan library[/b] (its last step builds the CLAP index). In the standalone build it's ready to go; on the source build first run pip install -r indexer/requirements-clap.txt. Uses your GPU if onnxruntime-directml/-gpu is installed.

[b]Keeping everything up to date — one button[/b]
• [b]Rescan library[/b] (top row) does it ALL, in order, in the background: rescans the folder (index), analyses audio (loudness + Chop columns), builds acoustic fingerprints (Find similar), the semantic index (Semantic search), and the CLAP index (CLAP search / stronger Find similar — only if you've clicked Download CLAP). It runs automatically at startup too. Every step is incremental (only new/changed files), so re-running is cheap.
• [b]Download CLAP[/b]: one-time — fetches the optional CLAP model (ONNX, no PyTorch). After it, Rescan builds the CLAP index.

[b]Delete[/b]
Select rows and press [b]Del[/b] (or right-click → Delete) → confirm → moves them to the Recycle Bin (recoverable).

[b]Keywords panel[/b] (right)
One list of the library's keywords; the [b]Filter / Semantic / CLAP[/b] radio at the top picks what a CLICK does — add it to the text Filter, run a meaning search, or a sound search. The count next to each = number of libraries it appears in."
const KW_MIN_LEN := 2       # ignore 1-char tokens

# Default column widths (indices match COL_*). Columns are resizable at runtime.
const COL_DEFAULT_W := [460, 360, 56, 180, 140, 85, 65, 72, 42, 38, 78, 95, 58, 70, 72, 70, 80, 200, 96, 72, 64, 72]
const COL_MIN_W := 28       # smallest a column can be dragged to
const RESIZE_GRAB := 6      # px tolerance around a divider to start a resize

# Gap analysis defaults (chosen from exploration; tunable live in the analyser).
const DEF_SILENCE_DB := -60.0
const DEF_MIN_GAP_S := 1.5
const DEF_MIN_SOUND_S := 0.3


## Draws the loudness (dBFS) envelope vs time, the silence threshold, the
## detected "dead zones" (gaps) and a playback cursor.
class WaveGraph extends Control:
	signal threshold_picked(db: float)     # right-drag: set the silence threshold (height)
	signal seek_requested(fraction: float) # (kept for the seek strip below)
	signal region_selected(a: float, b: float)  # left-drag: selected [a,b] fractions (live)
	signal region_committed()              # left-release: region finalised (rebuild preview)

	var levels := PackedFloat32Array()
	var segments: Array = []          # [[start_frame, end_frame], ...]
	var threshold_db: float = DEF_SILENCE_DB
	var playhead: float = -1.0        # 0..1; < 0 hides
	# Left-drag picks ONE region [sel_a, sel_b] (fractions) to chop/play verbatim;
	# a plain left-click clears it (back to the detector). Right-drag sets height.
	var sel_a: float = -1.0
	var sel_b: float = -1.0

	func has_manual_sel() -> bool:
		return sel_a >= 0.0 and sel_b >= 0.0 and absf(sel_b - sel_a) > 0.0005
	const TOP_DB := 0.0
	const BOT_DB := -90.0
	const TRACK_PAD := 7.0            # px from the bottom for the seek track + dot

	# Height = PERCEIVED loudness, not raw dB. Using the app's own loudness model
	# (+10 dB ≈ twice as loud, i.e. loudness ∝ 2^(dB/10)), normalised so BOT→0,
	# TOP→1. So equal pixels ≈ equal perceived-loudness steps: quiet reads quiet,
	# loud reads tall, matching how you hear it (rather than dB plotted linearly,
	# which over-inflates near-silence). Threshold/detection still work in dB.
	func _loud_frac(db: float) -> float:
		var pmin := pow(2.0, BOT_DB / 10.0)
		var p := pow(2.0, db / 10.0)
		return clampf((p - pmin) / (1.0 - pmin), 0.0, 1.0)

	func _yfor(db: float) -> float:
		return (1.0 - _loud_frac(db)) * size.y

	func _db_at_y(y: float) -> float:
		var frac := clampf(1.0 - y / maxf(size.y, 1.0), 0.0, 1.0)
		var pmin := pow(2.0, BOT_DB / 10.0)
		var p := pmin + frac * (1.0 - pmin)
		return clampf(10.0 * log(p) / log(2.0), BOT_DB, TOP_DB)

	func _frac_at_x(x: float) -> float:
		return clampf(x / maxf(size.x, 1.0), 0.0, 1.0)

	# Left CLICK = scrub playback (x) AND set the chop dB level (y), both at once.
	# Left DRAG = scrub only (so a horizontal scrub doesn't wobble the threshold).
	# Right click/drag = set the chop dB level only.
	# Left-click-drag = select a region (left-click alone clears it). Right-click-
	# drag = set the height (silence threshold). Seeking is on the strip below.
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					sel_a = _frac_at_x(event.position.x)
					sel_b = sel_a
					queue_redraw()
					accept_event()
				else:                              # release: finalise (or clear on a click)
					if sel_a >= 0.0 and absf(sel_b - sel_a) <= 0.0005:
						sel_a = -1.0
						sel_b = -1.0
						region_selected.emit(-1.0, -1.0)
					else:
						region_selected.emit(minf(sel_a, sel_b), maxf(sel_a, sel_b))
					region_committed.emit()
					queue_redraw()
					accept_event()
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				if has_manual_sel():               # right-click drops back to auto/detector
					sel_a = -1.0
					sel_b = -1.0
					region_selected.emit(-1.0, -1.0)
				threshold_picked.emit(_db_at_y(event.position.y))
				queue_redraw()
				accept_event()
		elif event is InputEventMouseMotion:
			if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				sel_b = _frac_at_x(event.position.x)
				region_selected.emit(minf(sel_a, sel_b), maxf(sel_a, sel_b))
				queue_redraw()
				accept_event()
			elif (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
				threshold_picked.emit(_db_at_y(event.position.y))
				accept_event()

	# Kept sounds are green; the bits being chopped away are grey (still drawn).
	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.03, 0.04))   # = dead space
		var n := levels.size()
		if n == 0:
			draw_string(get_theme_default_font(), Vector2(10, h * 0.5 + 5),
				"Select a WAV to preview its sounds (green) and dead space (black)",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.5, 0.5, 0.55))
			return
		# Kept sounds (the detected segments) are GREEN; the bits being chopped
		# away (gaps / dead space) are GREY but still drawn, so you can see exactly
		# what's removed. With no detection yet the whole file reads as kept.
		var has_segs := segments.size() > 0
		var green := Color(0.30, 0.85, 0.45)
		var grey := Color(0.46, 0.46, 0.52)
		# "kept" (green) = inside the drag-selected region if one is picked, else
		# the detected segments. The waveform colours the same way either way.
		var sel := has_manual_sel()
		var m_lo := minf(sel_a, sel_b)
		var m_hi := maxf(sel_a, sel_b)
		for x in int(w):
			var fi := mini(int(float(x) / w * n), n - 1)
			var kept: bool
			if sel:
				var fx := float(x) / w
				kept = fx >= m_lo and fx <= m_hi
			else:
				kept = not has_segs or _frame_in_segment(fi)
			draw_line(Vector2(x, h), Vector2(x, _yfor(levels[fi])), green if kept else grey, 1.0)
		var font := get_theme_default_font()
		if sel:
			# bright yellow edges of the selected region
			var scol := Color(1.0, 0.85, 0.2)
			draw_line(Vector2(m_lo * w, 0), Vector2(m_lo * w, h), scol, 1.5)
			draw_line(Vector2(m_hi * w, 0), Vector2(m_hi * w, h), scol, 1.5)
		elif has_segs:
			# detector chop boundaries: start + end of every kept piece, in blue
			var bcol := Color(0.30, 0.62, 1.0, 0.9)
			for s in segments:
				var xs := float(int(s[0])) / n * w
				var xe := float(int(s[1])) / n * w
				draw_line(Vector2(xs, 0), Vector2(xs, h), bcol, 1.0)
				draw_line(Vector2(xe, 0), Vector2(xe, h), bcol, 1.0)
		# silence threshold (height) + its dB value — always shown; right-drag sets it
		var ty := _yfor(threshold_db)
		var ocol := Color(1.0, 0.6, 0.1)
		draw_line(Vector2(0, ty), Vector2(w, ty), ocol, 1.5)
		var lbl := "%d dB" % int(round(threshold_db))
		var lw := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var lyt := clampf(ty - 4.0, 11.0, h - 2.0)
		draw_string(font, Vector2(w - lw - 6.0, lyt), lbl,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ocol)
		# seek track along the very bottom (this IS the play bar), + playback cursor
		# and the play dot riding on it -- dot and white line share x, so they line
		# up exactly by construction. Left-click/drag the graph to scrub.
		var track_y := h - TRACK_PAD
		draw_line(Vector2(0, track_y), Vector2(w, track_y), Color(0.5, 0.5, 0.55, 0.45), 2.0)
		if playhead >= 0.0:
			var px := playhead * w
			draw_line(Vector2(px, 0), Vector2(px, h), Color(1, 1, 1, 0.85), 1.0)
			draw_circle(Vector2(px, track_y), 5.0, Color(1, 1, 1, 0.95))

	func _frame_in_segment(fi: int) -> bool:
		for s in segments:
			if fi >= int(s[0]) and fi < int(s[1]):
				return true
		return false


## Thin seek-only strip placed directly under the visualiser, full width. Its dot
## sits at pos*width — the same mapping as the graph's playhead — so they line up
## exactly. Click/drag seeks playback; it never touches the chop dB.
class SeekBar extends Control:
	signal seek_requested(fraction: float)
	var pos := -1.0                   # 0..1; < 0 hides the handle

	func _gui_input(event: InputEvent) -> void:
		var scrub := false
		if event is InputEventMouseButton and event.pressed:
			scrub = event.button_index == MOUSE_BUTTON_LEFT
		elif event is InputEventMouseMotion:
			scrub = (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		if scrub:
			seek_requested.emit(clampf(event.position.x / maxf(size.x, 1.0), 0.0, 1.0))
			accept_event()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var cy := h * 0.5
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.10, 0.13))
		draw_line(Vector2(0, cy), Vector2(w, cy), Color(0.5, 0.5, 0.55, 0.55), 2.0)
		if pos >= 0.0:
			var px := pos * w
			draw_line(Vector2(px, 2), Vector2(px, h - 2), Color(1, 1, 1, 0.5), 1.0)
			draw_circle(Vector2(px, cy), 6.0, Color(1, 1, 1, 0.95))


## A draggable column-resize grabber: a thin white strip with ◄► arrows that
## spans BOTH the filter row and the sort/title row at one column boundary. Drags
## are forwarded to main (gui_input signal); rendering is identical for every edge.
class ColGrabber extends Control:
	var col := -1

	func _ready() -> void:
		mouse_default_cursor_shape = Control.CURSOR_HSIZE

	func _draw() -> void:
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		var c := Color(1, 1, 1, 0.9)
		draw_line(Vector2(cx, 2.0), Vector2(cx, size.y - 2.0), Color(1, 1, 1, 0.5), 1.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(cx - 3.0, cy), Vector2(cx - 7.0, cy - 3.0), Vector2(cx - 7.0, cy + 3.0)]), c)
		draw_colored_polygon(PackedVector2Array([
			Vector2(cx + 3.0, cy), Vector2(cx + 7.0, cy - 3.0), Vector2(cx + 7.0, cy + 3.0)]), c)


## Yellow border drawn over the row whose track is currently playing. Sits on top
## of the Tree (mouse-ignored) and re-queries the row rect each frame so it follows
## scrolling. `item` is set from _playing_item; cleared when nothing is playing.
class RowHighlight extends Control:
	var tree: Tree
	var item: TreeItem = null
	var header_h := 0.0

	func _draw() -> void:
		if item == null or not is_instance_valid(item) or tree == null:
			return
		var r := tree.get_item_area_rect(item)     # row rect in tree space (follows scroll)
		if r.size.y <= 0.0:
			return
		var top := maxf(r.position.y, header_h)
		var bottom := minf(r.position.y + r.size.y, size.y)
		if bottom <= top:
			return                                  # scrolled out of the visible band
		draw_rect(Rect2(1.0, top, size.x - 2.0, bottom - top - 1.0),
			Color(1.0, 0.82, 0.10), false, 2.0)


## Two-knob range slider for numeric column filters. Maps over the column's actual
## data min..max (optionally log scale for wide positive ranges); drag either knob.
class RangeSlider extends Control:
	signal changed(lo: float, hi: float)
	var data_lo := 0.0
	var data_hi := 1.0
	var lo := 0.0
	var hi := 1.0
	var use_log := false
	var fmt_value: Callable           # column-aware value -> String (mm:ss, MB, dB…)
	var _drag := -1                    # 0 = lo knob, 1 = hi knob, -1 = none
	const PAD := 16.0
	const KNOB_R := 7.0
	const TRACK_Y := 22.0

	func setup(dlo: float, dhi: float, clo: float, chi: float, log_scale: bool) -> void:
		data_lo = dlo
		data_hi = maxf(dhi, dlo + 1e-9)
		use_log = log_scale and dlo > 0.0
		lo = clampf(clo, data_lo, data_hi)
		hi = clampf(chi, data_lo, data_hi)
		queue_redraw()

	func _v2t(v: float) -> float:
		if use_log:
			return clampf((log(maxf(v, 1e-9)) - log(data_lo)) / (log(data_hi) - log(data_lo)), 0.0, 1.0)
		return clampf((v - data_lo) / (data_hi - data_lo), 0.0, 1.0)

	func _t2v(t: float) -> float:
		if use_log:
			return exp(log(data_lo) + t * (log(data_hi) - log(data_lo)))
		return data_lo + t * (data_hi - data_lo)

	func _v2x(v: float) -> float:
		return PAD + _v2t(v) * (size.x - 2.0 * PAD)

	func _x2v(x: float) -> float:
		return _t2v(clampf((x - PAD) / maxf(size.x - 2.0 * PAD, 1.0), 0.0, 1.0))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_drag = 0 if absf(event.position.x - _v2x(lo)) <= absf(event.position.x - _v2x(hi)) else 1
				_set_knob(event.position.x)
			else:
				_drag = -1
			accept_event()
		elif event is InputEventMouseMotion and _drag >= 0:
			_set_knob(event.position.x)
			accept_event()

	func _set_knob(x: float) -> void:
		var v := _x2v(x)
		if _drag == 0: lo = minf(v, hi)
		else: hi = maxf(v, lo)
		queue_redraw()
		changed.emit(lo, hi)

	static func fmt(v: float) -> String:
		var a := absf(v)
		if a >= 1.0e6: return "%.1fM" % (v / 1.0e6)
		if a >= 1.0e3: return "%.0fk" % (v / 1.0e3)
		if a >= 100.0 or v == floor(v): return "%d" % int(round(v))
		return "%.2f" % v

	func _fmt(v: float) -> String:
		return str(fmt_value.call(v)) if fmt_value.is_valid() else fmt(v)

	func _draw() -> void:
		var ty := TRACK_Y
		var font := get_theme_default_font()
		draw_line(Vector2(PAD, ty), Vector2(size.x - PAD, ty), Color(0.4, 0.4, 0.46), 3.0)
		draw_line(Vector2(_v2x(lo), ty), Vector2(_v2x(hi), ty), Color(0.30, 0.62, 1.0), 3.0)
		draw_circle(Vector2(_v2x(lo), ty), KNOB_R, Color(1, 1, 1))
		draw_circle(Vector2(_v2x(hi), ty), KNOB_R, Color(1, 1, 1))
		# current selected values above the knobs
		draw_string(font, Vector2(_v2x(lo) - 16, ty - 9), _fmt(lo), HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		draw_string(font, Vector2(_v2x(hi) - 16, ty - 9), _fmt(hi), HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		# data-scale ticks below
		for i in 5:
			var t := i / 4.0
			draw_string(font, Vector2(PAD + t * (size.x - 2.0 * PAD) - 16.0, ty + 20.0),
				_fmt(_t2v(t)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.6, 0.65))

# ----- data ----------------------------------------------------------------
var _all: Array = []          # all records (Dictionaries)
var _filtered: Array = []     # current view
var _library_root: String = ""
var _sort_col: int = COL_FILENAME
var _sort_asc: bool = true

# user data: { rel_path : { "rating": int 0-5, "plays": int } }  -- survives
# re-indexing because it is stored separately from index.json.
var _userdata: Dictionary = {}
var _ud_path: String = ""
var _star_btns: Array = []    # 5 rating buttons in the player bar

# suggested/edited chop params -- { rel_path : {"silence_db","min_gap_s",
# "min_sound_s","chops"} } or {"continuous": true}. Lives with the audio.
var _chopping: Dictionary = {}
var _chop_path: String = ""

# measured loudness -- { rel_path : {"lufs","peak_db"} } in dB. Lives with
# the audio (loudness.json). Used to normalise tracks to a target level.
var _loudness: Dictionary = {}
var _lo_path: String = ""

# analyser panel / live preview state
var _graph: WaveGraph
var _seekbar: SeekBar
var _an_levels := PackedFloat32Array()    # cached envelope for the loaded file
var _an_frame_s: float = 0.02
var _an_duration: float = 0.0
var _an_rec: Variant = null               # record currently in the analyser
var _an_suggested: float = DEF_SILENCE_DB
var _sil_slider: HSlider
var _gap_slider: HSlider
var _snd_slider: HSlider
var _sil_lbl: Label
var _gap_lbl: Label
var _snd_lbl: Label
var _an_status: Label
var _an_thread: Thread = null
var _an_busy: bool = false
var _an_out_path: String = ""

# analyse-audio (chops + loudness) progress file — a step in the update pipeline
var _sg_progress_path: String = ""

# chop-to-disk job (chop.py writes name_chopped_NNN next to the original; the
# original is kept). Runs in a thread.
var _chop_thread: Thread = null
var _chop_busy: bool = false
var _chop_btn: Button
var _playing_chops: bool = false       # currently auditioning the chops/region preview
# What the player is (or was last) loaded with: "track" | "loop" | "chops" | "".
# Each transport row (Track/Loop/Chops) owns one kind; only one plays at a time.
# Space toggles the LAST-USED row = this kind. (`_playing_chops` == kind in loop/chops.)
var _play_kind: String = ""
# Maps a chops/loop PREVIEW's timeline back onto the original file so the graph's
# playhead can sweep the green region while a preview plays. Entries are
# [prev_start_frac, prev_end_frac, orig_start_frac, orig_end_frac] (all 0..1);
# `_preview_rec` is the file it was built from (guards against a stale overlay).
var _preview_map: Array = []
var _preview_rec: Variant = null
var _chop_spec_path: String = ""
var _chop_result_path: String = ""
var _loop_thread: Thread = null
var _loop_busy: bool = false
var _loop_btn: Button
var _suggest_loop_btn: Button
var _sl_thread: Thread = null
var _sl_busy: bool = false
var _sl_result_path: String = ""
var _ctx_menu: PopupMenu               # right-click row context menu
var _ctx_rec: Variant = null           # the row it was opened on
var _pending_ctx: String = ""          # action to run once analysis of _ctx_rec finishes
var _ctx_after_suggest: bool = false   # bake the loop once Suggest loop lands (Make loop)
var _convert_thread: Thread = null     # non-WAV (mp3/…) -> sibling WAV decode
var _convert_busy: bool = false
var _convert_result_path: String = ""
var _convert_then: String = ""         # ctx action to run once the decode lands
var _to16_thread: Thread = null        # bulk "Convert to 16-bit" copies
var _to16_busy: bool = false
var _to16_result_path: String = ""
var _to16_spec_path: String = ""
var _to16_progress_path: String = ""
var _to16_poll: Timer
var _confirm_dialog: ConfirmationDialog  # Del -> yes/no delete-to-Recycle-Bin
var _delete_pending: Array = []          # records awaiting delete confirmation
var _index_generated: String = ""        # preserved index.json "generated" stamp
var _info_dialog: AcceptDialog            # simple summary popup (renames, etc.)
var _sg_renames_path: String = ""         # analyse job's invalid-name rename report
var _lib_picker: FileDialog               # "Choose library folder" directory picker
var _reindex_thread: Thread = null        # re-index after changing the library folder
var _reindex_busy: bool = false
var _rescan_btn: Button                   # "Rescan library" -> runs the whole pipeline
var _rescan_poll: Timer                   # polls the current pipeline step's progress
var _rescan_progress_path: String = ""    # index.py step's progress file
# End-to-end update pipeline (index -> analyse -> fingerprints -> embeddings -> CLAP)
var _pipe_steps: Array = []
var _pipe_i: int = -1
var _pipe_busy: bool = false
var _pipe_thread: Thread = null
var _pipe_index_changed: bool = false
var _pa_thread: Thread = null             # targeted analyse of new chops/loops
var _pa_busy: bool = false
var _pa_paths_file: String = ""
var _pa_pending: Array = []               # rel paths queued while a run is in flight
var _xfade_chk: CheckButton             # preview the region as a crossfaded loop
var _xfade_edit: LineEdit               # crossfade length (ms) for preview + Make loop
var _loop_spec_path: String = ""
var _loop_result_path: String = ""


# semantic search (its own bar above the text filter; ranks via indexer/search.py)
var _sem_edit: LineEdit               # the semantic query box
var _sem_thread: Thread = null
var _sem_busy: bool = false
var _sem_active: bool = false         # a semantic result set is the current base
var _sem_ranked: Array = []           # records in cosine-rank order (the base set)
var _sem_scores: Dictionary = {}      # rel_path -> cosine score (for the Score column)
var _sem_result_path: String = ""
var _clap_edit: LineEdit              # the CLAP "search by sound" query box
var _clap_search_thread: Thread = null
var _clap_search_busy: bool = false
var _clap_search_result_path: String = ""
var _by_path: Dictionary = {}         # rel_path -> record, for fast rank lookup

# embeddings.npz / fingerprints.npz progress files — steps in the update pipeline
var _emb_path: String = ""
var _emb_progress_path: String = ""
var _fp_progress_path: String = ""
var _similar_thread: Thread = null       # "Find similar" query
var _similar_busy: bool = false
var _similar_result_path: String = ""
var _clap_dl_thread: Thread = null       # optional CLAP model download
var _clap_dl_busy: bool = false
var _clap_dl_btn: Button
var _clap_dl_result_path: String = ""
var _clapidx_progress_path: String = ""  # CLAP audio-index step of the update pipeline

# persisted UI prefs (window geom, column widths, sort, search/filters, toggles)
var _prefs: Dictionary = {}
var _prefs_path: String = ""

# ----- nodes ---------------------------------------------------------------
var _row_hl: RowHighlight             # yellow border over the currently-playing row
var _search: LineEdit
var _lib_label: Label                 # library-root path shown top-left
var _vol_slider: HSlider
# per-column filter header (aligned above the columns; type per column)
var _filter_header: Control
var _grabbers: Array = []              # ColGrabber pool: white ◄► resize strips per edge
var _colfilters: Dictionary = {}      # col -> the filter control node
var _filter_text: Dictionary = {}     # col -> lowercased substring (text columns)
var _filter_set: Dictionary = {}      # col -> {value:true} allow-set (tick columns)
var _filter_min: Dictionary = {}      # col -> float min (numeric columns)
var _filter_max: Dictionary = {}      # col -> float max (numeric columns)
var _distinct_cache: Dictionary = {}  # col -> sorted distinct string values
var _num_popup: PopupPanel            # shared range editor for numeric columns
var _num_slider: RangeSlider
var _num_lbl: Label
var _num_popup_col: int = -1
var _range_cache: Dictionary = {}     # col -> [data_min, data_max]
const TICK_MAX := 25                   # <= this many distinct -> tickbox, else text filter
var _autoplay: CheckButton
var _tree: Tree
var _count_label: Label
var _status_label: Label

# keyword analysis panel
var _kw_list: ItemList
var _kw_filter: LineEdit
var _kw_header: Label
var _kw_hint: Label
var _kw_mode: int = 0                    # 0 Filter, 1 Semantic, 2 CLAP — what a click does
var _help_dialog: AcceptDialog
var _keywords: Array = []   # [ [token, library_count], ... ] sorted desc

# player
var _player: AudioStreamPlayer
var _play_btn: Button                 # Track row play/pause
var _loop_play_btn: Button            # Loop row play/pause
var _chops_play_btn: Button           # Chops row play/pause
var _time_label: Label
var _now_label: Label
var _stream_len: float = 0.0
var _playing_rec: Variant = null     # record currently loaded in the player
var _playing_item: TreeItem = null   # its row, for live cell updates
var _global_vol: float = 0.9         # the 0..1 global Vol slider value
var _play_gain_db: float = 0.0       # current track's per-track Gain dB trim
var _loop_chk: CheckButton
var _loop_on: bool = false           # "Loop" toggle: replay the current track
var _last_click_col: int = -1        # column of the last mouse click (gates play)
var _hover_item: TreeItem = null     # row whose Rating cell is showing a preview
var _hover_star: int = -1            # previewed star count under the cursor
var _star_glyph_w: float = 0.0       # measured pixel width of one star glyph

# column resizing (header divider drag)
var _col_w: Array = []               # current width of each column
var _resize_col: int = -1            # column whose right divider is being dragged
var _resize_start_x: float = 0.0
var _resize_start_w: int = 0
var _header_h: float = 0.0           # measured header (title row) height, cached
var _suppress_title_click: bool = false

# drag-to-select a range of rows (Excel-style; SELECT_MULTI has no native drag)
var _drag_sel: bool = false
var _drag_anchor: TreeItem = null
var _drag_last: TreeItem = null
var _drag_col: int = 0
var _drag_additive: bool = false     # Shift/Ctrl: keep the selection from before this drag
var _drag_toggle: bool = false       # Ctrl: flip cells in the region instead of adding
var _drag_base: Array = []           # [[item, col], ...] selection before this drag
var _drag_base_col: Dictionary = {}  # item -> selected column, for fast toggle lookup

# type-into-a-selection: overwrite an editable column's cells across the selection
var _cell_edit_active: bool = false
var _cell_edit_col: int = -1
var _cell_edit_buf: String = ""
var _cell_edit_items: Array = []     # the TreeItems being edited
var _cell_edit_orig: Dictionary = {} # item -> original cell text (for Esc cancel)

var _debounce: Timer
var _an_debounce: Timer        # auto-analyse the selected row after a short pause
var _chop_save_debounce: Timer # coalesce chopping.json writes during a live drag


func _ready() -> void:
	_prefs_path = ProjectSettings.globalize_path("user://prefs.json")
	_prefs = _load_json_dict(_prefs_path)
	_apply_window_prefs()
	_player = $Player
	_player.finished.connect(_on_playback_finished)
	# Your data lives WITH the audio library (outside the code repo), so it
	# survives moving the library and is never touched by repo housekeeping.
	var data_dir := _data_dir()
	_ud_path = data_dir.path_join("userdata.json")
	_chop_path = data_dir.path_join("chopping.json")
	_lo_path = data_dir.path_join("loudness.json")
	_an_out_path = ProjectSettings.globalize_path("user://envelope.json")
	_sg_progress_path = ProjectSettings.globalize_path("user://chop_progress.json")
	_chop_spec_path = ProjectSettings.globalize_path("user://chop_spec.json")
	_chop_result_path = ProjectSettings.globalize_path("user://chop_result.json")
	_loop_spec_path = ProjectSettings.globalize_path("user://loop_spec.json")
	_loop_result_path = ProjectSettings.globalize_path("user://loop_result.json")
	_sl_result_path = ProjectSettings.globalize_path("user://suggest_loop.json")
	_convert_result_path = ProjectSettings.globalize_path("user://to_wav_result.json")
	_to16_result_path = ProjectSettings.globalize_path("user://to_16bit_result.json")
	_to16_spec_path = ProjectSettings.globalize_path("user://to_16bit_spec.json")
	_to16_progress_path = ProjectSettings.globalize_path("user://to_16bit_progress.json")
	_sg_renames_path = ProjectSettings.globalize_path("user://analyse_renames.json")
	_pa_paths_file = ProjectSettings.globalize_path("user://analyse_paths.json")
	_sem_result_path = ProjectSettings.globalize_path("user://search_result.json")
	_clap_search_result_path = ProjectSettings.globalize_path("user://clap_search_result.json")
	_emb_path = data_dir.path_join("embeddings.npz")
	_emb_progress_path = ProjectSettings.globalize_path("user://embed_progress.json")
	_fp_progress_path = ProjectSettings.globalize_path("user://fingerprint_progress.json")
	_similar_result_path = ProjectSettings.globalize_path("user://similar_result.json")
	_clap_dl_result_path = ProjectSettings.globalize_path("user://clap_download.json")
	_clapidx_progress_path = ProjectSettings.globalize_path("user://clap_progress.json")
	_rescan_progress_path = ProjectSettings.globalize_path("user://rescan_progress.json")
	# So the indexer scripts / frozen tool.exe resolve app/index.json + library.cfg
	# from the app's own location (globalize res://.. = the repo/dist root).
	OS.set_environment("SOUNDLIB_REPO", _repo_root())
	_load_userdata()
	_load_chopping()
	_load_loudness()
	_build_ui()
	_load_index()
	_apply_view_prefs()
	call_deferred("_start_rescan")              # pick up files added since last run (background)


# Open at half the screen AREA (≈71% on each axis), keeping the screen's aspect
# ratio, centered — but never narrower than the table needs, so every column is
# visible. On a 4K (3840×2160) display that's ~2715×1527.
func _size_window_to_screen() -> void:
	var win := get_window()
	var scr := win.current_screen
	var ss := DisplayServer.screen_get_size(scr)
	if ss.x <= 0 or ss.y <= 0:
		return
	var scale := 0.70710678                       # 1/sqrt(2) → half the total area
	var size := Vector2i(int(round(ss.x * scale)), int(round(ss.y * scale)))
	var min_w := 300                              # keyword panel + handle + scrollbar
	for w in COL_DEFAULT_W:
		min_w += w                                # all column widths
	size.x = clampi(size.x, mini(min_w, ss.x), ss.x)
	size.y = mini(size.y, ss.y)
	win.mode = Window.MODE_WINDOWED
	win.size = size
	win.position = DisplayServer.screen_get_position(scr) + (ss - size) / 2


# Restore saved window geometry, else size to the screen. Ignores absurd/tiny
# saved sizes (e.g. from a headless run) so the window never opens unusable.
func _apply_window_prefs() -> void:
	var sw := int(_prefs.get("win_w", 0))
	var sh := int(_prefs.get("win_h", 0))
	if sw >= 800 and sh >= 500:
		var win := get_window()
		win.mode = Window.MODE_WINDOWED
		win.size = Vector2i(sw, sh)
		if _prefs.has("win_x") and _prefs.has("win_y"):
			win.position = Vector2i(int(_prefs["win_x"]), int(_prefs["win_y"]))
	else:
		_size_window_to_screen()


# Restore column widths, sort, search/filters and toggles after the UI + data
# are built. Calls _apply() once at the end to re-filter/sort with them.
func _apply_view_prefs() -> void:
	if _prefs.get("col_w") is Array and _prefs["col_w"].size() == COL_COUNT:
		for c in COL_COUNT:
			_col_w[c] = int(_prefs["col_w"][c])
			_tree.set_column_custom_minimum_width(c, _col_w[c])
	if _prefs.has("sort_col"):
		_sort_col = clampi(int(_prefs["sort_col"]), 0, COL_COUNT - 1)
		_sort_asc = bool(_prefs.get("sort_asc", true))
		for c in COL_COUNT:
			var arrow := ("  v" if _sort_asc else "  ^") if c == _sort_col else ""
			_tree.set_column_title(c, COL_TITLES[c] + arrow)
	if _prefs.has("autoplay"):
		_autoplay.button_pressed = bool(_prefs["autoplay"])
	if _prefs.has("loop"):
		_loop_chk.button_pressed = bool(_prefs["loop"])   # toggled -> _loop_on
	if _prefs.has("volume"):
		_vol_slider.value = float(_prefs["volume"])       # value_changed -> _on_volume_changed
	if _prefs.has("search"):
		_search.text = String(_prefs["search"])
	_apply()


func _save_prefs() -> void:
	var win := get_window()
	_prefs = {
		"win_w": win.size.x, "win_h": win.size.y,
		"win_x": win.position.x, "win_y": win.position.y,
		"col_w": _col_w.duplicate(),
		"sort_col": _sort_col, "sort_asc": _sort_asc,
		"search": _search.text if _search else "",
		"autoplay": _autoplay.button_pressed if _autoplay else true,
		"loop": _loop_on,
		"volume": _global_vol,
	}
	_save_json_atomic(_prefs_path, _prefs)


## Directory for user data (ratings / play counts / tags) and analysis results:
## the library root from library.cfg (e.g. S:\code\sound_lib_data). Falls back to
## the project folder only if the config can't be read.
# Repo/dist root that holds app/, indexer/, library.cfg (globalize res://.. ).
func _repo_root() -> String:
	return ProjectSettings.globalize_path("res://../").simplify_path()


# The frozen standalone tool (bundles Python + deps), if present; else "".
func _tool_exe() -> String:
	var exe := _repo_root().path_join("tool/tool.exe")
	return exe if FileAccess.file_exists(exe) else ""


# Run an indexer command. args[0] is the .py script path used in dev (py script.py);
# when the frozen tool.exe is present we call `tool.exe <cmd> <rest>` instead, so end
# users need no Python. Output is captured in `output`.
func _exec_tool(args: Array, output: Array) -> void:
	var exe := _tool_exe()
	if exe != "":
		var a := args.slice(1)
		a.insert(0, String(args[0]).get_file().get_basename())   # "search.py" -> "search"
		OS.execute(exe, a, output, true)
	else:
		var code := OS.execute("py", args, output, true)
		if code == -1:
			OS.execute("python", args, output, true)


func _data_dir() -> String:
	var cfg := ProjectSettings.globalize_path("res://../library.cfg").simplify_path()
	if FileAccess.file_exists(cfg):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(cfg))
		if typeof(d) == TYPE_DICTIONARY and d.has("library_root"):
			var root := String(d["library_root"]).replace("\\", "/")
			if DirAccess.dir_exists_absolute(root):
				return root
	return ProjectSettings.globalize_path("res://")


# ===========================================================================
#  UI construction
# ===========================================================================
func _build_ui() -> void:
	# top-level split: everything on the left, the Keywords panel as a full-height
	# (top-to-bottom) column on the right.
	var outer := HSplitContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(outer)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	outer.add_child(root)
	outer.add_child(_build_keyword_panel())        # one panel; a mode picker (Filter/
	                                               # Semantic/CLAP) sets what a click does
	outer.set_deferred("split_offset", 5000)       # left takes the slack

	# --- toolbar row: library folder (top-left) + path ------------------
	var barlib := HBoxContainer.new()
	barlib.add_theme_constant_override("separation", 8)
	root.add_child(barlib)

	var helpbtn := Button.new()
	helpbtn.text = "Help"
	helpbtn.tooltip_text = "What every part of the app does."
	helpbtn.pressed.connect(_show_help)
	barlib.add_child(helpbtn)

	var libbtn := Button.new()
	libbtn.text = "Choose library folder"
	libbtn.tooltip_text = "Pick the folder that holds your sound library. The app " \
		+ "updates library.cfg, re-indexes that folder, and reloads. (To open a " \
		+ "single track's folder, right-click it → Open folder.)"
	libbtn.pressed.connect(_on_choose_library)
	barlib.add_child(libbtn)

	_rescan_btn = Button.new()
	_rescan_btn.text = "Rescan library"
	_rescan_btn.tooltip_text = "Update EVERYTHING end-to-end: rescan the folder for " \
		+ "added/changed/removed files, then analyse audio (chops + loudness), build " \
		+ "fingerprints, the semantic index, and the CLAP index (if downloaded). All " \
		+ "incremental and in the background — runs at startup too; click any time " \
		+ "you've moved files in."
	_rescan_btn.pressed.connect(_start_rescan)
	barlib.add_child(_rescan_btn)

	_lib_label = Label.new()                       # the library-root path
	_lib_label.clip_text = true
	_lib_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.66))
	barlib.add_child(_lib_label)

	barlib.add_child(VSeparator.new())
	_status_label = Label.new()                    # status / messages, top row
	_status_label.clip_text = true
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.66))
	barlib.add_child(_status_label)

	# --- toolbar row: SEMANTIC search (meaning of the text metadata) ------
	var bar0 := HBoxContainer.new()
	bar0.add_theme_constant_override("separation", 8)
	root.add_child(bar0)

	_sem_edit = LineEdit.new()
	_sem_edit.placeholder_text = "Semantic (words): describe a sound — \"guns shooting\" — Enter. Matches the MEANING of the text."
	_sem_edit.clear_button_enabled = true
	_sem_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sem_edit.text_submitted.connect(_on_semantic_submitted)
	_sem_edit.text_changed.connect(_on_semantic_text_changed)   # emptying it unsearches
	bar0.add_child(_sem_edit)

	# --- toolbar row: CLAP search (by SOUND) + its build buttons ----------
	var barclap := HBoxContainer.new()
	barclap.add_theme_constant_override("separation", 8)
	root.add_child(barclap)

	_clap_dl_btn = Button.new()
	_clap_dl_btn.text = "Download CLAP"
	_clap_dl_btn.tooltip_text = "Download the CLAP model (~120 MB audio + ~500 MB text; " \
		+ "ONNX, no PyTorch) → enables the CLAP sound-search box + a much stronger Find " \
		+ "similar. In the standalone the code is bundled — just click this, then Rescan " \
		+ "library (it builds the CLAP index as its last step). (Source build: pip install " \
		+ "-r indexer/requirements-clap.txt first.)"
	_clap_dl_btn.pressed.connect(_download_clap)
	barclap.add_child(_clap_dl_btn)

	_clap_edit = LineEdit.new()
	_clap_edit.placeholder_text = "CLAP (by sound): describe it — \"creepy metallic scrape\" — Enter. Matches the actual SOUND. (needs Download CLAP + Rescan)"
	_clap_edit.clear_button_enabled = true
	_clap_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clap_edit.text_submitted.connect(_on_clap_submitted)
	_clap_edit.text_changed.connect(_on_clap_text_changed)
	barclap.add_child(_clap_edit)

	# --- toolbar row: Clear filters + count + text Filter box (one row) ----
	var bar1 := HBoxContainer.new()
	bar1.add_theme_constant_override("separation", 8)
	root.add_child(bar1)

	var clear := Button.new()
	clear.text = "Clear filters"
	clear.pressed.connect(_on_clear)
	bar1.add_child(clear)

	_count_label = Label.new()
	bar1.add_child(_count_label)

	_search = LineEdit.new()
	_search.placeholder_text = "filter by filename / library / supplier / description / tags  (space = AND)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	bar1.add_child(_search)

	_autoplay = CheckButton.new()                # added to the player bar below
	_autoplay.text = "Autoplay"
	_autoplay.button_pressed = true

	# --- table ----------------------------------------------------------
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.columns = COL_COUNT
	_tree.column_titles_visible = true
	_tree.hide_root = true
	# Multi (cell) select so you can Ctrl/Shift-pick a range of Tags cells and
	# Ctrl+C / Ctrl+V like a spreadsheet. Row actions still use get_selected().
	_tree.select_mode = Tree.SELECT_MULTI
	_tree.allow_reselect = true
	_tree.allow_rmb_select = true          # so right-click emits item_mouse_selected (context menu)
	# Column widths (resizable by dragging the dividers in the header row).
	_col_w = COL_DEFAULT_W.duplicate()
	for c in COL_COUNT:
		_tree.set_column_title(c, COL_TITLES[c])
		_tree.set_column_clip_content(c, true)
		_tree.set_column_expand(c, false)
		_tree.set_column_custom_minimum_width(c, _col_w[c])
	_tree.column_title_clicked.connect(_on_title_clicked)
	_tree.item_selected.connect(_on_row_selected)
	_tree.multi_selected.connect(_on_multi_selected)   # SELECT_MULTI emits this
	_tree.item_activated.connect(_on_row_activated)
	_tree.item_mouse_selected.connect(_on_tree_mouse_selected)
	_tree.item_edited.connect(_on_tree_item_edited)
	_tree.gui_input.connect(_on_tree_gui_input)
	_tree.focus_exited.connect(_commit_cell_edit)   # clicking away commits a type-over

	# --- table: per-column filter header ABOVE the tree (shares the tree's column
	#     widths / horizontal scroll so the filters line up over the columns) ---
	var tablebox := VBoxContainer.new()
	tablebox.add_theme_constant_override("separation", 0)
	tablebox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tablebox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_filter_header = Control.new()
	_filter_header.custom_minimum_size = Vector2(0, 28)
	_filter_header.clip_contents = true
	tablebox.add_child(_filter_header)
	tablebox.add_child(_tree)
	# yellow border over the row whose track is playing (mouse-ignored overlay on
	# top of the Tree; positioned/redrawn each frame in _process to follow scroll)
	_row_hl = RowHighlight.new()
	_row_hl.tree = _tree
	_row_hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row_hl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tree.add_child(_row_hl)
	root.add_child(tablebox)

	# Draggable resize grabbers (white ◄► strips). One per column edge, floated on
	# top of the whole window so each spans BOTH the filter row and the sort/title
	# row; positioned every frame in _layout_filter_header. Children of self so the
	# 8px strips draw above the table and capture the press at an edge.
	_grabbers.clear()
	for i in range(COL_COUNT):
		var g := ColGrabber.new()
		g.col = -1
		g.visible = false
		g.gui_input.connect(_on_grabber_input.bind(g))
		add_child(g)
		_grabbers.append(g)

	# right-click row context menu
	_ctx_menu = PopupMenu.new()
	_ctx_menu.add_item("Open folder", 0)
	_ctx_menu.add_item("Copy path", 1)
	_ctx_menu.add_separator()
	_ctx_menu.add_item("Suggest loop  (audition)", 2)
	_ctx_menu.add_item("Suggest chops  (audition)", 3)
	_ctx_menu.add_item("Find similar sounds", 8)
	_ctx_menu.add_separator()
	_ctx_menu.add_item("Make loop", 4)
	_ctx_menu.add_item("Make chops", 5)
	_ctx_menu.add_separator()
	_ctx_menu.add_item("Convert to WAV", 6)
	_ctx_menu.add_item("Convert to 16-bit (copy)", 9)
	_ctx_menu.add_separator()
	_ctx_menu.add_item("Delete…", 7)
	_ctx_menu.id_pressed.connect(_on_ctx_menu)
	add_child(_ctx_menu)

	# Delete confirmation (Del key or context menu) -> moves files to the Recycle Bin
	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Delete files"
	_confirm_dialog.ok_button_text = "Yes"
	_confirm_dialog.get_cancel_button().text = "No"
	_confirm_dialog.confirmed.connect(_do_delete_confirmed)
	add_child(_confirm_dialog)

	_info_dialog = AcceptDialog.new()              # summaries (e.g. files renamed)
	add_child(_info_dialog)

	_build_num_popup()

	# Lower section, grouped into rows: transport+rating, then loop, then chops,
	# then the visualiser at the very bottom.
	_build_transport_row(root)     # Row 1: play/stop/autoplay/loop/vol + rating
	_build_analyser(root)          # Row 2 (loop) + Row 3 (chops) + visualiser (bottom)

	# (status label lives on the top "Open folder" row — built there)

	# debounce for search typing
	_debounce = Timer.new()
	_debounce.wait_time = 0.15
	_debounce.one_shot = true
	_debounce.timeout.connect(_apply)
	add_child(_debounce)

	# debounce auto-analysis so scrolling through rows doesn't spawn a Python
	# read per row -- only the row you settle on gets analysed.
	_an_debounce = Timer.new()
	_an_debounce.wait_time = 0.25
	_an_debounce.one_shot = true
	_an_debounce.timeout.connect(_auto_analyse)
	add_child(_an_debounce)

	# poll the current update-pipeline step's progress file while it runs
	_rescan_poll = Timer.new()
	_rescan_poll.wait_time = 0.5
	_rescan_poll.timeout.connect(_rescan_tick)
	add_child(_rescan_poll)

	_to16_poll = Timer.new()
	_to16_poll.wait_time = 0.5
	_to16_poll.timeout.connect(_to16_tick)
	add_child(_to16_poll)

	# coalesce chopping.json writes so a slider/graph drag saves once, not per tick
	_chop_save_debounce = Timer.new()
	_chop_save_debounce.wait_time = 0.4
	_chop_save_debounce.one_shot = true
	_chop_save_debounce.timeout.connect(_save_chopping)
	add_child(_chop_save_debounce)


# ===========================================================================
#  Per-column filters (text / tick-box / min–max, by column type)
# ===========================================================================
# The string value a column filters on (text + tick columns).
func _filter_string_value(rec: Dictionary, col: int) -> String:
	match col:
		COL_FILENAME: return String(rec.get("filename", ""))
		COL_DIRECTORY: return _directory_of(rec)
		COL_LIBRARY: return String(rec.get("library", ""))
		COL_SUPPLIER: return String(rec.get("supplier", ""))
		COL_BUNDLE: return String(rec.get("bundle", ""))
		COL_TAGS: return _get_tags(rec)
	return ""


# The full directory holding this file (its absolute path minus the filename) — the
# value shown in the Directory column and used to sort/filter it.
func _directory_of(rec: Dictionary) -> String:
	var full := _abs_path(rec)
	var slash := full.rfind("/")
	return full.substr(0, slash) if slash > 0 else full


const STRING_FILTER_COLS := [COL_FILENAME, COL_DIRECTORY, COL_LIBRARY, COL_SUPPLIER, COL_BUNDLE, COL_TAGS]


func _distinct_values(col: int) -> Array:
	if _distinct_cache.has(col):
		return _distinct_cache[col]
	var seen := {}
	for rec in _all:
		var v := _filter_string_value(rec, col)
		if v != "":
			seen[v] = true
	var vals := seen.keys()
	vals.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	_distinct_cache[col] = vals
	return vals


# "num" (min/max), "tick" (few distinct -> checkboxes), "text" (substring), or "".
func _col_filter_kind(col: int) -> String:
	if col in NUMERIC_COLS:
		return "num"
	if col in STRING_FILTER_COLS:
		return "tick" if _distinct_values(col).size() <= TICK_MAX else "text"
	return ""


# Build a filter control per column inside the aligned header (after data load).
func _build_filter_controls() -> void:
	_distinct_cache = {}
	_range_cache = {}
	for c in _colfilters:
		_colfilters[c].queue_free()
	_colfilters = {}
	for col in COL_COUNT:
		var ctrl: Control = null
		match _col_filter_kind(col):
			"text":
				var le := LineEdit.new()
				le.placeholder_text = "filter"
				le.add_theme_font_size_override("font_size", 12)
				le.text_changed.connect(func(t: String):
					var s := t.strip_edges().to_lower()
					if s == "": _filter_text.erase(col)
					else: _filter_text[col] = s
					_debounce.start())
				ctrl = le
			"tick":
				var mb := MenuButton.new()
				mb.text = COL_TITLES[col]
				mb.clip_text = true
				var pop := mb.get_popup()
				pop.hide_on_checkable_item_selection = false
				var vals := _distinct_values(col)
				for i in vals.size():
					pop.add_check_item(_short_bundle(vals[i]) if col == COL_BUNDLE else vals[i], i)
					pop.set_item_metadata(i, vals[i])
				pop.id_pressed.connect(_on_tick_toggled.bind(col, mb))
				ctrl = mb
			"num":
				var b := Button.new()
				b.text = "min–max"
				b.add_theme_font_size_override("font_size", 11)
				b.pressed.connect(_on_num_filter_pressed.bind(col, b))
				ctrl = b
		if ctrl:
			ctrl.tooltip_text = COL_TITLES[col]
			_filter_header.add_child(ctrl)
			_colfilters[col] = ctrl
	_layout_filter_header()


func _on_tick_toggled(id: int, col: int, mb: MenuButton) -> void:
	var pop := mb.get_popup()
	var idx := pop.get_item_index(id)
	var checked := not pop.is_item_checked(idx)
	pop.set_item_checked(idx, checked)
	var s: Dictionary = _filter_set.get(col, {})
	var val := String(pop.get_item_metadata(idx))
	if checked: s[val] = true
	else: s.erase(val)
	if s.is_empty(): _filter_set.erase(col)
	else: _filter_set[col] = s
	mb.text = COL_TITLES[col] + ("" if s.is_empty() else " (%d)" % s.size())
	_apply()


func _build_num_popup() -> void:
	_num_popup = PopupPanel.new()
	add_child(_num_popup)
	var vb := VBoxContainer.new()
	_num_popup.add_child(vb)
	_num_lbl = Label.new()
	vb.add_child(_num_lbl)
	_num_slider = RangeSlider.new()
	_num_slider.custom_minimum_size = Vector2(340, 56)
	_num_slider.changed.connect(_on_range_changed)
	vb.add_child(_num_slider)
	var clearb := Button.new()
	clearb.text = "Clear (show all)"
	clearb.pressed.connect(_on_num_filter_clear)
	vb.add_child(clearb)
	# apply the filter only when the popup closes (click away) — not on every drag,
	# which would re-filter the whole table mid-drag and make the knobs unusable.
	_num_popup.popup_hide.connect(_on_num_popup_hide)


# Min/max for a column across the data (cached). Uses _num_value so "absent"
# rows (NaN) don't pollute the range.
func _col_data_range(col: int) -> Array:
	if _range_cache.has(col):
		return _range_cache[col]
	var lo := INF
	var hi := -INF
	for rec in _all:
		var v := _num_value(rec, col)
		if is_nan(v):
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
	if lo == INF:
		lo = 0.0
		hi = 1.0
	_range_cache[col] = [lo, hi]
	return _range_cache[col]


func _on_num_filter_pressed(col: int, btn: Button) -> void:
	_num_popup_col = col
	_num_lbl.text = "%s   (drag the two knobs)" % COL_TITLES[col]
	var rng := _col_data_range(col)
	var dlo := float(rng[0])
	var dhi := float(rng[1])
	var clo := float(_filter_min.get(col, dlo))
	var chi := float(_filter_max.get(col, dhi))
	var uselog: bool = dlo > 0.0 and dhi / maxf(dlo, 1e-9) > 100.0
	_num_slider.fmt_value = _fmt_col_value.bind(col)   # mm:ss / MB / dB per column
	_num_slider.setup(dlo, dhi, clo, chi, uselog)
	var gp := btn.get_screen_position()
	_num_popup.position = Vector2i(int(gp.x), int(gp.y + btn.size.y))
	_num_popup.popup()


# Live during a drag: update the stored range + the button label, but do NOT
# re-filter (that happens once on popup close, in _on_num_popup_hide).
func _on_range_changed(lo: float, hi: float) -> void:
	if _num_popup_col < 0:
		return
	var rng := _col_data_range(_num_popup_col)
	if lo <= rng[0] + 1e-9 and hi >= rng[1] - 1e-9:   # full range -> no filter
		_filter_min.erase(_num_popup_col)
		_filter_max.erase(_num_popup_col)
	else:
		_filter_min[_num_popup_col] = lo
		_filter_max[_num_popup_col] = hi
	_mark_num_btn(_num_popup_col)


func _on_num_popup_hide() -> void:
	_apply()                                       # apply the chosen range now


func _on_num_filter_clear() -> void:
	if _num_popup_col < 0:
		return
	_filter_min.erase(_num_popup_col)
	_filter_max.erase(_num_popup_col)
	_mark_num_btn(_num_popup_col)
	_num_popup.hide()                              # popup_hide -> _apply


func _mark_num_btn(col: int) -> void:
	var b: Variant = _colfilters.get(col)
	if b is Button:
		var active: bool = _filter_min.has(col) or _filter_max.has(col)
		b.text = ("%s–%s" % [_fmt_col_value(float(_filter_min.get(col, 0.0)), col),
			_fmt_col_value(float(_filter_max.get(col, 0.0)), col)]) if active else "min–max"


# Position each filter control over its column, using the Tree's ACTUAL drawn
# cell rects (exact: accounts for the panel margin, inter-column spacing and the
# horizontal scroll, which summing _col_w does not).
func _layout_filter_header() -> void:
	if _filter_header == null or _tree == null:
		return
	var root := _tree.get_root()
	if root == null:
		return
	var first := root.get_first_child()
	if first == null:
		return
	var h := _filter_header.size.y
	var edge_cols := PackedInt32Array()              # columns that have a visible edge
	var edge_xs := PackedFloat32Array()              # their right-edge x (tree/header-local)
	for col in COL_COUNT:
		var r := _tree.get_item_area_rect(first, col)   # exact column x + width
		var ctrl: Variant = _colfilters.get(col)
		if ctrl != null:
			# leave an 8px gap at the right (the divider side) so the grabber strip
			# there is clear of the filter control beneath it.
			ctrl.position = Vector2(r.position.x, 2.0)
			ctrl.size = Vector2(maxf(8.0, r.size.x - 8.0), h - 4.0)
		var ex := r.end.x                                # right divider of this column
		if ex > 2.0 and ex < _filter_header.size.x - 1.0:
			edge_cols.append(col)
			edge_xs.append(ex)

	# Float each grabber over its column edge, spanning the filter row + the
	# sort/title row, in self-local space (grabbers are children of self).
	var origin := global_position
	var fhg := _filter_header.global_position
	var top := fhg.y - origin.y
	var span := _filter_header.size.y + _header_height()
	var gi := 0
	for k in range(edge_xs.size()):
		if gi >= _grabbers.size():
			break
		var g: ColGrabber = _grabbers[gi]
		g.col = edge_cols[k]
		g.position = Vector2(fhg.x + edge_xs[k] - origin.x - 4.0, top)
		g.size = Vector2(8.0, span)
		g.visible = true
		g.queue_redraw()
		gi += 1
	while gi < _grabbers.size():
		_grabbers[gi].visible = false
		_grabbers[gi].col = -1
		gi += 1


# A column's numeric value for filtering — NaN when the row has no value there
# (so absent rows don't pollute ranges and are excluded by an active range).
func _num_value(rec: Dictionary, col: int) -> float:
	match col:
		COL_SCORE:
			var s: Variant = _sem_scores.get(String(rec.get("path", "")))
			return float(s) if s != null else NAN
		COL_CHOP_DB:
			var v := _chop_db_val(rec); return NAN if v < -150.0 else v
		COL_CHOP_GAP:
			var v := _chop_gap_val(rec); return NAN if v < -0.5 else v
		COL_CHOP_SND:
			var v := _chop_snd_val(rec); return NAN if v < -0.5 else v
		COL_CHOP_N:
			var v := _chop_n_val(rec); return NAN if v < 0 else float(v)
		COL_LEVEL:
			return _get_level(rec)
		COL_LOUDNESS:
			return _loudness_rms(rec)
		COL_GAIN_DB:
			return _get_gain_db(rec)
		COL_FINAL_DB:
			return _final_db(rec)
	return float(_sort_value(rec, col))            # duration/rate/bit/ch/size/rating/plays


# Does a row pass every active per-column filter?
func _passes_col_filters(rec: Dictionary) -> bool:
	for col in _filter_text:                       # substring (text columns)
		if not _filter_string_value(rec, col).to_lower().contains(String(_filter_text[col])):
			return false
	for col in _filter_set:                        # allow-set (tick columns)
		if not _filter_set[col].has(_filter_string_value(rec, col)):
			return false
	for col in _filter_min:                        # numeric range
		var v := _num_value(rec, col)
		if is_nan(v) or v < float(_filter_min[col]) or v > float(_filter_max.get(col, 1e18)):
			return false
	return true


# The "Semantic" keyword panel: same style as Keywords, but clicking a token runs
# a MEANING-based search (into the semantic box) instead of a text quick-filter.
func _show_help() -> void:
	if _help_dialog == null:
		_help_dialog = AcceptDialog.new()
		_help_dialog.title = "Sound Library — Help"
		_help_dialog.min_size = Vector2i(780, 700)
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(740, 620)
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.fit_content = true
		rt.custom_minimum_size = Vector2(716, 0)
		rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rt.add_theme_constant_override("line_separation", 3)
		rt.text = HELP_TEXT
		scroll.add_child(rt)
		_help_dialog.add_child(scroll)
		add_child(_help_dialog)
	_help_dialog.popup_centered()


# One Keywords panel; a radio picker chooses what a keyword CLICK does — add to the
# text Filter, run a Semantic (meaning) search, or a CLAP (sound) search. Same list.
func _build_keyword_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(216, 0)
	panel.add_theme_constant_override("separation", 4)

	_kw_header = Label.new()
	_kw_header.text = "Keywords"
	panel.add_child(_kw_header)

	# mode radio: Filter / Semantic / CLAP (what a click applies)
	var modebar := HBoxContainer.new()
	modebar.add_theme_constant_override("separation", 2)
	panel.add_child(modebar)
	var grp := ButtonGroup.new()
	var labels := ["Filter", "Semantic", "CLAP"]
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.toggle_mode = true
		b.button_group = grp
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = (i == _kw_mode)
		b.pressed.connect(_set_kw_mode.bind(i))
		modebar.add_child(b)

	_kw_hint = Label.new()
	_kw_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	panel.add_child(_kw_hint)

	_kw_filter = LineEdit.new()
	_kw_filter.placeholder_text = "find keyword..."
	_kw_filter.clear_button_enabled = true
	_kw_filter.text_changed.connect(func(_t): _populate_keyword_list())
	panel.add_child(_kw_filter)

	_kw_list = ItemList.new()
	_kw_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_kw_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_kw_list.item_clicked.connect(_on_keyword_clicked)
	panel.add_child(_kw_list)
	_set_kw_mode(_kw_mode)                          # set the hint text
	return panel


func _set_kw_mode(m: int) -> void:
	_kw_mode = m
	if _kw_hint:
		_kw_hint.text = ["click a keyword → add to the text Filter",
			"click a keyword → search by meaning (semantic)",
			"click a keyword → search by sound (CLAP)"][m]


# A small grey group label that heads each tool row.
func _group_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(52, 0)
	l.add_theme_color_override("font_color", Color(0.6, 0.68, 0.82))
	return l


# Row 1: standard transport (play/stop/autoplay/loop/vol) + rating + now-playing.
func _build_transport_row(root: VBoxContainer) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)
	bar.add_child(_group_label("Track"))

	_play_btn = Button.new()
	_play_btn.text = "Play Track"
	_play_btn.custom_minimum_size = Vector2(100, 0)
	_play_btn.pressed.connect(_on_play_track_pressed)
	_play_btn.tooltip_text = "Play the selected track. (Chops/loops play via their own buttons.)"
	bar.add_child(_play_btn)

	var stop := Button.new()
	stop.text = "Stop"
	stop.pressed.connect(_on_stop_pressed)
	bar.add_child(stop)

	_autoplay.focus_mode = Control.FOCUS_NONE      # don't eat the Space shortcut
	bar.add_child(_autoplay)

	_loop_chk = CheckButton.new()
	_loop_chk.text = "Loop"
	_loop_chk.tooltip_text = "Replay this track: loop the current track seamlessly."
	_loop_chk.focus_mode = Control.FOCUS_NONE
	_loop_chk.toggled.connect(_on_loop_toggled)
	bar.add_child(_loop_chk)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(110, 0)
	_time_label.text = "0:00 / 0:00"
	bar.add_child(_time_label)

	var vlab := Label.new()
	vlab.text = "Vol"
	bar.add_child(vlab)
	_vol_slider = HSlider.new()
	_vol_slider.min_value = 0.0
	_vol_slider.max_value = 1.0
	_vol_slider.step = 0.01
	_vol_slider.value = 0.9
	_vol_slider.custom_minimum_size = Vector2(110, 0)
	_vol_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_vol_slider.value_changed.connect(_on_volume_changed)
	bar.add_child(_vol_slider)
	_on_volume_changed(0.9)

	bar.add_child(VSeparator.new())
	var rlab := Label.new()
	rlab.text = "Rate:"
	rlab.tooltip_text = "Rate the selected row (or click stars in the Rating column; right-click clears)."
	bar.add_child(rlab)
	for i in range(1, 6):
		var b := Button.new()
		b.custom_minimum_size = Vector2(34, 0)
		b.tooltip_text = "%d star%s" % [i, "" if i == 1 else "s"]
		b.pressed.connect(_on_star_pressed.bind(i))
		bar.add_child(b)
		_star_btns.append(b)
	var clr := Button.new()
	clr.text = "Clear"
	clr.pressed.connect(_on_star_pressed.bind(0))
	bar.add_child(clr)
	_refresh_star_buttons(null)

	bar.add_child(VSeparator.new())
	_now_label = Label.new()
	_now_label.text = "No file loaded."
	_now_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_now_label.clip_text = true
	bar.add_child(_now_label)


# Row 2 (loop) + Row 3 (chops) + the visualiser at the very bottom.
func _build_analyser(root: VBoxContainer) -> void:
	# --- Row 2: LOOP ---------------------------------------------------
	var loopbar := HBoxContainer.new()
	loopbar.add_theme_constant_override("separation", 8)
	root.add_child(loopbar)
	loopbar.add_child(_group_label("Loop"))

	_loop_play_btn = Button.new()
	_loop_play_btn.text = "Play Loop"
	_loop_play_btn.custom_minimum_size = Vector2(100, 0)
	_loop_play_btn.tooltip_text = "Audition the selected region as a seamless crossfaded " \
		+ "loop (turns Crossfade + Loop on). Suggest loop or drag a region first."
	_loop_play_btn.pressed.connect(_on_play_loop)
	loopbar.add_child(_loop_play_btn)

	_suggest_loop_btn = Button.new()
	_suggest_loop_btn.text = "Suggest loop"
	_suggest_loop_btn.custom_minimum_size = Vector2(110, 0)
	_suggest_loop_btn.tooltip_text = "Analyse the file and pick a good seamless-loop " \
		+ "region: a whole number of cycles for rhythmic sounds (gunfire, engines), or " \
		+ "the steady sustain for textures (flame, rain). Sets the region + crossfade " \
		+ "and previews it — tweak, then Make loop."
	_suggest_loop_btn.pressed.connect(_suggest_loop)
	loopbar.add_child(_suggest_loop_btn)

	_loop_btn = Button.new()
	_loop_btn.text = "Make loop"
	_loop_btn.custom_minimum_size = Vector2(100, 0)
	_loop_btn.tooltip_text = "Bake a SEAMLESS loop of the selected region (green) as " \
		+ "name_loop.wav next to the original — equal-power crossfade so it wraps " \
		+ "with no click/seam. Original kept. Set the crossfade (ms) at right."
	_loop_btn.pressed.connect(_make_loop)
	loopbar.add_child(_loop_btn)

	_xfade_chk = CheckButton.new()
	_xfade_chk.text = "Crossfade"
	_xfade_chk.tooltip_text = "Preview the selected region as a SEAMLESS crossfaded " \
		+ "loop (in memory — nothing written). Turn Loop on and press Play chops to " \
		+ "audition; tweak Xfade ms (Enter) and re-drag the region to experiment."
	_xfade_chk.toggled.connect(_on_xfade_changed)
	loopbar.add_child(_xfade_chk)

	var xlab := Label.new()
	xlab.text = "Xfade ms"
	loopbar.add_child(xlab)
	_xfade_edit = LineEdit.new()
	_xfade_edit.text = "100"
	_xfade_edit.custom_minimum_size = Vector2(48, 0)
	_xfade_edit.tooltip_text = "Crossfade length in milliseconds for the loop preview " \
		+ "and Make loop (longer = smoother but blends more of the ends). Enter applies."
	_xfade_edit.text_submitted.connect(func(_t): _on_xfade_changed(true))
	loopbar.add_child(_xfade_edit)

	# --- Row 3: CHOPS --------------------------------------------------
	var chopbar := HBoxContainer.new()
	chopbar.add_theme_constant_override("separation", 8)
	root.add_child(chopbar)
	chopbar.add_child(_group_label("Chops"))

	_chops_play_btn = Button.new()
	_chops_play_btn.text = "Play chops"
	_chops_play_btn.custom_minimum_size = Vector2(100, 0)
	_chops_play_btn.tooltip_text = "Play each chop piece in turn with 1 s of silence " \
		+ "between them, so the boundaries are audibly obvious."
	_chops_play_btn.pressed.connect(_on_play_chops_btn)
	chopbar.add_child(_chops_play_btn)

	var sug := Button.new()
	sug.text = "Suggest Chops"
	sug.custom_minimum_size = Vector2(110, 0)
	sug.tooltip_text = "Set the silence threshold from this file's loudness histogram"
	sug.pressed.connect(_apply_suggested)
	chopbar.add_child(sug)

	_chop_btn = Button.new()
	_chop_btn.text = "Make chops"                   # aligns under 'Make loop'
	_chop_btn.custom_minimum_size = Vector2(100, 0)
	_chop_btn.tooltip_text = "Write each piece as name_chopped_NNN.wav next to the " \
		+ "original (the original is KEPT). Re-run the indexer to see them."
	_chop_btn.pressed.connect(_chop_selected)
	chopbar.add_child(_chop_btn)

	_sil_slider = _add_slider(chopbar, "Silence", -90, 0, 1, DEF_SILENCE_DB)
	_sil_lbl = chopbar.get_child(chopbar.get_child_count() - 1) as Label
	_gap_slider = _add_slider(chopbar, "Min gap", 0.0, 5.0, 0.1, DEF_MIN_GAP_S)
	_gap_lbl = chopbar.get_child(chopbar.get_child_count() - 1) as Label
	_snd_slider = _add_slider(chopbar, "Min sound", 0.0, 2.0, 0.05, DEF_MIN_SOUND_S)
	_snd_lbl = chopbar.get_child(chopbar.get_child_count() - 1) as Label

	# ('Analyse Audio' now lives on the top library row, next to Choose library folder.)
	_an_status = Label.new()
	_an_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_an_status.text = "Analyser idle."
	chopbar.add_child(_an_status)

	# --- visualiser at the very bottom (graph + aligned seek strip) ----
	_graph = WaveGraph.new()
	_graph.custom_minimum_size = Vector2(0, 120)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.tooltip_text = "Left-click-drag: select a region to chop/play. " \
		+ "Right-click-drag: set the height (silence threshold) — also returns to " \
		+ "auto/detector. Seek on the strip below."
	_graph.threshold_picked.connect(_on_graph_threshold_picked)
	_graph.seek_requested.connect(_on_graph_seek)
	_graph.region_selected.connect(_on_graph_region_selected)
	_graph.region_committed.connect(_on_region_committed)
	root.add_child(_graph)

	_seekbar = SeekBar.new()
	_seekbar.custom_minimum_size = Vector2(0, 16)
	_seekbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seekbar.tooltip_text = "Drag to move the play position (does not change the chop dB)."
	_seekbar.seek_requested.connect(_on_graph_seek)
	root.add_child(_seekbar)

	_update_param_labels()


# Adds "label [slider]" to a bar; returns the slider and appends a value Label
# (so the caller can grab it as the last child).
func _add_slider(bar: HBoxContainer, name: String, lo: float, hi: float,
		step: float, val: float) -> HSlider:
	var l := Label.new()
	l.text = name
	bar.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(120, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(func(_v): _on_user_param_changed())
	bar.add_child(s)
	var vl := Label.new()
	vl.custom_minimum_size = Vector2(58, 0)
	bar.add_child(vl)
	return s


# ===========================================================================
#  Data load
# ===========================================================================
func _load_index() -> void:
	# Read the LIVE index.json from disk (globalize), not res:// — in an exported
	# build res:// points into the read-only packed archive, but the indexer writes
	# the real file to disk next to the app. Same path in the editor.
	var path := ProjectSettings.globalize_path("res://index.json")
	if not FileAccess.file_exists(path):
		_status_label.text = "index.json not found. Run:  py indexer/index.py"
		_now_label.text = "No index. Generate it with the Python indexer, then restart."
		return
	var txt := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		_status_label.text = "index.json could not be parsed."
		return
	_all = data.get("files", [])
	_by_path = {}
	for rec in _all:
		_by_path[String(rec.get("path", ""))] = rec
	_library_root = String(data.get("library_root", "")).replace("\\", "/")
	_index_generated = str(data.get("generated", ""))
	if _lib_label:
		_lib_label.text = _library_root            # path shown next to Open folder
	_status_label.text = "indexed %s" % str(data.get("generated", "?"))
	_build_filter_controls()
	_build_keywords()
	_apply()


# ===========================================================================
#  Keyword analysis  (frequency = number of distinct libraries containing it)
# ===========================================================================
func _tokenize(text: String) -> PackedStringArray:
	# Lowercase, split on any run of non-alphanumeric chars (space _ - , . ( ) etc).
	var out := PackedStringArray()
	var cur := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			cur += ch
		elif cur != "":
			out.append(cur)
			cur = ""
	if cur != "":
		out.append(cur)
	return out


func _keep_token(t: String) -> bool:
	if t.length() < KW_MIN_LEN:
		return false
	if STOPWORDS.has(t):
		return false
	# drop pure-number tokens (001, 02, 2020...) but keep alphanumerics like "3d"
	if t.is_valid_int():
		return false
	return true


func _build_keywords() -> void:
	# Group files into libraries, collect the UNIQUE token set per library
	# (library name + every filename in it), then count how many libraries
	# contain each token. So a big library counts a keyword only once.
	var lib_tokens: Dictionary = {}   # lib_id -> { token: true }
	for rec in _all:
		var lib_id := "%s|%s|%s" % [
			String(rec.get("bundle", "")),
			String(rec.get("supplier", "")),
			String(rec.get("library", "")),
		]
		var bag: Dictionary = lib_tokens.get(lib_id, {})
		for t in _tokenize(String(rec.get("library", ""))):
			if _keep_token(t):
				bag[t] = true
		for t in _tokenize(String(rec.get("filename", ""))):
			if _keep_token(t):
				bag[t] = true
		lib_tokens[lib_id] = bag

	var freq: Dictionary = {}
	for lib_id in lib_tokens:
		for t in lib_tokens[lib_id]:
			freq[t] = int(freq.get(t, 0)) + 1

	_keywords = []
	for t in freq:
		_keywords.append([t, freq[t]])
	_keywords.sort_custom(func(a, b):
		if a[1] != b[1]:
			return a[1] > b[1]               # most frequent first
		return a[0].naturalnocasecmp_to(b[0]) < 0
	)
	_populate_keyword_list()


func _populate_keyword_list() -> void:
	if _kw_list == null:
		return
	var filt := _kw_filter.text.strip_edges().to_lower()
	_kw_list.clear()
	var shown := 0
	for pair in _keywords:
		var token: String = pair[0]
		if filt != "" and not token.contains(filt):
			continue
		var idx := _kw_list.add_item("%s  (%d)" % [token, pair[1]])
		_kw_list.set_item_metadata(idx, token)
		shown += 1
		if shown >= KW_MAX_SHOWN:
			break
	_kw_header.text = "Keywords (%d) — n = libraries" % _keywords.size()


func _on_keyword_clicked(index: int, _at: Vector2, _mouse_btn: int) -> void:
	var token := String(_kw_list.get_item_metadata(index))
	match _kw_mode:
		1:                                          # Semantic (meaning) search
			if _sem_edit: _sem_edit.text = token
			_run_semantic(token)
		2:                                          # CLAP (sound) search
			if _clap_edit: _clap_edit.text = token
			_run_clap_search(token)
		_:                                          # Filter: add as an AND term
			var terms := _search.text.strip_edges().to_lower().split(" ", false)
			if token in terms:
				return
			_search.text = (_search.text.strip_edges() + " " + token).strip_edges()
			_apply()


# ===========================================================================
#  Filtering / sorting
# ===========================================================================
func _on_search_changed(_t: String) -> void:
	_debounce.start()                              # filters the base set (live, debounced)


func _on_semantic_submitted(text: String) -> void:
	var q := text.strip_edges()
	if q == "":                                    # Enter on an empty box -> unsearch
		_clear_semantic()
		_apply()
		return
	if _clap_edit:
		_clap_edit.text = ""                       # the two search boxes are exclusive
	_run_semantic(q)


# --- CLAP "search by sound": text -> audio ranking of the library ------------
func _on_clap_submitted(text: String) -> void:
	var q := text.strip_edges()
	if q == "":
		_clear_semantic()
		_apply()
		return
	if _sem_edit:
		_sem_edit.text = ""                        # exclusive with the semantic box
	_run_clap_search(q)


func _on_clap_text_changed(text: String) -> void:
	if text.strip_edges() == "" and _sem_active:
		_clear_semantic()
		_apply()


func _run_clap_search(query: String) -> void:
	if _clap_search_busy:
		return
	if not FileAccess.file_exists(_library_root.path_join("clap.npz")):
		_status_label.text = "CLAP sound search needs the index — Download CLAP, then Rescan library."
		return
	if FileAccess.file_exists(_clap_search_result_path):
		DirAccess.remove_absolute(_clap_search_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/clap_search.py").simplify_path()
	_clap_search_busy = true
	_status_label.text = "CLAP sound search: \"%s\" …" % query
	_clap_search_thread = Thread.new()
	_clap_search_thread.start(_clap_search_run.bind(script, query, _clap_search_result_path))


func _clap_search_run(script: String, query: String, out: String) -> void:
	var output: Array = []
	var args := [script, query, out, "500"]
	_exec_tool(args, output)
	call_deferred("_clap_search_finished")


func _clap_search_finished() -> void:
	_clap_search_busy = false
	if _clap_search_thread:
		_clap_search_thread.wait_to_finish()
		_clap_search_thread = null
	if not FileAccess.file_exists(_clap_search_result_path):
		_status_label.text = "CLAP search failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_clap_search_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		var err := String(d.get("error", "?")) if typeof(d) == TYPE_DICTIONARY else "?"
		if err == "no clap index":
			_status_label.text = "CLAP sound search needs the index — Download CLAP, then Rescan library."
		elif err == "no text model":
			_status_label.text = "CLAP text model missing — click 'Download CLAP'."
		elif err == "deps":
			_status_label.text = "CLAP needs onnxruntime + tokenizers — pip install -r indexer/requirements-clap.txt"
		else:
			_status_label.text = "CLAP search error: %s" % err
		return
	_apply_ranked_results(d.get("paths", []), d.get("scores", []))
	_status_label.text = "CLAP sound-matches for \"%s\" — closest first (%d). Filter narrows." % [
		String(d.get("query", "")), _filtered.size()]


# Emptying the semantic box (backspace or the X button) "unsearches" — reverts to
# the full base set. text_changed fires per keystroke; only act when it goes empty.
func _on_semantic_text_changed(text: String) -> void:
	if text.strip_edges() == "" and _sem_active:
		_clear_semantic()
		_apply()


# Drop the semantic result set as the base (used by clear box + Clear filters).
func _clear_semantic() -> void:
	_sem_active = false
	_sem_ranked = []
	_sem_scores = {}
	if _sort_col == COL_SCORE:                      # leave Score-sort behind
		_sort_col = COL_FILENAME
		_sort_asc = true


func _on_clear() -> void:
	_search.text = ""
	_sem_edit.text = ""                            # Clear filters also clears semantic
	_clear_semantic()
	_filter_text = {}
	_filter_set = {}
	_filter_min = {}
	_filter_max = {}
	_build_filter_controls()                       # reset every column control's UI
	_apply()


# The text box filters the BASE set: the semantic results (in rank order) when a
# semantic search is active, else all files. So semantic finds, text narrows.
func _apply() -> void:
	var base: Array = _sem_ranked if _sem_active else _all
	var tokens := _search.text.strip_edges().to_lower().split(" ", false)
	_filtered = []
	for rec in base:
		if not _passes_col_filters(rec):
			continue
		if tokens.size() > 0:
			var hay := (
				String(rec.get("filename", "")) + " "
				+ String(rec.get("library", "")) + " "
				+ String(rec.get("supplier", "")) + " "
				+ String(rec.get("description", "")) + " "
				+ _get_tags(rec)                       # your own keywords are searchable
			).to_lower()
			var ok := true
			for tok in tokens:
				if not hay.contains(tok):
					ok = false
					break
			if not ok:
				continue
		_filtered.append(rec)

	if not _sem_active:                            # semantic keeps its cosine rank
		_sort_filtered()
	_populate_tree()


# ----- semantic search (indexer/search.py embeds the query, ranks by cosine) --
func _run_semantic(query: String) -> void:
	if query == "":
		_apply()
		return
	if not FileAccess.file_exists(_emb_path):
		_status_label.text = "No semantic index yet — click 'Update index' (or run py indexer/embed.py)."
		return
	if _sem_busy:
		return
	_sem_busy = true
	_status_label.text = "Semantic search: \"%s\" …" % query
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/search.py").simplify_path()
	if FileAccess.file_exists(_sem_result_path):
		DirAccess.remove_absolute(_sem_result_path)
	_sem_thread = Thread.new()
	_sem_thread.start(_sem_run.bind(script, query, _sem_result_path))


func _sem_run(script: String, query: String, out: String) -> void:
	var output: Array = []
	var args := [script, query, out, "500"]
	_exec_tool(args, output)
	call_deferred("_sem_finished")


func _sem_finished() -> void:
	_sem_busy = false
	if _sem_thread:
		_sem_thread.wait_to_finish()
		_sem_thread = null
	if not FileAccess.file_exists(_sem_result_path):
		_status_label.text = "Semantic search failed (no output). Is python + fastembed installed?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_sem_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		_status_label.text = "Semantic search error: %s" % (
			d.get("error", "?") if typeof(d) == TYPE_DICTIONARY else "?")
		return
	_apply_ranked_results(d.get("paths", []), d.get("scores", []))
	_status_label.text = "Semantic results for \"%s\" — most relevant first (%d). Use Filter to narrow." % [
		String(d.get("query", "")), _filtered.size()]


# Make a ranked path list (semantic search OR find-similar) the current base set,
# with the scores in the Score column, sorted best-first. Text/filters still narrow.
func _apply_ranked_results(paths: Array, scores: Array) -> void:
	_sem_ranked = []
	_sem_scores = {}
	for i in paths.size():
		var rp := String(paths[i])
		var rec: Variant = _by_path.get(rp)
		if typeof(rec) == TYPE_DICTIONARY:
			_sem_ranked.append(rec)
			if i < scores.size():
				_sem_scores[rp] = float(scores[i])
	_sem_active = true
	_sort_col = COL_SCORE                       # sorted highest->lowest by default
	_sort_asc = false
	_apply()                                    # narrow by text/dropdowns, keep rank


# ----- optional CLAP: download the model (building its index is part of Rescan) -
func _download_clap() -> void:
	if _clap_dl_busy:
		return
	if FileAccess.file_exists(_clap_dl_result_path):
		DirAccess.remove_absolute(_clap_dl_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/clap_embed.py").simplify_path()
	_clap_dl_busy = true
	_clap_dl_btn.disabled = true
	_clap_dl_btn.text = "Downloading CLAP… (~1 GB)"
	_clap_dl_thread = Thread.new()
	_clap_dl_thread.start(_clap_dl_run.bind(script, _clap_dl_result_path))


func _clap_dl_run(script: String, result: String) -> void:
	var output: Array = []
	var args := [script, "--download", "--result", result]
	_exec_tool(args, output)
	call_deferred("_clap_dl_finished")


func _clap_dl_finished() -> void:
	_clap_dl_busy = false
	if _clap_dl_thread:
		_clap_dl_thread.wait_to_finish()
		_clap_dl_thread = null
	_clap_dl_btn.disabled = false
	_clap_dl_btn.text = "Download CLAP"
	var ok := false
	var err := "CLAP needs onnxruntime + tokenizers — pip install -r indexer/requirements-clap.txt"
	if FileAccess.file_exists(_clap_dl_result_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_clap_dl_result_path))
		if typeof(d) == TYPE_DICTIONARY:
			ok = bool(d.get("ok", false))
			err = String(d.get("error", err))
	_status_label.text = "CLAP model downloaded — click 'Rescan library' to build the CLAP index." if ok else ("Download CLAP failed: " + err)


# ----- bulk "Convert to 16-bit": a 16-bit copy of every selected higher-bit file -
func _sibling_16bit_path(rel: String) -> String:
	var dot := rel.rfind(".")
	if dot < 0:
		return rel + "_16bit.wav"
	return rel.substr(0, dot) + "_16bit.wav"


func _convert_16bit_selected() -> void:
	if _to16_busy:
		return
	var todo: Array = []                           # rel paths that need converting
	var skipped := 0
	var it := _tree.get_next_selected(null)
	while it != null:
		var r: Variant = it.get_metadata(0)
		if typeof(r) == TYPE_DICTIONARY:
			var rel := String(r.get("path", ""))
			var bits: Variant = r.get("bit_depth")
			var sib := _sibling_16bit_path(rel)
			var exists := _by_path.has(sib) or FileAccess.file_exists(_library_root.path_join(sib))
			if typeof(bits) == TYPE_NIL or int(bits) <= 16 or exists:
				skipped += 1                       # already 16-bit/lower, or already done
			else:
				todo.append(rel)
		it = _tree.get_next_selected(it)
	if todo.is_empty():
		_status_label.text = "Nothing to convert — selection is already 16-bit or done (%d skipped)." % skipped
		return
	var f := FileAccess.open(_to16_spec_path, FileAccess.WRITE)
	if f == null:
		_status_label.text = "Could not write 16-bit spec."
		return
	f.store_string(JSON.stringify(todo))
	f.close()
	if FileAccess.file_exists(_to16_result_path):
		DirAccess.remove_absolute(_to16_result_path)
	if FileAccess.file_exists(_to16_progress_path):
		DirAccess.remove_absolute(_to16_progress_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/to_16bit.py").simplify_path()
	_to16_busy = true
	_status_label.text = "Converting %d file%s to 16-bit… (%d skipped)" % [
		todo.size(), "" if todo.size() == 1 else "s", skipped]
	_to16_thread = Thread.new()
	_to16_thread.start(_to16_run.bind(script, _to16_spec_path, _to16_result_path, _to16_progress_path))
	_to16_poll.start()


func _to16_run(script: String, spec: String, result: String, progress: String) -> void:
	var output: Array = []
	var args := [script, "--spec", spec, "--progress", progress, result]
	_exec_tool(args, output)
	call_deferred("_to16_finished")


func _to16_tick() -> void:
	if FileAccess.file_exists(_to16_progress_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_to16_progress_path))
		if typeof(d) == TYPE_DICTIONARY and int(d.get("total", 0)) > 0:
			_status_label.text = "Converting to 16-bit… %d / %d" % [
				int(d.get("analysed", 0)), int(d.get("total", 0))]


func _to16_finished() -> void:
	_to16_poll.stop()
	_to16_busy = false
	if _to16_thread:
		_to16_thread.wait_to_finish()
		_to16_thread = null
	if not FileAccess.file_exists(_to16_result_path):
		_status_label.text = "Convert to 16-bit failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_to16_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		_status_label.text = "Convert to 16-bit error: %s" % (d.get("error", "?") if typeof(d) == TYPE_DICTIONARY else "?")
		return
	var recs: Array = d.get("records", [])
	for rec in recs:                               # each copy inherits its source's data
		var cp := String(rec.get("path", ""))
		var src_rel := cp.substr(0, cp.length() - String("_16bit.wav").length()) + ".wav"
		_inherit_userdata(src_rel, cp)             # tags + target Level + Gain dB + rating
	_save_userdata()
	_merge_new_records(recs)
	_analyse_paths(_paths_of(recs))                # measure dB; Level then re-drives Gain
	_status_label.text = "16-bit: %d converted, %d skipped." % [
		int(d.get("converted", 0)), int(d.get("skipped", 0))]


# Copy a source row's user data (tags, target Level, Gain dB, rating, …) onto a new
# row (e.g. a 16-bit copy) so it behaves the same for balancing. Not saved here.
func _inherit_userdata(src_rel: String, dst_rel: String) -> void:
	var su: Dictionary = _userdata.get(src_rel, {})
	if su.is_empty():
		return
	var du: Dictionary = _userdata.get(dst_rel, {})
	for k in ["tags", "level", "gain_db", "rating", "target_db", "vol_mult"]:
		if su.has(k):
			du[k] = su[k]
	_userdata[dst_rel] = du


# ----- "Find similar": rank the library by how close a file SOUNDS to _ctx_rec ---
func _find_similar(rec: Dictionary) -> void:
	if _similar_busy:
		return
	if String(rec.get("ext", "")).to_lower() != "wav":
		_status_label.text = "Find similar works on WAV files (convert first)."
		return
	if FileAccess.file_exists(_similar_result_path):
		DirAccess.remove_absolute(_similar_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/similar.py").simplify_path()
	_similar_busy = true
	_status_label.text = "Finding sounds similar to %s …" % String(rec.get("filename", ""))
	_similar_thread = Thread.new()
	_similar_thread.start(_similar_run.bind(script, String(rec.get("path", "")), _similar_result_path))


func _similar_run(script: String, rel: String, out: String) -> void:
	var output: Array = []
	var args := [script, rel, out, "500"]
	_exec_tool(args, output)
	call_deferred("_similar_finished")


func _similar_finished() -> void:
	_similar_busy = false
	if _similar_thread:
		_similar_thread.wait_to_finish()
		_similar_thread = null
	if not FileAccess.file_exists(_similar_result_path):
		_status_label.text = "Find similar failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_similar_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		var err := String(d.get("error", "?")) if typeof(d) == TYPE_DICTIONARY else "?"
		if err.begins_with("no fingerprints") or err.begins_with("query not"):
			_status_label.text = "No fingerprints yet — click 'Rescan library' to build them."
		else:
			_status_label.text = "Find similar error: %s" % err
		return
	_sem_edit.text = ""                            # this is a sound-similarity result set
	_apply_ranked_results(d.get("paths", []), d.get("scores", []))
	_status_label.text = "Sounds most similar to %s (%d). Score = acoustic similarity; Filter narrows." % [
		String(d.get("query", "")).get_file(), _filtered.size()]


func _sort_value(rec: Dictionary, col: int) -> Variant:
	# Rating/Plays come from user data; everything else from the record.
	if col == COL_DIRECTORY:
		return _directory_of(rec)
	if col == COL_SCORE:
		return float(_sem_scores.get(String(rec.get("path", "")), -1.0))
	if col == COL_RATING:
		return _get_rating(rec)
	if col == COL_PLAYS:
		return _get_plays(rec)
	if col == COL_CHOP_DB:
		return _chop_db_val(rec)
	if col == COL_CHOP_GAP:
		return _chop_gap_val(rec)
	if col == COL_CHOP_SND:
		return _chop_snd_val(rec)
	if col == COL_CHOP_N:
		return _chop_n_val(rec)
	if col == COL_TAGS:
		return _get_tags(rec)
	if col == COL_GAIN_DB:
		return _get_gain_db(rec)
	if col == COL_LEVEL:
		var t := _get_level(rec)
		return t if not is_nan(t) else -999.0
	if col == COL_LOUDNESS:
		var r := _loudness_rms(rec)
		return r if not is_nan(r) else -999.0
	if col == COL_FINAL_DB:
		var f := _final_db(rec)
		return f if not is_nan(f) else -999.0
	return rec.get(COL_FIELD[col])


func _sort_filtered() -> void:
	var col := _sort_col
	var numeric := col in NUMERIC_COLS
	var asc := _sort_asc
	_filtered.sort_custom(func(a, b):
		var va: Variant = _sort_value(a, col)
		var vb: Variant = _sort_value(b, col)
		var r := 0
		if numeric:
			var fa := float(va) if va != null else -1.0
			var fb := float(vb) if vb != null else -1.0
			r = -1 if fa < fb else (1 if fa > fb else 0)
		else:
			r = String(va).naturalnocasecmp_to(String(vb))
		return r < 0 if asc else r > 0
	)


func _on_title_clicked(col: int, _mouse_btn: int) -> void:
	if _suppress_title_click:                 # a divider drag, not a sort click
		_suppress_title_click = false
		return
	if col == _sort_col:
		_sort_asc = not _sort_asc
	else:
		_sort_col = col
		_sort_asc = true
	# arrow indicator in titles
	for c in COL_COUNT:
		var arrow := ""
		if c == _sort_col:
			arrow = "  v" if _sort_asc else "  ^"
		_tree.set_column_title(c, COL_TITLES[c] + arrow)
	_sort_filtered()
	_populate_tree()


# ===========================================================================
#  Tree population
# ===========================================================================
func _populate_tree() -> void:
	_hover_item = null   # items are about to be freed; drop the stale preview ref
	_hover_star = -1
	_tree.clear()
	var root := _tree.create_item()
	for i in _filtered.size():
		var rec: Dictionary = _filtered[i]
		var odd := (i & 1) == 1                     # zebra: shade every other row
		var it := _tree.create_item(root)
		it.set_text(COL_FILENAME, String(rec.get("filename", "")))
		var dir := _directory_of(rec)
		it.set_text(COL_DIRECTORY, dir)
		it.set_tooltip_text(COL_DIRECTORY, dir)     # full path clips in the cell; hover to read
		it.set_text(COL_LIBRARY, String(rec.get("library", "")))
		it.set_text(COL_SUPPLIER, String(rec.get("supplier", "")))
		it.set_text(COL_BUNDLE, _short_bundle(String(rec.get("bundle", ""))))
		it.set_text(COL_DURATION, _fmt_dur(rec.get("duration")))
		it.set_text(COL_RATE, _fmt_rate(rec.get("sample_rate")))
		it.set_text(COL_BIT, "" if rec.get("bit_depth") == null else str(int(rec.get("bit_depth"))))
		it.set_text(COL_CH, "" if rec.get("channels") == null else str(int(rec.get("channels"))))
		it.set_text(COL_SIZE, _fmt_size(rec.get("size")))
		var sc: Variant = _sem_scores.get(String(rec.get("path", "")))
		it.set_text(COL_SCORE, "%.3f" % float(sc) if sc != null else "")
		_apply_userdata_cells(it, rec)
		_apply_chop_cells(it, rec)
		_apply_loudness_cell(it, rec)
		for c in [COL_SCORE, COL_DURATION, COL_RATE, COL_BIT, COL_CH, COL_SIZE, COL_PLAYS,
				COL_CHOP_DB, COL_CHOP_GAP, COL_CHOP_SND, COL_CHOP_N,
				COL_LEVEL, COL_LOUDNESS, COL_GAIN_DB, COL_FINAL_DB]:
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
		# row background: red if the player can't play it directly, else zebra
		# stripe + editable-cell tint, in one pass over the columns
		var playable := _is_playable(rec)
		for c in range(COL_COUNT):
			if not playable:
				it.set_custom_bg_color(c, UNSUPPORTED_BG_ODD if odd else UNSUPPORTED_BG)
			elif EDITABLE_COLS.has(c):
				it.set_custom_bg_color(c, EDIT_CELL_BG_ODD if odd else EDIT_CELL_BG)
			elif odd:
				it.set_custom_bg_color(c, ZEBRA_BG)
		if not playable:
			it.set_tooltip_text(COL_FILENAME,
				"The player can't play this file directly (non-WAV format, or a WAV with " \
				+ ">2 channels). Right-click -> Convert to WAV, or just press Play to decode " \
				+ "and audition it.")
		it.set_metadata(0, rec)
	_count_label.text = "%d / %d files" % [_filtered.size(), _all.size()]


func _apply_loudness_cell(it: TreeItem, rec: Dictionary) -> void:
	var r := _loudness_rms(rec)
	it.set_text(COL_LOUDNESS, "" if is_nan(r) else "%.1f dB" % r)
	it.set_tooltip_text(COL_LOUDNESS,
		"Measured original loudness (LUFS, integrated). Run 'Analyse audio' to fill.")
	_apply_final_cell(it, rec)


# The resulting playback loudness = orig dB + Gain dB. Read-only; blank until
# loudness is measured.
func _final_db(rec: Variant) -> float:
	var r := _loudness_rms(rec)
	return NAN if is_nan(r) else r + _get_gain_db(rec)


func _apply_final_cell(it: TreeItem, rec: Dictionary) -> void:
	var f := _final_db(rec)
	it.set_text(COL_FINAL_DB, "" if is_nan(f) else "%.1f dB" % f)
	it.set_tooltip_text(COL_FINAL_DB,
		"Resulting loudness when played = orig dB + Gain dB. This is what the Level " \
		+ "is steering. Read-only.")


func _apply_userdata_cells(it: TreeItem, rec: Dictionary) -> void:
	var rating := _get_rating(rec)
	it.set_text(COL_RATING, _stars(rating))
	var plays := _get_plays(rec)
	it.set_text(COL_PLAYS, "" if plays == 0 else str(plays))
	it.set_text(COL_TAGS, _get_tags(rec))
	it.set_editable(COL_TAGS, true)            # double-click to edit
	it.set_tooltip_text(COL_TAGS, "Double-click to edit. Separate keywords with spaces or commas.")
	it.set_text(COL_LEVEL, _fmt_level(_get_level(rec)))
	it.set_editable(COL_LEVEL, true)
	it.set_tooltip_text(COL_LEVEL,
		"How loud you want this to play, on a 0-10 perceptual scale (10 = loudest, " \
		+ "5 = half as loud, 0 = silence). The app sets Gain dB to hit it, capped so " \
		+ "it never clips. Same number = equally loud (needs measured Loudness).")
	it.set_text(COL_GAIN_DB, _fmt_gain(_get_gain_db(rec)))
	it.set_editable(COL_GAIN_DB, true)
	it.set_tooltip_text(COL_GAIN_DB,
		"Applied playback gain in dB (auto-filled from Level when set, else " \
		+ "manual). Negative = quieter (no clipping); positive may clip. Blank = 0.")


# ===========================================================================
#  Playback
# ===========================================================================
func _abs_path(rec: Dictionary) -> String:
	return _library_root.path_join(String(rec.get("path", "")))


# Can the player play this record directly? WAV (mono/stereo) and MP3 only; other
# formats decode to a sibling WAV on demand. Non-playable rows are tinted red and,
# on Play, auto-decoded. (Multichannel WAVs can't preview — see _play_selected.)
func _is_playable(rec: Dictionary) -> bool:
	var ext := String(rec.get("ext", "")).to_lower()
	if ext == "mp3":
		return true
	if ext == "wav":
		var ch := int(rec.get("channels")) if rec.get("channels") != null else 0
		return ch <= 2
	return false


func _on_row_selected() -> void:
	# Selection change updates the rating buttons and (debounced) auto-analyses
	# the row so its sound/dead-space picture shows without pressing Analyse.
	# Playback is decided in _on_tree_mouse_selected so clicking the Rating/Tags/
	# Chop cells doesn't play.
	_refresh_star_buttons(_selected_rec())
	_an_debounce.start()


# In SELECT_MULTI the tree emits multi_selected instead of item_selected; route
# it through the same per-selection refresh (auto-analyse + rating buttons).
func _on_multi_selected(_item: TreeItem, _col: int, _selected: bool) -> void:
	_on_row_selected()


# Auto-analyse the selected row (fired by _an_debounce) unless it's already the
# file in the analyser, isn't a WAV, or an analysis is already running.
func _auto_analyse() -> void:
	var rec: Variant = _selected_rec()
	if rec == null or rec == _an_rec or _an_busy:
		return
	if String(rec.get("ext", "")).to_lower() != "wav":
		return
	_analyse_selected()


func _on_row_activated() -> void:
	# Double-click plays -- except on the editable Rating/Tags/Chop cells, where
	# a double-click opens the editor / sets a rating instead of playing.
	if _last_click_col in [COL_RATING, COL_TAGS, COL_CHOP_DB, COL_CHOP_GAP, COL_CHOP_SND,
			COL_LEVEL, COL_GAIN_DB]:
		return
	_play_selected()


func _on_tree_mouse_selected(pos: Vector2, mouse_btn: int) -> void:
	var it := _tree.get_item_at_position(pos)
	if it == null:
		return
	var rec: Variant = it.get_metadata(0)
	var col := _tree.get_column_at_position(pos)
	_last_click_col = col
	if col == COL_RATING:
		if mouse_btn == MOUSE_BUTTON_RIGHT:
			_apply_rating(rec, it, 0)          # right-click clears
		elif mouse_btn == MOUSE_BUTTON_LEFT:
			_apply_rating(rec, it, _star_at(it, pos.x))
		return                                 # never play when rating
	# (right-click context menu is opened from _on_tree_gui_input so it doesn't
	#  collapse a multi-selection; only the Rating column falls through to here.)
	if col == COL_TAGS or col == COL_CHOP_DB or col == COL_CHOP_GAP or col == COL_CHOP_SND \
			or col == COL_LEVEL or col == COL_GAIN_DB:
		return                                 # let the inline editor handle it
	# Don't autoplay / stop while Shift/Ctrl-extending a selection range.
	var ranging := Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CTRL)
	if mouse_btn == MOUSE_BUTTON_LEFT and not ranging:
		if _autoplay.button_pressed:
			_play_selected()                       # autoplay: the new track replaces the old
		elif rec != _playing_rec and (_player.playing or _player.stream_paused):
			_on_stop_pressed()                     # clicking a DIFFERENT row stops the old
			                                       # track/preview (don't leave it playing)


func _on_tree_item_edited() -> void:
	var it := _tree.get_edited()
	if it == null:
		return
	var col := _tree.get_edited_column()
	var rec: Variant = it.get_metadata(0)
	if col == COL_TAGS:
		_set_tags(rec, it.get_text(COL_TAGS))
	elif col == COL_CHOP_DB or col == COL_CHOP_GAP or col == COL_CHOP_SND:
		_on_chop_edited(rec, it, col)
	elif col == COL_GAIN_DB:
		_on_gain_db_edited(rec, it)
	elif col == COL_LEVEL:
		_on_level_edited(rec, it)


# ===========================================================================
#  Column resizing — drag a white ◄► grabber that spans the filter + sort rows
#  (or a divider in the title row). Tracking runs in _process off the global
#  mouse, so the thin grabber strips don't lose the drag when the cursor leaves.
# ===========================================================================

# Start dragging column `col`'s right edge. Snapshot the global mouse x + width;
# _process updates the width while the button is held, and ends on release.
func _begin_resize(col: int) -> void:
	_resize_col = col
	_resize_start_x = get_global_mouse_position().x
	_resize_start_w = _col_w[col]
	_suppress_title_click = true                   # this drag isn't a sort click


# A grabber strip was pressed -> begin resizing its column.
func _on_grabber_input(event: InputEvent, g: ColGrabber) -> void:
	if g.col < 0:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_begin_resize(g.col)
		g.accept_event()


func _header_height() -> float:
	if _header_h <= 0.0:
		var root := _tree.get_root()
		if root and root.get_first_child():
			_header_h = _tree.get_item_area_rect(root.get_first_child()).position.y
		if _header_h <= 0.0:
			_header_h = 24.0
	return _header_h


# Column whose right divider sits under x (only within the header band), else -1.
# Uses the Tree's ACTUAL column right-edges (get_item_area_rect) so the grab zones
# line up with the drawn dividers — summing _col_w drifts (panel margin/spacing).
func _divider_at(pos: Vector2) -> int:
	if pos.y > _header_height():
		return -1
	var first: TreeItem = null
	var root := _tree.get_root()
	if root:
		first = root.get_first_child()
	if first != null:
		for c in range(COL_COUNT):
			if absf(pos.x - _tree.get_item_area_rect(first, c).end.x) <= RESIZE_GRAB:
				return c
		return -1
	# fallback (empty table): sum the stored widths
	var x := -float(_tree.get_scroll().x)
	for c in range(COL_COUNT):
		x += _col_w[c]
		if absf(pos.x - x) <= RESIZE_GRAB:
			return c
	return -1


func _on_tree_gui_input(event: InputEvent) -> void:
	# Spreadsheet-style cell keys (on the SELECTED editable column). Only fire when
	# the tree has focus and no inline cell editor is open (that LineEdit grabs keys).
	if event is InputEventKey and event.pressed:
		# 1) an active "type over the selection" edit captures everything
		if _cell_edit_active:
			if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
				_commit_cell_edit()
			elif event.keycode == KEY_ESCAPE:
				_cancel_cell_edit()
			elif event.keycode == KEY_BACKSPACE:
				_cell_edit_buf = _cell_edit_buf.substr(0, maxi(0, _cell_edit_buf.length() - 1))
				_cell_edit_live()
			elif event.keycode == KEY_DELETE:
				_cell_edit_buf = ""
				_cell_edit_live()
			elif event.unicode >= 32:
				_cell_edit_buf += String.chr(event.unicode)
				_cell_edit_live()
			_tree.accept_event()
			return
		# 2) Ctrl+C / Ctrl+V copy-paste of the selected column
		if event.ctrl_pressed:
			if event.keycode == KEY_C:
				_copy_selected_cells()
				_tree.accept_event()
				return
			elif event.keycode == KEY_V:
				_paste_to_selection()
				_tree.accept_event()
				return
		# 3) Del clears the selected cells; a printable key starts a type-over
		#    edit — both only when an editable column's cells are selected.
		else:
			var ecol := _selected_edit_col()
			if event.keycode == KEY_DELETE and ecol >= 0:
				_clear_selected_cells(ecol)
				_tree.accept_event()
				return
			elif event.keycode == KEY_DELETE:      # non-editable selection -> delete file(s)
				_confirm_delete_selected()
				_tree.accept_event()
				return
			elif event.unicode >= 32 and ecol >= 0:
				_begin_cell_edit(ecol, String.chr(event.unicode))
				_tree.accept_event()
				return
	# Clicking anywhere commits an in-progress type-over edit (then the click
	# proceeds normally to start a fresh selection).
	if event is InputEventMouseButton and event.pressed and _cell_edit_active:
		_commit_cell_edit()
	# Right-click: open the context menu WITHOUT collapsing a multi-selection. We
	# handle it HERE (gui_input runs before the Tree's own rmb-select) and accept the
	# event so the Tree never touches the selection. The Rating column is left to the
	# Tree so its right-click-clear (via item_mouse_selected) still fires.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var hit := _tree.get_item_at_position(event.position)
		if hit != null and typeof(hit.get_metadata(0)) == TYPE_DICTIONARY \
				and _tree.get_column_at_position(event.position) != COL_RATING:
			var rec: Dictionary = hit.get_metadata(0)
			if not _selected_paths().has(String(rec.get("path", ""))):
				_tree.deselect_all()               # clicked an unselected row -> pick just it
				hit.select(0)
			_ctx_rec = rec
			_refresh_star_buttons(rec)
			_ctx_menu.reset_size()
			_ctx_menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))
			_tree.accept_event()                   # keep the selection intact
			return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var c := _divider_at(event.position)
			if c >= 0:
				_begin_resize(c)                   # tracking continues in _process
				_tree.accept_event()
			elif event.position.y > _header_height():
				var it := _tree.get_item_at_position(event.position)
				if it != null:
					_drag_sel = true
					_drag_anchor = it
					_drag_last = it
					_drag_col = maxi(0, _tree.get_column_at_position(event.position))
					_drag_additive = event.shift_pressed or event.ctrl_pressed
					_drag_toggle = event.ctrl_pressed
					if _drag_additive:
						# Take over: snapshot the prior selection (Shift adds the
						# region, Ctrl toggles it) and apply the click now so a
						# modifier-click without a drag still works. accept_event
						# runs before Tree's own handler (gui_input signal first),
						# so native modifier behaviour is suppressed cleanly.
						_snapshot_selection()
						_apply_drag_range(it, it)
						_tree.accept_event()
		else:                                  # released
			# If a real drag happened (moved to another row), accept the release so the
			# Tree doesn't collapse the range OR open the inline editor on the final
			# cell. A plain click (no move) falls through and still plays.
			if _drag_sel and _drag_anchor != null and _drag_last != null and _drag_last != _drag_anchor:
				_tree.accept_event()
			_drag_sel = false
			_drag_additive = false
			_drag_toggle = false
			_drag_anchor = null
			_drag_last = null
			_drag_base = []
			_drag_base_col = {}
	elif event is InputEventMouseMotion:
		if _drag_sel and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			var it := _tree.get_item_at_position(event.position)
			if it != null and it != _drag_last and _drag_anchor != null:
				_drag_last = it
				_apply_drag_range(_drag_anchor, it)
				_tree.accept_event()
		else:
			# show the horizontal-resize cursor when hovering a divider
			_tree.mouse_default_cursor_shape = (
				Control.CURSOR_HSIZE if _divider_at(event.position) >= 0
				else Control.CURSOR_ARROW)


# Snapshot the current cell selection so a modifier-drag can preserve it.
func _snapshot_selection() -> void:
	_drag_base = []
	_drag_base_col = {}
	var it := _tree.get_next_selected(null)
	while it != null:
		var col := 0
		for cc in COL_COUNT:
			if it.is_selected(cc):
				col = cc
				break
		_drag_base.append([it, col])
		_drag_base_col[it] = col
		it = _tree.get_next_selected(it)


# Items between two rows (inclusive), in display order, either drag direction.
func _rows_between(a: TreeItem, b: TreeItem) -> Array:
	var out: Array = []
	var root := _tree.get_root()
	if root == null:
		return out
	var inside := false
	var it := root.get_first_child()
	while it != null:
		if it == a or it == b:
			out.append(it)
			if a == b or inside:
				break                          # second endpoint reached -> done
			inside = true
		elif inside:
			out.append(it)
		it = it.get_next()
	return out


# Apply the current drag's region (a..b at _drag_col) to the selection:
#   plain  -> replace selection with the region
#   Shift  -> prior selection + the region (additive)
#   Ctrl   -> prior selection with the region's cells toggled (deselect if they
#             were already selected, else select)
# Programmatic select()/deselect() are silent, so no signal storm during a drag.
func _apply_drag_range(a: TreeItem, b: TreeItem) -> void:
	_tree.deselect_all()
	if _drag_additive:
		for pair in _drag_base:
			if is_instance_valid(pair[0]):
				pair[0].select(pair[1])
	for it in _rows_between(a, b):
		if _drag_toggle and _drag_base_col.has(it):
			it.deselect(_drag_base_col[it])    # was selected -> toggle off
		else:
			it.select(_drag_col)


## Which star (1-5) the x position falls on, measured against the actual drawn
## star glyphs (left-aligned in the cell) so the cursor tip maps exactly.
func _star_at(item: TreeItem, x: float) -> int:
	if _star_glyph_w <= 0.0:
		var font := _tree.get_theme_font("font")
		var fsize := _tree.get_theme_font_size("font_size")
		_star_glyph_w = font.get_string_size("★", HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var rect := _tree.get_item_area_rect(item, COL_RATING)
	var ml := 0
	if _tree.has_theme_constant("inner_item_margin_left"):
		ml = _tree.get_theme_constant("inner_item_margin_left")
	var x0 := rect.position.x + ml
	return clampi(int(floor((x - x0) / maxf(_star_glyph_w, 1.0))) + 1, 1, 5)


## Live hover preview: highlight, in gold, the rating that a click would apply.
func _update_rating_hover() -> void:
	var lp := _tree.get_local_mouse_position()
	var item: TreeItem = null
	var star := -1
	if Rect2(Vector2.ZERO, _tree.size).has_point(lp) \
			and _tree.get_column_at_position(lp) == COL_RATING:
		item = _tree.get_item_at_position(lp)
		if item != null:
			star = _star_at(item, lp.x)
	if item == _hover_item and star == _hover_star:
		return
	if _hover_item != null and is_instance_valid(_hover_item):
		_restore_rating_cell(_hover_item)      # un-preview the previous row
	_hover_item = item
	_hover_star = star
	if item != null:
		item.set_text(COL_RATING, _stars(star))
		item.set_custom_color(COL_RATING, Color(1.0, 0.82, 0.2))


func _restore_rating_cell(item: TreeItem) -> void:
	item.clear_custom_color(COL_RATING)
	item.set_text(COL_RATING, _stars(_get_rating(item.get_metadata(0))))


func _selected_rec() -> Variant:
	var it := _tree.get_selected()
	return it.get_metadata(0) if it else null


func _play_selected() -> void:
	var rec: Variant = _selected_rec()
	if rec == null:
		return
	var abs := _abs_path(rec)
	var ext := String(rec.get("ext", "")).to_lower()
	_now_label.text = abs
	if ext == "mp3":
		# audition mp3 directly; chop/loop/analyse use the decoded WAV (Convert to WAV)
		if not FileAccess.file_exists(abs):
			_now_label.text = "File not found (library moved?): %s" % abs
			return
		var mp3 := AudioStreamMP3.new()
		mp3.data = FileAccess.get_file_as_bytes(abs)
		if mp3.data.is_empty():
			_now_label.text = "Could not read mp3: %s" % abs
			return
		mp3.loop = _loop_on
		_player.stream = mp3
		_play_gain_db = _get_gain_db(rec)
		_apply_volume()
		_player.play()
		_playing_chops = false
		_play_kind = "track"
		_stream_len = mp3.get_length()
		_playing_rec = rec
		_playing_item = _tree.get_selected()
		_update_play_btn()
		_now_label.text = "Playing (mp3):  %s" % String(rec.get("filename", ""))
		return
	if ext != "wav":
		# not directly playable — reuse the decoded sibling WAV if it exists, else
		# decode it (indexer/to_wav.py) and play the result when that finishes.
		var wrec: Variant = _sibling_wav_rec(rec)
		if typeof(wrec) == TYPE_DICTIONARY:
			_select_row_by_path(String(wrec.get("path", "")))
			_play_selected()
			return
		if _convert_busy:
			_now_label.text = "Decoding another file… try Play again in a moment."
			return
		_now_label.text = "Decoding %s to WAV to play…" % String(rec.get("filename", ""))
		_convert_to_wav(rec, "__play__")
		return
	if not FileAccess.file_exists(abs):
		_now_label.text = "File not found (library moved?): %s" % abs
		return
	var ch := int(rec.get("channels", 0)) if rec.get("channels") != null else 0
	if ch > 2:
		_now_label.text = "Can't preview: %d-channel WAV (ambisonic/surround). The player handles mono/stereo only — %s" % [
			ch, String(rec.get("filename", ""))]
		return
	var stream: AudioStreamWAV = AudioStreamWAV.load_from_file(abs)
	if stream == null:
		# Godot's runtime WAV loader can't read this file — almost always
		# WAVE_FORMAT_EXTENSIBLE (common for 24-bit). soundfile CAN, so make a 16-bit
		# sibling (<stem>_16bit.wav) and play that. Reuse one if it already exists.
		if String(rec.get("path", "")).ends_with("_16bit.wav"):
			_now_label.text = "Could not load WAV (unsupported format): %s" % abs
			return
		var s16: Variant = _sibling_16bit_rec(rec)
		if typeof(s16) == TYPE_DICTIONARY:
			_select_row_by_path(String(s16.get("path", "")))
			_play_selected()
			return
		if _convert_busy:
			_now_label.text = "Converting another file… try Play again in a moment."
			return
		_convert_to_16bit(rec, "__play__")     # sets status; plays the 16-bit copy when done
		return
	_set_stream_loop(stream)                   # honour the Loop toggle
	_player.stream = stream
	_play_gain_db = _get_gain_db(rec)          # per-track gain on top of the slider
	_apply_volume()
	_player.play()
	_playing_chops = false                     # this is a whole-file play, not a region
	_play_kind = "track"
	_stream_len = stream.get_length()
	_playing_rec = rec
	_playing_item = _tree.get_selected()
	_update_play_btn()
	_now_label.text = "Playing:  %s" % String(rec.get("filename", ""))


# Each of the three transport rows (Track / Loop / Chops) owns one play button and
# reflects ONLY its own kind: "Pause X" if that kind is the one currently playing,
# else "Play X". Only one kind plays at a time, so at most one shows "Pause".
func _update_play_btn() -> void:
	var playing := _player.playing
	_play_btn.text = "Pause Track" if (playing and _play_kind == "track") else "Play Track"
	_loop_play_btn.text = "Pause Loop" if (playing and _play_kind == "loop") else "Play Loop"
	_chops_play_btn.text = "Pause chops" if (playing and _play_kind == "chops") else "Play chops"


# Toggle pause/resume of whatever is currently loaded (Space, and the active row's
# button when its kind is the one loaded). Never STARTS a different kind.
func _toggle_pause() -> void:
	if _player.stream == null:
		return
	if _player.playing:
		_player.stream_paused = true
	elif _player.stream_paused:
		_player.stream_paused = false
	else:
		_player.play()                             # stopped/finished -> replay this stream
	_update_play_btn()


# True when the player is actively playing or paused (not stopped/finished) — used
# so a row's play button pauses/resumes only a LIVE stream, else starts fresh.
func _is_active() -> bool:
	return _player.playing or _player.stream_paused


# Track row's play button: pause/resume if THIS track is what's live, else start
# the selected track (which supersedes any loop/chops preview).
func _on_play_track_pressed() -> void:
	var rec: Variant = _selected_rec()
	if _play_kind == "track" and rec != null and rec == _playing_rec and _is_active():
		_toggle_pause()
	else:
		_play_selected()


# Kept for callers/back-compat: Space routes here. Toggle the last-used row's state.
func _on_play_pressed() -> void:
	if _player.stream == null:
		_play_selected()
		return
	_toggle_pause()


func _on_stop_pressed() -> void:
	_player.stop()
	_playing_chops = false                     # stop ends the region/chops audition
	_update_play_btn()
	_time_label.text = "0:00 / 0:00"


# Left-click/drag on the visualiser scrubs the player to that fraction.
func _on_graph_seek(fraction: float) -> void:
	if _player.stream == null:
		_play_selected()                       # nothing loaded -> start, then seek
	if _player.stream == null or _stream_len <= 0.0:
		return
	_player.seek(clampf(fraction, 0.0, 1.0) * _stream_len)
	if not _player.playing and not _player.stream_paused:
		_player.play()
	_update_play_btn()


func _on_volume_changed(v: float) -> void:
	_global_vol = v
	_apply_volume()


# Final player gain = global slider (in dB) + the playing track's Gain dB trim.
func _apply_volume() -> void:
	var base_db := -80.0 if _global_vol <= 0.001 else linear_to_db(_global_vol)
	_player.volume_db = base_db + _play_gain_db


# Set a WAV stream to loop (or not) per the Loop toggle. A looping stream plays
# seamlessly and never emits `finished` (so it doesn't count as a play).
func _set_stream_loop(stream: AudioStreamWAV) -> void:
	if stream == null:
		return
	if _loop_on:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		# Exact sample-frame count from the PCM buffer — NOT get_length()*mix_rate,
		# whose rounding can overshoot the data and play a sliver of silence before
		# wrapping (an audible gap). This wraps precisely at the last frame.
		stream.loop_end = _wav_frame_count(stream)
	else:
		stream.loop_mode = AudioStreamWAV.LOOP_DISABLED


# Total sample frames in a PCM AudioStreamWAV (data bytes / bytes-per-frame).
func _wav_frame_count(stream: AudioStreamWAV) -> int:
	var bps := 0
	if stream.format == AudioStreamWAV.FORMAT_8_BITS:
		bps = 1
	elif stream.format == AudioStreamWAV.FORMAT_16_BITS:
		bps = 2
	if bps > 0:
		var ch := 2 if stream.stereo else 1
		return stream.data.size() / (bps * ch)
	return int(round(stream.get_length() * stream.mix_rate))   # compressed fallback


func _on_loop_toggled(on: bool) -> void:
	_loop_on = on
	if _player.stream is AudioStreamWAV:
		_set_stream_loop(_player.stream)       # apply to the current track live
	elif _player.stream is AudioStreamMP3:
		_player.stream.loop = on


func _on_reveal() -> void:
	# the selected file's folder, or the library root if nothing is selected
	var rec: Variant = _selected_rec()
	var folder := _library_root
	if typeof(rec) == TYPE_DICTIONARY:
		folder = _library_root.path_join(String(rec.get("path", "")).get_base_dir())
	OS.shell_open(folder)


# ----- choose (change) the library folder: pick -> library.cfg -> re-index ------
func _on_choose_library() -> void:
	if _reindex_busy:
		return
	if _pipe_busy:                              # both write index.json — don't collide
		_status_label.text = "A background update is running — try again in a moment."
		return
	if _lib_picker == null:
		_lib_picker = FileDialog.new()
		_lib_picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_lib_picker.access = FileDialog.ACCESS_FILESYSTEM
		_lib_picker.use_native_dialog = true
		_lib_picker.title = "Choose your sound library folder"
		_lib_picker.dir_selected.connect(_on_library_chosen)
		add_child(_lib_picker)
	if DirAccess.dir_exists_absolute(_library_root):
		_lib_picker.current_dir = _library_root
	_lib_picker.popup_centered(Vector2i(900, 620))


func _on_library_chosen(dir: String) -> void:
	var newroot := dir.replace("\\", "/")
	if newroot == _library_root:
		_status_label.text = "Library unchanged."
		return
	if not DirAccess.dir_exists_absolute(newroot):
		_status_label.text = "Folder not found: %s" % newroot
		return
	var cfg := ProjectSettings.globalize_path("res://../library.cfg").simplify_path()
	var f := FileAccess.open(cfg, FileAccess.WRITE)
	if f == null:
		_status_label.text = "Could not write library.cfg"
		return
	f.store_string(JSON.stringify({"library_root": newroot}))
	f.close()
	# rewire the user-data sidecars to the new library (they live beside the audio)
	_ud_path = newroot.path_join("userdata.json")
	_chop_path = newroot.path_join("chopping.json")
	_lo_path = newroot.path_join("loudness.json")
	_reindex_library()


func _reindex_library() -> void:
	if _reindex_busy:
		return
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/index.py").simplify_path()
	_reindex_busy = true
	_status_label.text = "Indexing the library… (reading headers; this can take a minute)"
	_reindex_thread = Thread.new()
	_reindex_thread.start(_reindex_run.bind(script))


func _reindex_run(script: String) -> void:
	var output: Array = []
	_exec_tool([script], output)
	call_deferred("_reindex_finished")


func _reindex_finished() -> void:
	_reindex_busy = false
	if _reindex_thread:
		_reindex_thread.wait_to_finish()
		_reindex_thread = null
	if not FileAccess.file_exists(ProjectSettings.globalize_path("res://index.json")):
		_status_label.text = "Indexing failed (no index.json). Is python on PATH?"
		return
	_load_userdata()                           # sidecars for the (possibly new) library
	_load_chopping()
	_load_loudness()
	_load_index()                              # rebuilds the view + sets the status line


# ---- Background "update everything" pipeline --------------------------------
# One button (Rescan library) + startup run the whole chain in the background, one
# step at a time, so the app stays usable: rescan the index -> analyse audio
# (chops+loudness) -> fingerprints -> semantic embeddings -> CLAP index (only if the
# model is downloaded). Each step is incremental (--only-missing), so an up-to-date
# library finishes in seconds; a fresh one fills everything in over time.
func _indexer_script(name: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("../indexer/" + name).simplify_path()


func _clap_model_present() -> bool:
	return FileAccess.file_exists(_repo_root().path_join("models/clap/onnx/audio_model.onnx"))


func _build_pipeline() -> Array:
	var steps: Array = [
		{"kind": "index", "label": "Scanning", "script": "index.py",
			"progress": _rescan_progress_path,
			"args": ["--progress", _rescan_progress_path]},
		{"kind": "count", "label": "Analysing audio", "script": "analyse_audio.py",
			"progress": _sg_progress_path,
			"args": ["--only-missing", "--progress", _sg_progress_path, "--renames", _sg_renames_path]},
		{"kind": "count", "label": "Fingerprints", "script": "fingerprint.py",
			"progress": _fp_progress_path,
			"args": ["--only-missing", "--progress", _fp_progress_path]},
		{"kind": "count", "label": "Semantic index", "script": "embed.py",
			"progress": _emb_progress_path,
			"args": ["--only-missing", "--progress", _emb_progress_path]},
	]
	if _clap_model_present():
		steps.append({"kind": "count", "label": "CLAP index", "script": "clap_embed.py",
			"progress": _clapidx_progress_path,
			"args": ["--only-missing", "--progress", _clapidx_progress_path]})
	return steps


# Entry point: the Rescan library button AND startup (call_deferred in _ready).
func _start_rescan() -> void:
	if _pipe_busy or _reindex_busy:
		return                                  # a pipeline/reindex is already running
	if not DirAccess.dir_exists_absolute(_library_root):
		return                                  # no library configured yet
	_pipe_steps = _build_pipeline()
	_pipe_i = -1
	_pipe_index_changed = false
	_pipe_busy = true
	_rescan_btn.disabled = true
	_pipe_advance()


func _pipe_advance() -> void:
	_pipe_i += 1
	if _pipe_i >= _pipe_steps.size():
		_pipe_all_done()
		return
	var step: Dictionary = _pipe_steps[_pipe_i]
	var prog := String(step.progress)
	if prog != "" and FileAccess.file_exists(prog):
		DirAccess.remove_absolute(prog)
	_rescan_btn.text = _pipe_btn_text(step, {})
	var args: Array = [_indexer_script(String(step.script))] + step.args
	_pipe_thread = Thread.new()
	_pipe_thread.start(_pipe_run.bind(args))
	_rescan_poll.start()


func _pipe_run(args: Array) -> void:
	var output: Array = []
	_exec_tool(args, output)
	call_deferred("_pipe_step_finished")


# Poll: show the current step's progress on the button. During the analyse step,
# live-refresh the chop/loudness cells as they fill in.
func _rescan_tick() -> void:
	if _pipe_i < 0 or _pipe_i >= _pipe_steps.size():
		return
	var step: Dictionary = _pipe_steps[_pipe_i]
	if String(step.label) == "Analysing audio":
		_reload_chop_cells()
		_reload_loudness_cells()
	var d: Dictionary = {}
	var prog := String(step.progress)
	if prog != "" and FileAccess.file_exists(prog):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(prog))
		if typeof(parsed) == TYPE_DICTIONARY:
			d = parsed
	_rescan_btn.text = _pipe_btn_text(step, d)


func _pipe_btn_text(step: Dictionary, d: Dictionary) -> String:
	var phase := "%d/%d" % [_pipe_i + 1, _pipe_steps.size()]
	if String(step.kind) == "index":
		var scanned := int(d.get("scanned", 0))
		if scanned <= 0:
			return "Updating %s: scanning…" % phase
		return "Updating %s: %d scanned, %d new" % [phase, scanned, int(d.get("new", 0))]
	var tot := int(d.get("total", 0))
	if tot > 0:
		return "Updating %s: %s %d/%d" % [phase, String(step.label), int(d.get("analysed", 0)), tot]
	return "Updating %s: %s…" % [phase, String(step.label)]


func _pipe_step_finished() -> void:
	_rescan_poll.stop()
	if _pipe_thread:
		_pipe_thread.wait_to_finish()
		_pipe_thread = null
	var step: Dictionary = _pipe_steps[_pipe_i]
	if String(step.kind) == "index" and FileAccess.file_exists(_rescan_progress_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_rescan_progress_path))
		if typeof(d) == TYPE_DICTIONARY and bool(d.get("changed", false)):
			_pipe_index_changed = true
	_pipe_advance()


func _pipe_all_done() -> void:
	_pipe_busy = false
	_rescan_btn.disabled = false
	_rescan_btn.text = "Rescan library"
	# Reload what the UI shows: analysis sidecars always; the full index (new/removed
	# rows) only if the scan changed it, keeping the user's selected row.
	_load_chopping()
	_load_loudness()
	if _pipe_index_changed:
		var sel_rec: Variant = _selected_rec()
		var sel_path := String(sel_rec.get("path", "")) if typeof(sel_rec) == TYPE_DICTIONARY else ""
		_load_index()
		if sel_path != "" and _by_path.has(sel_path):
			_select_row_by_path(sel_path)
	else:
		_reload_chop_cells()
		_reload_loudness_cells()
	_recompute_targets()                       # newly-measured level'd rows -> Gain dB
	_report_renames()                          # if analyse renamed invalid-named files
	_status_label.text = "Library up to date — index, analysis, fingerprints, semantics%s." % (
		" + CLAP" if _clap_model_present() else "")
	if not _pa_pending.is_empty():             # analyse chops/loops queued during the run
		var next: Array = _pa_pending
		_pa_pending = []
		_analyse_paths(next)


# Space toggles play/pause globally -- except while typing in a text field (the
# search box, an inline cell editor) or during a type-over tag edit, where Space
# must reach the text.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		var foc := get_viewport().gui_get_focus_owner()
		if foc is LineEdit or foc is TextEdit or _cell_edit_active:
			return
		_on_play_pressed()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_update_rating_hover()
	# live column resize, driven off the global mouse so the 8px grabber strips
	# (and the title-row divider) don't drop the drag when the cursor moves off.
	if _resize_col >= 0:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var w := maxi(COL_MIN_W, _resize_start_w + int(get_global_mouse_position().x - _resize_start_x))
			if w != _col_w[_resize_col]:
				_col_w[_resize_col] = w
				_tree.set_column_custom_minimum_width(_resize_col, w)
		else:
			_resize_col = -1
	_layout_filter_header()                        # keep filters aligned over columns
	# playback cursor + play dot on the visualiser, when the loaded file is the one
	# shown in the analyser (playing OR paused). For a chops/loop PREVIEW the player
	# is on a different timeline, so map its position back onto the original file.
	if _graph and not _an_levels.is_empty():
		var ph := -1.0
		if _player.stream != null and _stream_len > 0.0:
			var f := clampf(_player.get_playback_position() / _stream_len, 0.0, 1.0)
			if _playing_rec != null and _playing_rec == _an_rec:
				ph = f                                 # whole-track: preview == file timeline
			elif _playing_chops and _preview_rec == _an_rec and not _preview_map.is_empty():
				ph = _preview_frac_to_orig(f)          # loop/chops: map back to the file
		if ph != _graph.playhead:
			_graph.playhead = ph
			_graph.queue_redraw()
			if _seekbar:
				_seekbar.pos = ph
				_seekbar.queue_redraw()
	# yellow border on the playing row (track playback only, not chops/loop preview)
	if _row_hl:
		var playing_now := _player.stream != null and (_player.playing or _player.stream_paused)
		var target: TreeItem = _playing_item if (playing_now and not _playing_chops) else null
		_row_hl.header_h = _header_height()
		if _row_hl.item != target:
			_row_hl.item = target
			_row_hl.queue_redraw()
		elif target != null:
			_row_hl.queue_redraw()                 # follow scrolling
	if _player.stream == null or _stream_len <= 0.0:
		return
	if _player.playing:
		var pos := _player.get_playback_position()
		_time_label.text = "%s / %s" % [_fmt_time(pos), _fmt_time(_stream_len)]
	# finished (not paused) but a row still shows "Pause X" -> reset all to "Play X"
	if not _is_active() and (_play_btn.text.begins_with("Pause") \
			or _loop_play_btn.text.begins_with("Pause") \
			or _chops_play_btn.text.begins_with("Pause")):
		_update_play_btn()


func _on_playback_finished() -> void:
	# Fired only when the stream plays through to the end (not on Stop) -- i.e.
	# the user finished listening. Count it.
	_update_play_btn()
	if _playing_rec == null:
		return
	var key := String(_playing_rec.get("path", ""))
	var ud: Dictionary = _userdata.get(key, {})
	ud["plays"] = int(ud.get("plays", 0)) + 1
	_userdata[key] = ud
	_save_userdata()
	if _playing_item != null and is_instance_valid(_playing_item):
		_apply_userdata_cells(_playing_item, _playing_rec)


# ===========================================================================
#  User data (ratings + play counts)  -- app/userdata.json
# ===========================================================================
# Crash-safe JSON write: write <path>.tmp, verify it parses, then swap it into
# place keeping one <path>.bak. A crash mid-write can't corrupt the live file.
func _save_json_atomic(path: String, data: Variant) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("save failed (open %s): %d" % [tmp, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(data))
	f.flush()
	f = null                                   # close before renaming
	# verify the temp parses back to the same type (guards a truncated write)
	if typeof(JSON.parse_string(FileAccess.get_file_as_string(tmp))) != typeof(data):
		push_warning("save failed (verify): %s" % tmp)
		return false
	if FileAccess.file_exists(path):
		var bak := path + ".bak"
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(path, bak)   # keep previous as backup
	DirAccess.rename_absolute(tmp, path)
	return true


# Load a JSON dict, falling back to the .bak if the live file is missing/corrupt.
func _load_json_dict(path: String) -> Dictionary:
	for p in [path, path + ".bak"]:
		if FileAccess.file_exists(p):
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if typeof(d) == TYPE_DICTIONARY:
				return d
	return {}


func _load_userdata() -> void:
	_userdata = _load_json_dict(_ud_path)


func _save_userdata() -> void:
	if not _save_json_atomic(_ud_path, _userdata):
		var msg := "ERROR: could not save your data to %s" % _ud_path
		push_warning(msg)
		if _status_label:
			_status_label.text = msg


func _get_rating(rec: Dictionary) -> int:
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	return int(ud.get("rating", 0)) if typeof(ud) == TYPE_DICTIONARY else 0


func _get_plays(rec: Dictionary) -> int:
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	return int(ud.get("plays", 0)) if typeof(ud) == TYPE_DICTIONARY else 0


func _get_tags(rec: Dictionary) -> String:
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	return String(ud.get("tags", "")) if typeof(ud) == TYPE_DICTIONARY else ""


# Per-track playback gain in dB (default 0 = unchanged). Migrates an older
# `vol_mult` (linear) entry to dB on read so existing data isn't lost.
const GAIN_DB_MIN := -80.0
const GAIN_DB_MAX := 24.0
func _get_gain_db(rec: Variant) -> float:
	if typeof(rec) != TYPE_DICTIONARY:
		return 0.0
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	if typeof(ud) == TYPE_DICTIONARY:
		if ud.has("gain_db"):
			return clampf(float(ud["gain_db"]), GAIN_DB_MIN, GAIN_DB_MAX)
		if ud.has("vol_mult"):                 # legacy: convert linear mult -> dB
			var m := float(ud["vol_mult"])
			if m > 0.0:
				return clampf(linear_to_db(m), GAIN_DB_MIN, GAIN_DB_MAX)
	return 0.0


func _fmt_gain(v: float) -> String:
	return "" if is_equal_approx(v, 0.0) else str(snappedf(v, 0.1))


# Level scale: a 0-10 perceptual loudness dial. 10 = LEVEL_TOP_DBFS (loudest),
# 0 = silence, and halving the dial halves perceived loudness = -10 dB (the
# "+10 dB ≈ twice as loud" rule). dBFS = top + 10·log2(level/10).
const LEVEL_TOP_DBFS := -10.0
const LEVEL_MAX := 10.0
const LEVEL_SILENT_DBFS := -120.0     # level 0 -> effectively silent


func _level_to_dbfs(level: float) -> float:
	if level <= 0.0:
		return LEVEL_SILENT_DBFS
	return LEVEL_TOP_DBFS + 10.0 * (log(level / LEVEL_MAX) / log(2.0))


func _dbfs_to_level(dbfs: float) -> float:
	return clampf(LEVEL_MAX * pow(2.0, (dbfs - LEVEL_TOP_DBFS) / 10.0), 0.0, LEVEL_MAX)


# Level cell shows 0-10 (1 decimal); only an UNSET level (NAN) is blank.
func _fmt_level(v: float) -> String:
	return "" if is_nan(v) else str(snappedf(v, 0.1))


# Inline edit of the Gain dB cell. Any number; blank = 0. Clamped to a sane
# range; a positive value warns (it may clip).
func _on_gain_db_edited(rec: Variant, it: TreeItem) -> void:
	if typeof(rec) != TYPE_DICTIONARY:
		return
	var txt := it.get_text(COL_GAIN_DB).strip_edges()
	if txt != "" and not txt.is_valid_float():
		_status_label.text = "Gain dB must be a number (got \"%s\")." % txt
		it.set_text(COL_GAIN_DB, _fmt_gain(_get_gain_db(rec)))      # revert
		return
	var v := clampf(0.0 if txt == "" else txt.to_float(), GAIN_DB_MIN, GAIN_DB_MAX)
	_set_userdata(rec, "gain_db", v)
	it.set_text(COL_GAIN_DB, _fmt_gain(v))
	_apply_final_cell(it, rec)
	if v > 0.0:
		_status_label.text = "Gain dB +%s boosts above the file's level and may clip." % str(snappedf(v, 0.1))
	if rec == _playing_rec:                    # live-apply to the current track
		_play_gain_db = v
		_apply_volume()


# Desired Level (0-10) for the track, or NAN if not set. Migrates an older
# `target_db` (dBFS) entry to the 0-10 scale on read.
func _get_level(rec: Variant) -> float:
	if typeof(rec) != TYPE_DICTIONARY:
		return NAN
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	if typeof(ud) == TYPE_DICTIONARY:
		if ud.get("level") != null:
			return float(ud["level"])
		if ud.get("target_db") != null:        # legacy dBFS target -> level
			return _dbfs_to_level(float(ud["target_db"]))
	return NAN


# The Gain dB that makes a track play at its Level: target_dBFS − measured RMS,
# capped at −peak so the peak never crosses 0 dBFS (no clipping). NAN if the track
# has no level or hasn't been measured. Returns [gain, capped].
func _target_gain(rec: Variant) -> Array:
	var lvl := _get_level(rec)
	if is_nan(lvl):
		return [NAN, false]
	var rms := _loudness_rms(rec)
	var peak := _loudness_peak(rec)
	if is_nan(rms) or is_nan(peak):
		return [NAN, false]
	var g := _level_to_dbfs(lvl) - rms        # bring loudness to the level's dBFS
	var max_clean := 0.0 - peak
	var capped := g > max_clean
	g = clampf(minf(g, max_clean), GAIN_DB_MIN, GAIN_DB_MAX)
	return [snappedf(g, 0.1), capped]


# Recompute + store Gain dB from a row's Level (if measured). Updates the Gain
# cell and live playback. Returns 0 = no level, 1 = applied, -1 = unmeasured.
func _apply_target_to_gain(rec: Variant, it: TreeItem) -> int:
	if is_nan(_get_level(rec)):
		return 0
	var res := _target_gain(rec)
	if is_nan(res[0]):
		return -1                              # has a level but no measurement yet
	var g: float = res[0]
	var key := String(rec.get("path", ""))      # write in memory; caller saves once
	var ud: Dictionary = _userdata.get(key, {})
	ud["gain_db"] = g
	_userdata[key] = ud
	if it != null and is_instance_valid(it):
		it.set_text(COL_GAIN_DB, _fmt_gain(g))
		_apply_final_cell(it, rec)
	if rec == _playing_rec:
		_play_gain_db = g
		_apply_volume()
	return 1


# Inline edit of the Level cell (0-10; blank clears it). Stores the level and
# recomputes Gain dB to hit that perceived loudness, clip-safe.
func _on_level_edited(rec: Variant, it: TreeItem) -> void:
	if typeof(rec) != TYPE_DICTIONARY:
		return
	var key := String(rec.get("path", ""))
	var txt := it.get_text(COL_LEVEL).strip_edges()
	if txt == "":
		var u: Dictionary = _userdata.get(key, {})  # clear level; leave Gain as-is
		u.erase("level")
		u.erase("target_db")
		_userdata[key] = u
		_save_userdata()
		it.set_text(COL_LEVEL, "")
		return
	if not txt.is_valid_float():
		_status_label.text = "Level must be a number 0-10 (got \"%s\")." % txt
		it.set_text(COL_LEVEL, _fmt_level(_get_level(rec)))
		return
	var lvl := clampf(txt.to_float(), 0.0, LEVEL_MAX)
	var ud: Dictionary = _userdata.get(key, {})
	ud["level"] = lvl
	ud.erase("target_db")                       # supersede any legacy entry
	_userdata[key] = ud
	it.set_text(COL_LEVEL, _fmt_level(lvl))
	var r := _apply_target_to_gain(rec, it)
	_save_userdata()                            # persist level + recomputed gain
	if r == -1:
		_status_label.text = "Level set. Run 'Analyse audio' to apply it (no measurement yet)."
	else:
		var res := _target_gain(rec)
		if res.size() == 2 and res[1]:
			_status_label.text = "Level %s is hotter than this file can play cleanly — Gain dB capped (no clip)." % _fmt_level(lvl)


func _set_userdata(rec: Variant, field: String, value: Variant) -> void:
	if typeof(rec) != TYPE_DICTIONARY:
		return
	var key := String(rec.get("path", ""))
	var ud: Dictionary = _userdata.get(key, {})
	ud[field] = value
	_userdata[key] = ud
	_save_userdata()


func _set_tags(rec: Variant, text: String) -> void:
	_set_userdata(rec, "tags", text.strip_edges())


# ===========================================================================
#  Spreadsheet-style multi-cell editing — generic over the selected COLUMN
#  (Tags, Gain dB, ...), not hard-wired to Tags. Copy/paste/Del/type-over all act
#  on whichever editable column your selected cells are in.
# ===========================================================================

# The editable column that the current selection sits in, or -1. (Selection is
# per-cell at one column, so the first match wins.)
func _selected_edit_col() -> int:
	for c in SEL_EDIT_COLS:
		var it := _tree.get_next_selected(null)
		while it != null:
			if it.is_selected(c):
				return c
			it = _tree.get_next_selected(it)
	return -1


func _selected_items_in_col(col: int) -> Array:
	var out: Array = []
	var it := _tree.get_next_selected(null)
	while it != null:
		if it.is_selected(col) and typeof(it.get_metadata(0)) == TYPE_DICTIONARY:
			out.append(it)
		it = _tree.get_next_selected(it)
	return out


# Current value of a cell as text, per column.
func _cell_get(rec: Variant, col: int) -> String:
	if typeof(rec) != TYPE_DICTIONARY:
		return ""
	match col:
		COL_TAGS:
			return _get_tags(rec)
		COL_GAIN_DB:
			return _fmt_gain(_get_gain_db(rec))
		COL_LEVEL:
			return _fmt_level(_get_level(rec))
	return ""


# Validate + write a value to a cell (in memory + the cell text), per column.
# Returns false (no change) if the value is invalid. Caller saves once after.
func _cell_set(rec: Variant, it: TreeItem, col: int, raw: String) -> bool:
	if typeof(rec) != TYPE_DICTIONARY:
		return false
	var key := String(rec.get("path", ""))
	match col:
		COL_TAGS:
			var t := raw.strip_edges()
			var ud: Dictionary = _userdata.get(key, {})
			ud["tags"] = t
			_userdata[key] = ud
			it.set_text(COL_TAGS, t)
			return true
		COL_GAIN_DB:
			var s := raw.strip_edges()
			if s != "" and not s.is_valid_float():
				return false                        # must be a number
			var v := clampf(0.0 if s == "" else s.to_float(), GAIN_DB_MIN, GAIN_DB_MAX)
			var ud2: Dictionary = _userdata.get(key, {})
			ud2["gain_db"] = v
			_userdata[key] = ud2
			it.set_text(COL_GAIN_DB, _fmt_gain(v))
			_apply_final_cell(it, rec)
			if rec == _playing_rec:                 # live-apply to the current track
				_play_gain_db = v
				_apply_volume()
			return true
		COL_LEVEL:
			var s2 := raw.strip_edges()
			var ud3: Dictionary = _userdata.get(key, {})
			if s2 == "":
				ud3.erase("level")                  # clear the level
				ud3.erase("target_db")
				_userdata[key] = ud3
				it.set_text(COL_LEVEL, "")
				return true
			if not s2.is_valid_float():
				return false
			var lvl := clampf(s2.to_float(), 0.0, LEVEL_MAX)
			ud3["level"] = lvl
			ud3.erase("target_db")
			_userdata[key] = ud3
			it.set_text(COL_LEVEL, _fmt_level(lvl))
			_apply_target_to_gain(rec, it)          # recompute Gain dB (if measured)
			return true
	return false


# Persist after a bulk edit. Tags and Gain dB both live in userdata.
func _save_after_edit(_col: int) -> void:
	_save_userdata()


# --- copy / paste / clear (Ctrl+C, Ctrl+V, Del) -----------------------------
func _copy_selected_cells() -> void:
	var col := _selected_edit_col()
	if col < 0:
		return
	var it := _tree.get_selected()
	if it == null or not it.is_selected(col):
		var items := _selected_items_in_col(col)
		it = items[0] if not items.is_empty() else null
	if it == null:
		return
	var val := _cell_get(it.get_metadata(0), col)
	DisplayServer.clipboard_set(val)
	_status_label.text = "Copied %s: \"%s\"" % [COL_TITLES[col], val]


func _paste_to_selection() -> void:
	var col := _selected_edit_col()
	if col < 0:
		return
	var text := DisplayServer.clipboard_get().strip_edges()
	var n := 0
	for it in _selected_items_in_col(col):
		if _cell_set(it.get_metadata(0), it, col, text):
			n += 1
	if n > 0:
		_save_after_edit(col)
	_status_label.text = "Pasted %s to %d cell%s." % [COL_TITLES[col], n, "" if n == 1 else "s"]


func _clear_selected_cells(col: int) -> void:
	var n := 0
	for it in _selected_items_in_col(col):
		if _cell_set(it.get_metadata(0), it, col, ""):
			n += 1
	if n > 0:
		_save_after_edit(col)
	_status_label.text = "Cleared %s on %d cell%s." % [COL_TITLES[col], n, "" if n == 1 else "s"]


# --- type over a multi-cell selection (any editable column) -----------------
func _begin_cell_edit(col: int, first: String) -> void:
	_cell_edit_items = _selected_items_in_col(col)
	if _cell_edit_items.is_empty():
		return
	_cell_edit_col = col
	_cell_edit_orig = {}
	for it in _cell_edit_items:
		_cell_edit_orig[it] = it.get_text(col)
	_cell_edit_active = true
	_cell_edit_buf = first
	_cell_edit_live()
	_status_label.text = "Editing %d %s cell%s — type, Enter to apply, Esc to cancel" % [
		_cell_edit_items.size(), COL_TITLES[col], "" if _cell_edit_items.size() == 1 else "s"]


func _cell_edit_live() -> void:
	for it in _cell_edit_items:
		if is_instance_valid(it):
			it.set_text(_cell_edit_col, _cell_edit_buf)


func _commit_cell_edit() -> void:
	if not _cell_edit_active:
		return
	var col := _cell_edit_col
	var items := _cell_edit_items
	var raw := _cell_edit_buf
	var orig := _cell_edit_orig
	_end_cell_edit()
	var n := 0
	for it in items:
		if not is_instance_valid(it):
			continue
		if _cell_set(it.get_metadata(0), it, col, raw):
			n += 1
		else:
			it.set_text(col, String(orig.get(it, "")))   # revert invalid value
	if n > 0:
		_save_after_edit(col)
	_tree.deselect_all()
	_status_label.text = "Set %s on %d cell%s." % [COL_TITLES[col], n, "" if n == 1 else "s"]


func _cancel_cell_edit() -> void:
	for it in _cell_edit_items:
		if is_instance_valid(it):
			it.set_text(_cell_edit_col, String(_cell_edit_orig.get(it, "")))
	_end_cell_edit()
	_status_label.text = "Edit cancelled."


func _end_cell_edit() -> void:
	_cell_edit_active = false
	_cell_edit_col = -1
	_cell_edit_buf = ""
	_cell_edit_items = []
	_cell_edit_orig = {}


func _apply_rating(rec: Variant, it: TreeItem, rating: int) -> void:
	if typeof(rec) != TYPE_DICTIONARY:
		return
	_set_userdata(rec, "rating", rating)
	if it != null and is_instance_valid(it):
		_apply_userdata_cells(it, rec)
	_refresh_star_buttons(rec)
	if _sort_col == COL_RATING:                # keep order if sorted by rating
		_sort_filtered()
		_populate_tree()


func _on_star_pressed(rating: int) -> void:
	_apply_rating(_selected_rec(), _tree.get_selected(), rating)


func _refresh_star_buttons(rec: Variant) -> void:
	var rating := _get_rating(rec) if typeof(rec) == TYPE_DICTIONARY else 0
	for i in range(_star_btns.size()):
		_star_btns[i].text = "★" if (i + 1) <= rating else "☆"


func _stars(n: int) -> String:
	if n <= 0:
		return ""
	return "★".repeat(n) + "☆".repeat(5 - n)


# ===========================================================================
#  Gap analysis / chop visualiser
# ===========================================================================
# ----- chop params (chopping.json, beside the audio) -----------------------
func _load_chopping() -> void:
	_chopping = _load_json_dict(_chop_path)


func _save_chopping() -> void:
	_save_json_atomic(_chop_path, _chopping)


# ----- measured loudness (loudness.json, beside the audio) ------------------
func _load_loudness() -> void:
	_loudness = _load_json_dict(_lo_path)


func _get_loudness(rec: Variant) -> Variant:
	if typeof(rec) != TYPE_DICTIONARY:
		return null
	return _loudness.get(String(rec.get("path", "")))


func _loudness_rms(rec: Dictionary) -> float:
	# integrated LUFS; falls back to a legacy "rms_db" entry if present.
	var l: Variant = _get_loudness(rec)
	if typeof(l) == TYPE_DICTIONARY:
		if l.has("lufs"):
			return float(l["lufs"])
		if l.has("rms_db"):
			return float(l["rms_db"])
	return NAN


func _loudness_peak(rec: Dictionary) -> float:
	var l: Variant = _get_loudness(rec)
	return float(l["peak_db"]) if typeof(l) == TYPE_DICTIONARY and l.has("peak_db") else NAN


# The chop entry for a record, or null. A choppable file has "silence_db";
# a continuous one is {"continuous": true} and shows blank chop columns.
func _get_chop(rec: Variant) -> Variant:
	if typeof(rec) != TYPE_DICTIONARY:
		return null
	return _chopping.get(String(rec.get("path", "")))


func _chop_db_val(rec: Dictionary) -> float:
	var c: Variant = _get_chop(rec)
	return float(c["silence_db"]) if typeof(c) == TYPE_DICTIONARY and c.has("silence_db") else -999.0


func _chop_gap_val(rec: Dictionary) -> float:
	var c: Variant = _get_chop(rec)
	return float(c.get("min_gap_s", -1.0)) if typeof(c) == TYPE_DICTIONARY and c.has("silence_db") else -1.0


func _chop_snd_val(rec: Dictionary) -> float:
	var c: Variant = _get_chop(rec)
	return float(c.get("min_sound_s", -1.0)) if typeof(c) == TYPE_DICTIONARY and c.has("silence_db") else -1.0


func _chop_n_val(rec: Dictionary) -> int:
	var c: Variant = _get_chop(rec)
	return int(c.get("chops", -1)) if typeof(c) == TYPE_DICTIONARY and c.has("chops") else -1


func _apply_chop_cells(it: TreeItem, rec: Dictionary) -> void:
	var c: Variant = _get_chop(rec)
	var db_txt := ""
	var gap_txt := ""
	var snd_txt := ""
	var n_txt := ""
	if typeof(c) == TYPE_DICTIONARY:
		if c.has("silence_db"):
			db_txt = "%d" % int(round(float(c["silence_db"])))
			gap_txt = "%.1f" % float(c.get("min_gap_s", DEF_MIN_GAP_S))
			snd_txt = "%.2f" % float(c.get("min_sound_s", DEF_MIN_SOUND_S))
		if c.has("chops"):
			n_txt = str(int(c["chops"]))      # continuous files report 1 piece
	it.set_text(COL_CHOP_DB, db_txt)
	it.set_text(COL_CHOP_GAP, gap_txt)
	it.set_text(COL_CHOP_SND, snd_txt)
	it.set_text(COL_CHOP_N, n_txt)
	it.set_editable(COL_CHOP_DB, true)
	it.set_editable(COL_CHOP_GAP, true)
	it.set_editable(COL_CHOP_SND, true)
	it.set_tooltip_text(COL_CHOP_DB,
		"Chop silence threshold (dBFS). Blank = continuous, no chop. Double-click to edit.")
	it.set_tooltip_text(COL_CHOP_GAP, "Chop min-gap (s). Double-click to edit.")
	it.set_tooltip_text(COL_CHOP_SND,
		"Min sound (s): drop pieces shorter than this. 0 = keep all. Double-click to edit.")
	it.set_tooltip_text(COL_CHOP_N, "Pieces this file chops into at its settings (run/edit to fill).")


func _parse_float(txt: String, fallback: float) -> float:
	txt = txt.strip_edges()
	return txt.to_float() if txt.is_valid_float() else fallback


# Inline edit of a chop column: refine the stored param (creating an entry if the
# file was continuous), and -- if it's the file shown in the analyser -- recount
# live from the cached envelope.
func _on_chop_edited(rec: Variant, it: TreeItem, col: int) -> void:
	if typeof(rec) != TYPE_DICTIONARY:
		return
	var key := String(rec.get("path", ""))
	var c: Dictionary = _chopping.get(key, {})
	if not c.has("silence_db"):              # seed from defaults if newly created
		c = {"silence_db": DEF_SILENCE_DB, "min_gap_s": DEF_MIN_GAP_S,
			"min_sound_s": DEF_MIN_SOUND_S}
	c.erase("continuous")
	if col == COL_CHOP_DB:
		c["silence_db"] = clampf(_parse_float(it.get_text(col), c["silence_db"]), -90.0, 0.0)
	elif col == COL_CHOP_GAP:
		c["min_gap_s"] = clampf(_parse_float(it.get_text(col), c["min_gap_s"]), 0.0, 10.0)
	else:  # COL_CHOP_SND
		c["min_sound_s"] = clampf(_parse_float(it.get_text(col), c.get("min_sound_s", DEF_MIN_SOUND_S)), 0.0, 10.0)
	_chopping[key] = c
	# Live recount when this is the analysed file (we have its envelope cached).
	if rec == _an_rec and not _an_levels.is_empty():
		_sil_slider.set_value_no_signal(c["silence_db"])
		_gap_slider.set_value_no_signal(c["min_gap_s"])
		_snd_slider.set_value_no_signal(c.get("min_sound_s", DEF_MIN_SOUND_S))
		_update_param_labels()
		_on_param_changed()
		c["chops"] = _graph.segments.size()
		_chopping[key] = c
	_save_chopping()
	_apply_chop_cells(it, rec)


# Analyse EXACTLY these files (chops + loudness) in a thread — used to auto-fill the
# dB / Chop columns for freshly made chops/loops. Coalesces if one is already running.
func _analyse_paths(paths: Array) -> void:
	if paths.is_empty():
		return
	if _pa_busy or _pipe_busy:                  # don't collide with the update pipeline's
		for p in paths:                         # analyse step; _pipe_all_done drains these
			if not _pa_pending.has(p):
				_pa_pending.append(p)
		return
	var f := FileAccess.open(_pa_paths_file, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(paths))
	f.close()
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/analyse_audio.py").simplify_path()
	_pa_busy = true
	_an_status.text = "Analysing %d new file%s…" % [paths.size(), "" if paths.size() == 1 else "s"]
	_pa_thread = Thread.new()
	_pa_thread.start(_pa_run.bind(script, _pa_paths_file))


func _paths_of(recs: Array) -> Array:
	var out: Array = []
	for r in recs:
		if typeof(r) == TYPE_DICTIONARY:
			out.append(String(r.get("path", "")))
	return out


func _pa_run(script: String, paths_file: String) -> void:
	var output: Array = []
	var args := [script, "--paths", paths_file]
	_exec_tool(args, output)
	call_deferred("_pa_finished")


func _pa_finished() -> void:
	_pa_busy = false
	if _pa_thread:
		_pa_thread.wait_to_finish()
		_pa_thread = null
	_load_chopping()
	_load_loudness()
	_reload_chop_cells()
	_reload_loudness_cells()
	_recompute_targets()                       # level'd rows -> Gain dB now they're measured
	_an_status.text = "New chops/loops analysed (dB + chops filled)."
	if not _pa_pending.is_empty():             # analyse anything queued while we ran
		var next := _pa_pending
		_pa_pending = []
		_analyse_paths(next)


# If the analyse job renamed files with invalid characters, reload the path-keyed
# stores (they were migrated on disk) and summarise the renames in a dialog.
func _report_renames() -> void:
	if not FileAccess.file_exists(_sg_renames_path):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_sg_renames_path))
	if typeof(d) != TYPE_ARRAY or d.is_empty():
		return
	_load_index()                              # picks up renamed paths (rebuilds view)
	_load_userdata()
	_load_chopping()
	_load_loudness()
	_apply()
	var lines := "Renamed %d file%s with invalid characters:\n" % [d.size(), "" if d.size() == 1 else "s"]
	var shown := mini(d.size(), 15)
	for i in shown:
		lines += "\n• %s\n    → %s" % [String(d[i].get("old", "")).get_file(), String(d[i].get("new", "")).get_file()]
	if d.size() > shown:
		lines += "\n…and %d more" % (d.size() - shown)
	_info_dialog.title = "Files renamed"
	_info_dialog.dialog_text = lines
	_info_dialog.popup_centered()


# Re-read chopping.json from disk and repaint the chop cells of visible rows
# (cheap; doesn't disturb selection/scroll like a full repopulate would).
func _reload_chop_cells() -> void:
	_load_chopping()
	var root := _tree.get_root()
	if root == null:
		return
	var it := root.get_first_child()
	while it != null:
		var rec: Variant = it.get_metadata(0)
		if typeof(rec) == TYPE_DICTIONARY:
			_apply_chop_cells(it, rec)
		it = it.get_next()


# After (re)measuring, recompute Gain dB for every visible row that has a Target.
func _recompute_targets() -> int:
	var root := _tree.get_root()
	if root == null:
		return 0
	var applied := 0
	var it := root.get_first_child()
	while it != null:
		var rec: Variant = it.get_metadata(0)
		if typeof(rec) == TYPE_DICTIONARY and _apply_target_to_gain(rec, it) == 1:
			applied += 1
		it = it.get_next()
	if applied > 0:
		_save_userdata()
	return applied


func _reload_loudness_cells() -> void:
	_load_loudness()
	var root := _tree.get_root()
	if root == null:
		return
	var it := root.get_first_child()
	while it != null:
		var rec: Variant = it.get_metadata(0)
		if typeof(rec) == TYPE_DICTIONARY:
			_apply_loudness_cell(it, rec)
		it = it.get_next()


# ----- play chops: each piece + 1 s of silence, as a single preview stream ---
# Loop row's play button: pause/resume if a LOOP is what's loaded, else start a
# fresh loop preview of the selected region (seamless crossfade).
func _on_play_loop() -> void:
	if _play_kind == "loop" and _is_active():
		_toggle_pause()
		return
	if _xfade_chk:
		_xfade_chk.button_pressed = true       # crossfade preview
	if _loop_chk:
		_loop_chk.button_pressed = true         # loop so the seam is audible
	_play_chops("loop")


# Chops row's play button: pause/resume if CHOPS are what's live, else start them.
func _on_play_chops_btn() -> void:
	if _play_kind == "chops" and _is_active():
		_toggle_pause()
		return
	_play_chops("chops")


# `kind` labels the preview's owning row ("loop" or "chops"); "" keeps the current
# kind (internal re-previews: region re-drag, suggest auto-preview).
func _play_chops(kind := "") -> void:
	if typeof(_an_rec) != TYPE_DICTIONARY or _effective_segments().is_empty():
		_an_status.text = "Analyse a file (or drag a region) first — no chops to play."
		return
	var abs := _abs_path(_an_rec)
	if String(_an_rec.get("ext", "")).to_lower() != "wav" or not FileAccess.file_exists(abs):
		_an_status.text = "Play chops supports existing WAV files only."
		return
	var stream: AudioStreamWAV = AudioStreamWAV.load_from_file(abs)
	if stream == null:
		_an_status.text = "Could not load WAV: %s" % abs
		return
	var preview := _build_chops_stream(stream)
	if preview == null:
		_an_status.text = "Play chops needs 8/16-bit PCM (format %d)." % stream.format
		return
	_set_stream_loop(preview)                  # honour the Loop toggle
	_player.stream = preview
	_play_gain_db = _get_gain_db(_an_rec)      # match the source track's Gain dB
	_apply_volume()
	_player.play()
	_playing_chops = true                      # so re-selecting a region rebuilds this
	_preview_rec = _an_rec                      # the file this preview's playhead maps onto
	if kind == "":                             # internal re-preview keeps the current row
		kind = _play_kind if _play_kind in ["loop", "chops"] else "chops"
	_play_kind = kind
	var npieces := _effective_segments().size()    # WYSIWYG: the GREEN pieces actually played
	_stream_len = preview.get_length()
	_playing_rec = null          # preview timeline != original; skip cursor + play-count
	_playing_item = null
	_update_play_btn()
	var fn := String(_an_rec.get("filename", ""))
	var xfade_on: bool = _xfade_chk and _xfade_chk.button_pressed and npieces == 1
	if xfade_on:
		_now_label.text = "Playing crossfaded loop (%s ms):  %s" % [_xfade_edit.text.strip_edges(), fn]
	elif _graph.has_manual_sel() and npieces == 1:
		_now_label.text = "Playing region:  %s" % fn
	else:
		_now_label.text = "Playing %d chops (1 s gaps):  %s" % [npieces, fn]


# Concatenate the loaded WAV's pieces (segment frames -> samples) with 1 s of
# silence between each. Returns null for non-PCM formats we can't byte-slice.
func _build_chops_stream(stream: AudioStreamWAV) -> AudioStreamWAV:
	var bps := 0
	if stream.format == AudioStreamWAV.FORMAT_8_BITS:
		bps = 1
	elif stream.format == AudioStreamWAV.FORMAT_16_BITS:
		bps = 2
	else:
		return null
	var ch := 2 if stream.stereo else 1
	var frame_bytes := bps * ch
	var sr := stream.mix_rate
	var data := stream.data
	var total := data.size() / frame_bytes
	var segs := _effective_segments()
	# Crossfade preview: a SINGLE region baked (in memory) into a seamless loop —
	# the same equal-power overlap-add as loopify.py, so the preview == Make loop.
	if _xfade_chk and _xfade_chk.button_pressed and segs.size() == 1:
		return _build_xfade_loop_stream(stream, segs[0], bps, ch, frame_bytes, sr, data, total)
	var silence := PackedByteArray()
	silence.resize(int(sr) * frame_bytes)        # 1 s of zeros (= silence, signed PCM)
	var out := PackedByteArray()
	var first := true
	var cum := 0                                   # running sample offset into the preview
	var map_entries: Array = []                    # [prev_start_samp, prev_end_samp, a, b]
	for s in segs:
		var a := clampi(int(round(float(s[0]) * _an_frame_s * sr)), 0, total)
		var b := clampi(int(round(float(s[1]) * _an_frame_s * sr)), 0, total)
		if b <= a:
			continue
		if not first:
			out.append_array(silence)              # 1 s BETWEEN pieces only — no
			cum += int(sr)
		map_entries.append([cum, cum + (b - a), a, b])
		out.append_array(data.slice(a * frame_bytes, b * frame_bytes))
		cum += b - a
		first = false                              # leading/trailing pad, so a single
	if out.is_empty():                             # region loops seamlessly (no gap)
		return null
	_set_preview_map(map_entries, out.size() / frame_bytes, total)
	var sw := AudioStreamWAV.new()
	sw.format = stream.format
	sw.mix_rate = sr
	sw.stereo = stream.stereo
	sw.data = out
	return sw


# In-memory equal-power crossfade loop of ONE region (mirror of loopify.crossfade_
# loop): tail (L frames) faded out + blended over the head (faded in), then the
# untouched middle. Result length = N − L and wraps seamlessly. Per-sample mixing
# is only over the L overlap (cheap); the middle is a fast byte slice.
func _build_xfade_loop_stream(stream: AudioStreamWAV, seg: Array, bps: int, ch: int,
		frame_bytes: int, sr: int, data: PackedByteArray, total: int) -> AudioStreamWAV:
	var a := clampi(int(round(float(seg[0]) * _an_frame_s * sr)), 0, total)
	var b := clampi(int(round(float(seg[1]) * _an_frame_s * sr)), 0, total)
	if b <= a:
		return null
	var n := b - a
	var xfade_ms := maxf(0.0, _xfade_edit.text.strip_edges().to_float())
	var L := clampi(int(round(xfade_ms / 1000.0 * sr)), 0, n / 2)
	var out := PackedByteArray()
	if L > 0:
		out.resize(L * frame_bytes)              # the blended head; written below
		for i in range(L):
			var t := float(i) / float(L)
			var g_in := sin(t * PI / 2.0)        # equal power (constant power blend)
			var g_out := cos(t * PI / 2.0)
			for c in range(ch):
				var head_off := (a + i) * frame_bytes + c * bps
				var tail_off := (a + n - L + i) * frame_bytes + c * bps
				var dst := (i * ch + c) * bps
				if bps == 2:
					var hs := data.decode_s16(head_off)
					var ts := data.decode_s16(tail_off)
					out.encode_s16(dst, clampi(int(round(g_out * ts + g_in * hs)), -32768, 32767))
				else:                            # signed 8-bit
					var hs8 := data[head_off] - (256 if data[head_off] > 127 else 0)
					var ts8 := data[tail_off] - (256 if data[tail_off] > 127 else 0)
					out[dst] = clampi(int(round(g_out * ts8 + g_in * hs8)), -128, 127) & 0xff
	# untouched middle: frames [a+L, a+n-L)
	out.append_array(data.slice((a + L) * frame_bytes, (a + n - L) * frame_bytes))
	if out.is_empty():
		return null
	# preview frame j maps to original frame a+j (the whole crossfaded loop covers
	# original samples [a, a + (n-L)) — i.e. the region minus the crossfade tail)
	var ptot := out.size() / frame_bytes
	_set_preview_map([[0, ptot, a, a + ptot]], ptot, total)
	var sw := AudioStreamWAV.new()
	sw.format = stream.format
	sw.mix_rate = sr
	sw.stereo = stream.stereo
	sw.data = out
	return sw


# Crossfade option / Xfade ms changed — rebuild the live preview if one is playing.
func _on_xfade_changed(_v: Variant = null) -> void:
	if _playing_chops and not _effective_segments().is_empty():
		_play_chops()


# Live feedback as the region is dragged (status text + green repaint happens in
# the graph). No audio rebuild here — that waits for region_committed (release).
func _on_graph_region_selected(a: float, _b: float) -> void:
	if a < 0.0:
		_an_status.text = "Selection cleared — back to the detector."
		return
	var segs := _effective_segments()
	if segs.is_empty():
		return
	var t0 := float(segs[0][0]) * _an_frame_s
	var t1 := float(segs[0][1]) * _an_frame_s
	_an_status.text = "Region %s–%s (%.2f s). Chop to files / Play chops." % [
		_fmt_time(t0), _fmt_time(t1), t1 - t0]


# The region drag finished. If we're currently auditioning the preview, rebuild it
# from the NEW region and replay (so a looping preview follows the new selection).
func _on_region_committed() -> void:
	if _playing_chops and not _effective_segments().is_empty():
		_play_chops()


# Segments to chop/play: the drag-selected region (one piece) when one is picked,
# otherwise the detector's segments. WYSIWYG with the green in the graph.
func _effective_segments() -> Array:
	if _graph != null and _graph.has_manual_sel():
		var lo := minf(_graph.sel_a, _graph.sel_b)
		var hi := maxf(_graph.sel_a, _graph.sel_b)
		var n := _an_levels.size()
		return [[lo * n, hi * n]]
	return _graph.segments


# Store the preview->original timeline map, normalising raw sample offsets to 0..1
# fractions (see `_preview_map`). Called from the two preview builders.
func _set_preview_map(entries: Array, prev_total: int, orig_total: int) -> void:
	_preview_map.clear()
	if prev_total <= 0 or orig_total <= 0:
		return
	for e in entries:
		_preview_map.append([
			float(e[0]) / prev_total, float(e[1]) / prev_total,
			float(e[2]) / orig_total, float(e[3]) / orig_total])


# Map a fraction along the PREVIEW (0..1) to the matching fraction of the ORIGINAL
# file, so the graph playhead tracks the green region. Returns -1 in a silence gap
# between chops (cursor hidden there).
func _preview_frac_to_orig(f: float) -> float:
	for e in _preview_map:
		var p0 := float(e[0])
		var p1 := float(e[1])
		if f >= p0 and f <= p1:
			var span := p1 - p0
			var loc := 0.0 if span <= 0.0 else (f - p0) / span
			var o0 := float(e[2])
			return clampf(o0 + loc * (float(e[3]) - o0), 0.0, 1.0)
	return -1.0


# ----- chop to files: chop.py writes name_chopped_NNN.wav beside the original --
func _chop_selected() -> void:
	if _chop_busy:
		return
	var segs := _effective_segments()
	if typeof(_an_rec) != TYPE_DICTIONARY or segs.is_empty():
		_an_status.text = "Analyse a file (or drag a region) first — nothing to chop."
		return
	# A single segment is fine to chop: it trims the surrounding silence, writing
	# just the kept (green) region as one _chopped_001 file.
	var abs := _abs_path(_an_rec)
	if String(_an_rec.get("ext", "")).to_lower() != "wav" or not FileAccess.file_exists(abs):
		_an_status.text = "Chop supports existing WAV files only."
		return
	# WYSIWYG: chop exactly the pieces drawn (current segments / drag region), in seconds.
	var segs_s: Array = []
	for s in segs:
		segs_s.append([float(s[0]) * _an_frame_s, float(s[1]) * _an_frame_s])
	# chops inherit the parent's library/supplier/bundle/url in the index
	var parent := {
		"bundle": _an_rec.get("bundle", ""),
		"library": _an_rec.get("library", ""),
		"supplier": _an_rec.get("supplier", ""),
		"url": _an_rec.get("url", ""),
	}
	var f := FileAccess.open(_chop_spec_path, FileAccess.WRITE)
	if f == null:
		_an_status.text = "Could not write chop spec."
		return
	f.store_string(JSON.stringify({"segments_s": segs_s, "parent": parent}))
	f.close()
	if FileAccess.file_exists(_chop_result_path):
		DirAccess.remove_absolute(_chop_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/chop.py").simplify_path()
	_chop_busy = true
	_chop_btn.disabled = true
	_an_status.text = "Chopping %s into %d piece%s…" % [
		String(_an_rec.get("filename", "")), segs_s.size(), "" if segs_s.size() == 1 else "s"]
	_chop_thread = Thread.new()
	_chop_thread.start(_chop_run.bind(script, abs, _chop_spec_path, _chop_result_path))


func _chop_run(script: String, audio: String, spec: String, result: String) -> void:
	var output: Array = []
	var args := [script, audio, spec, result]
	var code := OS.execute("py", args, output, true)
	if code == -1:                       # py launcher not found; try python
		OS.execute("python", args, output, true)
	call_deferred("_chop_finished")


func _chop_finished() -> void:
	_chop_busy = false
	if _chop_thread:
		_chop_thread.wait_to_finish()
		_chop_thread = null
	_chop_btn.disabled = false
	if not FileAccess.file_exists(_chop_result_path):
		_an_status.text = "Chop failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_chop_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		_an_status.text = "Chop error: %s" % (d.get("error", "?") if typeof(d) == TYPE_DICTIONARY else "?")
		return
	# chop.py already added the new files to index.json; merge them into the live
	# list so they show now (no full re-scan, no restart).
	var recs: Array = d.get("records", [])
	var ptags := _get_tags(_an_rec) if typeof(_an_rec) == TYPE_DICTIONARY else ""
	_inherit_tags_to(recs, ptags)            # chops inherit the parent's tags
	_merge_new_records(recs)
	var tag_note := "  (tags inherited)" if ptags.strip_edges() != "" else ""
	_an_status.text = "Chopped into %d pieces — added to the library (original kept).%s" % [
		recs.size(), tag_note]
	_analyse_paths(_paths_of(recs))          # auto-fill dB + chop columns for the new chops


# ----- right-click context menu ---------------------------------------------
func _on_ctx_menu(id: int) -> void:
	if typeof(_ctx_rec) != TYPE_DICTIONARY:
		return
	match id:
		0:                                          # open folder (uses selected row)
			_on_reveal()
		1:                                          # copy absolute path
			DisplayServer.clipboard_set(_abs_path(_ctx_rec))
			_now_label.text = "Copied path:  %s" % _abs_path(_ctx_rec)
		2: _ctx_run("suggest_loop")
		3: _ctx_run("suggest_chops")
		4: _ctx_run("make_loop")
		5: _ctx_run("make_chops")
		6:                                          # convert non-WAV -> sibling WAV
			if String(_ctx_rec.get("ext", "")).to_lower() == "wav":
				_an_status.text = "Already a WAV."
			else:
				_convert_to_wav(_ctx_rec, "")
		7:                                          # delete (uses the current selection)
			_confirm_delete_selected()
		8:                                          # content-based similarity search
			_find_similar(_ctx_rec)
		9:                                          # 16-bit copies of the whole selection
			_convert_16bit_selected()


# Run a ctx action on _ctx_rec. Non-WAV sources (mp3/…) are decoded to a sibling
# WAV first (reused if it already exists), then the action runs on that WAV.
# Actions that need analysis queue via _pending_ctx and dispatch from _an_finished.
func _ctx_run(action: String) -> void:
	if typeof(_ctx_rec) != TYPE_DICTIONARY:
		return
	if String(_ctx_rec.get("ext", "")).to_lower() != "wav":
		var wrec: Variant = _sibling_wav_rec(_ctx_rec)
		if typeof(wrec) == TYPE_DICTIONARY:
			_ctx_rec = wrec                         # already decoded -> use the WAV
			_select_row_by_path(String(wrec.get("path", "")))
		else:
			_convert_to_wav(_ctx_rec, action)       # decode, then re-run on the WAV
			return
	if _ctx_rec == _an_rec and not _an_levels.is_empty() and not _an_busy:
		_dispatch_ctx(action)                       # already analysed -> go now
	else:
		_pending_ctx = action                       # analyse first, then dispatch
		_analyse_selected()                         # the ctx row is already selected


# The sibling <stem>.wav record for a non-WAV rec, if it's already in the library.
func _sibling_wav_rec(rec: Dictionary) -> Variant:
	var p := String(rec.get("path", ""))
	var dot := p.rfind(".")
	if dot < 0:
		return null
	return _by_path.get(p.substr(0, dot) + ".wav")


# The <stem>_16bit.wav sibling for a WAV rec (16-bit copy of a 24-bit/EXTENSIBLE
# WAV Godot can't load directly), if it's already in the library.
func _sibling_16bit_rec(rec: Dictionary) -> Variant:
	var p := String(rec.get("path", ""))
	var dot := p.rfind(".")
	if dot < 0:
		return null
	return _by_path.get(p.substr(0, dot) + "_16bit.wav")


func _convert_to_wav(rec: Dictionary, then_action: String) -> void:
	_convert_audio(rec, "to_wav.py", "Decoding %s to WAV…", then_action)


func _convert_to_16bit(rec: Dictionary, then_action: String) -> void:
	_convert_audio(rec, "to_16bit.py", "Converting %s to 16-bit to play…", then_action)


# Shared decode/convert launcher: runs indexer/<script_name> <src> <result> in a
# thread, then _convert_finished merges the new record and continues `then_action`.
func _convert_audio(rec: Dictionary, script_name: String, status_fmt: String, then_action: String) -> void:
	if _convert_busy:
		return
	var abs := _abs_path(rec)
	if not FileAccess.file_exists(abs):
		_an_status.text = "File not found: %s" % abs
		return
	if FileAccess.file_exists(_convert_result_path):
		DirAccess.remove_absolute(_convert_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/" + script_name).simplify_path()
	_convert_busy = true
	_convert_then = then_action
	_an_status.text = status_fmt % String(rec.get("filename", ""))
	_convert_thread = Thread.new()
	_convert_thread.start(_convert_run.bind(script, abs, _convert_result_path))


func _convert_run(script: String, audio: String, result: String) -> void:
	var output: Array = []
	var args := [script, audio, result]
	_exec_tool(args, output)
	call_deferred("_convert_finished")


func _convert_finished() -> void:
	_convert_busy = false
	var then := _convert_then
	_convert_then = ""
	if _convert_thread:
		_convert_thread.wait_to_finish()
		_convert_thread = null
	if not FileAccess.file_exists(_convert_result_path):
		_an_status.text = "Convert failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_convert_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		_an_status.text = "Convert error: %s" % (d.get("error", "?") if typeof(d) == TYPE_DICTIONARY else "?")
		return
	var recs: Array = d.get("records", [])
	_merge_new_records(recs)                        # the new WAV row appears now
	# to_wav.py reports "out"; to_16bit.py returns records only — fall back to those.
	var wpath := String(d.get("out", ""))
	if wpath == "" and not recs.is_empty():
		wpath = String(recs[0].get("path", ""))
	if wpath == "":                                 # nothing produced (e.g. already existed)
		_an_status.text = "Convert produced no new file (a converted copy may already exist)."
		return
	_select_row_by_path(wpath)
	var wrec: Variant = _by_path.get(wpath)
	_an_status.text = "Converted: %s" % wpath.get_file()
	if then == "__play__":
		if typeof(wrec) == TYPE_DICTIONARY:
			_play_selected()                        # the converted WAV row is now selected
		return
	if then != "" and typeof(wrec) == TYPE_DICTIONARY:
		_ctx_rec = wrec
		_ctx_run(then)                              # continue the original action on the WAV


# ----- delete selected files (Del / context menu) -> Recycle Bin, with confirm --
func _confirm_delete_selected() -> void:
	var recs: Array = []
	var it := _tree.get_next_selected(null)
	while it != null:
		var r: Variant = it.get_metadata(0)
		if typeof(r) == TYPE_DICTIONARY:
			recs.append(r)
		it = _tree.get_next_selected(it)
	if recs.is_empty():
		return
	_delete_pending = recs
	var shown := mini(recs.size(), 8)
	var names := ""
	for i in shown:
		names += "\n•  " + String(recs[i].get("filename", ""))
	if recs.size() > shown:
		names += "\n…and %d more" % (recs.size() - shown)
	_confirm_dialog.dialog_text = "Move %d file%s to the Recycle Bin?%s" % [
		recs.size(), "" if recs.size() == 1 else "s", names]
	_confirm_dialog.popup_centered()


func _do_delete_confirmed() -> void:
	var recs := _delete_pending
	_delete_pending = []
	if recs.is_empty():
		return
	var del_paths := {}
	var failed := 0
	for rec in recs:
		var key := String(rec.get("path", ""))
		var err := OS.move_to_trash(_abs_path(rec))   # Recycle Bin (recoverable)
		if err == OK:
			del_paths[key] = true
			_userdata.erase(key)
		else:
			failed += 1
	if del_paths.is_empty():
		_status_label.text = "Delete failed (%d file(s) could not be moved to the Recycle Bin)." % failed
		return
	# stop/clear anything pointing at a deleted file
	if typeof(_playing_rec) == TYPE_DICTIONARY and del_paths.has(String(_playing_rec.get("path", ""))):
		_player.stop()
		_playing_rec = null
	if typeof(_an_rec) == TYPE_DICTIONARY and del_paths.has(String(_an_rec.get("path", ""))):
		_an_rec = null
		_an_levels = PackedFloat32Array()
		_graph.levels = _an_levels
		_graph.queue_redraw()
	var kept: Array = []
	for r in _all:
		if not del_paths.has(String(r.get("path", ""))):
			kept.append(r)
	_all = kept
	_by_path = {}
	for r in _all:
		_by_path[String(r.get("path", ""))] = r
	_save_userdata()
	_save_index()                                  # persist so they don't reappear on restart
	_apply()
	_status_label.text = "Deleted %d file(s) to the Recycle Bin%s." % [
		del_paths.size(), ("  (%d failed)" % failed) if failed else ""]


# Persist _all back to res://index.json (atomic-ish) so deletions/merges survive a
# restart without a full re-index.
func _save_index() -> void:
	if _library_root == "":
		return
	# Godot's JSON.stringify does NOT escape raw control chars (< 0x20); a stray one
	# in a bext description (e.g. \x13) would make index.json invalid for strict
	# parsers (Python's json, so analyse_audio.py). Scrub descriptions before write.
	var ctrl := RegEx.new()
	ctrl.compile("[\\x00-\\x1f]")
	for r in _all:
		var d: Variant = r.get("description")
		if typeof(d) == TYPE_STRING and ctrl.search(d) != null:
			r["description"] = ctrl.sub(d, " ", true).strip_edges()
	var out := {
		"library_root": _library_root,
		"generated": _index_generated,
		"count": _all.size(),
		"files": _all,
	}
	var path := ProjectSettings.globalize_path("res://index.json")
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)


# Rel paths of every currently-selected row.
func _selected_paths() -> Array:
	var out: Array = []
	var it := _tree.get_next_selected(null)
	while it != null:
		var r: Variant = it.get_metadata(0)
		if typeof(r) == TYPE_DICTIONARY:
			out.append(String(r.get("path", "")))
		it = _tree.get_next_selected(it)
	return out


# Find the row with this rel path, select it and scroll it into view.
func _select_row_by_path(path: String) -> void:
	var root := _tree.get_root()
	if root == null:
		return
	var it := root.get_first_child()
	while it != null:
		var r: Variant = it.get_metadata(0)
		if typeof(r) == TYPE_DICTIONARY and String(r.get("path", "")) == path:
			_tree.deselect_all()
			it.select(0)
			_tree.scroll_to_item(it)
			_refresh_star_buttons(r)
			return
		it = it.get_next()


func _dispatch_ctx(action: String) -> void:
	match action:
		"suggest_loop":
			_suggest_loop()                         # sets region + xfade, loops, auditions
		"suggest_chops":
			_apply_suggested()                      # histogram threshold -> re-detect segments
			_graph.sel_a = -1.0                     # detector segments (not a manual region)
			_graph.sel_b = -1.0
			_graph.queue_redraw()
			if _xfade_chk: _xfade_chk.button_pressed = false
			if _loop_chk: _loop_chk.button_pressed = true
			_play_chops("chops")                    # audition the chops, looping
		"make_loop":
			_ctx_after_suggest = true               # bake once Suggest loop lands
			_suggest_loop()
		"make_chops":
			_chop_selected()


# ----- suggest loop: loopfind.py picks a good loop region, then auto-preview ----
func _suggest_loop() -> void:
	if _sl_busy:
		return
	if typeof(_an_rec) != TYPE_DICTIONARY:
		_an_status.text = "Click a file first, then Suggest loop."
		return
	var abs := _abs_path(_an_rec)
	if String(_an_rec.get("ext", "")).to_lower() != "wav" or not FileAccess.file_exists(abs):
		_an_status.text = "Suggest loop supports existing WAV files only."
		return
	if FileAccess.file_exists(_sl_result_path):
		DirAccess.remove_absolute(_sl_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/loopfind.py").simplify_path()
	_sl_busy = true
	_suggest_loop_btn.disabled = true
	_an_status.text = "Finding a good loop…"
	_sl_thread = Thread.new()
	_sl_thread.start(_sl_run.bind(script, abs, _sl_result_path))


func _sl_run(script: String, audio: String, result: String) -> void:
	var output: Array = []
	var args := [script, audio, result]
	_exec_tool(args, output)
	call_deferred("_sl_finished")


func _sl_finished() -> void:
	_sl_busy = false
	if _sl_thread:
		_sl_thread.wait_to_finish()
		_sl_thread = null
	_suggest_loop_btn.disabled = false
	if not FileAccess.file_exists(_sl_result_path):
		_an_status.text = "Suggest loop failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_sl_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		_an_status.text = "Suggest loop error: %s" % (d.get("error", "?") if typeof(d) == TYPE_DICTIONARY else "?")
		return
	var dur := float(d.get("duration", _an_duration))
	if dur <= 0.0:
		dur = maxf(_an_duration, 0.001)
	# set the green region from the suggested seconds, and the crossfade
	_graph.sel_a = clampf(float(d.get("start_s", 0.0)) / dur, 0.0, 1.0)
	_graph.sel_b = clampf(float(d.get("end_s", dur)) / dur, 0.0, 1.0)
	_graph.queue_redraw()
	_xfade_edit.text = "%.0f" % float(d.get("crossfade_ms", 100.0))
	_xfade_chk.button_pressed = true            # preview as a crossfaded loop
	if _loop_chk:
		_loop_chk.button_pressed = true         # loop it so the seam is audible
	var kind := ("rhythmic %.0f ms" % float(d.get("period_ms", 0.0))) if d.get("periodic", false) else "texture"
	if _ctx_after_suggest:                      # right-click "Make loop": bake it now
		_ctx_after_suggest = false
		_an_status.text = "Suggested loop %.3f–%.3fs (%s) — baking…" % [
			float(d.get("start_s", 0.0)), float(d.get("end_s", 0.0)), kind]
		_make_loop()
		return
	_an_status.text = "Suggested loop %.3f–%.3fs (%.0f ms xfade, %s) — auditioning; tweak then Make loop." % [
		float(d.get("start_s", 0.0)), float(d.get("end_s", 0.0)), float(d.get("crossfade_ms", 0.0)), kind]
	_play_chops("loop")                         # audition the crossfaded loop now


# ----- make loop: loopify.py bakes a seamless name_loop.wav beside the original --
func _make_loop() -> void:
	if _loop_busy:
		return
	var segs := _effective_segments()
	if typeof(_an_rec) != TYPE_DICTIONARY or segs.is_empty():
		_an_status.text = "Drag a region (or analyse a file) first — nothing to loop."
		return
	if segs.size() > 1 and not _graph.has_manual_sel():
		_an_status.text = "Pick ONE region to loop: drag it on the waveform."
		return
	var abs := _abs_path(_an_rec)
	if String(_an_rec.get("ext", "")).to_lower() != "wav" or not FileAccess.file_exists(abs):
		_an_status.text = "Make loop supports existing WAV files only."
		return
	var seg: Array = segs[0]                    # the green region (or the single piece)
	var start_s := float(seg[0]) * _an_frame_s
	var end_s := float(seg[1]) * _an_frame_s
	var xfade_ms := maxf(0.0, _xfade_edit.text.strip_edges().to_float())
	# crossfade can't exceed half the region, or loopify clamps it anyway
	var spec := {
		"start_s": start_s, "end_s": end_s,
		"crossfade_ms": xfade_ms, "curve": "equal_power",
		"parent": {
			"bundle": _an_rec.get("bundle", ""),
			"library": _an_rec.get("library", ""),
			"supplier": _an_rec.get("supplier", ""),
			"url": _an_rec.get("url", ""),
		},
	}
	var f := FileAccess.open(_loop_spec_path, FileAccess.WRITE)
	if f == null:
		_an_status.text = "Could not write loop spec."
		return
	f.store_string(JSON.stringify(spec))
	f.close()
	if FileAccess.file_exists(_loop_result_path):
		DirAccess.remove_absolute(_loop_result_path)
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/loopify.py").simplify_path()
	_loop_busy = true
	_loop_btn.disabled = true
	_an_status.text = "Baking seamless loop (%.0f ms crossfade)…" % xfade_ms
	_loop_thread = Thread.new()
	_loop_thread.start(_loop_run.bind(script, abs, _loop_spec_path, _loop_result_path))


func _loop_run(script: String, audio: String, spec: String, result: String) -> void:
	var output: Array = []
	var args := [script, audio, spec, result]
	_exec_tool(args, output)
	call_deferred("_loop_finished")


func _loop_finished() -> void:
	_loop_busy = false
	if _loop_thread:
		_loop_thread.wait_to_finish()
		_loop_thread = null
	_loop_btn.disabled = false
	if not FileAccess.file_exists(_loop_result_path):
		_an_status.text = "Make loop failed (no output). Is python on PATH?"
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_loop_result_path))
	if typeof(d) != TYPE_DICTIONARY or not d.get("ok", false):
		_an_status.text = "Make loop error: %s" % (d.get("error", "?") if typeof(d) == TYPE_DICTIONARY else "?")
		return
	var recs: Array = d.get("records", [])
	var ptags := _get_tags(_an_rec) if typeof(_an_rec) == TYPE_DICTIONARY else ""
	_inherit_tags_to(recs, ptags)               # the loop inherits the parent's tags
	_merge_new_records(recs)
	var tag_note := "  (tags inherited)" if ptags.strip_edges() != "" else ""
	_an_status.text = "Seamless loop added (%.2fs, %.0f ms xfade) — original kept.%s" % [
		float(d.get("out_duration", 0.0)), float(d.get("xfade_ms", 0.0)), tag_note]
	_analyse_paths(_paths_of(recs))             # auto-fill dB + chop columns for the loop


# Give each new record (e.g. fresh chops) the parent's tags in userdata, keyed by
# their own paths, so they carry your keywords from the moment they appear.
func _inherit_tags_to(recs: Array, tags: String) -> void:
	if tags.strip_edges() == "":
		return
	for r in recs:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var key := String(r.get("path", ""))
		var ud: Dictionary = _userdata.get(key, {})
		ud["tags"] = tags
		_userdata[key] = ud
	_save_userdata()


# Insert/replace records (e.g. fresh chops) into _all by path, then refresh the
# view so they appear immediately.
func _merge_new_records(recs: Array) -> void:
	if recs.is_empty():
		return
	var by_path := {}
	for i in _all.size():
		by_path[String(_all[i].get("path", ""))] = i
	for r in recs:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var rp := String(r.get("path", ""))
		if by_path.has(rp):
			_all[by_path[rp]] = r
		else:
			_all.append(r)
	_apply()                  # re-filter + repopulate so the chops are visible now


func _update_param_labels() -> void:
	if _sil_lbl: _sil_lbl.text = "%d dB" % int(_sil_slider.value)
	if _gap_lbl: _gap_lbl.text = "%.1f s" % _gap_slider.value
	if _snd_lbl: _snd_lbl.text = "%.2f s" % _snd_slider.value


# --- run the Python envelope extractor for the selected file (off-thread) ---
func _analyse_selected() -> void:
	var rec: Variant = _selected_rec()
	if rec == null:
		_an_status.text = "Select a row first."
		return
	if String(rec.get("ext", "")).to_lower() != "wav":
		_an_status.text = "Analyser supports WAV only."
		return
	if _an_busy:
		return
	var audio := _abs_path(rec)
	if not FileAccess.file_exists(audio):
		_an_status.text = "File not found: %s" % audio
		return
	if FileAccess.file_exists(_an_out_path):
		DirAccess.remove_absolute(_an_out_path)
	var script := ProjectSettings.globalize_path("res://").path_join("../indexer/envelope.py").simplify_path()
	_an_rec = rec
	_an_busy = true
	_an_status.text = "Analysing %s ..." % String(rec.get("filename", ""))
	_an_thread = Thread.new()
	_an_thread.start(_an_run.bind(script, audio, _an_out_path))


func _an_run(script: String, audio: String, out: String) -> void:
	var output: Array = []
	var code := OS.execute("py", [script, audio, out], output, true)
	if code == -1:                       # py launcher not found; try python
		OS.execute("python", [script, audio, out], output, true)
	call_deferred("_an_finished")


func _exit_tree() -> void:
	_save_prefs()
	if _chop_save_debounce and _chop_save_debounce.time_left > 0.0:
		_save_chopping()                 # flush a pending coalesced write
	if _an_thread and _an_thread.is_started():
		_an_thread.wait_to_finish()
	if _pipe_thread and _pipe_thread.is_started():
		_pipe_thread.wait_to_finish()
	if _chop_thread and _chop_thread.is_started():
		_chop_thread.wait_to_finish()
	if _sem_thread and _sem_thread.is_started():
		_sem_thread.wait_to_finish()
	if _convert_thread and _convert_thread.is_started():
		_convert_thread.wait_to_finish()
	if _sl_thread and _sl_thread.is_started():
		_sl_thread.wait_to_finish()
	if _reindex_thread and _reindex_thread.is_started():
		_reindex_thread.wait_to_finish()
	if _pa_thread and _pa_thread.is_started():
		_pa_thread.wait_to_finish()
	if _similar_thread and _similar_thread.is_started():
		_similar_thread.wait_to_finish()
	if _clap_dl_thread and _clap_dl_thread.is_started():
		_clap_dl_thread.wait_to_finish()
	if _to16_thread and _to16_thread.is_started():
		_to16_thread.wait_to_finish()
	if _clap_search_thread and _clap_search_thread.is_started():
		_clap_search_thread.wait_to_finish()


func _an_finished() -> void:
	_an_busy = false
	var pend := _pending_ctx            # a right-click action waiting on analysis
	_pending_ctx = ""                   # cleared up front: a failed analysis drops it
	if _an_thread:
		_an_thread.wait_to_finish()
		_an_thread = null
	if not FileAccess.file_exists(_an_out_path):
		_an_status.text = "Analysis failed (no output). Is python on PATH?"
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_an_out_path))
	if typeof(data) != TYPE_DICTIONARY or not data.get("ok", false):
		_an_status.text = "Analysis error: %s" % (data.get("error", "?") if typeof(data) == TYPE_DICTIONARY else "?")
		return
	_an_levels = PackedFloat32Array(data["levels"])
	_an_frame_s = float(data["frame_s"])
	_an_duration = float(data["duration"])
	_an_suggested = float(data["suggested_db"])
	_graph.levels = _an_levels
	_graph.sel_a = -1.0                 # drop any stale manual selection from the prior file
	_graph.sel_b = -1.0
	_apply_saved_or_suggested()        # also recomputes + redraws
	if pend != "":
		_dispatch_ctx(pend)


# Drive the sliders from this file's saved chop params if it has any, else from
# the per-file suggested threshold. Either way recomputes + redraws.
func _apply_saved_or_suggested() -> void:
	if _an_levels.is_empty():
		return
	var c: Variant = _get_chop(_an_rec)
	if typeof(c) == TYPE_DICTIONARY and c.has("silence_db"):
		_sil_slider.set_value_no_signal(float(c["silence_db"]))
		_gap_slider.set_value_no_signal(float(c.get("min_gap_s", DEF_MIN_GAP_S)))
		_snd_slider.set_value_no_signal(float(c.get("min_sound_s", DEF_MIN_SOUND_S)))
		_update_param_labels()
		_on_param_changed()
	else:
		_apply_suggested()


func _apply_suggested() -> void:
	if _an_levels.is_empty():
		return
	# Suggest Chops works on the DETECTOR segments, so drop any leftover manual
	# region (e.g. the green loop region a prior Suggest loop left) — otherwise
	# _effective_segments() keeps returning that one region and chops do nothing.
	if _graph != null and _graph.has_manual_sel():
		_graph.sel_a = -1.0
		_graph.sel_b = -1.0
	_sil_slider.set_value_no_signal(_an_suggested)
	_update_param_labels()
	_on_param_changed()


func _on_param_changed() -> void:
	_update_param_labels()
	if _an_levels.is_empty():
		_graph.queue_redraw()
		return
	var segs := _gd_find_segments(_an_levels, _sil_slider.value,
		_gap_slider.value, _snd_slider.value, _an_frame_s)
	_graph.threshold_db = _sil_slider.value
	_graph.segments = segs
	_graph.queue_redraw()
	var name := String(_an_rec.get("filename", "")) if typeof(_an_rec) == TYPE_DICTIONARY else "?"
	# If nothing survived, say WHY: usually Min sound discarding short pieces
	# (e.g. tight gun bursts) rather than the threshold finding nothing.
	if segs.is_empty() and _snd_slider.value > 0.0:
		var raw := _gd_find_segments(_an_levels, _sil_slider.value,
			_gap_slider.value, 0.0, _an_frame_s)
		if raw.size() > 0:
			_an_status.text = "%s  →  0 pieces  (%d below Min sound %.2fs — lower Min sound)" % [
				name, raw.size(), _snd_slider.value]
			return
	_an_status.text = "%s  →  %d piece%s  (%d gaps)" % [
		name, segs.size(), "" if segs.size() == 1 else "s", maxi(0, segs.size() - 1)]


# A USER param change (slider drag or click on the graph): recompute live AND
# persist the result to chopping.json for the analysed file, so the Chop dB /
# gap / pieces columns track what you set. (Auto-load uses _on_param_changed,
# which never persists — browsing files doesn't write config.)
func _on_user_param_changed() -> void:
	_on_param_changed()
	_persist_analysed_chop()


func _persist_analysed_chop() -> void:
	if typeof(_an_rec) != TYPE_DICTIONARY or _an_levels.is_empty():
		return
	var key := String(_an_rec.get("path", ""))
	var entry := {
		"silence_db": _sil_slider.value,
		"min_gap_s": _gap_slider.value,
		"min_sound_s": _snd_slider.value,
		"chops": _graph.segments.size(),
	}
	var old: Variant = _chopping.get(key)
	if typeof(old) == TYPE_DICTIONARY and old.has("size"):
		entry["size"] = old["size"]
	_chopping[key] = entry
	_chop_save_debounce.start()          # disk write coalesced (see _build_ui)
	# refresh the analysed file's row (usually the selected one)
	var it := _tree.get_selected()
	if it and it.get_metadata(0) == _an_rec:
		_apply_chop_cells(it, _an_rec)


# Click/drag on the visualiser sets the silence threshold to that dB level.
func _on_graph_threshold_picked(db: float) -> void:
	if _an_levels.is_empty():
		return
	_sil_slider.set_value_no_signal(clampf(db, _sil_slider.min_value, _sil_slider.max_value))
	_on_user_param_changed()


# GDScript port of indexer/gaps.find_segments — runs live as sliders move.
func _gd_find_segments(levels: PackedFloat32Array, silence_db: float,
		min_gap_s: float, min_sound_s: float, frame_s: float) -> Array:
	var n := levels.size()
	if n == 0:
		return []
	var min_gap_frames := maxi(1, int(round(min_gap_s / frame_s)))
	var min_sound_frames := min_sound_s / frame_s
	var segs: Array = []
	var seg_start := -1
	var quiet := 0
	for i in n:
		if levels[i] >= silence_db:
			if seg_start < 0:
				seg_start = i
			quiet = 0
		else:
			quiet += 1
			if seg_start >= 0 and quiet >= min_gap_frames:
				var seg_end := i - quiet + 1
				if (seg_end - seg_start) >= min_sound_frames:
					segs.append([seg_start, seg_end])
				seg_start = -1
	if seg_start >= 0 and (n - seg_start) >= min_sound_frames:
		segs.append([seg_start, n])
	return segs


# ===========================================================================
#  Formatting helpers
# ===========================================================================
func _short_bundle(b: String) -> String:
	# "Sonniss.com - GDC 2018 - Game Audio Bundle" -> "GDC 2018"
	var digits := ""
	for ch in b:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits.length() >= 4:
		return "GDC " + digits.substr(0, 4)
	return "GDC (orig)"


func _fmt_dur(d: Variant) -> String:
	if d == null:
		return ""
	return _fmt_time(float(d))


func _fmt_time(secs: float) -> String:
	var s := int(round(secs))
	return "%d:%02d" % [s / 60, s % 60]


func _fmt_rate(r: Variant) -> String:
	if r == null:
		return ""
	var khz := float(r) / 1000.0
	return ("%.0f kHz" % khz) if khz == floor(khz) else ("%.1f kHz" % khz)


func _fmt_size(b: Variant) -> String:
	if b == null:
		return ""
	var mb := float(b) / 1048576.0
	if mb >= 1.0:
		return "%.1f MB" % mb
	return "%.0f KB" % (float(b) / 1024.0)


# Format a numeric value in a column's own units (for the range slider + button).
func _fmt_col_value(v: float, col: int) -> String:
	match col:
		COL_DURATION: return _fmt_time(v)                 # mm:ss
		COL_SIZE: return _fmt_size(v)                     # bytes -> MB/KB
		COL_RATE: return _fmt_rate(v)                     # Hz -> kHz
		COL_CHOP_GAP, COL_CHOP_SND: return "%.2fs" % v
		COL_LOUDNESS, COL_GAIN_DB, COL_FINAL_DB, COL_CHOP_DB: return "%.1f dB" % v
		COL_SCORE: return "%.2f" % v
		COL_LEVEL: return "%.1f" % v
		COL_BIT, COL_CH, COL_RATING, COL_PLAYS, COL_CHOP_N: return "%d" % int(round(v))
	return RangeSlider.fmt(v)
