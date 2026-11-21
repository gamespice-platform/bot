class_name GSBotNavTiles
extends RefCounted

## A navigation bake cut into square tiles and joined into one mesh, for a map [GSBotNav] could not bake in one grid.
##
## Godot's baker refuses a bake whose cell grid is over 30 million cells ("suspiciously big") while
## `navigation/baking/use_crash_prevention_checks` is on, and one Recast poly mesh holds under 65535
## vertices; a wider cell is no answer (rp_southside at one baked nothing). So such a map is baked at
## the same cell in tiles, each with a border of cells around it the way Recast's tiled meshes are, and
## the tiles are joined: the vertices two tiles share on a line are welded, and a tile's edge along
## the line is split at the other side's vertices, so every seam is a shared edge, the navigation
## server connects it, and a path crosses it.
##
## Nothing is clamped: a size the engine would refuse, or a negative one, is a failed [GSResult] with the reason.
## [GSBotNav] owns one of these; a game sets the bake's agent key `tile`, it names this class never.

const CHANNEL := "gs.bot.nav"

## The engine's refusal line (nav_mesh_generator_3d.cpp, `use_crash_prevention_checks`): a fact of the engine, not a limit of ours.
const ENGINE_MAX_CELLS := 30000000

## The tile side, metres, when the map is over the budget and the asked size is 0 (auto).
const AUTO_TILE := 128.0

## Metres within which a seam vertex counts as an edge's own end, not a point inside it to split at.
const SPLIT_EPSILON := 0.0001

## Cells of border past the agent's radius around each tile (Recast's own advice is 3).
const BORDER_PAD := 3

## The mesh whose settings every tile copies, and which receives the joined result.
var mesh: NavigationMesh = null

## The tile side in use, metres (0 when the bake is one grid), and the tile boxes (no border) on the grid.
var side_m: float = 0.0
var boxes: Array[AABB] = []

var _origin := Vector3.ZERO
var _counts := Vector2i.ZERO


## How many tiles the plan has (0 for one grid).
func count() -> int:
	return boxes.size()


## Forgets the plan.
func reset() -> void:
	boxes.clear()
	side_m = 0.0


## Recast's grid (rcCalcGridSize) for [param size] at [param cell].
static func grid_cells(size: Vector3, cell: float) -> int:
	return int(size.x / cell + 0.5) * int(size.z / cell + 0.5)


## The border around a tile, metres: the radius in whole cells plus [constant BORDER_PAD].
func border() -> float:
	return (ceilf(mesh.agent_radius / mesh.cell_size - 0.001) + BORDER_PAD) * mesh.cell_size


## Plans the tiles for [param source] baked with [param target]'s settings. [param asked] is the tile side in metres:
## 0 = auto (one grid while the map is within the engine's limit, else [constant AUTO_TILE] tiles), above 0 always tiles.
## Success holds the tile count (0 for one grid); a size the engine would refuse, a negative one or one under four borders fails.
func plan(source: NavigationMeshSourceGeometryData3D, target: NavigationMesh, asked: float) -> GSResult:
	reset()
	mesh = target
	var engine_checks := bool(ProjectSettings.get_setting("navigation/baking/use_crash_prevention_checks", true))
	var bounds := source.get_bounds()
	var cell := mesh.cell_size

	if is_nan(asked) or asked < 0.0:
		return GSResult.fail(GSError.CODE_INVALID, "the bake's tile is %s; it is metres, 0 for auto" % str(asked))

	var side := asked

	if side == 0.0:
		if not engine_checks or grid_cells(bounds.size, cell) <= ENGINE_MAX_CELLS:
			return GSResult.success(0)
		side = AUTO_TILE

	side = ceilf(side / cell - 0.001) * cell
	var pad := border()

	if side < 4.0 * pad:
		return GSResult.fail(GSError.CODE_INVALID,
			"the bake's tile %.2f m is under four times the %.2f m border each tile bakes around it; raise it or use 0 for auto" % [side, pad])

	var with_border := Vector3(side + 2.0 * pad, 0.0, side + 2.0 * pad)

	if engine_checks and grid_cells(with_border, cell) > ENGINE_MAX_CELLS:
		return GSResult.fail(GSError.CODE_INVALID,
			"the bake's tile %.0f m needs %d cells a tile, over the engine's %d while navigation/baking/use_crash_prevention_checks is on; lower it or use 0 for auto" % [
				side, grid_cells(with_border, cell), ENGINE_MAX_CELLS])

	# The tiles sit on the cell grid, so the two sides of a seam put their vertices on the same line.
	_origin = Vector3(floorf(bounds.position.x / cell) * cell, bounds.position.y - 1.0, floorf(bounds.position.z / cell) * cell)
	_counts = Vector2i(maxi(int(ceilf((bounds.end.x - _origin.x) / side)), 1), maxi(int(ceilf((bounds.end.z - _origin.z) / side)), 1))
	var height := bounds.size.y + 2.0

	for tz in _counts.y:
		for tx in _counts.x:
			boxes.append(AABB(_origin + Vector3(tx * side, 0.0, tz * side), Vector3(side, height, side)))

	side_m = side
	GSLog.info(CHANNEL, "navigation bake: the map is baked in tiles", {
		"extent": "%.0fx%.0f m" % [bounds.size.x, bounds.size.z], "cells": grid_cells(bounds.size, cell),
		"tile": snappedf(side, 0.001), "tiles": "%dx%d" % [_counts.x, _counts.y], "border": snappedf(pad, 0.001)})
	return GSResult.success(boxes.size())


