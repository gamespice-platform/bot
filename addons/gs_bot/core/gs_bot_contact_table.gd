class_name GSBotContactTable
extends RefCounted

## Every body of one tick as packed columns, one row per body: what the brain's sight scan and the per-tick readers walk instead of one [GSBotContact] per body.
## A game fills it in one call (GameSpice Sim's [code]GSSimBotContacts.fill_table[/code] writes the columns with no object touched) and hands it to [method GSBotWorld.set_table].
## [b]The objects stay, as a view:[/b] [method contact] writes a row's fields onto its [GSBotContact] the first time this tick anybody asks for it, so the bot's own body and its target read as before, and a body nobody looks at this tick costs no object write.
## The fields a game writes on the objects itself ([member GSBotContact.loadout], [member GSBotContact.weapon_class], [member GSBotContact.magazine], [member GSBotContact.id]) are not columns: the view keeps them.

# No log channel: a record.

## [member flags] bits.
const ALIVE := 1
const GROUNDED := 2
const SLIDING := 4
const WALL_RUNNING := 8
const AIR_JUMP := 16
## [member floats] per row: eye height, aim height, view yaw, view pitch, health.
const FLOATS := 5

## The [member GSBotWorld.contacts_version] these rows are for.
var version: int = -1
var ids := PackedInt64Array()
var positions := PackedVector3Array()
var velocities := PackedVector3Array()
## [constant FLOATS] per row.
var floats := PackedFloat64Array()
var teams := PackedInt32Array()
## [constant ALIVE] and the motion bits per row.
var flags := PackedInt32Array()
## The sight rows: [method GSBotContact.aim_point], [method GSBotContact.eye] and alive (1 or 0) per row, to the bit.
var points := PackedVector3Array()
var eyes := PackedVector3Array()
var alive := PackedByteArray()
## The [GSBotContact] each row writes onto, in row order.
var views: Array = []

var _index: Dictionary = {}
var _synced := PackedByteArray()
## Two brains on worker threads may ask for the same row's view.
var _lock := Mutex.new()


func size() -> int:
	return ids.size()


## Takes one tick's columns (each one row per body, [param p_floats] [constant FLOATS] per row) and the objects they view,
## none written yet. GameSpice Sim's [code]GSSimBotContacts[/code] after [code]fill_table[/code] hands them as they are.
func take(p_version: int, p_views: Array, p_ids: PackedInt64Array, p_positions: PackedVector3Array, p_velocities: PackedVector3Array,
		p_floats: PackedFloat64Array, p_teams: PackedInt32Array, p_flags: PackedInt32Array, p_points: PackedVector3Array,
		p_eyes: PackedVector3Array, p_alive: PackedByteArray) -> void:
	version = p_version
	if p_ids != ids:
		_index.clear()
		for i in p_ids.size():
			_index[p_ids[i]] = i
	ids = p_ids
	views = p_views
	positions = p_positions
	velocities = p_velocities
	floats = p_floats
	teams = p_teams
	flags = p_flags
	points = p_points
	eyes = p_eyes
	alive = p_alive
	_synced.resize(ids.size())
	_synced.fill(0)


## Starts an empty table for [param p_version], to [method add] to (a game's script contact loop).
func begin(p_version: int) -> void:
	version = p_version
	# One by one: a loop over a list of them would clear copies.
	ids.clear()
	positions.clear()
	velocities.clear()
	floats.clear()
	teams.clear()
	flags.clear()
	points.clear()
	eyes.clear()
	alive.clear()
	_synced.clear()
	views.clear()
	_index.clear()


## Appends [param c] as a row; it is its own view, already written.
func add(c: GSBotContact) -> void:
	_index[c.id] = ids.size()
	ids.append(c.id)
	positions.append(c.position)
	velocities.append(c.velocity)
	floats.append(c.eye_height)
	floats.append(c.aim_height)
	floats.append(c.view_yaw)
	floats.append(c.view_pitch)
	floats.append(c.health)
	teams.append(c.team)
	flags.append(flags_of(c))
	points.append(c.aim_point())
	eyes.append(c.eye())
	alive.append(1 if c.alive else 0)
	views.append(c)
	_synced.append(1)


## The table of the contacts in [param all] (anything else skipped), for [param p_version].
static func from_contacts(p_version: int, all: Array) -> GSBotContactTable:
	var t := GSBotContactTable.new()
	t.begin(p_version)
	for item in all:
		if item is GSBotContact:
			t.add(item as GSBotContact)
	return t


## [member flags] of [param c].
static func flags_of(c: GSBotContact) -> int:
	return (ALIVE if c.alive else 0) | (GROUNDED if c.grounded else 0) | (SLIDING if c.sliding else 0) \
		| (WALL_RUNNING if c.wall_running else 0) | (AIR_JUMP if c.air_jump_ready else 0)


## The row of the body with [param id], or -1.
func row_of(id: int) -> int:
	return _index.get(id, -1)


## Row [param i]'s [GSBotContact], its fields written from the row.
func contact(i: int) -> GSBotContact:
	if _synced[i] == 0:
		_write_view(i)
	return views[i]


## The [GSBotContact] of the body with [param id], or null.
func contact_by_id(id: int) -> GSBotContact:
	var i: int = _index.get(id, -1)
	return contact(i) if i >= 0 else null


## Every row's [GSBotContact], all written: the compatibility list ([method GSBotWorld.contacts]).
func contacts() -> Array:
	for i in ids.size():
		if _synced[i] == 0:
			_write_view(i)
	return views


## Whether row [param i] is a live enemy of [param me] ([method GSBotContact.is_enemy] on the row).
func live_enemy(i: int, me: GSBotContact) -> bool:
	if flags[i] & ALIVE == 0 or ids[i] == me.id:
		return false
	var team := teams[i]
	return me.team == 0 or team == 0 or me.team != team


## A hash of every column, for a suite's on/off check.
func digest() -> int:
	return hash(var_to_bytes([ids, positions, velocities, floats, teams, flags, points, eyes, alive]))


func _write_view(i: int) -> void:
	_lock.lock()
	if _synced[i] == 0:
		var c: GSBotContact = views[i]
		var f := i * FLOATS
		var bits := flags[i]
		c.id = ids[i]
		c.eye_height = floats[f]
		c.aim_height = floats[f + 1]
		c.alive = bits & ALIVE != 0
		c.team = teams[i]
		c.position = positions[i]
		c.velocity = velocities[i]
		c.view_yaw = floats[f + 2]
		c.view_pitch = floats[f + 3]
		c.grounded = bits & GROUNDED != 0
		c.sliding = bits & SLIDING != 0
		c.wall_running = bits & WALL_RUNNING != 0
		c.air_jump_ready = bits & AIR_JUMP != 0
		c.health = floats[f + 4]
		_synced[i] = 1
	_lock.unlock()
