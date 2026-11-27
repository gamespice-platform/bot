extends RefCounted

## [GSBotNav]'s bake, cache, routes, ride edges and islands. Split out of gs_bot_nav.gd for file size;
## nothing outside the nav names this script.

const CHANNEL := "gs.bot.nav"

## Default metres a cell of the mesh covers, flat and up (a bake's `cell` and `cell_height` override
## them). The radius rounds up to whole cells, so a body whose radius is not a multiple wants its own
## cell: 0.4064 m at 0.175 bakes as 0.525 m. Finer costs bake time on a big map.
const CELL := 0.175
const CELL_HEIGHT := 0.1

## The baked mesh, or null before [method bake].
var mesh: NavigationMesh = null

## Boxes the next bake cuts out of the mesh, so no path ends inside one: a kill volume a bot would
## walk into. A box reaches [member avoid_body] metres below its floor too, since a body is hit by
## what overlaps its column. Kept across [method clear] and a re-bake, like the ride edges.
var avoid: Array[AABB] = []
var avoid_body: float = 1.8

## How long the last bake took, milliseconds: from the parse to the mesh taken in, so a
## [method bake_in_background] counts the time it spent on its thread.
var bake_ms: float = 0.0

## Opt-in bake cache: a directory (usually under `user://`) and a map id. With both set, a bake
## whose geometry digest matches the file for that id loads the mesh instead of baking it; a
## different digest rebakes and replaces the file. Empty [member cache_dir] is off.
var cache_dir: String = ""
var cache_id: String = ""
## Whether the last bake took its mesh from the cache.
var last_bake_cached: bool = false

## The tiles the last bake was cut into (0 for one grid) and their side, metres. See the bake's agent key `tile`.
var tiles_used: int = 0
var tile_used: float = 0.0

## The map's edge-merge cell as a share of the mesh cell (agent key `merge_scale`), 0 when the bake left the engine's default for a new map.
var merge_scale_used: float = 0.0

## The range NavigationServer3D keeps a map's merge rasterizer cell scale in; it clamps outside it.
const MERGE_SCALE_MIN := 0.01
const MERGE_SCALE_MAX := 0.1

const CACHE_FORMAT := 1
const CACHE_META := &"gs_bot_nav_cache"

var _cache_digest: String = ""
var _started: int = 0
var _tiler: GSBotNavTiles = GSBotNavTiles.new()
## How long [method bake_in_background] parses the colliders per frame before it yields (microseconds); 0 parses
## them in one call on the spot, which stalls a big map's frame for seconds. Same triangles either way.
var parse_slice_usec: int = 4000
const GSBotNavParse := preload("gs_bot_nav_parse.gd")
## The root last baked, for [method find_drops]'s clearance rays.
var _root: Node3D = null
var _baking: bool = false
## Bumped by [method clear]; a background bake started under another number is dropped.
var _generation: int = 0

var _map: RID = RID()
var _synced: bool = false
var _region: RID = RID()

## Ride edges: `{"id", "from", "to", "cost", "rid"}`, linked into the map whenever it is baked.
var _rides: Array[Dictionary] = []
## Link RID -> ride id, for [method route].
var _ride_of_link: Dictionary = {}

## Polygon index -> island, from [method islands]; empty until asked.
var _island_of: PackedInt32Array = PackedInt32Array()
var _islands: Array[Dictionary] = []
## Polygon indices bucketed by [constant GSBotNavGeometry.ISLAND_CELL] cell over their bounds, built the first time [method polygon_at] asks.
var _poly_grid: Dictionary = {}
var _poly_grid_for := Vector2i.ZERO
## Island -> islands one ride edge reaches, for [method joined]; null until asked.
var _ride_graph: Variant = null

## Polygon index -> cumulative area, for [method random_point].
var _areas: PackedFloat32Array = PackedFloat32Array()
var _total_area: float = 0.0


