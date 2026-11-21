extends RefCounted

## [GSBotSurfPilot]'s cache: the remembered ride states, the lookup of the nearest one, and the actions.
## Split out of dot_bot_surf_pilot.gd for file size; nothing outside the pilot names this script.

# No log channel: the game that rides says what happened.


## The actions, by index: [angle off the heading in degrees (+ is left), jump]. NAN is no movement key at all. Index 0 is coasting. Kept short on purpose: every action is a branch of the planner's search and a candidate in the veto. Relative to the velocity, because the same action means the same thing on the left face of a ramp at 600 u/s and at 900 u/s, which is what lets one recorded action be reused from a nearby state.
## [b]Two more are anchored to the ride, not the velocity[/b] (index [constant ANCHORED_FROM] on): a wish square to the course's reference yaw, either side. A wish square to the velocity turns the velocity with it, so held for long it circles off a ramp; a surfer holds the face with a wish that stays put while the velocity swings under it.
## On game-airdrift's stage the beam made that by alternating; down game-fatal-contact's combat surf ramps, whose first metres are nearly upright, it never did, and only a held world-fixed wish landed. Appended, so a cache's action numbers keep their meaning.
const ACTIONS: Array = [
	[NAN, false],
	[-90.0, false], [-60.0, false], [-30.0, false], [0.0, false],
	[30.0, false], [60.0, false], [90.0, false],
	[0.0, true],
	[-90.0, false], [90.0, false],
]

## Actions from this index are anchored to the reference yaw, not the heading.
const ANCHORED_FROM := 9

## Below this horizontal speed (m/s, about 60 genre u/s) the velocity has no direction worth
## steering by, and an action is taken relative to the reference yaw instead.
const HEADING_SPEED := 1.143

## Seconds of velocity weighed against one metre of position in the nearest-state lookup.
const VELOCITY_SECONDS := 0.25
## Grid cell for the lookup, metres (128 genre units).
const CELL := 2.4384
## The far lookup's grid: a cell this many CELLs wide, and the rings of cells it reads at most.
const COARSE_CELLS := 4
const COARSE_RINGS := 3
## Further out than the rings reach, every this-many-th entry is looked at: such a state is
## falling past the ramp, and its action is a guess whichever entry it comes from.
const SPARSE_STRIDE := 16
## Floats per entry: x, y, z, vx, vy, vz, action.
const STRIDE := 7

## How far (metres, and m/s) the real state may be from the forecast and still be it.
const FORECAST_SLACK := 0.01
## Simulator steps a veto spends in all (eight futures), for its latency estimate.
const VETO_STEPS := 2000
## The fewest ticks between two fresh forecasts. A bot whose game turns its keys for its own view
## walks off the forecast on the ground every tick (a backward key is slower there), and a fresh
## 192-tick forecast every tick was half a core (game-fatal-contact).
const RESYNC_GAP := 16

var entries: PackedFloat32Array = PackedFloat32Array()
## Per entry: the index one past the last entry of its ride.
var _ride_end: PackedInt32Array = PackedInt32Array()
## Cell (Vector3i) -> PackedInt32Array of entry indices.
var _grid: Dictionary = {}
## The same for a state far from every ride: a coarser grid.
var _coarse: Dictionary = {}
## Cells with an entry within two cells of them: a state in any other is far from every ride, and
## goes straight to the coarse grid instead of opening 124 empty cells to find that out.
var _near: Dictionary = {}
## Cell -> [ring 1 boxes, ring 1 buckets, ring 2 boxes, ring 2 buckets]: the cell's neighbours that hold entries, in the order [method nearest] opens them, with each one's lower corner.
## Filled as states ask: most of the 124 neighbours of a cell are empty, and finding that out a lookup at a time was a third of the lookup.
var _rings: Dictionary = {}
## Coarse cell -> [shell 0 boxes, shell 0 buckets, shell 1 ...]: the same for the coarse grid.
var _shells: Dictionary = {}
var _sparse: PackedInt32Array = PackedInt32Array()
var reference_yaw: float = 0.0

