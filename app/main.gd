extends Control
## Sound Library browser.
## Loads res://index.json (produced by indexer/index.py), shows an Excel-like
## sortable/filterable table, and auditions the original WAV files on demand.

# ----- column layout -------------------------------------------------------
const COL_FILENAME := 0
const COL_SCORE := 1    # semantic-search cosine similarity (read-only; blank otherwise)
const COL_LIBRARY := 2
const COL_SUPPLIER := 3
const COL_BUNDLE := 4
const COL_DURATION := 5
const COL_RATE := 6
const COL_BIT := 7
const COL_CH := 8
const COL_SIZE := 9
const COL_RATING := 10  # user data (userdata.json)
const COL_PLAYS := 11   # user data (auto-incremented on finished playback)
const COL_CHOP_DB := 12 # suggested/edited chop silence threshold (chopping.json)
const COL_CHOP_GAP := 13 # suggested/edited chop min-gap seconds (chopping.json)
const COL_CHOP_SND := 14 # suggested/edited chop min-sound seconds (chopping.json)
const COL_CHOP_N := 15  # resulting chop pieces at those settings (chopping.json)
const COL_TAGS := 16    # user data (your own keywords; editable inline)
const COL_LEVEL := 17   # user data: desired loudness on a 0-10 perceptual scale; -> Gain dB
const COL_LOUDNESS := 18 # measured integrated loudness "orig dB", LUFS (loudness.json; read-only)
const COL_GAIN_DB := 19 # user data: per-track applied playback gain in dB
const COL_FINAL_DB := 20 # read-only: resulting loudness = orig dB + Gain dB
const COL_COUNT := 21