## Bakes the static colliders under [param root]. [param agent] keys: `radius`, `height` (lowest a body can go, crouched), `climb`, `slope` (degrees), `cell`, `cell_height`, `merge_scale` ([constant MERGE_SCALE_MIN] to [constant MERGE_SCALE_MAX]; 0 leaves the engine's 0.1; out of range fails) and `tile` (metres; 0 = auto, tiled only when the grid would pass 30 million cells, see [GSBotNavTiles]; negative or refused sizes fail, never clamped).
## Defaults for `cell` and `cell_height` are [constant CELL] and [constant CELL_HEIGHT].
## [param mask] is the collision layers that count as ground and walls (0 for all). With [param bodies] (nodes under [param root]), only those and their children are parsed.
func bake(root: Node3D, agent: Dictionary = {}, mask: int = 0, bodies: Array = []) -> GSResult:
	var parsed := _parse(root, agent, mask, bodies)
	if not parsed.ok:
		return parsed
	if _cache_load(parsed.value):
		return _take_in()
	return _bake_now(parsed.value)


## The synchronous bake of an already parsed [param source]: one grid, or the tiles baked in turn and joined.
func _bake_now(source: NavigationMeshSourceGeometryData3D) -> GSResult:
	if _tiler.count() == 0:
		NavigationServer3D.bake_from_source_geometry_data(mesh, source)
		return _take_in()
	var parts: Array[NavigationMesh] = []
	for box in _tiler.boxes:
		var part := _tiler.tile_mesh(box)
		NavigationServer3D.bake_from_source_geometry_data(part, source)
		parts.append(part)
	return _joined(parts)


## Joins the baked tile [param parts] into [member mesh] and takes it in.
func _joined(parts: Array[NavigationMesh]) -> GSResult:
	_tiler.join(parts)
	return _take_in()


## [method bake] with the mesh built on a worker thread, for a map too big to bake inside a tick: [param done] gets [method bake]'s result when it arrives; until then [method path] is empty and [method is_baking] true.
## When the mesh arrives depends on the machine, so a game replaying a seeded round must use [method bake]. Without threads this is [method bake].
## With [member parse_slice_usec] set, the colliders are parsed that long per frame first, the frames' own work around them.
func bake_in_background(root: Node3D, agent: Dictionary = {}, mask: int = 0, bodies: Array = [], done: Callable = Callable()) -> GSResult:
	if parse_slice_usec <= 0 or not GSPlatform.has_threads():
		var parsed := _parse(root, agent, mask, bodies)
		return _bake_parsed(parsed.value, done) if parsed.ok else parsed
	var set_up := _set_up(root, agent, mask, bodies)
	if not set_up.ok:
		return set_up
	_baking = true
	var parser := GSBotNavParse.new(root, mesh)
	_ungroup(bodies)
	_parse_slice(parser, root, root.get_tree(), _generation, agent, done)
	return GSResult.success(0)


## One frame's slice of a sliced parse, the next called from the tree's next frame until done or dropped. [param root] is untyped: a caller may free it between slices, and a freed object fails a typed argument before the body runs, which hung the bake with no [code]done[/code].
func _parse_slice(parser: GSBotNavParse, root: Variant, tree: SceneTree, generation: int, agent: Dictionary, done: Callable) -> void:
	if generation != _generation:
		return
	var gone := not is_instance_valid(root) or not (root as Node3D).is_inside_tree()
	if not gone and not parser.step(mesh, Time.get_ticks_usec() + parse_slice_usec):
		tree.process_frame.connect(_parse_slice.bind(parser, root, tree, generation, agent, done), CONNECT_ONE_SHOT)
		return
	var planned := GSResult.fail(GSError.CODE_INVALID, "nothing to bake: the map left the tree while it was parsed") if gone else _planned(parser.source(), agent)
	if planned.ok:
		var _started_bake := _bake_parsed(planned.value, done)
		return
	_baking = false
	if done.is_valid():
		done.call(planned)


