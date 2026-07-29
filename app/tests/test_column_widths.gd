extends SceneTree
# Golden test for COLUMN RESIZING: every column must end up EXACTLY the width
# asked for, whatever its title and whether or not it carries the sort arrow.
#
#   Godot..._console.exe --headless --path app --script tests/test_column_widths.gd
#
# Why this can go wrong: a Tree floors a column's drawn width at the width of its
# TITLE text (+8px panel padding) no matter what set_column_custom_minimum_width
# says — "Ch" floors at 29px, "Chop pieces" at 101px — so without the eliding in
# _apply_col a drag stops at a different width per column and the stored _col_w
# silently drifts away from what is on screen. (Exits non-zero on failure.)

var fails := 0

func ck(name: String, cond: bool, extra: String = "") -> void:
	if not cond:
		fails += 1
	print(("PASS  " if cond else "FAIL  "), name, "  ", extra)

func _initialize() -> void:
	var Main = load("res://main.gd")
	# NOT added to the scene tree, so _ready (which builds the whole app) never
	# runs; _apply_col only touches _tree / _col_w / _sort_col / _sort_asc.
	var m = Main.new()
	var t := Tree.new()
	t.columns = Main.COL_COUNT
	t.column_titles_visible = true
	t.hide_root = true
	for c in Main.COL_COUNT:
		t.set_column_title(c, Main.COL_TITLES[c])
		t.set_column_clip_content(c, true)
		t.set_column_expand(c, false)
	root.add_child(t)
	t.size = Vector2(4000, 400)
	m._tree = t
	m._col_w = Main.COL_DEFAULT_W.duplicate()

	# 1) exact widths, for every column, sorted and unsorted
	var bad := ""
	for sorted_col in [-1, 0, Main.COL_COUNT - 1]:
		for asc in [true, false]:
			m._sort_col = sorted_col
			m._sort_asc = asc
			for w in [Main.COL_MIN_W, 40, 60, 120, 460]:
				for c in Main.COL_COUNT:
					m._col_w[c] = w
					m._apply_col(c)
					var got := t.get_column_width(c)
					if got != w or int(m._col_w[c]) != w:
						bad += " col%d(%s) want %d got %d;" % [c, Main.COL_TITLES[c], w, got]
	ck("every column reaches the exact requested width", bad == "", bad)

	# 2) a width under the floor is clamped to COL_MIN_W, not silently kept
	m._col_w[Main.COL_COUNT - 1] = 5
	m._apply_col(Main.COL_COUNT - 1)
	ck("below-minimum width clamps to COL_MIN_W",
		int(m._col_w[Main.COL_COUNT - 1]) == Main.COL_MIN_W
		and t.get_column_width(Main.COL_COUNT - 1) == Main.COL_MIN_W)

	# 3) a wide column keeps its FULL title (eliding only kicks in when needed)
	m._sort_col = -1
	m._col_w[Main.COL_CHOP_N] = 200
	m._apply_col(Main.COL_CHOP_N)
	ck("wide column keeps the full title",
		t.get_column_title(Main.COL_CHOP_N) == Main.COL_TITLES[Main.COL_CHOP_N],
		t.get_column_title(Main.COL_CHOP_N))

	# 4) the sort arrow is present when it fits and never widens the column
	m._sort_col = Main.COL_CHOP_N
	m._sort_asc = true
	m._apply_col(Main.COL_CHOP_N)
	ck("sort arrow shown when it fits",
		t.get_column_title(Main.COL_CHOP_N).ends_with("v") and t.get_column_width(Main.COL_CHOP_N) == 200,
		t.get_column_title(Main.COL_CHOP_N))
	m._col_w[Main.COL_CHOP_N] = Main.COL_MIN_W
	m._apply_col(Main.COL_CHOP_N)
	ck("sort arrow never widens a narrow column", t.get_column_width(Main.COL_CHOP_N) == Main.COL_MIN_W)

	m.free()
	print("\n", "ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails)
	quit(0 if fails == 0 else 1)
