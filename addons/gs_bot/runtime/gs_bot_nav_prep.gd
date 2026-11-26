extends RefCounted

## What [GSBotNav]'s edge searches (drops, hops, stitches) read of one bake, worked out a slice at a time:
## the polygons per edge (an open border is used once), the islands ([method GSBotNav.islands], the same
## dictionaries [method GSBotNavGeometry.islands] builds) and the polygon grid of [method GSBotNav.polygon_at].
## Before this, the islands and the grid were built in one go on the first slice, 25 ms on a converted map.
## [member native] hands the edge passes to GameSpice Sim's [code]GSSimNavJoin[/code] when the library is loaded;
## its answers are the script's (GameSpice Bot's selftest compares them).
##
## Preloaded by [GSBotNav], no class name.

const NATIVE_CLASS := &"GSSimNavJoin"
## Work done between two looks at the clock, per stage.
const POLYGONS_PER_LOOK := 256
const SLOTS_PER_LOOK := 4096

enum Stage { FETCH, KEYS, EDGES, USES, ROOTS, GROUPS, SUMMARY, ISLANDS, GRID, DONE }

## Whether the edge passes may run natively (when the library is loaded).
var native: bool = true
## The bake this is of: [method GSBotNav.clear] or a new bake makes it stale.
var generation: int = -1
var mesh: NavigationMesh
var stage: int = Stage.FETCH
## Whether the edge passes ran natively.
var ran_native: bool = false

## Every polygon's corners end to end; polygon i is polys[offsets[i]] up to polys[offsets[i + 1]].
var polys := PackedInt32Array()
var offsets := PackedInt32Array([0])
## Per corner slot (offsets[i] + k): the polygon sides on the edge from corner k to corner k + 1.
var uses := PackedInt32Array()
## Per polygon: the lowest polygon index of its island.
var roots := PackedInt32Array()

var _vertices := PackedVector3Array()
var _count := 0
var _at := 0
var _canon: Dictionary = {}
var _vid := PackedInt32Array()
var _edge_of: Dictionary = {}
var _slot_edge := PackedInt32Array()
var _edge_owner := PackedInt32Array()
var _edge_count := PackedInt32Array()
var _parent := PackedInt32Array()
var _group_of: Dictionary = {}
var _gid := PackedInt32Array()
var _starts := PackedInt32Array()
var _cursor := PackedInt32Array()
var _order := PackedInt32Array()
var _area := PackedFloat64Array()
var _weighted := PackedVector3Array()
var _bounds: Array[AABB] = []
var _seen := PackedByteArray()
var _islands: Array[Dictionary] = []
var _island_of := PackedInt32Array()
var _grid: Dictionary = {}


func _init(of_mesh: NavigationMesh, of_generation: int, use_native: bool) -> void:
	mesh = of_mesh
	generation = of_generation
	native = use_native
	_vertices = mesh.get_vertices()
	_count = mesh.get_polygon_count()


## Whether this is of [param of_mesh] as baked in [param of_generation] (a mesh edited since has other counts).
func is_of(of_mesh: NavigationMesh, of_generation: int) -> bool:
	return mesh == of_mesh and generation == of_generation and _count == of_mesh.get_polygon_count() \
			and _vertices.size() == of_mesh.get_vertices().size()


func is_done() -> bool:
	return stage == Stage.DONE


## Works until done (true, and [param nav]'s islands and polygon grid are this bake's) or
## [param until_usec] (false; 0 runs it out).
func step(nav: Object, until_usec: int) -> bool:
	while stage != Stage.DONE:
		var finished := false
		match stage:
			Stage.FETCH: finished = _fetch(until_usec)
			Stage.KEYS: finished = _keys(until_usec)
			Stage.EDGES: finished = _edges(until_usec)
			Stage.USES: finished = _uses_pass(until_usec)
			Stage.ROOTS: finished = _roots(until_usec)
			Stage.GROUPS: finished = _groups(until_usec)
			Stage.SUMMARY: finished = _summary(until_usec)
			Stage.ISLANDS: finished = _make_islands()
			Stage.GRID: finished = _grid_pass(until_usec)
		if not finished:
			return false
		_at = 0
		stage += 1
		if stage == Stage.KEYS and native and _native_topology():
			stage = Stage.GROUPS
		if stage == Stage.DONE:
			_install(nav)
			return true
		if _past(until_usec):
			return false
	return true


static func _past(until_usec: int) -> bool:
	return until_usec > 0 and Time.get_ticks_usec() >= until_usec


func _fetch(until_usec: int) -> bool:
	while _at < _count:
		polys.append_array(mesh.get_polygon(_at))
		offsets.append(polys.size())
		_at += 1
		if _at % POLYGONS_PER_LOOK == 0 and _past(until_usec):
			return false
	return true


func _native_topology() -> bool:
	if not ClassDB.class_exists(NATIVE_CLASS):
		return false
	var answer: Dictionary = ClassDB.instantiate(NATIVE_CLASS).call(&"topology", _vertices, polys, offsets)
	if not answer.has("roots"):
		return false
	roots = answer["roots"]
	uses = answer["uses"]
	ran_native = true
	return true


## Each vertex's first vertex with the same centimetre key ([method GSBotNavGeometry.vertex_key]).
func _keys(until_usec: int) -> bool:
	if _at == 0:
		_vid.resize(_vertices.size())
	while _at < _vertices.size():
		var key := GSBotNavGeometry.vertex_key(_vertices[_at])
		var first: int = _canon.get(key, -1)
		if first < 0:
			_canon[key] = _at
			first = _at
		_vid[_at] = first
		_at += 1
		if _at % SLOTS_PER_LOOK == 0 and _past(until_usec):
			return false
	_canon.clear()
	return true