## The rest of [method bake_in_background] once [param source] is parsed: the cache, else the async bake.
func _bake_parsed(source: NavigationMeshSourceGeometryData3D, done: Callable) -> GSResult:
	var cached := _cache_load(source)
	if cached or not GSPlatform.has_threads():
		_baking = false
		var res := _take_in() if cached else _bake_now(source)
		if done.is_valid():
			done.call(res)
		return res
	_baking = true
	# The generation and the mesh are bound so a bake that lands after clear() or a newer bake
	# is dropped instead of taken in over the map that replaced it.
	if _tiler.count() == 0:
		NavigationServer3D.bake_from_source_geometry_data_async(mesh, source, _on_baked.bind(_generation, mesh, done))
		return GSResult.success(0)
	# Tiles side by side on the server's workers; the last to land joins them.
	var parts: Array[NavigationMesh] = []
	var landed := [0]
	for box in _tiler.boxes:
		parts.append(_tiler.tile_mesh(box))
	for part in parts:
		NavigationServer3D.bake_from_source_geometry_data_async(part, source, _on_tile.bind(_generation, mesh, parts, landed, done))
	return GSResult.success(0)


## Whether a [method bake_in_background] has not landed yet.
func is_baking() -> bool:
	return _baking


func _on_baked(generation: int, baked: NavigationMesh, done: Callable) -> void:
	if generation != _generation or baked != mesh:
		return
	_baking = false
	var res := _take_in()
	if done.is_valid():
		done.call(res)


func _on_tile(generation: int, base: NavigationMesh, parts: Array[NavigationMesh], landed: Array, done: Callable) -> void:
	if generation != _generation or base != mesh:
		return
	landed[0] += 1
	if landed[0] < parts.size():
		return
	_baking = false
	var res := _joined(parts)
	if done.is_valid():
		done.call(res)


## Clears, then sets [member mesh] up and parses the colliders into source geometry.
func _parse(root: Node3D, agent: Dictionary, mask: int, bodies: Array) -> GSResult:
	var set_up := _set_up(root, agent, mask, bodies)
	if not set_up.ok:
		return set_up
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(mesh, source, root)
	_ungroup(bodies)
	return _planned(source, agent)


## Clears, then sets [member mesh] up to parse [param root] (with [param bodies] put in this nav's group).
func _set_up(root: Node3D, agent: Dictionary, mask: int, bodies: Array) -> GSResult:
	clear()

	if root == null or not root.is_inside_tree():
		return GSResult.fail(GSError.CODE_INVALID, "nothing to bake: the map is not in the tree")

	_started = Time.get_ticks_usec()
	_root = root
	last_bake_cached = false
	_cache_digest = ""
	_tiler.reset()
	tiles_used = 0
	tile_used = 0.0
	mesh = NavigationMesh.new()
	_poly_grid.clear()
	var merge_scale := float(agent.get("merge_scale", 0.0))
	if merge_scale != 0.0 and (merge_scale < MERGE_SCALE_MIN or merge_scale > MERGE_SCALE_MAX):
		return GSResult.fail(GSError.CODE_INVALID, "the bake's merge_scale %s is outside the engine's %s to %s (0 for its default)" % [
			merge_scale, MERGE_SCALE_MIN, MERGE_SCALE_MAX])
	merge_scale_used = merge_scale
	var cell := maxf(float(agent.get("cell", CELL)), 0.01)
	var cell_height := maxf(float(agent.get("cell_height", CELL_HEIGHT)), 0.01)
	mesh.cell_size = cell
	mesh.cell_height = cell_height
	# Whole cells, rounded the safe way (a body wider and taller, a step lower), which the baker
	# does anyway and warns about.
	mesh.agent_radius = ceilf(float(agent.get("radius", 0.35)) / cell - 0.001) * cell
	mesh.agent_height = ceilf(float(agent.get("height", 0.9)) / cell_height - 0.001) * cell_height
	mesh.agent_max_climb = floorf(float(agent.get("climb", 0.4)) / cell_height + 0.001) * cell_height
	mesh.agent_max_slope = float(agent.get("slope", 46.0))
	mesh.region_min_size = 2.0
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	if not bodies.is_empty():
		mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		mesh.geometry_source_group_name = _group()
		for body: Node in bodies:
			body.add_to_group(_group())
	if mask != 0:
		mesh.geometry_collision_mask = mask
	return GSResult.success(0)


func _group() -> StringName:
	return StringName("gs_bot_nav_%d" % get_instance_id())