const COL_TITLES := [
	"Filename", "Score", "Library", "Supplier", "Bundle",
	"Duration", "Rate", "Bit", "Ch", "Size", "Rating", "Plays",
	"Chop dB", "Chop gap", "Min snd", "Chop pieces", "Tags",
	"tgt vol/Level", "orig dB", "Gain dB", "final dB",
]
# Which record field each column sorts/reads. Score, Bundle, Rating, Plays,
# Chop dB/gap/snd/pieces, Tags, Level, orig dB, Gain dB and final dB are special-cased.
const COL_FIELD := [
	"filename", "", "library", "supplier", "bundle",
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
const KW_MIN_LEN := 2       # ignore 1-char tokens

# Default column widths (indices match COL_*). Columns are resizable at runtime.
const COL_DEFAULT_W := [460, 56, 180, 140, 85, 65, 72, 42, 38, 78, 95, 58, 70, 72, 70, 80, 200, 96, 72, 64, 72]
const COL_MIN_W := 28       # smallest a column can be dragged to
const RESIZE_GRAB := 6      # px tolerance around a divider to start a resize

# Gap analysis defaults (chosen from exploration; tunable live in the analyser).
const DEF_SILENCE_DB := -60.0
const DEF_MIN_GAP_S := 1.5
const DEF_MIN_SOUND_S := 0.3


## Draws the loudness (dBFS) envelope vs time, the silence threshold, the
## detected "dead zones" (gaps) and a playback cursor.
class WaveGraph extends Control:
	signal threshold_picked(db: float)     # right-click/drag: set the silence threshold
	signal seek_requested(fraction: float) # left-click/drag: scrub playback

	var levels := PackedFloat32Array()
	var segments: Array = []          # [[start_frame, end_frame], ...]
	var threshold_db: float = DEF_SILENCE_DB
	var playhead: float = -1.0        # 0..1; < 0 hides
	const TOP_DB := 0.0
	const BOT_DB := -90.0
	const TRACK_PAD := 7.0            # px from the bottom for the seek track + dot

	func _yfor(db: float) -> float:
		return clampf((TOP_DB - db) / (TOP_DB - BOT_DB), 0.0, 1.0) * size.y

	func _db_at_y(y: float) -> float:
		var t := clampf(y / maxf(size.y, 1.0), 0.0, 1.0)
		return TOP_DB - t * (TOP_DB - BOT_DB)

	func _frac_at_x(x: float) -> float:
		return clampf(x / maxf(size.x, 1.0), 0.0, 1.0)

	# Left CLICK = scrub playback (x) AND set the chop dB level (y), both at once.
	# Left DRAG = scrub only (so a horizontal scrub doesn't wobble the threshold).
	# Right click/drag = set the chop dB level only.
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				seek_requested.emit(_frac_at_x(event.position.x))
				threshold_picked.emit(_db_at_y(event.position.y))
				accept_event()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				threshold_picked.emit(_db_at_y(event.position.y))
				accept_event()
		elif event is InputEventMouseMotion:
			if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				seek_requested.emit(_frac_at_x(event.position.x))
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
		for x in int(w):
			var fi := mini(int(float(x) / w * n), n - 1)
			var kept := not has_segs or _frame_in_segment(fi)
			draw_line(Vector2(x, h), Vector2(x, _yfor(levels[fi])), green if kept else grey, 1.0)
		# chop boundaries: start + end of every kept piece, in blue
		if has_segs:
			var bcol := Color(0.30, 0.62, 1.0, 0.9)
			for s in segments:
				var xs := float(int(s[0])) / n * w
				var xe := float(int(s[1])) / n * w
				draw_line(Vector2(xs, 0), Vector2(xs, h), bcol, 1.0)
				draw_line(Vector2(xe, 0), Vector2(xe, h), bcol, 1.0)
		# silence threshold + its dB value
		var ty := _yfor(threshold_db)
		var ocol := Color(1.0, 0.6, 0.1)
		draw_line(Vector2(0, ty), Vector2(w, ty), ocol, 1.5)
		var font := get_theme_default_font()
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


## Two-knob range slider for numeric column filters. Maps over the column's actual
## data min..max (optionally log scale for wide positive ranges); drag either knob.
class RangeSlider extends Control:
	signal changed(lo: float, hi: float)
	var data_lo := 0.0
	var data_hi := 1.0
	var lo := 0.0
	var hi := 1.0
	var use_log := false
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

	func _draw() -> void:
		var ty := TRACK_Y
		var font := get_theme_default_font()
		draw_line(Vector2(PAD, ty), Vector2(size.x - PAD, ty), Color(0.4, 0.4, 0.46), 3.0)
		draw_line(Vector2(_v2x(lo), ty), Vector2(_v2x(hi), ty), Color(0.30, 0.62, 1.0), 3.0)
		draw_circle(Vector2(_v2x(lo), ty), KNOB_R, Color(1, 1, 1))
		draw_circle(Vector2(_v2x(hi), ty), KNOB_R, Color(1, 1, 1))
		# current selected values above the knobs
		draw_string(font, Vector2(_v2x(lo) - 12, ty - 9), fmt(lo), HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		draw_string(font, Vector2(_v2x(hi) - 12, ty - 9), fmt(hi), HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		# data-scale ticks below
		for i in 5:
			var t := i / 4.0
			draw_string(font, Vector2(PAD + t * (size.x - 2.0 * PAD) - 12.0, ty + 20.0),
				fmt(_t2v(t)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.6, 0.65))

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

# bulk "suggest missing chops" job (runs suggest_chops.py over files lacking a
# chopping.json entry, in a thread, with a polled progress file)
var _sg_thread: Thread = null
var _sg_busy: bool = false
var _sg_btn: Button
var _sg_poll: Timer
var _sg_progress_path: String = ""

# chop-to-disk job (chop.py writes name_chopped_NNN next to the original; the
# original is kept). Runs in a thread.
var _chop_thread: Thread = null
var _chop_busy: bool = false
var _chop_btn: Button
var _chop_spec_path: String = ""
var _chop_result_path: String = ""

var _norm_target_edit: LineEdit       # the 0-10 Level for the "set on selection" action

# semantic search (its own bar above the text filter; ranks via indexer/search.py)
var _sem_edit: LineEdit               # the semantic query box
var _sem_thread: Thread = null
var _sem_busy: bool = false
var _sem_active: bool = false         # a semantic result set is the current base
var _sem_ranked: Array = []           # records in cosine-rank order (the base set)
var _sem_scores: Dictionary = {}      # rel_path -> cosine score (for the Score column)
var _sem_result_path: String = ""
var _by_path: Dictionary = {}         # rel_path -> record, for fast rank lookup

# embeddings.npz (beside the audio) + the "Update semantic index" job
var _emb_path: String = ""
var _emb_thread: Thread = null
var _emb_busy: bool = false
var _emb_btn: Button
var _emb_poll: Timer
var _emb_progress_path: String = ""

# persisted UI prefs (window geom, column widths, sort, search/filters, toggles)
var _prefs: Dictionary = {}
var _prefs_path: String = ""

# ----- nodes ---------------------------------------------------------------
var _search: LineEdit
var _lib_label: Label                 # library-root path shown top-left
var _vol_slider: HSlider
# per-column filter header (aligned above the columns; type per column)
var _filter_header: Control
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
var _keywords: Array = []   # [ [token, library_count], ... ] sorted desc

# player
var _player: AudioStreamPlayer
var _play_btn: Button
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
	_sem_result_path = ProjectSettings.globalize_path("user://search_result.json")
	_emb_path = data_dir.path_join("embeddings.npz")
	_emb_progress_path = ProjectSettings.globalize_path("user://embed_progress.json")
	_load_userdata()
	_load_chopping()
	_load_loudness()
	_build_ui()
	_load_index()
	_apply_view_prefs()


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
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# --- toolbar row: library folder (top-left) + path ------------------
	var barlib := HBoxContainer.new()
	barlib.add_theme_constant_override("separation", 8)
	root.add_child(barlib)

	var openbtn := Button.new()
	openbtn.text = "Open folder"
	openbtn.tooltip_text = "Open the selected file's folder (or the library root) in your file browser."
	openbtn.pressed.connect(_on_reveal)
	barlib.add_child(openbtn)

	_lib_label = Label.new()
	_lib_label.clip_text = true
	_lib_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lib_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.66))
	barlib.add_child(_lib_label)

	# --- toolbar row: SEMANTIC search box (left) + Update index (right) ---
	# No label — the placeholder describes it; left edge aligns with the Filter box.
	var bar0 := HBoxContainer.new()
	bar0.add_theme_constant_override("separation", 8)
	root.add_child(bar0)

	_sem_edit = LineEdit.new()
	_sem_edit.placeholder_text = "describe a sound — e.g. \"guns shooting\" — and press Enter (meaning, not words)"
	_sem_edit.clear_button_enabled = true
	_sem_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sem_edit.text_submitted.connect(_on_semantic_submitted)
	bar0.add_child(_sem_edit)

	_emb_btn = Button.new()
	_emb_btn.text = "Update semantic index"
	_emb_btn.tooltip_text = "Embed any files that don't have a semantic vector yet " \
		+ "(e.g. new chops). Run once before first use; quick afterwards."
	_emb_btn.pressed.connect(_update_embeddings)
	bar0.add_child(_emb_btn)

	# --- toolbar row: text Filter box (left-aligned with the semantic box) --
	var bar1 := HBoxContainer.new()
	bar1.add_theme_constant_override("separation", 8)
	root.add_child(bar1)

	_search = LineEdit.new()
	_search.placeholder_text = "filter by filename / library / supplier / description / tags  (space = AND)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	bar1.add_child(_search)

	_autoplay = CheckButton.new()                # added to the player bar below
	_autoplay.text = "Autoplay"
	_autoplay.button_pressed = true

	# --- toolbar row 2: clear + count (per-column filters live above the table) --
	var bar2 := HBoxContainer.new()
	bar2.add_theme_constant_override("separation", 8)
	root.add_child(bar2)

	var clear := Button.new()
	clear.text = "Clear filters"
	clear.pressed.connect(_on_clear)
	bar2.add_child(clear)

	var fhint := Label.new()
	fhint.text = "  ↓ each column filters by its own type (text / tick-boxes / min–max)"
	fhint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	bar2.add_child(fhint)

	_count_label = Label.new()
	_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar2.add_child(_count_label)

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

	# --- table + keyword panel (split) ----------------------------------
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	# left pane = per-column filter header ABOVE the tree, so it shares the tree's
	# column widths / horizontal scroll and lines up over the columns.
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_filter_header = Control.new()
	_filter_header.custom_minimum_size = Vector2(0, 28)
	_filter_header.clip_contents = true
	left.add_child(_filter_header)
	left.add_child(_tree)
	split.add_child(left)
	split.add_child(_build_keyword_panel())
	# big offset -> table takes the slack, keyword panel rests at its min width
	split.set_deferred("split_offset", 5000)

	_build_num_popup()

	_build_analyser(root)

	# --- seek strip directly under the visualiser (aligned; seek only) --
	_seekbar = SeekBar.new()
	_seekbar.custom_minimum_size = Vector2(0, 16)
	_seekbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seekbar.tooltip_text = "Drag to move the play position (does not change the chop dB)."
	_seekbar.seek_requested.connect(_on_graph_seek)
	root.add_child(_seekbar)

	# --- player bar -----------------------------------------------------
	var pbar := HBoxContainer.new()
	pbar.add_theme_constant_override("separation", 8)
	root.add_child(pbar)

	_play_btn = Button.new()
	_play_btn.text = "Play"
	_play_btn.custom_minimum_size = Vector2(70, 0)
	_play_btn.pressed.connect(_on_play_pressed)
	pbar.add_child(_play_btn)

	var stop := Button.new()
	stop.text = "Stop"
	stop.pressed.connect(_on_stop_pressed)
	pbar.add_child(stop)

	_autoplay.focus_mode = Control.FOCUS_NONE      # don't eat the Space shortcut
	pbar.add_child(_autoplay)                      # next to Play / Stop / Loop

	_loop_chk = CheckButton.new()
	_loop_chk.text = "Loop"
	_loop_chk.tooltip_text = "Replay this track: loop the current track seamlessly."
	_loop_chk.focus_mode = Control.FOCUS_NONE      # don't eat the Space shortcut
	_loop_chk.toggled.connect(_on_loop_toggled)
	pbar.add_child(_loop_chk)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(110, 0)
	_time_label.text = "0:00 / 0:00"
	pbar.add_child(_time_label)

	var vlab := Label.new()
	vlab.text = "Vol"
	pbar.add_child(vlab)
	_vol_slider = HSlider.new()
	_vol_slider.min_value = 0.0
	_vol_slider.max_value = 1.0
	_vol_slider.step = 0.01
	_vol_slider.value = 0.9
	_vol_slider.custom_minimum_size = Vector2(110, 0)
	_vol_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_vol_slider.value_changed.connect(_on_volume_changed)
	pbar.add_child(_vol_slider)
	_on_volume_changed(0.9)

	# Seeking now lives in the visualiser directly above (left-click/drag to
	# scrub); its play dot and white cursor line up exactly. The hint fills the
	# rest of this transport row.
	var seekhint := Label.new()
	seekhint.text = "  ↑ drag the seek strip to move position (chop dB unchanged)"
	seekhint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	seekhint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pbar.add_child(seekhint)

	# --- level / normalize row ------------------------------------------
	var lbar := HBoxContainer.new()
	lbar.add_theme_constant_override("separation", 6)
	root.add_child(lbar)

	var nlab := Label.new()
	nlab.text = "Set Level"
	lbar.add_child(nlab)
	_norm_target_edit = LineEdit.new()
	_norm_target_edit.text = "7"
	_norm_target_edit.custom_minimum_size = Vector2(48, 0)
	_norm_target_edit.tooltip_text = "Loudness on the 0-10 scale (10 = loudest, 5 = half as loud, 0 = silence)."
	lbar.add_child(_norm_target_edit)
	var dbfs_lab := Label.new()
	dbfs_lab.text = "(0-10)"
	lbar.add_child(dbfs_lab)
	var norm_btn := Button.new()
	norm_btn.text = "on selection"
	norm_btn.tooltip_text = "Set this Level on the selected rows (and recompute " \
		+ "their Gain dB to hit it, capped so nothing clips). Needs measured Loudness."
	norm_btn.pressed.connect(_normalize_selection)
	lbar.add_child(norm_btn)

	var nhint := Label.new()
	nhint.text = "  e.g. explosion 10, gunfire 6, footstep 3"
	nhint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	nhint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbar.add_child(nhint)

	# --- rating + now-playing row ---------------------------------------
	# Rating controls first; the expanding now-playing label goes LAST so it
	# doesn't push the star buttons off-screen.
	var nbar := HBoxContainer.new()
	nbar.add_theme_constant_override("separation", 6)
	root.add_child(nbar)

	var rlab := Label.new()
	rlab.text = "Rate selected:"
	nbar.add_child(rlab)
	for i in range(1, 6):
		var b := Button.new()
		b.custom_minimum_size = Vector2(34, 0)
		b.tooltip_text = "%d star%s" % [i, "" if i == 1 else "s"]
		b.pressed.connect(_on_star_pressed.bind(i))
		nbar.add_child(b)
		_star_btns.append(b)
	var clr := Button.new()
	clr.text = "Clear"
	clr.pressed.connect(_on_star_pressed.bind(0))
	nbar.add_child(clr)
	_refresh_star_buttons(null)

	var rhint := Label.new()
	rhint.text = "  (or click stars in the Rating column; right-click clears)"
	rhint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	nbar.add_child(rhint)

	nbar.add_child(VSeparator.new())
	_now_label = Label.new()
	_now_label.text = "No file loaded."
	_now_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_now_label.clip_text = true
	nbar.add_child(_now_label)

	# --- status ---------------------------------------------------------

	_status_label = Label.new()
	root.add_child(_status_label)

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

	# poll the bulk chop-suggest job's progress file while it runs
	_sg_poll = Timer.new()
	_sg_poll.wait_time = 1.0
	_sg_poll.timeout.connect(_sg_tick)
	add_child(_sg_poll)

	# poll the embeddings job's progress file while it runs
	_emb_poll = Timer.new()
	_emb_poll.wait_time = 1.0
	_emb_poll.timeout.connect(_emb_tick)
	add_child(_emb_poll)

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
		COL_LIBRARY: return String(rec.get("library", ""))
		COL_SUPPLIER: return String(rec.get("supplier", ""))
		COL_BUNDLE: return String(rec.get("bundle", ""))
		COL_TAGS: return _get_tags(rec)
	return ""


const STRING_FILTER_COLS := [COL_FILENAME, COL_LIBRARY, COL_SUPPLIER, COL_BUNDLE, COL_TAGS]


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
		b.text = ("%s–%s" % [RangeSlider.fmt(_filter_min.get(col, 0.0)),
			RangeSlider.fmt(_filter_max.get(col, 0.0))]) if active else "min–max"


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
	for col in COL_COUNT:
		var ctrl: Variant = _colfilters.get(col)
		if ctrl == null:
			continue
		var r := _tree.get_item_area_rect(first, col)   # exact column x + width
		ctrl.position = Vector2(r.position.x, 2.0)
		ctrl.size = Vector2(maxf(8.0, r.size.x - 2.0), h - 4.0)


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


func _build_keyword_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(250, 0)
	panel.add_theme_constant_override("separation", 4)

	_kw_header = Label.new()
	_kw_header.text = "Keywords"
	panel.add_child(_kw_header)

	var hint := Label.new()
	hint.text = "click to add to search"
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	panel.add_child(hint)

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
	return panel


func _build_analyser(root: VBoxContainer) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)

	var an_btn := Button.new()
	an_btn.text = "Analyse selected"
	an_btn.pressed.connect(_analyse_selected)
	bar.add_child(an_btn)

	var sug := Button.new()
	sug.text = "Suggest"
	sug.tooltip_text = "Set the silence threshold from this file's loudness histogram"
	sug.pressed.connect(_apply_suggested)
	bar.add_child(sug)

	_sil_slider = _add_slider(bar, "Silence", -90, 0, 1, DEF_SILENCE_DB)
	_sil_lbl = bar.get_child(bar.get_child_count() - 1) as Label
	_gap_slider = _add_slider(bar, "Min gap", 0.0, 5.0, 0.1, DEF_MIN_GAP_S)
	_gap_lbl = bar.get_child(bar.get_child_count() - 1) as Label
	_snd_slider = _add_slider(bar, "Min sound", 0.0, 2.0, 0.05, DEF_MIN_SOUND_S)
	_snd_lbl = bar.get_child(bar.get_child_count() - 1) as Label

	var playchops := Button.new()
	playchops.text = "Play chops"
	playchops.tooltip_text = "Play each chop piece in turn with 1 s of silence " \
		+ "between them, so the boundaries are audibly obvious."
	playchops.pressed.connect(_play_chops)
	bar.add_child(playchops)

	_chop_btn = Button.new()
	_chop_btn.text = "Chop to files"
	_chop_btn.tooltip_text = "Write each piece as name_chopped_NNN.wav next to the " \
		+ "original (the original is KEPT). Re-run the indexer to see them."
	_chop_btn.pressed.connect(_chop_selected)
	bar.add_child(_chop_btn)

	_sg_btn = Button.new()
	_sg_btn.text = "Analyse audio (chops + loudness)"
	_sg_btn.tooltip_text = "For every file not analysed yet, read its audio ONCE and " \
		+ "compute both the chop suggestion AND the loudness (fills the Chop, orig dB " \
		+ "and final dB columns). Slow on a fresh library; columns fill in as it runs."
	_sg_btn.pressed.connect(_suggest_missing_chops)
	bar.add_child(_sg_btn)

	_an_status = Label.new()
	_an_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_an_status.text = "Analyser idle."
	bar.add_child(_an_status)

	_graph = WaveGraph.new()
	_graph.custom_minimum_size = Vector2(0, 120)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.tooltip_text = "Left-click: seek + set the chop dB level (grey = below it). " \
		+ "Left-drag: scrub. Right-click/drag: set the chop dB only."
	_graph.threshold_picked.connect(_on_graph_threshold_picked)
	_graph.seek_requested.connect(_on_graph_seek)
	root.add_child(_graph)
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
	var path := "res://index.json"
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
	if _lib_label:
		_lib_label.text = _library_root
	_status_label.text = "Library root: %s   |   indexed %s" % [
		_library_root, str(data.get("generated", "?"))
	]
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
	# Append as an AND term to the search box if not already present.
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
	if q == "":                                    # cleared -> drop semantic base
		_sem_active = false
		_sem_ranked = []
		_sem_scores = {}
		if _sort_col == COL_SCORE:                 # leave Score-sort behind
			_sort_col = COL_FILENAME
			_sort_asc = true
		_apply()
		return
	_run_semantic(q)