## A copy of the mesh's settings that bakes [param box] and a border round it.
func tile_mesh(box: AABB) -> NavigationMesh:
	var part: NavigationMesh = mesh.duplicate()
	var pad := border()
	part.border_size = pad
	part.filter_baking_aabb = AABB(box.position - Vector3(pad, 0.0, pad), box.size + Vector3(2.0 * pad, 0.0, 2.0 * pad))
	return part


## Joins the baked [param parts] into the mesh (its polygons replaced); returns how many triangles the seams split.
func join(parts: Array[NavigationMesh]) -> int:
	var began := Time.get_ticks_usec()
	var vertices := PackedVector3Array()
	var tris := PackedInt32Array()

	for part in parts:
		var base := vertices.size()
		vertices.append_array(part.get_vertices())

		for p in part.get_polygon_count():
			var polygon := part.get_polygon(p)
			for k in range(1, polygon.size() - 1):
				tris.append(base + polygon[0])
				tris.append(base + polygon[k])
				tris.append(base + polygon[k + 1])

	var seams := _stitch(vertices, tris)
	var used := PackedInt32Array()
	used.resize(vertices.size())
	used.fill(-1)
	var kept := PackedVector3Array()

	for i in tris.size():
		var v := tris[i]
		if used[v] < 0:
			used[v] = kept.size()
			kept.append(vertices[v])
		tris[i] = used[v]

	mesh.clear_polygons()
	mesh.vertices = kept

	for t in range(0, tris.size(), 3):
		mesh.add_polygon(PackedInt32Array([tris[t], tris[t + 1], tris[t + 2]]))

	GSLog.info(CHANNEL, "navigation bake: tiles joined", {"tiles": parts.size(), "polygons": tris.size() / 3,
		"vertices": kept.size(), "seam_splits": seams, "join_ms": snappedf((Time.get_ticks_usec() - began) / 1000.0, 0.1)})
	return seams


## Welds the vertices on the tile lines and splits each seam edge at the other side's vertices, so
## the tiles share their edges. Returns how many triangles were split.
func _stitch(vertices: PackedVector3Array, tris: PackedInt32Array) -> int:
	var side := side_m
	var near := mesh.cell_size * 0.25
	var rise := maxf(mesh.agent_max_climb, mesh.cell_height * 2.0)
	var count := vertices.size()
	var rep := PackedInt32Array()
	rep.resize(count)
	# Per vertex, the x line and z line it is on, -1 for none.
	var on_x := PackedInt32Array()
	var on_z := PackedInt32Array()
	on_x.resize(count)
	on_z.resize(count)
	var lines_x: Dictionary = {}
	var lines_z: Dictionary = {}

	for i in count:
		rep[i] = i
		var v := vertices[i]
		on_x[i] = _line_of(v.x - _origin.x, side, near, _counts.x)
		on_z[i] = _line_of(v.z - _origin.z, side, near, _counts.y)
		if on_x[i] >= 0:
			lines_x.get_or_add(on_x[i], []).append(i)
		if on_z[i] >= 0:
			lines_z.get_or_add(on_z[i], []).append(i)

	# Weld: along each line, the vertices in one cell and at one height become one (a corner is on two lines).
	for line: int in lines_x:
		_weld(lines_x[line], vertices, rep, 2, mesh.cell_size, rise)

	for line: int in lines_z:
		_weld(lines_z[line], vertices, rep, 0, mesh.cell_size, rise)

	var sorted_x: Dictionary = {}
	var sorted_z: Dictionary = {}

	for line: int in lines_x:
		sorted_x[line] = _line_list(lines_x[line], vertices, rep, 2)

	for line: int in lines_z:
		sorted_z[line] = _line_list(lines_z[line], vertices, rep, 0)

	for i in tris.size():
		tris[i] = _root_of(rep, tris[i])

	return _split_edges(vertices, tris, on_x, on_z, sorted_x, sorted_z, rise)