func _ungroup(bodies: Array) -> void:
	for body: Variant in bodies:
		if is_instance_valid(body):
			(body as Node).remove_from_group(_group())


## Adds the avoid boxes to the parsed [param source] and plans the tiles; the source back when it fits.
func _planned(source: NavigationMeshSourceGeometryData3D, agent: Dictionary) -> GSResult:
	for box in avoid:
		var lo := box.position
		var hi := box.end
		source.add_projected_obstruction(PackedVector3Array([
			Vector3(lo.x, 0.0, lo.z), Vector3(hi.x, 0.0, lo.z), Vector3(hi.x, 0.0, hi.z), Vector3(lo.x, 0.0, hi.z)]),
			lo.y - avoid_body, box.size.y + avoid_body, true)
	var planned := _tiler.plan(source, mesh, float(agent.get("tile", 0.0)))
	if not planned.ok:
		return planned
	tiles_used = _tiler.count()
	tile_used = _tiler.side_m
	return GSResult.success(source)


## Where this map's cache file lives, or "" when the cache is off.
func cache_path() -> String:
	if cache_dir.is_empty() or cache_id.is_empty():
		return ""
	var stem := cache_id.validate_filename()
	# A tiled bake keeps its own file, so changing the tile never reads the other's mesh.
	if tiles_used > 0:
		stem += ".tile%d" % roundi(tile_used * 1000.0)
	return cache_dir.path_join(stem + ".nav.res")


## Fingerprint of everything the bake depends on: the parsed triangles, the agent and cell sizes, the avoid boxes.
func _digest_of(source: NavigationMeshSourceGeometryData3D) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(source.get_vertices().to_byte_array())
	ctx.update(source.get_indices().to_byte_array())
	var params := PackedFloat32Array([CACHE_FORMAT, mesh.cell_size, mesh.cell_height, mesh.agent_radius,
		mesh.agent_height, mesh.agent_max_climb, mesh.agent_max_slope, mesh.region_min_size, avoid_body])
	for box in avoid:
		params.append_array(PackedFloat32Array([box.position.x, box.position.y, box.position.z, box.size.x, box.size.y, box.size.z]))
	ctx.update(params.to_byte_array())
	return ctx.finish().hex_encode()


## Takes [member mesh] from the cache file when its digest matches; a stale file is deleted. True on a hit.
func _cache_load(source: NavigationMeshSourceGeometryData3D) -> bool:
	var path := cache_path()
	if path.is_empty():
		return false
	_cache_digest = _digest_of(source)
	if not FileAccess.file_exists(path):
		return false
	var found := ResourceLoader.load(path, "NavigationMesh", ResourceLoader.CACHE_MODE_IGNORE) as NavigationMesh
	var meta: Variant = found.get_meta(CACHE_META, {}) if found != null else {}
	if found == null or not meta is Dictionary or meta.get("digest", "") != _cache_digest or found.get_polygon_count() == 0:
		GSLog.debug(CHANNEL, "bake cache stale", {"id": cache_id})
		DirAccess.remove_absolute(path)
		return false
	mesh = found
	last_bake_cached = true
	GSLog.debug(CHANNEL, "bake cache hit", {"id": cache_id})
	return true


func _cache_store() -> void:
	var path := cache_path()
	if path.is_empty() or _cache_digest.is_empty() or last_bake_cached:
		return
	var made := DirAccess.make_dir_recursive_absolute(cache_dir)
	mesh.set_meta(CACHE_META, {"digest": _cache_digest, "format": CACHE_FORMAT})
	var err := ResourceSaver.save(mesh, path) if made == OK else made
	mesh.remove_meta(CACHE_META)
	if err != OK:
		GSLog.warn(CHANNEL, "bake cache not written", {"path": path, "error": error_string(err)})
		return
	GSWeb.sync_filesystem()


