extends Control
## Sound Library browser.
## Loads res://index.json (produced by indexer/index.py), shows an Excel-like
## sortable/filterable table, and auditions the original WAV files on demand.

# ----- column layout -------------------------------------------------------
const COL_FILENAME := 0
const COL_LIBRARY := 1
const COL_SUPPLIER := 2
const COL_BUNDLE := 3
const COL_DURATION := 4
const COL_RATE := 5
const COL_BIT := 6
const COL_CH := 7
const COL_SIZE := 8
const COL_RATING := 9   # user data (app/userdata.json)
const COL_PLAYS := 10   # user data (auto-incremented on finished playback)
const COL_SOUNDS := 11  # analysis: detected sound count (app/analysis.json)
const COL_TAGS := 12    # user data (your own keywords; editable inline)
const COL_COUNT := 13

const COL_TITLES := [
	"Filename", "Library", "Supplier", "Bundle",
	"Duration", "Rate", "Bit", "Ch", "Size", "Rating", "Plays", "Sounds", "My Keywords",
]
# Which record field each column sorts/reads. Bundle, Rating, Plays, Sounds and
# Tags are special-cased in _sort_value (they don't live in the record).
const COL_FIELD := [
	"filename", "library", "supplier", "bundle",
	"duration", "sample_rate", "bit_depth", "channels", "size", "", "", "", "",
]
const NUMERIC_COLS := [COL_DURATION, COL_RATE, COL_BIT, COL_CH, COL_SIZE,
	COL_RATING, COL_PLAYS, COL_SOUNDS]

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
const COL_DEFAULT_W := [460, 180, 140, 85, 65, 72, 42, 38, 78, 95, 58, 60, 200]
const COL_MIN_W := 28       # smallest a column can be dragged to
const RESIZE_GRAB := 6      # px tolerance around a divider to start a resize

# Gap analysis defaults (chosen from exploration; tunable live in the analyser).
const DEF_SILENCE_DB := -60.0
const DEF_MIN_GAP_S := 1.5
const DEF_MIN_SOUND_S := 0.3


## Draws the loudness (dBFS) envelope vs time, the silence threshold, the
## detected "dead zones" (gaps) and a playback cursor.
class WaveGraph extends Control:
	var levels := PackedFloat32Array()
	var segments: Array = []          # [[start_frame, end_frame], ...]
	var threshold_db: float = DEF_SILENCE_DB
	var playhead: float = -1.0        # 0..1; < 0 hides
	const TOP_DB := 0.0
	const BOT_DB := -90.0

	func _yfor(db: float) -> float:
		return clampf((TOP_DB - db) / (TOP_DB - BOT_DB), 0.0, 1.0) * size.y

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.10, 0.13))
		var n := levels.size()
		if n == 0:
			draw_string(get_theme_default_font(), Vector2(10, h * 0.5 + 5),
				"Select a WAV and press Analyse to preview its sounds / gaps",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.5, 0.5, 0.55))
			return
		# dead zones = gaps between detected segments (what gets cut)
		var gap_col := Color(0.85, 0.25, 0.25, 0.20)
		var prev_end := 0
		for s in segments:
			var ge: int = int(s[0])
			if ge > prev_end:
				var gx := float(prev_end) / n * w
				draw_rect(Rect2(gx, 0, float(ge) / n * w - gx, h), gap_col)
			prev_end = int(s[1])
		if n > prev_end:
			var gx := float(prev_end) / n * w
			draw_rect(Rect2(gx, 0, w - gx, h), gap_col)
		# loudness envelope (one bar per pixel column)
		var col := Color(0.40, 0.85, 0.78)
		for x in int(w):
			var fi := mini(int(float(x) / w * n), n - 1)
			draw_line(Vector2(x, h), Vector2(x, _yfor(levels[fi])), col, 1.0)
		# silence threshold
		var ty := _yfor(threshold_db)
		draw_line(Vector2(0, ty), Vector2(w, ty), Color(1.0, 0.6, 0.1), 1.5)
		# chop boundaries (start of each detected sound)
		for s in segments:
			var xs := float(s[0]) / n * w
			draw_line(Vector2(xs, 0), Vector2(xs, h), Color(0.35, 1.0, 0.55, 0.7), 1.0)
		# playback cursor
		if playhead >= 0.0:
			draw_line(Vector2(playhead * w, 0), Vector2(playhead * w, h),
				Color(1, 1, 1, 0.85), 1.0)

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