# The cache.

## Builds the lookup from [param data] (a cache file's ride entry): `entries` as rows of
## `[x, y, z, vx, vy, vz, action]` in units of [param metres_per_unit] metres, `lengths` (entries
## per ride), `reference_yaw`.
func load_stage(data: Dictionary, metres_per_unit: float = 1.0) -> void:
	var rides := PackedFloat32Array()
	for row: Variant in data.get("entries", []):
		var r: Array = row
		rides.append_array([float(r[0]) * metres_per_unit, float(r[1]) * metres_per_unit, float(r[2]) * metres_per_unit,
			float(r[3]) * metres_per_unit, float(r[4]) * metres_per_unit, float(r[5]) * metres_per_unit, float(r[6])])
	var lengths := PackedInt32Array()
	for n: Variant in data.get("lengths", []):
		lengths.append(int(n))
	load_entries(rides, lengths, float(data.get("reference_yaw", 0.0)))


## Builds the lookup from rides in metres (the planner's), [param lengths] entries each.
func load_entries(rides: PackedFloat32Array, lengths: PackedInt32Array, yaw: float) -> void:
	# A copy: packed arrays are shared by reference, and the planner keeps appending to the one it
	# hands in, which left the ride ends short of the entries (game-dev/docs/gdscript-hazards.md).
	entries = rides.duplicate()
	reference_yaw = yaw
	_ride_end = PackedInt32Array()
	var at := 0
	for n: int in lengths:
		for _i in range(n):
			_ride_end.append(at + n)
		at += n
	while _ride_end.size() < size():
		_ride_end.append(size())
	_grid = {}
	_coarse = {}
	for i in range(size()):
		var ckey := _coarse_cell(Vector3(entries[i * STRIDE], entries[i * STRIDE + 1], entries[i * STRIDE + 2]))
		if not _coarse.has(ckey):
			_coarse[ckey] = PackedInt32Array()
		_coarse[ckey].append(i)
	for i in range(size()):
		var key := _cell(Vector3(entries[i * STRIDE], entries[i * STRIDE + 1], entries[i * STRIDE + 2]))
		# Through the dictionary, never `(_grid[key] as PackedInt32Array).append(i)`: the cast
		# hands back a copy and the append is lost, which left game-airdrift's prototype with an
		# empty grid and a scan of every entry on every lookup (game-dev/docs/gdscript-hazards.md).
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		_grid[key].append(i)
	_sparse = PackedInt32Array()
	for i in range(0, size(), SPARSE_STRIDE):
		_sparse.append(i)
	_near = {}
	_rings = {}
	_shells = {}
	for key: Vector3i in _grid:
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				for dz in range(-2, 3):
					_near[key + Vector3i(dx, dy, dz)] = true


func size() -> int:
	return entries.size() / STRIDE


## A ride's entries as a cache file keeps them: rows in units of [param metres_per_unit] metres,
## to a tenth of a unit.
static func entries_to_rows(rides: PackedFloat32Array, metres_per_unit: float = 1.0) -> Array:
	var rows: Array = []
	var k := 1.0 / metres_per_unit
	for i in range(rides.size() / STRIDE):
		var o := i * STRIDE
		rows.append([snappedf(rides[o] * k, 0.1), snappedf(rides[o + 1] * k, 0.1), snappedf(rides[o + 2] * k, 0.1),
			snappedf(rides[o + 3] * k, 0.1), snappedf(rides[o + 4] * k, 0.1), snappedf(rides[o + 5] * k, 0.1), int(rides[o + 6])])
	return rows


# Actions.

## The direction the player is going, as a yaw: the velocity's, or [param reference] when there
## is too little of it to have one.
static func heading_of(state: Variant, reference: float) -> float:
	var v: Vector3 = state.velocity
	var flat := Vector2(v.x, v.z)
	if flat.length() < HEADING_SPEED:
		return reference
	return rad_to_deg(atan2(-flat.x, -flat.y))