## Hands the baked [member mesh] to a navigation map of its own.
func _take_in() -> GSResult:
	if mesh.get_polygon_count() == 0:
		bake_ms = (Time.get_ticks_usec() - _started) / 1000.0
		return GSResult.fail(GSError.CODE_INVALID, "the bake found nowhere to walk")

	_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(_map, mesh.cell_size)
	NavigationServer3D.map_set_cell_height(_map, mesh.cell_height)
	if merge_scale_used > 0.0:
		NavigationServer3D.map_set_merge_rasterizer_cell_scale(_map, merge_scale_used)
	NavigationServer3D.map_set_active(_map, true)
	_region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(_region, _map)
	# Not on the navigation server's threads: taken in now, on this tick, so a game that asks
	# for a path right after baking gets one, and a seeded round plays the same on every run
	# however its frames fall.
	NavigationServer3D.map_set_use_async_iterations(_map, false)
	NavigationServer3D.region_set_use_async_iterations(_region, false)
	NavigationServer3D.region_set_navigation_mesh(_region, mesh)
	NavigationServer3D.map_set_link_connection_radius(_map, LINK_RADIUS)
	for ride in _rides:
		_link(ride)
	NavigationServer3D.map_force_update(_map)
	_index_areas()

	_cache_store()
	bake_ms = (Time.get_ticks_usec() - _started) / 1000.0
	GSLog.debug(CHANNEL, "baked", {"polygons": mesh.get_polygon_count(), "ms": snappedf(bake_ms, 0.1)})
	return GSResult.success(mesh.get_polygon_count())


## Baked, and taken in by the navigation server, which happens on a later frame (it syncs its maps on the process frame), never during [method bake]: a query before then answers with the origin or fails.
## [method random_point] needs only the bake. False while [member held].
func is_ready() -> bool:
	return not held and _live()


func _live() -> bool:
	if _synced:
		return true
	if not is_baked() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	# The map's first synchronisation can come before it holds the region (an empty map answers
	# every query with the origin), so ready is the region answering for its own first vertex.
	var probe := mesh.get_vertices()[mesh.get_polygon(0)[0]]
	_synced = NavigationServer3D.map_get_closest_point_owner(_map, probe) == _region
	return _synced


func is_baked() -> bool:
	return _map.is_valid() and mesh != null and _total_area > 0.0


## A walkable path from [param from] to [param to] (both snapped to the mesh), or empty.
func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if not is_ready():
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(_map, from, to, true)


## The length of [method path], or INF when there is none.
func path_length(from: Vector3, to: Vector3) -> float:
	var points := path(from, to)
	if points.size() < 2:
		return INF
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	# A path that ends far from where it was asked to go did not get there.
	if points[points.size() - 1].distance_to(closest(to)) > 0.6:
		return INF
	return total


## The nearest point on the mesh to [param at].
func closest(at: Vector3) -> Vector3:
	if not is_ready():
		return at
	return NavigationServer3D.map_get_closest_point(_map, at)


## A point on the mesh, drawn from [param stream] weighted by area.
func random_point(stream: GSRandomStream) -> Vector3:
	if not is_baked():
		return Vector3.ZERO
	var pick := stream.next_range_f(0.0, _total_area)
	var lo := 0
	var hi := _areas.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if _areas[mid] < pick:
			lo = mid + 1
		else:
			hi = mid
	var polygon := mesh.get_polygon(lo)
	var vertices := mesh.get_vertices()
	# A triangle of the fan, then a point in it.
	var fan := stream.next_range_i(1, maxi(polygon.size() - 2, 1))
	var a := vertices[polygon[0]]
	var b := vertices[polygon[fan]]
	var c := vertices[polygon[mini(fan + 1, polygon.size() - 1)]]
	var u := stream.next_unit()
	var v := stream.next_unit()
	if u + v > 1.0:
		u = 1.0 - u
		v = 1.0 - v
	return a + (b - a) * u + (c - a) * v


## Frees the navigation map. Call when the map it was baked from goes away.
func _notification(what: int) -> void:
	# The RIDs by hand: a method call on an object being deleted finds it already gone.
	if what == NOTIFICATION_PREDELETE:
		for ride in _rides:
			if (ride["rid"] as RID).is_valid():
				NavigationServer3D.free_rid(ride["rid"])
		if _region.is_valid():
			NavigationServer3D.free_rid(_region)
		if _map.is_valid():
			NavigationServer3D.free_rid(_map)