# analysis (gap detection) -- { rel_path : {"sounds": int} }, persisted apart.
var _analysis: Dictionary = {}
var _an_path: String = ""

# analyser panel / live preview state
var _graph: WaveGraph
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

# ----- nodes ---------------------------------------------------------------
var _search: LineEdit
var _bundle_opt: OptionButton
var _supplier_opt: OptionButton
var _library_opt: OptionButton
var _ext_opt: OptionButton
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
var _seek: HSlider
var _seeking: bool = false
var _time_label: Label
var _now_label: Label
var _stream_len: float = 0.0
var _playing_rec: Variant = null     # record currently loaded in the player
var _playing_item: TreeItem = null   # its row, for live cell updates
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

var _debounce: Timer


func _ready() -> void:
	_player = $Player
	_player.finished.connect(_on_playback_finished)
	_ud_path = ProjectSettings.globalize_path("res://userdata.json")
	_an_path = ProjectSettings.globalize_path("res://analysis.json")
	_an_out_path = ProjectSettings.globalize_path("user://envelope.json")
	_load_userdata()
	_load_analysis()
	_build_ui()
	_load_index()


# ===========================================================================
#  UI construction
# ===========================================================================
func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# --- toolbar row 1: search + autoplay -------------------------------
	var bar1 := HBoxContainer.new()
	bar1.add_theme_constant_override("separation", 8)
	root.add_child(bar1)

	var sl := Label.new()
	sl.text = "Search"
	bar1.add_child(sl)

	_search = LineEdit.new()
	_search.placeholder_text = "filename / library / supplier / description  (space = AND)"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	bar1.add_child(_search)

	_autoplay = CheckButton.new()
	_autoplay.text = "Autoplay on select"
	_autoplay.button_pressed = true
	bar1.add_child(_autoplay)

	# --- toolbar row 2: filters -----------------------------------------
	var bar2 := HBoxContainer.new()
	bar2.add_theme_constant_override("separation", 8)
	root.add_child(bar2)

	_bundle_opt = _add_filter(bar2, "Bundle")
	_supplier_opt = _add_filter(bar2, "Supplier")
	_library_opt = _add_filter(bar2, "Library")
	_ext_opt = _add_filter(bar2, "Type")

	var clear := Button.new()
	clear.text = "Clear filters"
	clear.pressed.connect(_on_clear)
	bar2.add_child(clear)

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
	_tree.select_mode = Tree.SELECT_ROW
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
	_tree.item_activated.connect(_on_row_activated)
	_tree.item_mouse_selected.connect(_on_tree_mouse_selected)
	_tree.item_edited.connect(_on_tree_item_edited)
	_tree.gui_input.connect(_on_tree_gui_input)

	# --- table + keyword panel (split) ----------------------------------
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	split.add_child(_tree)
	split.add_child(_build_keyword_panel())
	# big offset -> table takes the slack, keyword panel rests at its min width
	split.set_deferred("split_offset", 5000)

	_build_analyser(root)

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

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(110, 0)
	_time_label.text = "0:00 / 0:00"
	pbar.add_child(_time_label)

	var vlab := Label.new()
	vlab.text = "Vol"
	pbar.add_child(vlab)
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.01
	vol.value = 0.9
	vol.custom_minimum_size = Vector2(110, 0)
	vol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vol.value_changed.connect(_on_volume_changed)
	pbar.add_child(vol)
	_on_volume_changed(0.9)

	var reveal := Button.new()
	reveal.text = "Open folder"
	reveal.pressed.connect(_on_reveal)
	pbar.add_child(reveal)

	# Seek slider LAST: an EXPAND_FILL child shoves trailing siblings off the
	# right edge (same quirk as Tree expand columns), so nothing must follow it.
	_seek = HSlider.new()
	_seek.min_value = 0.0
	_seek.max_value = 1.0
	_seek.step = 0.001
	_seek.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seek.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_seek.drag_started.connect(func(): _seeking = true)
	_seek.drag_ended.connect(_on_seek_released)
	pbar.add_child(_seek)

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