func _on_clear() -> void:
	_search.text = ""
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
	var code := OS.execute("py", args, output, true)
	if code == -1:
		OS.execute("python", args, output, true)
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
	var paths: Array = d.get("paths", [])
	var scores: Array = d.get("scores", [])
	# Build the ranked BASE set (cosine order) + the score map for the Score column.
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
	_status_label.text = "Semantic results for \"%s\" — most relevant first (%d). Use Filter to narrow." % [
		String(d.get("query", "")), _filtered.size()]


# ----- "Update semantic index": embed files with no vector yet (embed.py) -----
func _update_embeddings() -> void:
	if _emb_busy:
		return
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/embed.py").simplify_path()
	if FileAccess.file_exists(_emb_progress_path):
		DirAccess.remove_absolute(_emb_progress_path)
	_emb_busy = true
	_emb_btn.disabled = true
	_emb_btn.text = "Scanning for new files…"        # progress shows on the button
	_emb_thread = Thread.new()
	_emb_thread.start(_emb_run.bind(script, _emb_progress_path))
	_emb_poll.start()


func _emb_run(script: String, progress: String) -> void:
	var output: Array = []
	var args := [script, "--only-missing", "--progress", progress]
	var code := OS.execute("py", args, output, true)
	if code == -1:
		OS.execute("python", args, output, true)
	call_deferred("_emb_finished")