func _split_edges(vertices: PackedVector3Array, tris: PackedInt32Array, on_x: PackedInt32Array, on_z: PackedInt32Array, sorted_x: Dictionary, sorted_z: Dictionary, rise: float) -> int:
	# Split: a triangle's edge along a line gains every vertex of the line strictly inside it at its height.
	var splits := 0
	var out := PackedInt32Array()
	var work: Array[PackedInt32Array] = []

	for t in range(0, tris.size(), 3):
		work.append(PackedInt32Array([tris[t], tris[t + 1], tris[t + 2]]))

	while not work.is_empty():
		var tri: PackedInt32Array = work.pop_back()
		var split := false

		# A sliver whose two corners were welded into one point has no floor left.
		if tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]:
			continue

		for e in 3:
			var a := tri[e]
			var b := tri[(e + 1) % 3]
			var c := tri[(e + 2) % 3]
			var inner := PackedInt32Array()

			if on_x[a] >= 0 and on_x[a] == on_x[b] and on_x[c] != on_x[a]:
				inner = _between(sorted_x.get(on_x[a], []), vertices, a, b, 2, rise)
			elif on_z[a] >= 0 and on_z[a] == on_z[b] and on_z[c] != on_z[a]:
				inner = _between(sorted_z.get(on_z[a], []), vertices, a, b, 0, rise)

			if inner.is_empty():
				continue

			var chain := PackedInt32Array([a])
			chain.append_array(inner)
			chain.append(b)
			for k in chain.size() - 1:
				work.append(PackedInt32Array([chain[k], chain[k + 1], c]))
			splits += 1
			split = true
			break

		if not split:
			out.append_array(tri)

	tris.resize(out.size())
	for i in out.size():
		tris[i] = out[i]

	return splits


## The tile line [param offset] (from the grid's origin) is on, -1 for none or the map's outer edge.
static func _line_of(offset: float, side: float, near: float, tiles: int) -> int:
	var line := roundi(offset / side)
	return line if line > 0 and line < tiles and absf(offset - line * side) <= near else -1


static func _root_of(rep: PackedInt32Array, i: int) -> int:
	while rep[i] != i:
		i = rep[i]
	return i


## Welds the [param members] of one line: those in one [param cell] along axis [param along] and within
## [param rise] of each other's height become one. The cell is the navigation map's own edge-merge
## cell (its cell size), so no two seam vertices are left for the map to read as one point: the
## detail mesh puts its edge samples at different places on the two sides of a seam, and two of
## them a few centimetres apart would otherwise be "more than 2 edges in one rasterization space".
static func _weld(members: Array, vertices: PackedVector3Array, rep: PackedInt32Array, along: int, cell: float, rise: float) -> void:
	members.sort_custom(func(p: int, q: int) -> bool:
		var cp := floori(vertices[p][along] / cell)
		var cq := floori(vertices[q][along] / cell)
		return cp < cq or (cp == cq and vertices[p].y < vertices[q].y))

	var at := 0

	while at < members.size():
		# The run of vertices in one cell of the line, low to high.
		var run_end := at + 1
		var run_cell := floori(vertices[members[at]][along] / cell)
		while run_end < members.size() and floori(vertices[members[run_end]][along] / cell) == run_cell:
			run_end += 1

		var first: int = members[at]

		for k in range(at + 1, run_end):
			var i: int = members[k]
			if absf(vertices[i].y - vertices[first].y) > rise:
				first = i
				continue
			var ri := _root_of(rep, i)
			var rf := _root_of(rep, first)
			if ri != rf:
				rep[ri] = rf

		at = run_end


## The welded vertices of a line, each once, sorted along axis [param along].
static func _line_list(members: Array, vertices: PackedVector3Array, rep: PackedInt32Array, along: int) -> Array:
	var seen: Dictionary = {}
	for i: int in members:
		seen[_root_of(rep, i)] = true
	var unique: Array = seen.keys()
	unique.sort_custom(func(p: int, q: int) -> bool: return vertices[p][along] < vertices[q][along])
	return unique


## The welded vertices of a line strictly between [param a] and [param b] at the edge's height, in order from a.
static func _between(line: Array, vertices: PackedVector3Array, a: int, b: int, along: int, rise: float) -> PackedInt32Array:
	var found := PackedInt32Array()
	var from: float = vertices[a][along]
	var to: float = vertices[b][along]
	var lo := minf(from, to)
	var hi := maxf(from, to)

	if hi - lo <= 2.0 * SPLIT_EPSILON:
		return found

	# First vertex past lo (binary search; the line is sorted along).
	var left := 0
	var right := line.size()
	while left < right:
		var mid := (left + right) >> 1
		if vertices[line[mid]][along] <= lo + SPLIT_EPSILON:
			left = mid + 1
		else:
			right = mid

	for k in range(left, line.size()):
		var m: int = line[k]
		var d: float = vertices[m][along]
		if d >= hi - SPLIT_EPSILON:
			break
		if m == a or m == b:
			continue
		var y := lerpf(vertices[a].y, vertices[b].y, (d - from) / (to - from))
		if absf(vertices[m].y - y) <= rise:
			found.append(m)

	if from > to:
		found.reverse()

	return found
