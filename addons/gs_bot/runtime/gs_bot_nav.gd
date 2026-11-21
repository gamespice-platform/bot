class_name GSBotNav
extends "gs_bot_nav_core.gd"

## Where a bot can walk: a navigation mesh baked from a map's static colliders, and paths across it.
##
## Optional: the brain walks straight at waypoints otherwise. Pass only bodies that never move (a door baked shut is a wall). It owns its navigation map, so [method clear] frees all of it, and [method random_point] draws from the caller's [GSRandomStream]. Usage: docs/design.md.

## The edge searches (drops, hops, stitches) are here; the bake, routes and islands are in gs_bot_nav_core.gd, split out for file size.

## Adds one-way drop edges from the mesh's open borders down to lower floor, id [param first_id] up, one per [param spacing] metres of rim, at most [param limit]; returns how many.
## A landing is the nearest mesh point below the rim, kept only when it lies under the probe and physics rays out and down hit nothing.
func find_drops(first_id: int, min_drop: float = 1.2, max_drop: float = 24.0, spacing: float = 4.0, limit: int = 400, cost: float = 2.0) -> int:
	return _run_edges(begin_edges(&"drops", first_id, {"min_drop": min_drop, "max_drop": max_drop, "spacing": spacing, "limit": limit, "cost": cost}))


## Adds one-way hop edges from the mesh's rims across a gap to another island's floor (at most 0.9 m higher, any
## depth lower), id [param first_id] up: a jump a body makes at the rim. [param max_gap] metres is what a
## standing run-up clears. The landing must be another island, or the edge only shortens a walk.
func find_hops(first_id: int, max_gap: float = 4.0, spacing: float = 1.5, limit: int = 800, cost: float = 3.0) -> int:
	return _run_edges(begin_edges(&"hops", first_id, {"max_gap": max_gap, "spacing": spacing, "limit": limit, "cost": cost}))


## Joins neighbouring islands where their rims come within [param max_gap] metres sideways: the lower rim climbs at most [param max_rise] to the higher, the higher drops to the lower, and a chest-high ray between them is clear.
## Defaults are a jump's reach: [param max_rise] 0.9 is what find_hops lands on, and the gap allowed shrinks linearly to half of [param max_gap] at that rise, since the apex is spent climbing. A wider or higher pair is left unlinked (a bot wedges at a rim it cannot cross). Rims closer than 0.5 m sideways drop at any height. One pair of edges per pair of islands (the closest of its eight nearest candidates that a ray sees across), at most [param limit] edges; returns how many. Hops only look off rims of one island at a time along one heading, so small islands beside a main one stayed apart.
const STITCH_CANDIDATES := 8


func find_stitches(first_id: int, max_gap: float = 3.0, max_rise: float = 0.9, limit: int = 600, cost: float = 3.0) -> int:
	var job := begin_edges(&"stitches", first_id, {"max_gap": max_gap, "max_rise": max_rise, "limit": limit, "cost": cost})
	var _done := step_edges(job)
	return int(job["added"])


func _run_edges(job: Dictionary) -> int:
	begin_batch()
	var _done := step_edges(job)
	end_batch()
	return int(job["added"])


## [method find_drops], [method find_hops] or [method find_stitches] ([param kind] `&"drops"`, `&"hops"`,
## `&"stitches"`) as a job [method step_edges] works through a slice at a time, for a map whose search
## outlasts a frame. [param options] are those methods' parameters by name. Same edges, ids and count (`"added"`).
func begin_edges(kind: StringName, first_id: int, options: Dictionary = {}) -> Dictionary:
	var job := {"kind": kind, "first_id": first_id, "generation": _generation, "stage": 0, "i": 0, "added": 0, "done": not _live()}
	var limit_default: int = 400 if kind == &"drops" else (800 if kind == &"hops" else 600)
	job["limit"] = int(options.get("limit", limit_default))
	job["cost"] = float(options.get("cost", 2.0 if kind == &"drops" else 3.0))
	match kind:
		&"drops":
			job["reaches"] = [0.9, 1.6]
			job["min_drop"] = float(options.get("min_drop", 1.2))
			job["max_drop"] = float(options.get("max_drop", 24.0))
			job["spacing"] = float(options.get("spacing", 4.0))
			job["other_island"] = false
		&"hops":
			var reaches: Array = []
			var max_gap := float(options.get("max_gap", 4.0))
			var gap := 2.0
			while gap <= max_gap + 0.01:
				reaches.append(gap)
				gap += 0.75
			job["reaches"] = reaches
			job["min_drop"] = -0.9
			job["max_drop"] = 24.0
			job["spacing"] = float(options.get("spacing", 1.5))
			job["other_island"] = true
		&"stitches":
			job["max_gap"] = float(options.get("max_gap", 3.0))
			job["max_rise"] = float(options.get("max_rise", 0.9))
		_:
			job["done"] = true
	return job