func _emb_tick() -> void:
	# until the progress file exists with a total we're still scanning -> the button
	# keeps "Scanning for new files…"; then it shows done / new.
	if FileAccess.file_exists(_emb_progress_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_emb_progress_path))
		if typeof(d) == TYPE_DICTIONARY and int(d.get("total", 0)) > 0:
			_emb_btn.text = "Embedding %d / %d new…" % [
				int(d.get("analysed", 0)), int(d.get("total", 0))]


func _emb_finished() -> void:
	_emb_poll.stop()
	if _emb_thread:
		_emb_thread.wait_to_finish()
		_emb_thread = null
	_emb_busy = false
	_emb_btn.disabled = false
	_emb_btn.text = "Update semantic index"          # restore the idle label
	var n := 0
	if FileAccess.file_exists(_emb_progress_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_emb_progress_path))
		if typeof(d) == TYPE_DICTIONARY:
			n = int(d.get("analysed", 0))
	_status_label.text = "Semantic index updated — %d new file%s embedded." % [
		n, "" if n == 1 else "s"]


func _sort_value(rec: Dictionary, col: int) -> Variant:
	# Rating/Plays come from user data; everything else from the record.
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
	for rec in _filtered:
		var it := _tree.create_item(root)
		it.set_text(COL_FILENAME, String(rec.get("filename", "")))
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
		for c in EDITABLE_COLS:                 # tint editable cells a touch lighter
			it.set_custom_bg_color(c, EDIT_CELL_BG)
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
	if col == COL_TAGS or col == COL_CHOP_DB or col == COL_CHOP_GAP or col == COL_CHOP_SND \
			or col == COL_LEVEL or col == COL_GAIN_DB:
		return                                 # let the inline editor handle it
	# Don't autoplay while Shift/Ctrl-extending a selection range.
	var ranging := Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_CTRL)
	if mouse_btn == MOUSE_BUTTON_LEFT and _autoplay.button_pressed and not ranging:
		_play_selected()


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
#  Column resizing — drag a divider in the header row (Tree has no native one)
# ===========================================================================
func _header_height() -> float:
	if _header_h <= 0.0:
		var root := _tree.get_root()
		if root and root.get_first_child():
			_header_h = _tree.get_item_area_rect(root.get_first_child()).position.y
		if _header_h <= 0.0:
			_header_h = 24.0
	return _header_h