## The edges (pairs of keyed vertices, either way round), the sides on each, and the islands' union-find.
func _edges(until_usec: int) -> bool:
	if _at == 0:
		_slot_edge.resize(polys.size())
		_parent.resize(_count)
		for i in _count:
			_parent[i] = i
	while _at < _count:
		var start := offsets[_at]
		var n := offsets[_at + 1] - start
		for k in n:
			var a := _vid[polys[start + k]]
			var b := _vid[polys[start + (k + 1) % n]]
			var key := Vector2i(mini(a, b), maxi(a, b))
			var e: int = _edge_of.get(key, -1)
			if e < 0:
				e = _edge_count.size()
				_edge_of[key] = e
				_edge_owner.append(_at)
				_edge_count.append(1)
			else:
				_edge_count[e] += 1
				GSBotNavGeometry._union(_parent, _at, _edge_owner[e])
			_slot_edge[start + k] = e
		_at += 1
		if _at % POLYGONS_PER_LOOK == 0 and _past(until_usec):
			return false
	_edge_of.clear()
	return true


func _uses_pass(until_usec: int) -> bool:
	if _at == 0:
		uses.resize(polys.size())
	while _at < polys.size():
		uses[_at] = _edge_count[_slot_edge[_at]]
		_at += 1
		if _at % SLOTS_PER_LOOK == 0 and _past(until_usec):
			return false
	return true


func _roots(until_usec: int) -> bool:
	if _at == 0:
		roots.resize(_count)
	while _at < _count:
		roots[_at] = GSBotNavGeometry._find(_parent, _at)
		_at += 1
		if _at % SLOTS_PER_LOOK == 0 and _past(until_usec):
			return false
	return true


## Each polygon's island in the order [method GSBotNavGeometry.islands] meets them (its root, the lowest
## polygon, ascending), and where each island's polygons start in _order.
func _groups(until_usec: int) -> bool:
	if _at == 0:
		_gid.resize(_count)
	while _at < _count:
		var root := roots[_at]
		var g: int = _group_of.get(root, -1)
		if g < 0:
			g = _starts.size()
			_group_of[root] = g
			_starts.append(0)
		_gid[_at] = g
		_starts[g] += 1
		_at += 1
		if _at % SLOTS_PER_LOOK == 0 and _past(until_usec):
			return false
	var groups := _starts.size()
	var total := 0
	for g in groups:
		var size := _starts[g]
		_starts[g] = total
		total += size
	_starts.append(total)
	_cursor = _starts.slice(0, groups)
	_order.resize(_count)
	_area.resize(groups)
	_weighted.resize(groups)
	_bounds.resize(groups)
	_seen.resize(groups)
	_group_of.clear()
	return true


## [method GSBotNavGeometry._summarise] of every island at once, each polygon added in the same order.
func _summary(until_usec: int) -> bool:
	while _at < _count:
		var g := _gid[_at]
		_order[_cursor[g]] = _at
		_cursor[g] += 1
		var polygon := polys.slice(offsets[_at], offsets[_at + 1])
		var a := GSBotNavGeometry._polygon_area(polygon, _vertices)
		_area[g] += a
		var centre := Vector3.ZERO
		var bounds := _bounds[g]
		for v in polygon:
			centre += _vertices[v]
			if _seen[g] == 0:
				bounds = AABB(_vertices[v], Vector3.ZERO)
				_seen[g] = 1
			else:
				bounds = bounds.expand(_vertices[v])
		_bounds[g] = bounds
		_weighted[g] += centre / float(polygon.size()) * a
		_at += 1
		if _at % POLYGONS_PER_LOOK == 0 and _past(until_usec):
			return false
	return true


func _make_islands() -> bool:
	for g in _area.size():
		var area := _area[g]
		_islands.append({"area": area, "polygons": _order.slice(_starts[g], _starts[g + 1]), "bounds": _bounds[g],
				"centre": _weighted[g] / maxf(area, 0.0001)})
	_islands.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["area"]) > float(y["area"]))
	_island_of.resize(_count)
	for index in _islands.size():
		_islands[index]["index"] = index
		for i: int in _islands[index]["polygons"]:
			_island_of[i] = index
	return true


## [method GSBotNav._build_poly_grid], a slice at a time.
func _grid_pass(until_usec: int) -> bool:
	var cell := GSBotNavGeometry.ISLAND_CELL
	while _at < _count:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for s in range(offsets[_at], offsets[_at + 1]):
			var v := _vertices[polys[s]]
			lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z))
			hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
		# Padded, because height_in accepts a point a little outside the triangle.
		for cx in range(floori((lo.x - 1.0) / cell), floori((hi.x + 1.0) / cell) + 1):
			for cz in range(floori((lo.y - 1.0) / cell), floori((hi.y + 1.0) / cell) + 1):
				var key := Vector2i(cx, cz)
				var bucket: PackedInt32Array = _grid.get(key, PackedInt32Array())
				bucket.append(_at)
				_grid[key] = bucket
		_at += 1
		if _at % POLYGONS_PER_LOOK == 0 and _past(until_usec):
			return false
	return true


func _install(nav: Object) -> void:
	nav.set(&"_islands", _islands)
	nav.set(&"_island_of", _island_of)
	nav.set(&"_poly_grid", _grid)
	nav.set(&"_poly_grid_for", Vector2i(_vertices.size(), _count))
	_vid = PackedInt32Array()
	_slot_edge = PackedInt32Array()
	_edge_owner = PackedInt32Array()
	_edge_count = PackedInt32Array()
	_parent = PackedInt32Array()
	_gid = PackedInt32Array()
	_cursor = PackedInt32Array()
	_islands = []
	_grid = {}