func _add_filter(parent: HBoxContainer, label: String) -> OptionButton:
	var l := Label.new()
	l.text = label
	parent.add_child(l)
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(150, 0)
	o.item_selected.connect(func(_i): _apply())
	parent.add_child(o)
	return o


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

	_sil_slider = _add_slider(bar, "Silence", -90, -30, 1, DEF_SILENCE_DB)
	_sil_lbl = bar.get_child(bar.get_child_count() - 1) as Label
	_gap_slider = _add_slider(bar, "Min gap", 0.2, 5.0, 0.1, DEF_MIN_GAP_S)
	_gap_lbl = bar.get_child(bar.get_child_count() - 1) as Label
	_snd_slider = _add_slider(bar, "Min sound", 0.0, 2.0, 0.05, DEF_MIN_SOUND_S)
	_snd_lbl = bar.get_child(bar.get_child_count() - 1) as Label

	var save := Button.new()
	save.text = "Save count"
	save.tooltip_text = "Store this sound count in the Sounds column"
	save.pressed.connect(_save_current_count)
	bar.add_child(save)

	_an_status = Label.new()
	_an_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_an_status.text = "Analyser idle."
	bar.add_child(_an_status)

	_graph = WaveGraph.new()
	_graph.custom_minimum_size = Vector2(0, 120)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	s.value_changed.connect(func(_v): _on_param_changed())
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
	_library_root = String(data.get("library_root", "")).replace("\\", "/")
	_status_label.text = "Library root: %s   |   indexed %s" % [
		_library_root, str(data.get("generated", "?"))
	]
	_populate_filters()
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


func _populate_filters() -> void:
	_fill_option(_bundle_opt, "bundle", true)
	_fill_option(_supplier_opt, "supplier", false)
	_fill_option(_library_opt, "library", false)
	_fill_option(_ext_opt, "ext", false)


func _fill_option(opt: OptionButton, field: String, short: bool) -> void:
	var seen := {}
	for rec in _all:
		var v := String(rec.get(field, ""))
		if v != "":
			seen[v] = true
	var values := seen.keys()
	values.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	opt.clear()
	opt.add_item("All %s" % field.capitalize())
	opt.set_item_metadata(0, "")
	for v in values:
		var disp: String = _short_bundle(v) if short else String(v)
		opt.add_item(disp)
		opt.set_item_metadata(opt.item_count - 1, v)


# ===========================================================================
#  Filtering / sorting
# ===========================================================================
func _on_search_changed(_t: String) -> void:
	_debounce.start()


func _on_clear() -> void:
	_search.text = ""
	for o in [_bundle_opt, _supplier_opt, _library_opt, _ext_opt]:
		o.select(0)
	_apply()


func _selected_meta(opt: OptionButton) -> String:
	var i := opt.get_selected()
	return String(opt.get_item_metadata(i)) if i >= 0 else ""


func _apply() -> void:
	var tokens := _search.text.strip_edges().to_lower().split(" ", false)
	var f_bundle := _selected_meta(_bundle_opt)
	var f_supplier := _selected_meta(_supplier_opt)
	var f_library := _selected_meta(_library_opt)
	var f_ext := _selected_meta(_ext_opt)

	_filtered = []
	for rec in _all:
		if f_bundle != "" and String(rec.get("bundle", "")) != f_bundle:
			continue
		if f_supplier != "" and String(rec.get("supplier", "")) != f_supplier:
			continue
		if f_library != "" and String(rec.get("library", "")) != f_library:
			continue
		if f_ext != "" and String(rec.get("ext", "")) != f_ext:
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

	_sort_filtered()
	_populate_tree()