# Column whose right divider sits under x (only within the header band), else -1.
func _divider_at(pos: Vector2) -> int:
	if pos.y > _header_height():
		return -1
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
			elif event.unicode >= 32 and ecol >= 0:
				_begin_cell_edit(ecol, String.chr(event.unicode))
				_tree.accept_event()
				return
	# Clicking anywhere commits an in-progress type-over edit (then the click
	# proceeds normally to start a fresh selection).
	if event is InputEventMouseButton and event.pressed and _cell_edit_active:
		_commit_cell_edit()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var c := _divider_at(event.position)
			if c >= 0:
				_resize_col = c
				_resize_start_x = event.position.x
				_resize_start_w = _col_w[c]
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
			if _resize_col >= 0:
				_resize_col = -1
				_tree.accept_event()
			_drag_sel = false
			_drag_additive = false
			_drag_toggle = false
			_drag_anchor = null
			_drag_last = null
			_drag_base = []
			_drag_base_col = {}
	elif event is InputEventMouseMotion:
		if _resize_col >= 0:
			var w := maxi(COL_MIN_W, _resize_start_w + int(event.position.x - _resize_start_x))
			_col_w[_resize_col] = w
			_tree.set_column_custom_minimum_width(_resize_col, w)
			_suppress_title_click = true       # this drag isn't a sort click
			_tree.accept_event()
		elif _drag_sel and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
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
	if ext != "wav":
		_now_label.text = "Preview supports WAV only (this is .%s):  %s" % [ext, abs]
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
		_now_label.text = "Could not load WAV (unsupported format — e.g. float, or too large): %s" % abs
		return
	_set_stream_loop(stream)                   # honour the Loop toggle
	_player.stream = stream
	_play_gain_db = _get_gain_db(rec)          # per-track gain on top of the slider
	_apply_volume()
	_player.play()
	_stream_len = stream.get_length()
	_playing_rec = rec
	_playing_item = _tree.get_selected()
	_play_btn.text = "Pause"
	_now_label.text = "Playing:  %s" % String(rec.get("filename", ""))


