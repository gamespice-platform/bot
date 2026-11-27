extends "res://examples/selftest/nav_join_tests.gd"
## The tiled-bake section of the bot suite.


## The edge-merge cell (API level 33): the default leaves the engine's 0.1 for a new map, an
## asked share reaches the map, one outside the engine's range fails and is not clamped.
func _check_merge_scale(small: Node3D, agent: Dictionary) -> void:
	var plain_merge := GSBotNav.new()
	_check(plain_merge.bake(small, agent).ok and plain_merge.merge_scale_used == 0.0
		and is_equal_approx(NavigationServer3D.map_get_merge_rasterizer_cell_scale(plain_merge._map), 0.1),
		"no merge_scale keeps the engine's 0.1 for the map", str(NavigationServer3D.map_get_merge_rasterizer_cell_scale(plain_merge._map)))
	var fine := GSBotNav.new()
	var fine_agent := agent.duplicate()
	fine_agent["merge_scale"] = 0.01
	var fine_res := fine.bake(small, fine_agent)
	_check(fine_res.ok and is_equal_approx(fine.merge_scale_used, 0.01) and is_equal_approx(float(fine.describe().get("merge_scale", 0.0)), 0.01)
		and is_equal_approx(NavigationServer3D.map_get_merge_rasterizer_cell_scale(fine._map), 0.01)
		and fine.path_length(Vector3(-9.0, 0.0, -9.0), Vector3(9.0, 0.0, 9.0)) < 27.0,
		"merge_scale 0.01 reaches the map, describe() says it, a path still crosses", str(NavigationServer3D.map_get_merge_rasterizer_cell_scale(fine._map)))
	for bad_merge in [-0.05, 0.005, 0.2]:
		var wrong_merge := GSBotNav.new()
		var wrong_merge_agent := agent.duplicate()
		wrong_merge_agent["merge_scale"] = bad_merge
		var wrong_merge_res := wrong_merge.bake(small, wrong_merge_agent)
		_check(not wrong_merge_res.ok and not wrong_merge.is_ready(), "a merge_scale of %s fails loudly and is not clamped" % bad_merge,
			str(wrong_merge_res.error) if not wrong_merge_res.ok else "baked")


## Tiled bakes: a map that fits bakes as before, an over-limit one bakes in tiles joined at the seams.
func _test_nav_tiles() -> void:
	_section("nav tiles: a map that fits bakes as before, an over-limit map bakes tiled and a path crosses a seam, a bad tile fails loudly")
	var agent := {"radius": 0.35, "height": 1.0, "climb": 0.4}
	var small := Node3D.new()
	add_child(small)
	var small_body := StaticBody3D.new()
	small.add_child(small_body)
	var small_shape := CollisionShape3D.new()
	var small_box := BoxShape3D.new()
	small_box.size = Vector3(20.0, 0.2, 20.0)
	small_shape.shape = small_box
	small_shape.position = Vector3(0.0, -0.1, 0.0)
	small_body.add_child(small_shape)
	await get_tree().physics_frame

	var dir := "user://gs_bot_nav_tiles_test"
	var fits := GSBotNav.new()
	fits.cache_dir = dir
	fits.cache_id = "tile fits"
	DirAccess.remove_absolute(fits.cache_path())
	var fit_res := fits.bake(small, agent)
	_check(fit_res.ok and fits.tiles_used == 0 and not fits.cache_path().contains(".tile") and FileAccess.file_exists(fits.cache_path()), "a map that fits bakes as one grid and keeps its plain cache file", str(fits.tiles_used))
	var fit_again := GSBotNav.new()
	fit_again.cache_dir = dir
	fit_again.cache_id = "tile fits"
	_check(fit_again.bake(small, agent).ok and fit_again.last_bake_cached and fit_again.tiles_used == 0, "and hits that cache the second time")

	var forced := GSBotNav.new()
	forced.cache_dir = dir
	forced.cache_id = "tile fits"
	var forced_agent := agent.duplicate()
	forced_agent["tile"] = 8.0
	var forced_res := forced.bake(small, forced_agent)
	var tile_file := forced.cache_path()
	var fresh := not forced.last_bake_cached
	DirAccess.remove_absolute(tile_file)
	_check(forced_res.ok and forced.tiles_used > 1 and tile_file.contains(".tile%d" % roundi(forced.tile_used * 1000.0)) and tile_file != fits.cache_path() and absf(forced.tile_used - 8.05) < 0.001,
		"an asked tile bakes tiled into its own cache file, not the plain one", "%s %d tiles of %s, file %s, fresh %s" % [forced_res.ok, forced.tiles_used, forced.tile_used, tile_file, fresh])
	DirAccess.remove_absolute(fits.cache_path())
	_check(forced.path_length(Vector3(-9.0, 0.0, -9.0), Vector3(9.0, 0.0, 9.0)) < 27.0, "a path crosses the seams of an asked tile", str(forced.path_length(Vector3(-9.0, 0.0, -9.0), Vector3(9.0, 0.0, 9.0))))

	_check_merge_scale(small, agent)

	var big := Node3D.new()
	add_child(big)
	var big_body := StaticBody3D.new()
	big.add_child(big_body)
	var big_shape := CollisionShape3D.new()
	var big_box := BoxShape3D.new()
	big_box.size = Vector3(1500.0, 0.2, 1500.0)
	big_shape.shape = big_box
	big_shape.position = Vector3(0.0, -0.1, 0.0)
	big_body.add_child(big_shape)
	await get_tree().physics_frame
	var huge := GSBotNav.new()
	var huge_res := huge.bake(big, agent)
	_check(huge_res.ok and huge.tiles_used > 1 and absf(huge.tile_used - GSBotNavTiles.AUTO_TILE) < 0.175, "a map over the engine's cell limit bakes tiled at the auto size", "%d tiles of %s" % [huge.tiles_used, huge.tile_used])
	var across := huge.path_length(Vector3(-700.0, 0.0, -10.0), Vector3(700.0, 0.0, 10.0))
	_check(huge.is_ready() and across > 1400.0 and across < 1415.0, "a path crosses eleven seams of a tiled map straight", str(across))
	var diagonal := huge.path_length(Vector3(-700.0, 0.0, -700.0), Vector3(700.0, 0.0, 700.0))
	_check(diagonal < INF, "and one through the corners where four tiles meet", str(diagonal))

	for bad in [-1.0, 0.5, 5000.0]:
		var wrong := GSBotNav.new()
		var wrong_agent := agent.duplicate()
		wrong_agent["tile"] = bad
		var wrong_res := wrong.bake(big, wrong_agent)
		_check(not wrong_res.ok and not wrong.is_ready() and wrong.tiles_used == 0, "a tile of %s fails loudly and is not clamped" % bad, str(wrong_res.error) if not wrong_res.ok else "baked")

	small.queue_free()
	big.queue_free()
	_done()


