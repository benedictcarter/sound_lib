extends SceneTree
# Golden test for WaveGraph's region-edge HANDLES: drives the control with
# synthetic mouse events and asserts an edge drag moves ONE end, can't cross the
# other, and never steals a press meant to start a fresh selection.
#
#   Godot..._console.exe --headless --path app --script tests/test_wavegraph_handles.gd
#
# (Exits non-zero on failure. The UI is built in code, so this is the only way to
# regression-test the graph's input without a human driving a mouse.)

var fails := 0

func ck(name: String, cond: bool, extra: String = "") -> void:
	if not cond:
		fails += 1
	print(("PASS  " if cond else "FAIL  "), name, "  ", extra)

func mb(g, x: float, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = Vector2(x, 100)
	g._gui_input(e)

func mm(g, x: float, held: bool) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(x, 100)
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	g._gui_input(e)

func _initialize() -> void:
	var Main = load("res://main.gd")
	var g = Main.WaveGraph.new()
	root.add_child(g)
	g.size = Vector2(1000, 200)
	var lv := PackedFloat32Array()
	for i in 500:
		lv.append(-20.0)
	g.levels = lv

	var committed := [0]
	g.region_committed.connect(func(): committed[0] += 1)

	# --- grabbing the START handle moves only that edge ---------------------
	g.sel_a = 0.2
	g.sel_b = 0.6
	mb(g, 200.0, true)                       # press exactly on the start edge
	ck("start handle grabbed", g._edge_drag == 1, "edge=%d" % g._edge_drag)
	mm(g, 300.0, true)
	mb(g, 300.0, false)
	ck("start edge moved to 0.30", is_equal_approx(snappedf(g.sel_a, 0.001), 0.300), str(g.sel_a))
	ck("end edge untouched", is_equal_approx(g.sel_b, 0.6), str(g.sel_b))
	ck("committed once", committed[0] == 1, str(committed[0]))

	# --- grabbing the END handle (within the 8 px grab zone) ----------------
	mb(g, 604.0, true)
	ck("end handle grabbed", g._edge_drag == 2, "edge=%d" % g._edge_drag)
	mm(g, 800.0, true)
	mb(g, 800.0, false)
	ck("end edge moved to 0.80", is_equal_approx(snappedf(g.sel_b, 0.001), 0.800), str(g.sel_b))
	ck("start edge untouched", is_equal_approx(snappedf(g.sel_a, 0.001), 0.300), str(g.sel_a))

	# --- a handle can't be dragged past the other end -----------------------
	mb(g, 800.0, true)                       # grab the END, drag it left past START
	mm(g, 50.0, true)
	mb(g, 50.0, false)
	ck("end clamped above start", g.sel_b > g.sel_a, "%f > %f" % [g.sel_b, g.sel_a])
	ck("region still valid", g.has_manual_sel())

	# --- pressing AWAY from both edges still starts a fresh selection -------
	g.sel_a = 0.2
	g.sel_b = 0.6
	mb(g, 500.0, true)                       # middle of the region = new drag
	ck("middle press is a new selection", g._edge_drag == 0 and is_equal_approx(g.sel_a, 0.5),
		"edge=%d a=%f" % [g._edge_drag, g.sel_a])
	mm(g, 700.0, true)
	mb(g, 700.0, false)
	ck("new region 0.5-0.7", is_equal_approx(snappedf(g.sel_a, 0.001), 0.5) \
		and is_equal_approx(snappedf(g.sel_b, 0.001), 0.7), "%f-%f" % [g.sel_a, g.sel_b])

	# --- a plain click (no drag) away from the edges still clears -----------
	mb(g, 100.0, true)
	mb(g, 100.0, false)
	ck("plain click clears the region", not g.has_manual_sel())
	ck("no handles when nothing is selected", g._edge_at(100.0) == 0)

	# --- hover sets the resize cursor ---------------------------------------
	g.sel_a = 0.2
	g.sel_b = 0.6
	mm(g, 201.0, false)
	ck("hover start -> HSIZE cursor", g._edge_hover == 1 \
		and g.mouse_default_cursor_shape == Control.CURSOR_HSIZE, str(g._edge_hover))
	mm(g, 450.0, false)
	ck("hover middle -> arrow cursor", g._edge_hover == 0 \
		and g.mouse_default_cursor_shape == Control.CURSOR_ARROW, str(g._edge_hover))

	print("\n", "ALL HANDLE TESTS PASSED" if fails == 0 else "%d FAILURE(S)" % fails)
	quit(1 if fails > 0 else 0)