func _on_play_pressed() -> void:
	if _player.stream == null:
		_play_selected()
		return
	if _player.playing:
		_player.stream_paused = true
		_play_btn.text = "Play"
	elif _player.stream_paused:
		_player.stream_paused = false
		_play_btn.text = "Pause"
	else:
		_player.play()
		_play_btn.text = "Pause"


func _on_stop_pressed() -> void:
	_player.stop()
	_play_btn.text = "Play"
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
	_play_btn.text = "Pause"


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
		stream.loop_end = int(round(stream.get_length() * stream.mix_rate))
	else:
		stream.loop_mode = AudioStreamWAV.LOOP_DISABLED


func _on_loop_toggled(on: bool) -> void:
	_loop_on = on
	if _player.stream is AudioStreamWAV:
		_set_stream_loop(_player.stream)       # apply to the current track live


func _on_reveal() -> void:
	# the selected file's folder, or the library root if nothing is selected
	var rec: Variant = _selected_rec()
	var folder := _library_root
	if typeof(rec) == TYPE_DICTIONARY:
		folder = _library_root.path_join(String(rec.get("path", "")).get_base_dir())
	OS.shell_open(folder)


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
	_layout_filter_header()                        # keep filters aligned over columns
	# playback cursor + play dot on the visualiser, when the loaded file is the one
	# shown in the analyser (playing OR paused).
	if _graph and not _an_levels.is_empty():
		var ph := -1.0
		if _player.stream != null and _playing_rec != null and _playing_rec == _an_rec and _stream_len > 0.0:
			ph = clampf(_player.get_playback_position() / _stream_len, 0.0, 1.0)
		if ph != _graph.playhead:
			_graph.playhead = ph
			_graph.queue_redraw()
			if _seekbar:
				_seekbar.pos = ph
				_seekbar.queue_redraw()
	if _player.stream == null or _stream_len <= 0.0:
		return
	if _player.playing:
		var pos := _player.get_playback_position()
		_time_label.text = "%s / %s" % [_fmt_time(pos), _fmt_time(_stream_len)]
	if not _player.playing and not _player.stream_paused and _play_btn.text == "Pause":
		_play_btn.text = "Play"  # finished