## The yaw the wish of [param action] points along from [param state], or NAN for no key.
static func wish_yaw(action: int, state: Variant, reference: float) -> float:
	var angle: float = ACTIONS[action][0]
	if is_nan(angle):
		return NAN
	return (reference if action >= ANCHORED_FROM else heading_of(state, reference)) + angle


## The stick that points the wish along [param yaw] for a view at [param view_yaw]: (x right, y forward).
## With the view at yaw v, forward is (-sin v, -cos v) and right is (cos v, -sin v); a wish at angle r to the left of it is forward*cos(r) - right*sin(r), keys (-sin r, cos r).
## What lets a bot surf and aim elsewhere: the motor only reads the wish direction in the air.
static func move_toward(yaw: float, view_yaw: float) -> Vector2:
	if is_nan(yaw):
		return Vector2.ZERO
	var r := deg_to_rad(yaw - view_yaw)
	return Vector2(-sin(r), cos(r))


## Whether [param action] holds jump.
static func jumps(action: int) -> bool:
	return bool(ACTIONS[action][1])


## The command for [param action] from [param state] on [param p_sim], the view along the heading.
static func command_for(p_sim: Variant, action: int, state: Variant, reference: float) -> Object:
	var heading := heading_of(state, reference)
	var angle: float = ACTIONS[action][0]
	var move := Vector2.ZERO
	if not is_nan(angle):
		# The wish's angle from the view: from the heading, or, anchored, from the reference.
		var a := deg_to_rad(angle + (reference - heading if action >= ANCHORED_FROM else 0.0))
		move = Vector2(-sin(a), cos(a))
	return p_sim.command(heading, move, bool(ACTIONS[action][1]))


## The index of the entry nearest [param state], or -1 with no entries.
func nearest(state: Variant) -> int:
	var position: Vector3 = state.position
	var velocity: Vector3 = state.velocity
	_scan_best = -1
	_scan_d = INF
	var centre := _cell(position)
	# The bot's own cell first, so the best so far is a near one before any neighbour is opened.
	var own: Variant = _grid.get(centre)
	if own != null:
		_scan(own, position, velocity)
	if _near.has(centre):
		var rings: Variant = _rings.get(centre)
		if rings == null:
			rings = _rings_of(centre)
		var side := Vector3(CELL, CELL, CELL)
		for r in [0, 2]:
			var boxes: PackedVector3Array = rings[r]
			var buckets: Array = rings[r + 1]
			for k in boxes.size():
				# A cell no entry of which can beat the best so far is skipped: the distance is at least the position part, and that is at least the distance to the cell's box.
				# The answer is the one the full scan gives; on a ride line most of the 26 neighbours hold hundreds of entries and are this far away.
				# It was most of a forecast's cost (game-airdrift: 390 us a simulated tick, 90 of it the motor).
				var lo := boxes[k]
				if position.clamp(lo, lo + side).distance_squared_to(position) >= _scan_d:
					continue
				_scan(buckets[k], position, velocity)
			if _scan_best >= 0:
				return _scan_best
	# Nothing within two cells: the state is off every ride (a veto's candidate gone wrong, a bot knocked away).
	# A scan of every entry was a millisecond a call, and a veto asks for hundreds (game-fatal-contact: 4 to 12 ms a riding tick, nearly all of it this scan).
	# A coarse grid, ring by ring outward, skipping a cell whose box is further than the best so far and stopping when the next ring cannot hold a nearer entry: the nearest entry. Past the last ring a sample.
	var ccentre := _coarse_cell(position)
	var shells: Variant = _shells.get(ccentre)
	if shells == null:
		shells = _shells_of(ccentre)
	var width := CELL * COARSE_CELLS
	var side := Vector3(width, width, width)
	for radius in range(0, COARSE_RINGS):
		var reach := float(radius - 1) * width
		if _scan_best >= 0 and radius >= 2 and reach * reach >= _scan_d:
			break
		var boxes: PackedVector3Array = shells[radius * 2]
		var buckets: Array = shells[radius * 2 + 1]
		for k in boxes.size():
			var lo := boxes[k]
			if _scan_best >= 0 and position.clamp(lo, lo + side).distance_squared_to(position) >= _scan_d:
				continue
			_scan(buckets[k], position, velocity)
	if _scan_best >= 0:
		return _scan_best
	_scan(_sparse, position, velocity)
	return _scan_best