func _sort_value(rec: Dictionary, col: int) -> Variant:
	# Rating/Plays come from user data; everything else from the record.
	if col == COL_RATING:
		return _get_rating(rec)
	if col == COL_PLAYS:
		return _get_plays(rec)
	if col == COL_SOUNDS:
		return _get_sounds(rec)
	if col == COL_TAGS:
		return _get_tags(rec)
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
		_apply_userdata_cells(it, rec)
		for c in [COL_DURATION, COL_RATE, COL_BIT, COL_CH, COL_SIZE, COL_PLAYS, COL_SOUNDS]:
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
		it.set_metadata(0, rec)
	_count_label.text = "%d / %d files" % [_filtered.size(), _all.size()]


func _apply_userdata_cells(it: TreeItem, rec: Dictionary) -> void:
	var rating := _get_rating(rec)
	it.set_text(COL_RATING, _stars(rating))
	var plays := _get_plays(rec)
	it.set_text(COL_PLAYS, "" if plays == 0 else str(plays))
	var sc := _get_sounds(rec)
	it.set_text(COL_SOUNDS, "" if sc <= 0 else str(sc))
	it.set_text(COL_TAGS, _get_tags(rec))
	it.set_editable(COL_TAGS, true)            # double-click to edit
	it.set_tooltip_text(COL_TAGS, "Double-click to edit. Separate keywords with spaces or commas.")


# ===========================================================================
#  Playback
# ===========================================================================
func _abs_path(rec: Dictionary) -> String:
	return _library_root.path_join(String(rec.get("path", "")))


func _on_row_selected() -> void:
	# Selection change only updates the rating buttons. Playback is decided in
	# _on_tree_mouse_selected so that clicking the Rating/Tags cells doesn't play.
	_refresh_star_buttons(_selected_rec())


func _on_row_activated() -> void:
	# Double-click plays -- except on the Rating/Tags cells, which are for
	# setting a rating / editing keywords (double-click there opens the editor).
	if _last_click_col == COL_RATING or _last_click_col == COL_TAGS:
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
	if col == COL_TAGS:
		return                                 # let the inline editor handle it
	if mouse_btn == MOUSE_BUTTON_LEFT and _autoplay.button_pressed:
		_play_selected()


func _on_tree_item_edited() -> void:
	var it := _tree.get_edited()
	if it == null or _tree.get_edited_column() != COL_TAGS:
		return
	var rec: Variant = it.get_metadata(0)
	_set_tags(rec, it.get_text(COL_TAGS))


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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var c := _divider_at(event.position)
			if c >= 0:
				_resize_col = c
				_resize_start_x = event.position.x
				_resize_start_w = _col_w[c]
				_tree.accept_event()
		elif _resize_col >= 0:
			_resize_col = -1
			_tree.accept_event()
	elif event is InputEventMouseMotion:
		if _resize_col >= 0:
			var w := maxi(COL_MIN_W, _resize_start_w + int(event.position.x - _resize_start_x))
			_col_w[_resize_col] = w
			_tree.set_column_custom_minimum_width(_resize_col, w)
			_suppress_title_click = true       # this drag isn't a sort click
			_tree.accept_event()
		else:
			# show the horizontal-resize cursor when hovering a divider
			_tree.mouse_default_cursor_shape = (
				Control.CURSOR_HSIZE if _divider_at(event.position) >= 0
				else Control.CURSOR_ARROW)


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
	var stream: AudioStreamWAV = AudioStreamWAV.load_from_file(abs)
	if stream == null:
		_now_label.text = "Could not load WAV: %s" % abs
		return
	_player.stream = stream
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
	_seek.value = 0.0
	_time_label.text = "0:00 / 0:00"


func _on_volume_changed(v: float) -> void:
	_player.volume_db = -80.0 if v <= 0.001 else linear_to_db(v)