func clear() -> void:
	_unlink_all()
	_island_of = PackedInt32Array()
	_islands.clear()
	_poly_grid.clear()
	_ride_graph = null
	if _region.is_valid():
		NavigationServer3D.free_rid(_region)
	if _map.is_valid():
		NavigationServer3D.free_rid(_map)
	_region = RID()
	_map = RID()
	_synced = false
	_baking = false
	held = false
	_generation += 1
	mesh = null
	_areas = PackedFloat32Array()
	_total_area = 0.0


func _index_areas() -> void:
	_areas = PackedFloat32Array()
	_total_area = 0.0
	var vertices := mesh.get_vertices()
	for i in range(mesh.get_polygon_count()):
		var polygon := mesh.get_polygon(i)
		var area := 0.0
		for k in range(1, polygon.size() - 1):
			area += (vertices[polygon[k]] - vertices[polygon[0]]).cross(vertices[polygon[k + 1]] - vertices[polygon[0]]).length() * 0.5
		_total_area += area
		_areas.append(_total_area)


# Ride edges.

## How far a ride edge's ends may be from the mesh and still join it, metres.
const LINK_RADIUS := 1.5

var _batching := false
var _batch_dirty := false

## Set while a game steps a [method begin_edges] job over frames: [method is_ready] answers false, so no
## route is laid over a half-joined mesh, and bots start once it is cleared. [method clear] clears it.
var held := false:
	set(on):
		var was := held
		held = on
		# joined() snaps through closest() only when ready, so a graph cached while held is stale
		_ride_graph = null
		if was and not on:
			_link_pending()


## Adds a one-way edge from [param from] to [param to] that is ridden, not walked (a surf ramp, a drop), under [param id]; [method route] crosses it when cheaper and says where. [param cost] scales its length. Kept across a re-bake; [method clear_rides] drops them.
## It is a navigation link because the bake leaves out faces steeper than the slope limit, so surf maps are islands.
func add_ride(from: Vector3, to: Vector3, id: int, cost: float = 1.0) -> void:
	var ride := {"id": id, "from": from, "to": to, "cost": cost, "rid": RID()}
	_rides.append(ride)
	_ride_graph = null
	# Held: the rides wait unlinked and go to the server together when the hold ends, as each link added
	# dirties the map and the server re-syncs all of it in the next physics step, a frame's worth of work per slice.
	if _map.is_valid() and not held:
		_link(ride)
		if _batching:
			_batch_dirty = true
		else:
			NavigationServer3D.map_force_update(_map)


## Holds back the server's map update until [method end_batch], for a run of [method add_ride] calls: each update costs time in the size of the whole map.
func begin_batch() -> void:
	_batching = true


func end_batch() -> void:
	_batching = false
	if _batch_dirty and _map.is_valid():
		NavigationServer3D.map_force_update(_map)
	_batch_dirty = false


## The ride edges added, as `{"id", "from", "to", "cost"}`.
func rides() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ride in _rides:
		out.append({"id": ride["id"], "from": ride["from"], "to": ride["to"], "cost": ride["cost"]})
	return out


func clear_rides() -> void:
	_ride_graph = null
	_unlink_all()
	_rides.clear()
	if _map.is_valid():
		NavigationServer3D.map_force_update(_map)


## Sends the server the rides added while [member held], in one map update.
func _link_pending() -> void:
	if not _map.is_valid():
		return
	var any := false
	for ride in _rides:
		if not (ride["rid"] as RID).is_valid():
			_link(ride)
			any = true
	if any:
		NavigationServer3D.map_force_update(_map)
	_batch_dirty = false


func _link(ride: Dictionary) -> void:
	var link := NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(link, _map)
	NavigationServer3D.link_set_bidirectional(link, false)
	NavigationServer3D.link_set_start_position(link, ride["from"])
	NavigationServer3D.link_set_end_position(link, ride["to"])
	NavigationServer3D.link_set_travel_cost(link, float(ride["cost"]))
	ride["rid"] = link
	_ride_of_link[link] = int(ride["id"])


func _unlink_all() -> void:
	for ride in _rides:
		var rid: RID = ride["rid"]
		if rid.is_valid():
			NavigationServer3D.free_rid(rid)
		ride["rid"] = RID()
	_ride_of_link.clear()