## Works on [param job] until it is done (true) or [method Time.get_ticks_usec] reaches [param until_usec]
## (false; 0 runs it out). Edges it adds reach the server's map when it is done; a job outlived by
## [method clear] or a new bake stops where it was.
func step_edges(job: Dictionary, until_usec: int = 0) -> bool:
	if bool(job["done"]):
		return true
	if int(job["generation"]) != _generation:
		job["done"] = true
		return true
	var was := _batching
	_batching = true
	var finished: bool = _step_stitches(job, until_usec) if job["kind"] == &"stitches" else _step_edges(job, until_usec)
	_batching = was
	if finished:
		job["done"] = true
		if not was:
			if _batch_dirty and _map.is_valid():
				NavigationServer3D.map_force_update(_map)
			_batch_dirty = false
	return finished


static func _past(until_usec: int) -> bool:
	return until_usec > 0 and Time.get_ticks_usec() >= until_usec


## Counts the polygons on each mesh edge into _uses, from where the last call stopped; true when all are.
func _count_uses(until_usec: int) -> bool:
	var vertices := mesh.get_vertices()
	var count := mesh.get_polygon_count()
	while _uses_at < count:
		var polygon := mesh.get_polygon(_uses_at)
		for k in polygon.size():
			var key := GSBotNavGeometry.edge_key(GSBotNavGeometry.vertex_key(vertices[polygon[k]]), GSBotNavGeometry.vertex_key(vertices[polygon[(k + 1) % polygon.size()]]))
			_uses[key] = _uses.get(key, 0) + 1
		_uses_at += 1
		if _uses_at % 128 == 0 and _past(until_usec):
			return _uses_at >= count
	return true


func _step_edges(job: Dictionary, until_usec: int) -> bool:
	if int(job["stage"]) == 0:
		# the island and polygon lookups build on first use; built here they are a slice of their own
		var _all := islands()
		_poly_grid_ready(mesh.get_vertices())
		job["stage"] = 1
		if _past(until_usec):
			return false
	if int(job["stage"]) == 1:
		if not _count_uses(until_usec):
			return false
		job["stage"] = 2
		job["seen"] = {}
		if _past(until_usec):
			return false
	var vertices := mesh.get_vertices()
	var count := mesh.get_polygon_count()
	var seen: Dictionary = job["seen"]
	var reaches: Array = job["reaches"]
	var min_drop: float = job["min_drop"]
	var max_drop: float = job["max_drop"]
	var spacing: float = job["spacing"]
	var limit: int = job["limit"]
	var cost: float = job["cost"]
	var other_island: bool = job["other_island"]
	var first_id: int = job["first_id"]
	var added: int = job["added"]
	var i: int = job["i"]
	while i < count:
		var polygon := mesh.get_polygon(i)
		var centre := Vector3.ZERO
		for index in polygon:
			centre += vertices[index]
		centre /= float(polygon.size())
		for k in polygon.size():
			var pa := vertices[polygon[k]]
			var pb := vertices[polygon[(k + 1) % polygon.size()]]
			var a := GSBotNavGeometry.vertex_key(pa)
			var b := GSBotNavGeometry.vertex_key(pb)
			var key := GSBotNavGeometry.edge_key(a, b)
			if _uses.get(key, 0) != 1:
				continue
			var along := pb - pa
			var out := Vector3(along.z, 0.0, -along.x).normalized()
			if out.dot(Vector3(pa.x - centre.x, 0.0, pa.z - centre.z)) < 0.0:
				out = -out
			var steps := maxi(1, int(along.length() / spacing))
			for s in steps:
				var rim := pa + along * ((float(s) + 0.5) / float(steps))
				if _buried(rim):
					continue
				var found := _drop_landing(rim, out, min_drop, max_drop, reaches, island_at(rim) if other_island else -2)
				if found == Vector3.INF or _buried(found):
					continue
				var cell := Vector4i(roundi(rim.x / spacing), roundi(rim.y), roundi(found.x / spacing), roundi(found.z / spacing))
				# per pair of islands: two floors a metre apart under one rim must not shadow each other
				var cell_key := [cell.x, cell.y / 3, cell.z, cell.w, island_at(rim), island_at(found)]
				if seen.has(cell_key):
					continue
				seen[cell_key] = true
				add_ride(rim, found, first_id + added, cost)
				added += 1
				if added >= limit:
					job["added"] = added
					return true
		i += 1
		if _past(until_usec):
			break
	job["i"] = i
	job["added"] = added
	return i >= count


