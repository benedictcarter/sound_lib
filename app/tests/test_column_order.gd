extends SceneTree
# Golden test for COLUMN REORDERING (drag a header title sideways).
#
#   Godot..._console.exe --headless --path app --script tests/test_column_order.gd
#
# The app addresses columns by LOGICAL id (COL_*) but the Tree addresses them by
# SLOT, so _col_order / _col_slot must stay EXACT mutual inverses and must always
# cover every column exactly once — a duplicate or a dropped id means a column
# silently vanishes from the table (or two columns write into the same cell), and
# the order is persisted, so a bad one would come back every launch. These tests
# hammer that invariant, including with corrupt/short/stale saved orders.
# (Exits non-zero on failure.)

var fails := 0

func ck(name: String, cond: bool, extra: String = "") -> void:
	if not cond:
		fails += 1
	print(("PASS  " if cond else "FAIL  "), name, "  ", extra)


# _col_order and _col_slot describe the same permutation, both ways round.
func consistent(m) -> bool:
	var n: int = m.COL_COUNT
	if m._col_order.size() != n or m._col_slot.size() != n:
		return false
	var seen := {}
	for s in n:
		var c: int = int(m._col_order[s])
		if c < 0 or c >= n or seen.has(c):
			return false
		seen[c] = true
		if int(m._col_slot[c]) != s:
			return false
	return seen.size() == n


func _initialize() -> void:
	var Main = load("res://main.gd")
	# NOT added to the scene tree, so _ready never runs; the order helpers touch
	# only _col_order / _col_slot.
	var m = Main.new()
	var n: int = Main.COL_COUNT

	ck("default order is identity and consistent",
		consistent(m) and m._col_order == range(n) and m._lcol(3) == 3)

	# _lcol maps a Tree slot back to a logical id, and passes "nowhere" through
	ck("_lcol(-1) stays -1 (get_column_at_position's miss)", m._lcol(-1) == -1)
	ck("_lcol past the end is -1", m._lcol(n) == -1)

	# --- repair of a bad saved order -------------------------------------------
	m._set_col_order([])
	ck("empty saved order restores every column", consistent(m) and m._col_order == range(n))

	m._set_col_order([5, 5, 5])
	ck("duplicates collapse, the rest are appended",
		consistent(m) and int(m._col_order[0]) == 5, str(m._col_order))

	m._set_col_order([2, -1, 999, 0])
	ck("out-of-range ids are dropped",
		consistent(m) and int(m._col_order[0]) == 2 and int(m._col_order[1]) == 0,
		str(m._col_order))

	# a SHORT order (saved by an older build with fewer columns) keeps its prefix
	# and gains the new columns at the end
	m._set_col_order(range(n - 3))
	ck("a short saved order keeps its prefix + gains the new columns",
		consistent(m) and m._col_order == range(n), str(m._col_order))

	# --- moving ----------------------------------------------------------------
	m._set_col_order(range(n))
	# insert index 0 = "in front of the column in slot 0"
	var order: Array = m._order_after_move(4, 0)
	ck("move to the front (0..3 each shift one right)",
		order.size() == n and int(order[0]) == 4 and int(order[1]) == 0 and int(order[4]) == 3,
		str(order))

	m._set_col_order(range(n))
	order = m._order_after_move(0, n)
	ck("move to the very end", order.size() == n and int(order[n - 1]) == 0 and int(order[0]) == 1, str(order))

	# a drop on either side of the column itself changes nothing (the insert index
	# is one MORE than the slot when dropping on its right half)
	m._set_col_order(range(n))
	ck("drop before itself is a no-op", m._order_after_move(3, 3).is_empty())
	ck("drop after itself is a no-op", m._order_after_move(3, 4).is_empty())

	# right-shift: the insert index counts slots BEFORE the lift, so 2 -> 5 lands
	# the column at slot 4, with 3,4 sliding left
	m._set_col_order(range(n))
	order = m._order_after_move(2, 5)
	ck("move right lands one slot left of the insert index",
		int(order[2]) == 3 and int(order[3]) == 4 and int(order[4]) == 2, str(order))

	# out-of-range drop indices clamp instead of erroring
	m._set_col_order(range(n))
	order = m._order_after_move(6, -50)
	ck("a negative drop index clamps to the front", order.size() == n and int(order[0]) == 6)
	order = m._order_after_move(6, 9999)
	ck("a huge drop index clamps to the end", order.size() == n and int(order[n - 1]) == 6)

	# --- a long random-ish walk keeps the permutation intact -------------------
	m._set_col_order(range(n))
	var bad := ""
	var k := 0
	for i in 400:
		k = (k * 37 + 11) % (n * (n + 1))
		var logical: int = k % n
		var before: int = (k / n) % (n + 1)
		var o: Array = m._order_after_move(logical, before)
		if not o.is_empty():
			m._set_col_order(o)
		if not consistent(m):
			bad = "broke at step %d (%d -> %d): %s" % [i, logical, before, str(m._col_order)]
			break
	ck("400 moves keep _col_order/_col_slot exact inverses covering every column",
		bad == "", bad)

	m.free()
	print("\n", "ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails)
	quit(0 if fails == 0 else 1)