## The coarse cells around [param centre] that hold entries, shell 0 to COARSE_RINGS - 1, each
## in the order nearest opened them before: x, then y, then z, from -radius up.
func _shells_of(centre: Vector3i) -> Array:
	var shells: Array = []
	var width := CELL * COARSE_CELLS
	for radius in range(0, COARSE_RINGS):
		var boxes := PackedVector3Array()
		var buckets: Array = []
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					if absi(dx) < radius and absi(dy) < radius and absi(dz) < radius:
						continue
					var key := centre + Vector3i(dx, dy, dz)
					var bucket: Variant = _coarse.get(key)
					if bucket != null:
						boxes.append(Vector3(key) * width)
						buckets.append(bucket)
		shells.append(boxes)
		shells.append(buckets)
	_shells[centre] = shells
	return shells


## The neighbours of [param centre] that hold entries, ring 1 then ring 2, each in the order
## nearest opened them before: x, then y, then z, from -radius up.
func _rings_of(centre: Vector3i) -> Array:
	var rings: Array = []
	for radius in [1, 2]:
		var boxes := PackedVector3Array()
		var buckets: Array = []
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					if absi(dx) < radius and absi(dy) < radius and absi(dz) < radius:
						continue
					var key := centre + Vector3i(dx, dy, dz)
					var bucket: Variant = _grid.get(key)
					if bucket != null:
						boxes.append(Vector3(key) * CELL)
						buckets.append(bucket)
		rings.append(boxes)
		rings.append(buckets)
	_rings[centre] = rings
	return rings


var _scan_best: int = -1
var _scan_d: float = INF


## Folds the entries of [param bucket] into [member _scan_best]. One call a cell, with the
## distance written out: a call and two Vector3s an entry was most of a lookup's cost.
func _scan(bucket: PackedInt32Array, position: Vector3, velocity: Vector3) -> void:
	var e := entries
	var px := position.x
	var py := position.y
	var pz := position.z
	var vx := velocity.x
	var vy := velocity.y
	var vz := velocity.z
	var w := VELOCITY_SECONDS * VELOCITY_SECONDS
	var best := _scan_best
	var best_d := _scan_d
	for i: int in bucket:
		var o := i * STRIDE
		var dx := e[o] - px
		var dy := e[o + 1] - py
		var dz := e[o + 2] - pz
		var d := dx * dx + dy * dy + dz * dz
		if d >= best_d:
			continue
		dx = e[o + 3] - vx
		dy = e[o + 4] - vy
		dz = e[o + 5] - vz
		d += (dx * dx + dy * dy + dz * dz) * w
		if d < best_d:
			best_d = d
			best = i
	_scan_best = best
	_scan_d = best_d


func _distance(i: int, position: Vector3, velocity: Vector3) -> float:
	var o := i * STRIDE
	var dp := Vector3(entries[o], entries[o + 1], entries[o + 2]) - position
	var dv := (Vector3(entries[o + 3], entries[o + 4], entries[o + 5]) - velocity) * VELOCITY_SECONDS
	return dp.length_squared() + dv.length_squared()


## The squared distance from [param p] to cell [param key]'s box (0 inside it).
func _box_distance_squared(key: Vector3i, p: Vector3) -> float:
	var lo := Vector3(key) * CELL
	var hi := lo + Vector3(CELL, CELL, CELL)
	var q := p.clamp(lo, hi)
	return q.distance_squared_to(p)


func _coarse_cell(p: Vector3) -> Vector3i:
	var w := CELL * COARSE_CELLS
	return Vector3i(int(floor(p.x / w)), int(floor(p.y / w)), int(floor(p.z / w)))


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL)))