func _step_stitches(job: Dictionary, until_usec: int) -> bool:
	var max_gap: float = job["max_gap"]
	var max_rise: float = job["max_rise"]
	var vertices := mesh.get_vertices()
	if int(job["stage"]) == 0:
		# fewer than two islands has nothing to join, whatever the rim holds
		if islands().size() < 2:
			return true
		job["stage"] = 1
		if _past(until_usec):
			return false
	if int(job["stage"]) == 1:
		if not _count_uses(until_usec):
			return false
		job["stage"] = 2
		job["grid"] = {}
		job["rim"] = []
		job["i"] = 0
		if _past(until_usec):
			return false
	if int(job["stage"]) == 2:
		if not _stitch_rim(job, until_usec, vertices, max_gap):
			return false
		job["stage"] = 3
		job["best"] = {}
		job["i"] = 0
		if _past(until_usec):
			return false
	if int(job["stage"]) == 3:
		if not _stitch_best(job, until_usec, max_gap, max_rise):
			return false
		job["stage"] = 4
		job["pairs"] = (job["best"] as Dictionary).keys()
		job["i"] = 0
		job.erase("grid")
		job.erase("rim")
		if _past(until_usec):
			return false
	var best_of: Dictionary = job["best"]
	var pairs: Array = job["pairs"]
	var space: PhysicsDirectSpaceState3D = null
	if _root != null and is_instance_valid(_root) and _root.is_inside_tree():
		space = _root.get_world_3d().direct_space_state
	var first_id: int = job["first_id"]
	var limit: int = job["limit"]
	var cost: float = job["cost"]
	var added: int = job["added"]
	var chest := Vector3(0.0, 0.9, 0.0)
	var n: int = job["i"]
	while n < pairs.size():
		var pair: Vector2i = pairs[n]
		n += 1
		# the closest pair may lie through a wall (a doorway's jamb); the next closest that sees across is the link
		var v := Vector3.INF
		var w := Vector3.INF
		for candidate: Array in best_of[pair]:
			if space == null or space.intersect_ray(PhysicsRayQueryParameters3D.create(candidate[0] + chest, candidate[1] + chest)).is_empty():
				v = candidate[0]
				w = candidate[1]
				break
		if v != Vector3.INF and not _buried(v) and not _buried(w):
			var low := v if v.y <= w.y else w
			var high := w if v.y <= w.y else v
			add_ride(high, low, first_id + added, cost)
			added += 1
			if high.y - low.y <= max_rise:
				add_ride(low, high, first_id + added, cost)
				added += 1
			if added >= limit:
				job["added"] = added
				return true
		if _past(until_usec):
			break
	job["i"] = n
	job["added"] = added
	return n >= pairs.size()


## Stage 2 of [method _step_stitches]: the open-border points of every polygon, gridded by [param max_gap]. True when every polygon is seen.
func _stitch_rim(job: Dictionary, until_usec: int, vertices: PackedVector3Array, max_gap: float) -> bool:
	var grid: Dictionary = job["grid"]
	var rim: Array = job["rim"]
	var count := mesh.get_polygon_count()
	var i: int = job["i"]
	while i < count:
		var polygon := mesh.get_polygon(i)
		var owner := _island_of[i] if i < _island_of.size() else -1
		for k in polygon.size():
			var pa := vertices[polygon[k]]
			var pb := vertices[polygon[(k + 1) % polygon.size()]]
			if _uses.get(GSBotNavGeometry.edge_key(GSBotNavGeometry.vertex_key(pa), GSBotNavGeometry.vertex_key(pb)), 0) != 1:
				continue
			# two points per rim edge, so a long wall of mesh still has candidates along it
			for p: Vector3 in [pa, pa.lerp(pb, 0.5)]:
				var cell := Vector2i(floori(p.x / max_gap), floori(p.z / max_gap))
				if not grid.has(cell):
					grid[cell] = []
				grid[cell].append(rim.size())
				rim.append([p, owner])
		i += 1
		if i % 64 == 0 and _past(until_usec):
			break
	job["i"] = i
	return i >= count


