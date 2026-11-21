extends "res://examples/selftest/nav_tests.gd"
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

	var dir := "user://dot_bot_nav_tiles_test"
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