## A way from [param from] to [param to] that may ride: `{"points": PackedVector3Array, "rides":
## PackedInt32Array}`, where `rides[i]` is the id of the ride edge that starts at `points[i]` (its
## end is `points[i + 1]`), or -1 for a walked corner. Empty points when unreachable.
func route(from: Vector3, to: Vector3) -> Dictionary:
	var out := {"points": PackedVector3Array(), "rides": PackedInt32Array()}
	if not is_ready():
		return out
	var query := NavigationPathQueryParameters3D.new()
	query.map = _map
	# a body a little off the mesh (island -1) gets a one-point stub unless snapped
	query.start_position = closest(from)
	query.target_position = to
	query.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_TYPES | NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_RIDS
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(query, result)
	var points := result.path
	var types := result.path_types
	var rids := result.path_rids
	var marks := PackedInt32Array()
	marks.resize(points.size())
	marks.fill(-1)
	for i in range(points.size()):
		if i < types.size() and types[i] == NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK and i < rids.size() and _ride_of_link.has(rids[i]):
			# The link's start is the point flagged as the link; its end is the next one.
			marks[i] = int(_ride_of_link[rids[i]])
	# A link can be reported on both of its points: keep the first of a run.
	for i in range(points.size() - 1, 0, -1):
		if marks[i] >= 0 and marks[i - 1] == marks[i]:
			marks[i] = -1
	out["points"] = points
	out["rides"] = marks
	return out


# Islands.

## The mesh's islands: polygons joined by shared edges, biggest first, as `{"index", "area",
## "polygons": PackedInt32Array, "bounds": AABB, "centre": Vector3}`. What a walked route cannot
## leave: on a combat surf map each platform group is one, and a ride edge joins two.
func islands() -> Array[Dictionary]:
	if not _islands.is_empty() or mesh == null:
		return _islands
	_islands = GSBotNavGeometry.islands(mesh)
	_island_of = PackedInt32Array()
	_island_of.resize(mesh.get_polygon_count())
	for island in _islands:
		for i: int in island["polygons"]:
			_island_of[i] = int(island["index"])
	return _islands


## The island [param at] stands on (the polygon nearest it, within [param reach] metres), or -1.
func island_at(at: Vector3, reach: float = 1.0) -> int:
	var polygon := polygon_at(at, reach)
	if polygon < 0:
		return -1
	var _all := islands()
	return _island_of[polygon] if polygon < _island_of.size() else -1


## Whether [param at] is over island [param index] (inside one of its triangles seen from above, within [param reach] metres up or down).
## Fast enough to ask every simulated tick: the island's triangles are bucketed on a grid of [constant GSBotNavGeometry.ISLAND_CELL] metres the first time.
## What a ride edge's course asks of its landing.
func on_island(index: int, at: Vector3, reach: float = 0.5) -> bool:
	var all := islands()
	if index < 0 or index >= all.size():
		return false
	var island := all[index]
	if not island.has("grid"):
		island["grid"] = GSBotNavGeometry.grid(mesh, island)
	var grid: Dictionary = island["grid"]
	var cell := Vector2i(floori(at.x / GSBotNavGeometry.ISLAND_CELL), floori(at.z / GSBotNavGeometry.ISLAND_CELL))
	var bucket: Variant = grid.get(cell)
	if bucket == null:
		return false
	for tri: Array in bucket:
		var height := GSBotNavGeometry.height_in(at, tri[0], tri[1], tri[2])
		if not is_nan(height) and absf(at.y - height) <= reach:
			return true
	return false


## Whether a walk (over ride edges too) from [param from] to [param to] can exist, answered from the islands without a path query (the server logs an error per query between islands). True before the bake.
## A game with its own idea of "reachable" passes a Callable to [method GSBotHiding.choose] instead.
func joined(from: Vector3, to: Vector3) -> bool:
	if mesh == null:
		return true
	var a := _island_near(from)
	var b := _island_near(to)
	if a < 0 or b < 0:
		return false
	if a == b:
		return true
	var graph := _rides_between_islands()
	var seen := {a: true}
	var queue: Array[int] = [a]
	while not queue.is_empty():
		var at: int = queue.pop_back()
		for next: int in graph.get(at, []):
			if next == b:
				return true
			if not seen.has(next):
				seen[next] = true
				queue.append(next)
	return false