func _on_playback_finished() -> void:
	# Fired only when the stream plays through to the end (not on Stop) -- i.e.
	# the user finished listening. Count it.
	_play_btn.text = "Play"
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


# ----- bulk "suggest missing chops" (suggest_chops.py in a thread) ---------
# One combined pass (chops + loudness) over files missing EITHER, reading each
# file's audio once. Runs analyse_audio.py in a thread with live progress.
func _suggest_missing_chops() -> void:
	if _sg_busy:
		return
	var missing := 0
	for rec in _all:
		if String(rec.get("ext", "")).to_lower() != "wav":
			continue
		var p := String(rec.get("path", ""))
		if not _chopping.has(p) or not _loudness.has(p):
			missing += 1
	if missing == 0:
		_an_status.text = "Every file is already analysed (chops + loudness)."
		return
	var script := ProjectSettings.globalize_path("res://").path_join(
		"../indexer/analyse_audio.py").simplify_path()
	if FileAccess.file_exists(_sg_progress_path):
		DirAccess.remove_absolute(_sg_progress_path)
	_sg_busy = true
	_sg_btn.disabled = true
	_an_status.text = "Analysing %d file%s (chops + loudness)… (reads their audio once)" % [
		missing, "" if missing == 1 else "s"]
	_sg_thread = Thread.new()
	_sg_thread.start(_sg_run.bind(script, _sg_progress_path))
	_sg_poll.start()


func _sg_run(script: String, progress: String) -> void:
	var output: Array = []
	var args := [script, "--only-missing", "--progress", progress]
	var code := OS.execute("py", args, output, true)
	if code == -1:                       # py launcher not found; try python
		OS.execute("python", args, output, true)
	call_deferred("_sg_finished")


# Polled while the job runs: refresh chop + loudness cells from disk, update status.
func _sg_tick() -> void:
	_reload_chop_cells()
	_reload_loudness_cells()
	if FileAccess.file_exists(_sg_progress_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_sg_progress_path))
		if typeof(d) == TYPE_DICTIONARY:
			_an_status.text = "Analysing audio… %d / %d" % [
				int(d.get("analysed", 0)), int(d.get("total", 0))]


func _sg_finished() -> void:
	_sg_poll.stop()
	if _sg_thread:
		_sg_thread.wait_to_finish()
		_sg_thread = null
	_sg_busy = false
	_sg_btn.disabled = false
	_reload_chop_cells()
	_reload_loudness_cells()
	var applied := _recompute_targets()        # newly-measured rows with a Level -> Gain dB
	var analysed := 0
	if FileAccess.file_exists(_sg_progress_path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_sg_progress_path))
		if typeof(d) == TYPE_DICTIONARY:
			analysed = int(d.get("analysed", 0))
	var extra := "  (%d level'd rows updated)" % applied if applied > 0 else ""
	_an_status.text = "Audio analysis complete: %d file%s (chops + loudness).%s" % [
		analysed, "" if analysed == 1 else "s", extra]


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