func _on_seek_released(_changed: bool) -> void:
	if _player.stream != null and _stream_len > 0.0:
		_player.seek(_seek.value * _stream_len)
		if not _player.playing and not _player.stream_paused:
			_player.play()
			_play_btn.text = "Pause"
	_seeking = false


func _on_reveal() -> void:
	var rec: Variant = _selected_rec()
	if rec == null:
		return
	var folder := _library_root.path_join(String(rec.get("path", "")).get_base_dir())
	OS.shell_open(folder)


func _process(_delta: float) -> void:
	_update_rating_hover()
	# playback cursor on the analyser graph (only when the playing file is the
	# one shown in the analyser)
	if _graph and not _an_levels.is_empty():
		var ph := -1.0
		if _player.playing and _playing_rec != null and _playing_rec == _an_rec and _stream_len > 0.0:
			ph = clampf(_player.get_playback_position() / _stream_len, 0.0, 1.0)
		if ph != _graph.playhead:
			_graph.playhead = ph
			_graph.queue_redraw()
	if _player.stream == null or _stream_len <= 0.0:
		return
	if _player.playing and not _seeking:
		var pos := _player.get_playback_position()
		_seek.value = clampf(pos / _stream_len, 0.0, 1.0)
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
func _load_userdata() -> void:
	if not FileAccess.file_exists(_ud_path):
		return
	var f := FileAccess.open(_ud_path, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_DICTIONARY:
		_userdata = data


func _save_userdata() -> void:
	var f := FileAccess.open(_ud_path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write user data: %s" % _ud_path)
		return
	f.store_string(JSON.stringify(_userdata))


func _get_rating(rec: Dictionary) -> int:
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	return int(ud.get("rating", 0)) if typeof(ud) == TYPE_DICTIONARY else 0


func _get_plays(rec: Dictionary) -> int:
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	return int(ud.get("plays", 0)) if typeof(ud) == TYPE_DICTIONARY else 0


func _get_tags(rec: Dictionary) -> String:
	var ud: Variant = _userdata.get(String(rec.get("path", "")))
	return String(ud.get("tags", "")) if typeof(ud) == TYPE_DICTIONARY else ""


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
#  Gap analysis / sound-count visualiser
# ===========================================================================
func _load_analysis() -> void:
	if not FileAccess.file_exists(_an_path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_an_path))
	if typeof(data) == TYPE_DICTIONARY:
		_analysis = data


func _save_analysis() -> void:
	var f := FileAccess.open(_an_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_analysis))


func _get_sounds(rec: Dictionary) -> int:
	var a: Variant = _analysis.get(String(rec.get("path", "")))
	return int(a.get("sounds", 0)) if typeof(a) == TYPE_DICTIONARY else 0


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
	if _an_thread and _an_thread.is_started():
		_an_thread.wait_to_finish()


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
	_apply_suggested()        # also recomputes + redraws


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
	_an_status.text = "%s  →  %d sound%s  (%d gaps)" % [
		name, segs.size(), "" if segs.size() == 1 else "s", maxi(0, segs.size() - 1)]


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


func _save_current_count() -> void:
	if typeof(_an_rec) != TYPE_DICTIONARY or _an_levels.is_empty():
		_an_status.text = "Nothing analysed to save."
		return
	var segs := _gd_find_segments(_an_levels, _sil_slider.value,
		_gap_slider.value, _snd_slider.value, _an_frame_s)
	var key := String(_an_rec.get("path", ""))
	_analysis[key] = {
		"sounds": segs.size(),
		"silence_db": _sil_slider.value,
		"min_gap_s": _gap_slider.value,
		"min_sound_s": _snd_slider.value,
	}
	_save_analysis()
	# refresh the row's Sounds cell
	var it := _tree.get_selected()
	if it and it.get_metadata(0) == _an_rec:
		it.set_text(COL_SOUNDS, str(segs.size()))
	_an_status.text = "Saved: %s → %d sounds" % [
		String(_an_rec.get("filename", "")), segs.size()]


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
