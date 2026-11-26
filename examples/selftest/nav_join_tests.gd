extends "res://examples/selftest/nav_tests.gd"
## The join-prep section of the bot suite (API level 38): the islands, polygon grid and sides per edge
## the join's searches read, built a slice at a time, natively or not, against the one-go builders.

const NavPrep := preload("res://addons/gs_bot/runtime/gs_bot_nav_prep.gd")


## Steps a prep of [param nav]'s bake to the end with a one-microsecond deadline per call; returns the calls.
static func _prep_sliced(nav: GSBotNav, native: bool) -> Array:
	var prep := NavPrep.new(nav.mesh, nav._generation, native)
	var calls := 1
	while not prep.step(nav, Time.get_ticks_usec() + 1) and calls < 100000:
		calls += 1
	return [prep, calls]


## Sides per corner slot the way the join counted them before (string keys of centimetre vertices).
static func _uses_by_strings(mesh: NavigationMesh) -> PackedInt32Array:
	var vertices := mesh.get_vertices()
	var count := {}
	var keys: Array[String] = []
	for i in mesh.get_polygon_count():
		var polygon := mesh.get_polygon(i)
		for k in polygon.size():
			var a := str(GSBotNavGeometry.vertex_key(vertices[polygon[k]]))
			var b := str(GSBotNavGeometry.vertex_key(vertices[polygon[(k + 1) % polygon.size()]]))
			var key := a + "|" + b if a < b else b + "|" + a
			count[key] = int(count.get(key, 0)) + 1
			keys.append(key)
	var uses := PackedInt32Array()
	for key in keys:
		uses.append(int(count[key]))
	return uses


func _test_join_prep() -> void:
	_section("links: the join's islands, grid and edge sides, sliced and native, are the one-go builders' to the bit")
	var made := await _floors([Vector3.ZERO, Vector3(11.0, 0.0, 0.0), Vector3(0.0, -3.0, 10.0), Vector3(0.0, 0.0, -13.0),
			Vector3(40.0, 0.0, 0.0)], Vector3(10.0, 0.0, 10.0))
	var agent := {"radius": 0.35, "height": 1.0, "climb": 0.4}
	var nav := GSBotNav.new()
	var baked := nav.bake(made[0], agent, 0, [made[1]]).ok
	var ran: Array = _prep_sliced(nav, false)
	var prep: RefCounted = ran[0]
	var sliced_islands: Array[Dictionary] = nav._islands.duplicate(true)
	var sliced_of: PackedInt32Array = nav._island_of
	var sliced_grid: Dictionary = nav._poly_grid.duplicate(true)
	var whole_islands := GSBotNavGeometry.islands(nav.mesh)
	_check(baked and whole_islands.size() >= 3 and int(ran[1]) > 3 and not prep.get("ran_native"),
		"the floors are several islands, the script prep took many calls", "%d islands, %d calls" % [whole_islands.size(), ran[1]])
	_check(sliced_islands == whole_islands, "sliced islands: GSBotNavGeometry.islands' dictionaries in its order",
		"%s vs %s" % [sliced_islands.map(func(d: Dictionary) -> float: return d["area"]), whole_islands.map(func(d: Dictionary) -> float: return d["area"])])
	nav._islands = []
	var _again := nav.islands()
	_check(sliced_of == nav._island_of, "sliced island_of: every polygon's island as islands() gives it", "%s vs %s" % [sliced_of, nav._island_of])
	nav._build_poly_grid(nav.mesh.get_vertices())
	_check(sliced_grid == nav._poly_grid, "sliced grid: the one-go polygon grid", "%d vs %d cells" % [sliced_grid.size(), nav._poly_grid.size()])
	_check(prep.get("uses") == _uses_by_strings(nav.mesh), "script edge sides: the string-keyed count per corner", str(prep.get("uses")))
	if ClassDB.class_exists(NavPrep.NATIVE_CLASS):
		var native_ran: Array = _prep_sliced(nav, true)
		var native: RefCounted = native_ran[0]
		_check(native.get("ran_native") and native.get("uses") == prep.get("uses") and native.get("roots") == prep.get("roots")
			and nav._islands == whole_islands, "native: the script's edge sides, roots and islands", "%s vs %s" % [native.get("roots"), prep.get("roots")])
	else:
		_check(true, "native: GSSimNavJoin not loaded here (gs-sim's selftest and the games compare it)", "")
	# The budgeted join and the script-only join add the very edges the unbudgeted native-or-not join does.
	var whole := GSBotNav.new()
	var budgeted := GSBotNav.new()
	var _b := whole.bake(made[0], agent, 0, [made[1]]).ok and budgeted.bake(made[0], agent, 0, [made[1]]).ok
	var at_once := GSBotLinks.new().join(whole)
	budgeted.native_join = false
	var links := GSBotLinks.new()
	links.slice_usec = 1
	var calls := 1
	while not links.join_step(budgeted) and calls < 100000:
		calls += 1
	_check(calls > 3 and links.joined == at_once and budgeted.rides() == whole.rides(),
		"slice_usec: many calls, the same stats and edges as one join", "%d calls, %s vs %s" % [calls, links.joined, at_once])
	nav.clear()
	whole.clear()
	budgeted.clear()
	made[0].queue_free()
	_done()