# Set the Level (0-10) on the selected rows (and recompute their Gain dB to hit
# that loudness, capped so nothing clips).
func _normalize_selection() -> void:
	var ttxt := _norm_target_edit.text.strip_edges()
	if not ttxt.is_valid_float():
		_status_label.text = "Level must be a number 0-10 (e.g. 7)."
		return
	var lvl := clampf(ttxt.to_float(), 0.0, LEVEL_MAX)
	var items := []
	var it := _tree.get_next_selected(null)
	while it != null:
		if typeof(it.get_metadata(0)) == TYPE_DICTIONARY:
			items.append(it)
		it = _tree.get_next_selected(it)
	if items.is_empty():
		_status_label.text = "Select some rows first, then set the Level."
		return
	var n := 0
	var unmeasured := 0
	var capped := 0
	for row in items:
		var rec: Dictionary = row.get_metadata(0)
		var key := String(rec.get("path", ""))
		var ud: Dictionary = _userdata.get(key, {})
		ud["level"] = lvl                         # persistent level (saved once below)
		ud.erase("target_db")
		_userdata[key] = ud
		row.set_text(COL_LEVEL, _fmt_level(lvl))
		var r := _apply_target_to_gain(rec, row)
		if r == -1:
			unmeasured += 1
		elif r == 1:
			n += 1
			if _target_gain(rec)[1]:
				capped += 1
	_save_userdata()
	var msg := "Level %s set on %d row%s." % [_fmt_level(lvl), items.size(), "" if items.size() == 1 else "s"]
	if capped > 0:
		msg += "  %d capped to avoid clipping." % capped
	if unmeasured > 0:
		msg += "  %d not measured yet (run Analyse audio, then it applies)." % unmeasured
	_status_label.text = msg


# ----- play chops: each piece + 1 s of silence, as a single preview stream ---
func _play_chops() -> void:
	if typeof(_an_rec) != TYPE_DICTIONARY or _graph.segments.is_empty():
		_an_status.text = "Analyse a file first — no chops to play."
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
	_stream_len = preview.get_length()
	_playing_rec = null          # preview timeline != original; skip cursor + play-count
	_playing_item = null
	_play_btn.text = "Pause"
	_now_label.text = "Playing %d chops (1 s gaps):  %s" % [
		_graph.segments.size(), String(_an_rec.get("filename", ""))]


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
	var silence := PackedByteArray()
	silence.resize(int(sr) * frame_bytes)        # 1 s of zeros (= silence, signed PCM)
	var out := PackedByteArray()
	for s in _graph.segments:
		var a := clampi(int(round(float(s[0]) * _an_frame_s * sr)), 0, total)
		var b := clampi(int(round(float(s[1]) * _an_frame_s * sr)), 0, total)
		if b <= a:
			continue
		out.append_array(data.slice(a * frame_bytes, b * frame_bytes))
		out.append_array(silence)
	if out.is_empty():
		return null
	var sw := AudioStreamWAV.new()
	sw.format = stream.format
	sw.mix_rate = sr
	sw.stereo = stream.stereo
	sw.data = out
	return sw


# ----- chop to files: chop.py writes name_chopped_NNN.wav beside the original --
func _chop_selected() -> void:
	if _chop_busy:
		return
	if typeof(_an_rec) != TYPE_DICTIONARY or _graph.segments.is_empty():
		_an_status.text = "Analyse a file first — nothing to chop."
		return
	if _graph.segments.size() <= 1:
		_an_status.text = "Only 1 piece at these settings — nothing to chop."
		return
	var abs := _abs_path(_an_rec)
	if String(_an_rec.get("ext", "")).to_lower() != "wav" or not FileAccess.file_exists(abs):
		_an_status.text = "Chop supports existing WAV files only."
		return
	# WYSIWYG: chop exactly the pieces drawn (current segments), in seconds.
	var segs_s: Array = []
	for s in _graph.segments:
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
	_an_status.text = "Chopping %s into %d pieces…" % [
		String(_an_rec.get("filename", "")), segs_s.size()]
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
	if _sg_thread and _sg_thread.is_started():
		_sg_thread.wait_to_finish()
	if _chop_thread and _chop_thread.is_started():
		_chop_thread.wait_to_finish()
	if _sem_thread and _sem_thread.is_started():
		_sem_thread.wait_to_finish()
	if _emb_thread and _emb_thread.is_started():
		_emb_thread.wait_to_finish()


func _an_finished() -> void:
	_an_busy = false
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
	_apply_saved_or_suggested()        # also recomputes + redraws


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
