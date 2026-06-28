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
const COL_COUNT := 9

const COL_TITLES := [
	"Filename", "Library", "Supplier", "Bundle",
	"Duration", "Rate", "Bit", "Ch", "Size",
]
# Which record field each column sorts/reads (Bundle handled specially).
const COL_FIELD := [
	"filename", "library", "supplier", "bundle",
	"duration", "sample_rate", "bit_depth", "channels", "size",
]
const NUMERIC_COLS := [COL_DURATION, COL_RATE, COL_BIT, COL_CH, COL_SIZE]

# ----- data ----------------------------------------------------------------
var _all: Array = []          # all records (Dictionaries)
var _filtered: Array = []     # current view
var _library_root: String = ""
var _sort_col: int = COL_FILENAME
var _sort_asc: bool = true

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

# player
var _player: AudioStreamPlayer
var _play_btn: Button
var _seek: HSlider
var _seeking: bool = false
var _time_label: Label
var _now_label: Label
var _stream_len: float = 0.0

var _debounce: Timer


func _ready() -> void:
	_player = $Player
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
	for c in COL_COUNT:
		_tree.set_column_title(c, COL_TITLES[c])
		_tree.set_column_clip_content(c, true)
	# Column sizing: filename/library/supplier flexible, numbers fixed-ish.
	_set_col_size(COL_FILENAME, 0.0, 600)
	_set_col_size(COL_LIBRARY, 0.0, 200)
	_set_col_size(COL_SUPPLIER, 0.0, 160)
	_set_col_size(COL_BUNDLE, 0.0, 90)
	_set_col_size(COL_DURATION, 0.0, 70)
	_set_col_size(COL_RATE, 0.0, 75)
	_set_col_size(COL_BIT, 0.0, 45)
	_set_col_size(COL_CH, 0.0, 40)
	_set_col_size(COL_SIZE, 0.0, 80)
	_tree.column_title_clicked.connect(_on_title_clicked)
	_tree.item_selected.connect(_on_row_selected)
	_tree.item_activated.connect(_on_row_activated)
	root.add_child(_tree)

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

	_seek = HSlider.new()
	_seek.min_value = 0.0
	_seek.max_value = 1.0
	_seek.step = 0.001
	_seek.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seek.drag_started.connect(func(): _seeking = true)
	_seek.drag_ended.connect(_on_seek_released)
	pbar.add_child(_seek)

	var vlab := Label.new()
	vlab.text = "Vol"
	pbar.add_child(vlab)
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.01
	vol.value = 0.9
	vol.custom_minimum_size = Vector2(110, 0)
	vol.value_changed.connect(_on_volume_changed)
	pbar.add_child(vol)
	_on_volume_changed(0.9)

	var reveal := Button.new()
	reveal.text = "Open folder"
	reveal.pressed.connect(_on_reveal)
	pbar.add_child(reveal)

	# --- status ---------------------------------------------------------
	_now_label = Label.new()
	_now_label.text = "No file loaded."
	root.add_child(_now_label)

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


func _set_col_size(col: int, expand_ratio: float, min_w: int) -> void:
	if expand_ratio > 0.0:
		_tree.set_column_expand(col, true)
		_tree.set_column_expand_ratio(col, int(expand_ratio * 10))
	else:
		_tree.set_column_expand(col, false)
	_tree.set_column_custom_minimum_width(col, min_w)


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
				+ String(rec.get("description", ""))
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


func _sort_filtered() -> void:
	var field: String = COL_FIELD[_sort_col]
	var numeric := _sort_col in NUMERIC_COLS
	var asc := _sort_asc
	_filtered.sort_custom(func(a, b):
		var va: Variant = a.get(field)
		var vb: Variant = b.get(field)
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
		for c in [COL_DURATION, COL_RATE, COL_BIT, COL_CH, COL_SIZE]:
			it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
		it.set_metadata(0, rec)
	_count_label.text = "%d / %d files" % [_filtered.size(), _all.size()]


# ===========================================================================
#  Playback
# ===========================================================================
func _abs_path(rec: Dictionary) -> String:
	return _library_root.path_join(String(rec.get("path", "")))


func _on_row_selected() -> void:
	if _autoplay.button_pressed:
		_play_selected()


func _on_row_activated() -> void:
	_play_selected()


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
	if _player.stream == null or _stream_len <= 0.0:
		return
	if _player.playing and not _seeking:
		var pos := _player.get_playback_position()
		_seek.value = clampf(pos / _stream_len, 0.0, 1.0)
		_time_label.text = "%s / %s" % [_fmt_time(pos), _fmt_time(_stream_len)]
	if not _player.playing and not _player.stream_paused and _play_btn.text == "Pause":
		_play_btn.text = "Play"  # finished


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