const NavParse := preload("res://addons/gs_bot/runtime/gs_bot_nav_parse.gd")


## A map of every shape the engine parses, under a turned and moved root: one body of more shape owners than a
## parse chunk, a disabled shape, a body nested under a plain node and one on a layer outside the mask.
func _parse_map() -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(3.3, -1.7, 12.25)
	root.rotation = Vector3(0.1, 0.7, -0.05)
	add_child(root)
	var stream := GSRandomStream.new(7)
	var holder := Node3D.new()
	holder.position = Vector3(0.0, 0.5, -3.0)
	root.add_child(holder)
	for b in 4:
		var body := StaticBody3D.new()
		body.position = Vector3(b * 5.1, 0.3 * b, -2.0 * b)
		body.rotation = Vector3(0.0, 0.3 * b, 0.0)
		body.collision_layer = 4 if b == 3 else 1
		(holder if b == 2 else root).add_child(body)
		var floor_box := BoxShape3D.new()
		floor_box.size = Vector3(4.0, 0.2, 4.0 + b)
		var convex := ConvexPolygonShape3D.new()
		var points := PackedVector3Array()
		for i in 14:
			points.append(Vector3(stream.next_unit() * 2.0 - 1.0, stream.next_unit() * 2.0, stream.next_unit() * 2.0 - 1.0))
		convex.points = points
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)]))
		for shape: Shape3D in [floor_box, convex, concave, SphereShape3D.new(), CapsuleShape3D.new(), CylinderShape3D.new()]:
			var node := CollisionShape3D.new()
			node.shape = shape
			node.position = Vector3(stream.next_unit() * 3.0, stream.next_unit(), stream.next_unit() * 3.0)
			node.rotation = Vector3(0.0, stream.next_unit() * 3.0, 0.0)
			node.disabled = b == 1 and shape is SphereShape3D
			body.add_child(node)
	var many := StaticBody3D.new()
	root.add_child(many)
	for i in NavParse.CHUNK * 2 + 9:
		var node := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.5, 0.3 + 0.01 * i, 0.5)
		node.shape = box
		node.position = Vector3(i % 13, 0.0, -8.0 - i / 13)
		many.add_child(node)
	return root