func _island_near(at: Vector3) -> int:
	var snapped_at := closest(at) if is_ready() else at
	var all := islands()
	for island in all:
		if on_island(int(island["index"]), snapped_at, 0.6):
			return int(island["index"])
	return island_at(snapped_at, 1.0)


func _rides_between_islands() -> Dictionary:
	if _ride_graph != null:
		return _ride_graph
	var graph: Dictionary = {}
	for ride in _rides:
		var a := _island_near(ride["from"])
		var b := _island_near(ride["to"])
		if a >= 0 and b >= 0 and a != b:
			if not graph.has(a):
				graph[a] = []
			graph[a].append(b)
	_ride_graph = graph
	return graph


## The index of the polygon under [param at] (within [param reach] metres up or down, and inside
## its outline seen from above), or -1. Uses a polygon grid built on first call, cheap
## enough per tick; the grid is padded by a metre, so keep [param reach] near that.
func polygon_at(at: Vector3, reach: float = 1.0) -> int:
	if mesh == null:
		return -1
	var vertices := mesh.get_vertices()
	_poly_grid_ready(vertices)
	var best := -1
	var best_dy := INF
	var bucket: Variant = _poly_grid.get(Vector2i(floori(at.x / GSBotNavGeometry.ISLAND_CELL), floori(at.z / GSBotNavGeometry.ISLAND_CELL)))
	if bucket == null:
		return -1
	for i: int in bucket:
		var polygon := mesh.get_polygon(i)
		for k in range(1, polygon.size() - 1):
			var a := vertices[polygon[0]]
			var b := vertices[polygon[k]]
			var c := vertices[polygon[k + 1]]
			var height := GSBotNavGeometry.height_in(at, a, b, c)
			if is_nan(height):
				continue
			var dy := absf(at.y - height)
			if dy <= reach and dy < best_dy:
				best_dy = dy
				best = i
	return best


func _poly_grid_ready(vertices: PackedVector3Array) -> void:
	if _poly_grid.is_empty() or _poly_grid_for != Vector2i(vertices.size(), mesh.get_polygon_count()):
		_build_poly_grid(vertices)


func _build_poly_grid(vertices: PackedVector3Array) -> void:
	_poly_grid.clear()
	_poly_grid_for = Vector2i(vertices.size(), mesh.get_polygon_count())
	var cell := GSBotNavGeometry.ISLAND_CELL
	for i in range(mesh.get_polygon_count()):
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for index in mesh.get_polygon(i):
			var v := vertices[index]
			lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z))
			hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
		# Padded, because height_in accepts a point a little outside the triangle.
		for cx in range(floori((lo.x - 1.0) / cell), floori((hi.x + 1.0) / cell) + 1):
			for cz in range(floori((lo.y - 1.0) / cell), floori((hi.y + 1.0) / cell) + 1):
				var key := Vector2i(cx, cz)
				var bucket: PackedInt32Array = _poly_grid.get(key, PackedInt32Array())
				bucket.append(i)
				_poly_grid[key] = bucket


func describe() -> Dictionary:
	return {
		"ready": is_ready() if is_baked() else false,
		"baking": _baking,
		"polygons": mesh.get_polygon_count() if mesh != null else 0,
		"area": snappedf(_total_area, 0.1),
		"bake_ms": snappedf(bake_ms, 0.1),
		"rides": _rides.size(),
		"avoid": avoid.size(),
		"tiles": tiles_used,
		"tile": snappedf(tile_used, 0.001),
		"merge_scale": merge_scale_used,
	}


func describe_lines() -> PackedStringArray:
	var facts := describe()
	return PackedStringArray(["nav  %s, %d polygons, %.0f m2, baked in %.0f ms" % [
		"ready" if facts["ready"] else ("baking" if facts["baking"] else "not baked"), facts["polygons"], facts["area"], facts["bake_ms"]]])