## Stage 3 of [method _step_stitches]: the closest candidate pairs of rim points per pair of islands. True when every rim point is seen.
func _stitch_best(job: Dictionary, until_usec: int, max_gap: float, max_rise: float) -> bool:
	var grid: Dictionary = job["grid"]
	var rim: Array = job["rim"]
	var best: Dictionary = job["best"]
	var i: int = job["i"]
	while i < rim.size():
		var entry: Array = rim[i]
		var v: Vector3 = entry[0]
		var a: int = entry[1]
		var cv := Vector2i(floori(v.x / max_gap), floori(v.z / max_gap))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				for j: int in grid.get(Vector2i(cv.x + dx, cv.y + dz), []):
					var w: Vector3 = rim[j][0]
					var b: int = rim[j][1]
					if b == a or a < 0 or b < 0 or a > b:
						continue
					var flat := Vector2(v.x - w.x, v.z - w.z).length()
					var dy := absf(v.y - w.y)
					if flat > max_gap * (1.0 - 0.5 * minf(dy / max_rise, 1.0)) or dy > 24.0 or (dy > max_rise and flat > 0.5):
						continue
					var score := flat + dy
					var pair := Vector2i(a, b)
					if not best.has(pair):
						best[pair] = []
					var kept: Array = best[pair]
					kept.append([v, w, score])
					kept.sort_custom(func(x: Array, y: Array) -> bool: return x[2] < y[2])
					if kept.size() > STITCH_CANDIDATES:
						kept.resize(STITCH_CANDIDATES)
		i += 1
		if i % 64 == 0 and _past(until_usec):
			break
	job["i"] = i
	return i >= rim.size()


## Whether a point a little above [param feet] lies inside a solid body: a scrap of mesh a bake leaves inside a wall's footprint, which no body stands on or reaches.
func _buried(feet: Vector3) -> bool:
	if _root == null or not is_instance_valid(_root) or not _root.is_inside_tree():
		return false
	var query := PhysicsPointQueryParameters3D.new()
	query.position = feet + Vector3(0.0, 0.5, 0.0)
	return not _root.get_world_3d().direct_space_state.intersect_point(query, 1).is_empty()


func _clear_fall(rim: Vector3, column: Vector3, landing: Vector3) -> bool:
	if _root == null or not is_instance_valid(_root) or not _root.is_inside_tree():
		return true
	var space := _root.get_world_3d().direct_space_state
	var up := Vector3(0.0, 1.0, 0.0)
	for leg in [[rim + up, column + up], [column + up, landing + up * 0.6], [rim + up * 0.3, column + up * 0.3]]:
		var query := PhysicsRayQueryParameters3D.create(leg[0], leg[1])
		if not space.intersect_ray(query).is_empty():
			return false
	return true


func _drop_landing(rim: Vector3, out: Vector3, min_drop: float, max_drop: float, reaches: Array, not_island: int = -2) -> Vector3:
	var space: PhysicsDirectSpaceState3D = null
	if _root != null and is_instance_valid(_root) and _root.is_inside_tree():
		space = _root.get_world_3d().direct_space_state
	for reach: float in reaches:
		var column: Vector3 = rim + out * reach
		if space != null:
			# the ground under the column, however much mesh lies nearer than it
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(rim + Vector3(0.0, 1.0, 0.0), column + Vector3(0.0, 1.0, 0.0))).is_empty():
				continue
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(column + Vector3(0.0, 1.0, 0.0), column + Vector3(0.0, -max_drop - 1.0, 0.0)))
			if hit.is_empty():
				continue
			var ground: Vector3 = hit["position"]
			var spot := NavigationServer3D.map_get_closest_point(_map, ground)
			# the nearest mesh can lie behind a wall the column stopped short of
			var chest := Vector3(0.0, 0.5, 0.0)
			if not space.intersect_ray(PhysicsRayQueryParameters3D.create(ground + chest, spot + chest)).is_empty():
				continue
			if rim.y - spot.y >= min_drop and rim.y - spot.y <= max_drop and Vector2(spot.x - ground.x, spot.z - ground.z).length() < 0.6 \
					and absf(spot.y - ground.y) < 0.8 and (not_island == -2 or island_at(spot) != not_island):
				return spot
			continue
		for depth in [min_drop + 0.3, 3.0, 6.0, 10.0, 16.0, 24.0]:
			if depth > max_drop:
				break
			var probe := column + Vector3(0.0, -depth, 0.0)
			var near := NavigationServer3D.map_get_closest_point(_map, probe)
			if rim.y - near.y >= min_drop and rim.y - near.y <= max_drop \
					and Vector2(near.x - column.x, near.z - column.z).length() < 0.6 and _clear_fall(rim, column, near):
				return near
	return Vector3.INF