## The engine's one call and the sliced parse (one microsecond a step) of [param nav]'s set-up bake; [one, sliced, steps].
func _parse_both(nav: GSBotNav, root: Node3D, agent: Dictionary, mask: int, bodies: Array) -> Array:
	var _set_up := nav._set_up(root, agent, mask, bodies)
	var one := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav.mesh, one, root)
	var parser := NavParse.new(root, nav.mesh)
	nav._ungroup(bodies)
	var steps := 1
	while not parser.step(nav.mesh, Time.get_ticks_usec() + 1) and steps < 100000:
		steps += 1
	return [one, parser.source(), steps]


func _same_source(a: NavigationMeshSourceGeometryData3D, b: NavigationMeshSourceGeometryData3D) -> bool:
	return a.get_vertices() == b.get_vertices() and a.get_indices() == b.get_indices() and a.get_vertices().size() > 0


## The collider parse a slice per frame (API level 45): the engine's own triangles to the bit, a bake from it the same mesh.
func _test_nav_parse_slices() -> void:
	_section("nav parse slices: the sliced collider parse writes the engine's one-call triangles, and a background bake from it the same mesh")
	var agent := {"radius": 0.35, "height": 1.0, "climb": 0.4}
	var root := _parse_map()
	await get_tree().physics_frame
	var nav := GSBotNav.new()
	var whole := _parse_both(nav, root, agent, 0, [])
	_check(_same_source(whole[0], whole[1]) and whole[2] > 2, "the whole root, a microsecond a step: the same vertices and indices",
		"%d/%d vertices in %d steps" % [whole[0].get_vertices().size(), whole[1].get_vertices().size(), whole[2]])
	var masked := _parse_both(nav, root, agent, 1, [])
	_check(_same_source(masked[0], masked[1]) and masked[0].get_vertices().size() < whole[0].get_vertices().size(),
		"a collision mask leaves out the same body", "%d vertices" % masked[1].get_vertices().size())
	var some: Array = [root.get_child(1), root.get_child(0)]
	var grouped := _parse_both(nav, root, agent, 0, some)
	_check(_same_source(grouped[0], grouped[1]) and not (some[0] as Node).is_in_group(nav._group()),
		"only the bodies passed in, in the engine's order, and the group is left empty", "%d vertices" % grouped[1].get_vertices().size())
	var csg: Node3D = ClassDB.instantiate("CSGBox3D") if ClassDB.class_exists("CSGBox3D") else null
	if csg != null:
		csg.set("use_collision", true)
		root.add_child(csg)
		await get_tree().physics_frame
	var odd := _parse_both(nav, root, agent, 0, [])
	_check(csg == null or _same_source(odd[0], odd[1]), "a node parsed another way (CSG) falls back to the one call, the same again")
	if csg != null:
		csg.free()

	var sync := GSBotNav.new()
	var _sync_res := sync.bake(root, agent)
	var landed: Array = []
	var sliced := GSBotNav.new()
	sliced.parse_slice_usec = 1
	var started := sliced.bake_in_background(root, agent, 0, [], func(res: GSResult) -> void: landed.append(res.ok))
	_check(started.ok and sliced.is_baking() and landed.is_empty() or not GSPlatform.has_threads(), "a sliced background bake is still parsing when the call returns")
	var frames := 0
	while landed.is_empty() and frames < 2000:
		await get_tree().process_frame
		frames += 1
	_check(landed == [true] and sliced.mesh.get_vertices() == sync.mesh.get_vertices() and sliced.mesh.get_polygon_count() == sync.mesh.get_polygon_count(),
		"it lands once with the one-call bake's mesh, vertex for vertex", "%s after %d frames, %d polygons" % [str(landed), frames, sliced.mesh.get_polygon_count()])
	var dropped: Array = []
	var again := GSBotNav.new()
	again.parse_slice_usec = 1
	var _again := again.bake_in_background(root, agent, 0, [], func(res: GSResult) -> void: dropped.append(res.ok))
	again.clear()
	for i in 30:
		await get_tree().process_frame
	_check(dropped.is_empty() and not again.is_baking() and not again.is_baked(), "a sliced parse cleared halfway is dropped", str(dropped))
	var copy := root.duplicate() as Node3D
	root.get_parent().add_child(copy)
	var lost: Array = []
	var orphan := GSBotNav.new()
	orphan.parse_slice_usec = 1
	var _orphan := orphan.bake_in_background(copy, agent, 0, [], func(res: GSResult) -> void: lost.append(res.ok))
	copy.free()
	for i in 30:
		if not lost.is_empty():
			break
		await get_tree().process_frame
	_check(lost == [false] and not orphan.is_baking() or not GSPlatform.has_threads(),
		"a source freed halfway through its parse ends the bake: done hears it failed and it is no longer baking", str(lost))
	root.queue_free()
	_done()
