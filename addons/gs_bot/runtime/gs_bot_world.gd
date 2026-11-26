class_name GSBotWorld
extends RefCounted

## Everything a bot brain may know about the world, and nothing else.
## [b]The brain cannot cheat because this is all it has:[/b] the bodies ([method contacts]), a line-of-sight answer ([method line_of_sight]), the sounds that were made and places to walk to; so "no shooting through walls" is structural.
## A game extends this and overrides the methods, or sets the callables on a plain one ([member contacts_fn] and friends). The defaults see everything and know no places, which is what a suite with no map wants.

# No log channel: answers questions; the brain and the game log.

## How long a sound stays in [member sounds], seconds. Longer than any brain's think interval.
const SOUND_LIFETIME := 1.0

## [code]() -> Array[/code] of [GSBotContact]: every body, the bots included.
var contacts_fn: Callable = Callable()

## Places beyond [member waypoints_fn], e.g. [method GSBotNav.spread_points]; roaming bots visit them too.
var extra_waypoints := PackedVector3Array()

## [code](from: Vector3, to: Vector3) -> bool[/code].
var line_of_sight_fn: Callable = Callable()

## [code]() -> PackedVector3Array[/code]: places worth walking to (spawns, objectives).
var waypoints_fn: Callable = Callable()

## [code](from: Vector3, dir: Vector3, reach: float) -> Dictionary[/code]: the nearest wall along
## [param dir] (flat, unit) within [param reach] as `{normal, distance}`, or empty. The brain asks
## it beside and ahead of a running bot to find a wall worth running along.
var wall_fn: Callable = Callable()

## [code](shooter: GSBotContact) -> float[/code]: how fast what this body fires travels, m/s;
## 0 for hitscan. The brain leads a target by it.
var projectile_speed_fn: Callable = Callable()

## [code](from: Vector3, to: Vector3) -> PackedVector3Array[/code]: the corners of a walkable way from one place to another, [param to] last; empty when the game has no graph or no way.
## The brain walks a route corner by corner where it has one and straight where it has none.
var route_fn: Callable = Callable()

## The native sight scan over [param all] packed once for this [member contacts_version], or null (no extension, the game does not bump the version, or a worker thread).
## The scan keeps its last answer, so a brain on a worker reads the handle [method GSBotBrain.par_ready] took on the main thread, or scans in script; [method sensed] maps its indices back.
var route_detail_fn: Callable = Callable()

## [code](at: Vector3) -> Vector3[/code]: the nearest point a body can stand on (the navigation mesh's closest), or unset. A bot that cannot get free of a corner is nudged toward it.
var walkable_fn: Callable = Callable()

## [code]drops_fn.call() -> Array[Dictionary][/code]: the weapons lying about, each
## [code]{id, position, slot, value, ammo}[/code] (value and ammo as in [member GSBotContact.loadout]).
## Unset: none, and no bot goes for one.
var drops_fn: Callable = Callable()

## The flags and each bot's team job in a flag mode, or null; brains read it, the game writes it.
var objective: GSBotObjective = null

## Recent sounds: dictionaries with position, loudness (1 is a gunshot), source (an id), at
## and seq.
var sounds: Array[Dictionary] = []

## The last sound's number. A brain remembers the last one it heard by this, never by time: a
## sound made at the same timestamp as a brain's last think was missed by a time comparison,
## and a bot with its back to a shooter at that moment died without turning round.
var _seq: int = 0
## [member sounds] packed for the native hearing (GSSimBotMind.hear), row for row: seq, source, x, y, z,
## loudness, at ([constant SOUND_STRIDE] each). [method emit_sound] and the pruning keep it; [method sound_rows]
## hands it out only while it still matches [member sounds] (a list written by hand is heard in script).
var _sound_rows := PackedFloat64Array()
const SOUND_STRIDE := 7


## Bumped by the game whenever [method contacts] holds a new tick's bodies (the tick number serves);
## the bodies must not change until the next bump, since the native scan packs them once per value.
## At -1, the default, the sight scan stays in script: see [method senses].
var contacts_version: int = -1

## The native sight scan's class (GameSpice Sim). Absent, every bot scans in script, as before.
const SENSES_CLASS := &"GSSimBotSenses"

## Whether the native sight scan is used when present; a suite turns it off to compare.
static var native_enabled: bool = true

static var _native_known: int = -1
## Bits of the native scan's optional loads this library has (1 load_eyes, 2 load_positions); -1 not asked yet.
static var _loads_known: int = -1
var _senses: Object = null
var _senses_version: int = -2
var _sensed: Array = []
## The contact table a game handed for one [member contacts_version] ([method set_rows]); -2 none.
var _handed_version: int = -2
var _handed_rows: Array = []

## Whether [method senses] takes the table a game handed through [method set_rows] (cvar `bot_native_think`
## in a game, 1 by default); off, it packs the contacts itself as before. A suite turns it off to compare.
static var rows_enabled: bool = true

## Whether [method table] answers with the table a game handed through [method set_table] (cvar `bot_contact_table` in a game,
## 1 by default); off, the brain and the sight scan read [method contacts] as before. A suite turns it off to compare.
static var table_enabled: bool = true

## The bodies of one [member contacts_version] as packed columns ([method set_table]), or null.
var contact_table: GSBotContactTable = null
## The table the last [method senses] loaded, or null when it loaded a list.
var _sensed_table: GSBotContactTable = null


## Hands this tick's bodies as one [GSBotContactTable] (its [member GSBotContactTable.version] the [member contacts_version] it is for).
## The brain then reads rows where it walks every body, and the bodies' objects only where it keeps one ([method GSBotContactTable.contact]);
## the sight scan loads its columns. [method contacts] must still answer the same bodies, in the same order, for a caller that asks.
func set_table(table: GSBotContactTable) -> void:
	contact_table = table


## The table handed for this [member contacts_version], or null (none, an older one, or [member table_enabled] off).
func table() -> GSBotContactTable:
	if table_enabled and contact_table != null and contact_table.version == contacts_version:
		return contact_table
	return null


## The contact table of [param version] (the [member contacts_version] it is for), filled by the game in the loop
## that builds its contacts, so [method senses] loads the native scan from it without walking the bodies again.
## Columns, one row per body in [param sensed]'s order: [param ids], [param points] (each body's
## [method GSBotContact.aim_point]), [param teams], [param alive] (1 or 0), [param eyes] ([method GSBotContact.eye])
## and [param positions]. They must be what [method rows_of] makes of the same bodies, to the bit (the suite's
## rows check). [param sensed] must hold the contacts [method contacts] returns, in that order.
func set_rows(version: int, sensed: Array, ids: PackedInt64Array, points: PackedVector3Array, teams: PackedInt32Array,
		alive: PackedByteArray, eyes: PackedVector3Array, positions: PackedVector3Array) -> void:
	_handed_version = version
	_handed_rows = [sensed, ids, points, teams, alive, eyes, positions]


## The table [method senses] builds of [param all], as [method set_rows] takes it (for a game's or the suite's check).
static func rows_of(all: Array) -> Array:
	var sensed := []
	var ids := PackedInt64Array()
	var points := PackedVector3Array()
	var teams := PackedInt32Array()
	var alive := PackedByteArray()
	var eyes := PackedVector3Array()
	var positions := PackedVector3Array()
	for item in all:
		if item is GSBotContact:
			var c := item as GSBotContact
			sensed.append(c)
			ids.append(c.id)
			points.append(c.aim_point())
			teams.append(c.team)
			alive.append(1 if c.alive else 0)
			eyes.append(c.eye())
			positions.append(c.position)
	return [sensed, ids, points, teams, alive, eyes, positions]


func contacts() -> Array:
	return contacts_fn.call() if contacts_fn.is_valid() else []


## Whether GameSpice Sim's native sight scan is loaded (never on the web, where no extension is).
static func native_available() -> bool:
	if _native_known < 0:
		_native_known = 1 if ClassDB.class_exists(SENSES_CLASS) else 0
	return native_enabled and _native_known == 1


## [code](from: Vector3, to: Vector3) -> Dictionary[/code]: a route that may ride, as [method GSBotNav.route] answers (`points`, and `rides`: per point the id of the ride edge that starts there, -1 for a walked corner).
## Unset, [method route_detail] is [member route_fn]'s corners, every one walked. The brain says when it reaches a ride's start ([member GSBotIntent.ride]); the game rides it.
func senses(all: Array) -> Object:
	if contacts_version < 0 or not native_available() or OS.get_thread_caller_id() != OS.get_main_thread_id():
		return null
	if _senses == null:
		_senses = ClassDB.instantiate(SENSES_CLASS)
	if _senses_version != contacts_version:
		_senses_version = contacts_version
		var t := table()
		if t != null:
			_load_table(t)
		else:
			_sensed_table = null
			_load_rows(_handed_rows if rows_enabled and _handed_version == contacts_version else rows_of(all))
		_handed_rows = []
	return _senses


## The bodies the last [method senses] packed, in its index order.
func sensed() -> Array:
	return _sensed_table.contacts() if _sensed_table != null else _sensed


## The body at index [param i] of the last [method senses]: [code]sensed()[i][/code], writing only that one view when the scan loaded a table.
func sensed_at(i: int) -> GSBotContact:
	return _sensed_table.contact(i) if _sensed_table != null else _sensed[i]


## Loads [param t]'s sight columns into the native scan.
func _load_table(t: GSBotContactTable) -> void:
	_sensed_table = t
	_sensed = []
	_senses.call(&"load_contacts", t.ids, t.points, t.teams, t.alive)
	if _senses.has_method(&"load_eyes"):
		_senses.call(&"load_eyes", t.eyes)
	if _senses.has_method(&"load_positions"):
		_senses.call(&"load_positions", t.positions)


## Loads a table in [method set_rows]'s shape into the native scan.
func _load_rows(rows: Array) -> void:
	_sensed = rows[0]
	_senses.call(&"load_contacts", rows[1], rows[2], rows[3], rows[4])
	if _loads_known < 0:
		_loads_known = (1 if _senses.has_method(&"load_eyes") else 0) | (2 if _senses.has_method(&"load_positions") else 0)
	if _loads_known & 1:
		_senses.call(&"load_eyes", rows[5])
	if _loads_known & 2:
		_senses.call(&"load_positions", rows[6])


## Sight LOD: a body farther than this (m) that was not seen keeps that answer for
## [member sight_far_reuse] seconds instead of the brain's own short reuse; 0 is off.
## Only a "not seen" is held, never for the bot's current target, so no shot goes blind.
var sight_far: float = 0.0
var sight_far_reuse: float = 0.15

## `{center, radius, until}` per sight blocker (smoke), by id; a segment through one is not clear.
var sight_blockers: Dictionary = {}
var _blocker_seq: int = 0


func line_of_sight(from: Vector3, to: Vector3) -> bool:
	# By key, not values(): that built a new array on every call, smoke or none.
	for id: int in sight_blockers:
		var b: Dictionary = sight_blockers[id]
		if segment_hits_sphere(from, to, b["center"], float(b["radius"])):
			return false
	return bool(line_of_sight_fn.call(from, to)) if line_of_sight_fn.is_valid() else true


## What a native mind asks sight through (`(from, to) -> bool`): [method line_of_sight] here. A game whose line_of_sight is one engine ray may hand a native one (GameSpice Sim's `GSSimSightRay.clear`), which the mind asks with no call into script.
## It must answer to the bit as the game's line_of_sight does. Asked once per native perceive, so the game may switch it from tick to tick.
func sight_callable() -> Callable:
	return Callable(self, &"line_of_sight")


## Changes whenever a sight blocker is added or removed, so cached sight results can be dropped.
func sight_stamp() -> int:
	return _blocker_seq * 4096 + sight_blockers.size()


## Blocks sight through a sphere until [param until] (game time); returns an id for [method remove_sight_blocker].
func add_sight_blocker(center: Vector3, radius: float, until: float) -> int:
	_blocker_seq += 1
	sight_blockers[_blocker_seq] = {"center": center, "radius": radius, "until": until}
	return _blocker_seq


func remove_sight_blocker(id: int) -> void:
	sight_blockers.erase(id)


## Drops the blockers that ended by [param now]; the brain calls it each think.
func prune_sight_blockers(now: float) -> void:
	if sight_blockers.is_empty():
		return
	for id in sight_blockers.keys():
		if now >= float(sight_blockers[id]["until"]):
			sight_blockers.erase(id)


static func segment_hits_sphere(from: Vector3, to: Vector3, center: Vector3, radius: float) -> bool:
	var d := to - from
	var len2 := d.length_squared()
	var t := 0.0 if len2 < 0.000001 else clampf((center - from).dot(d) / len2, 0.0, 1.0)
	return (from + d * t).distance_squared_to(center) <= radius * radius


func drops() -> Array:
	return drops_fn.call() if drops_fn.is_valid() else []


func wall_ahead(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
	return wall_fn.call(from, dir, reach) if wall_fn.is_valid() else {}


## The nearest standable point to [param at], or [constant Vector3.INF] when the game has none.
func walkable_near(at: Vector3) -> Vector3:
	return walkable_fn.call(at) if walkable_fn.is_valid() else Vector3.INF


func waypoints() -> PackedVector3Array:
	var out := waypoints_fn.call() if waypoints_fn.is_valid() else PackedVector3Array()
	out.append_array(extra_waypoints)
	return out


func route(from: Vector3, to: Vector3) -> PackedVector3Array:
	return route_fn.call(from, to) if route_fn.is_valid() else PackedVector3Array()


## A route that may ride: see [member route_detail_fn]. A subclass that overrides [method route]
## and not this gets its corners, all walked.
func route_detail(from: Vector3, to: Vector3) -> Dictionary:
	if route_detail_fn.is_valid():
		return route_detail_fn.call(from, to)
	var points := route(from, to)
	var rides := PackedInt32Array()
	rides.resize(points.size())
	rides.fill(-1)
	return {"points": points, "rides": rides}


## The ladder behind a ride id ([constant GSBotLinks.LADDER_ID] up): `{"box": AABB, "to": Vector3}`, or an empty dictionary. Assign [code]links.ladder_of[/code].
var ladder_fn := Callable()


func ladder(ride_id: int) -> Dictionary:
	return ladder_fn.call(ride_id) if ladder_fn.is_valid() else {}


func projectile_speed(shooter: GSBotContact) -> float:
	return float(projectile_speed_fn.call(shooter)) if projectile_speed_fn.is_valid() else 0.0


## Records a sound. [param loudness] scales every bot's hearing distance: 1 a gunshot, about
## 0.3 a footstep, 2 an explosion.
func emit_sound(position: Vector3, loudness: float, source: int, now: float) -> void:
	_seq += 1
	sounds.append({"position": position, "loudness": loudness, "source": source, "at": now, "seq": _seq})
	_sound_rows.append_array([float(_seq), float(source), position.x, position.y, position.z, loudness, now])
	_prune(now)


## The sounds after number [param after_seq] (0 for all), oldest first.
func sounds_after(after_seq: int, now: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	sounds_into(after_seq, now, out)
	return out


## [method sounds_after] into [param out], cleared first: a brain hears every think and keeps one array for it.
func sounds_into(after_seq: int, now: float, out: Array[Dictionary]) -> void:
	_prune(now)
	out.clear()
	var n := sounds.size()
	if n == 0:
		return
	# emit_sound numbers them one by one, so the new ones are the tail and counting finds it;
	# a list somebody wrote by hand is walked whole.
	if int(sounds[n - 1]["seq"]) == _seq and int(sounds[0]["seq"]) == _seq - n + 1:
		for i in range(maxi(0, n - (_seq - after_seq)), n):
			out.append(sounds[i])
		return
	for s in sounds:
		if int(s["seq"]) > after_seq:
			out.append(s)


## The number of the newest sound.
func last_sound() -> int:
	return _seq


func _prune(now: float) -> void:
	var gone := 0
	while not sounds.is_empty() and now - float(sounds[0]["at"]) > SOUND_LIFETIME:
		sounds.pop_front()
		gone += 1
	if gone > 0:
		_sound_rows = _sound_rows.slice(gone * SOUND_STRIDE)


## [member sounds] as packed rows for GSSimBotMind.hear ([member _sound_rows]); empty when they no longer match
## [member sounds] row for row (somebody wrote the list by hand), and then the brain hears in script.
## Reads only, so a brain on a worker thread may call it.
func sound_rows() -> PackedFloat64Array:
	var n := sounds.size()
	if _sound_rows.size() != n * SOUND_STRIDE or n == 0:
		return PackedFloat64Array()
	if int(_sound_rows[0]) != int(sounds[0]["seq"]) or int(_sound_rows[(n - 1) * SOUND_STRIDE]) != int(sounds[n - 1]["seq"]):
		return PackedFloat64Array()
	return _sound_rows


## The contact with [param id] among [param all], this think's [method contacts]. A world that
## keeps them by id overrides this; the brain asks it for every sound heard and every think of a fight.
func contact_of(all: Array, id: int) -> GSBotContact:
	var t := table() if all.is_empty() else null
	return t.contact_by_id(id) if t != null else find(all, id)


## The contact with [param id] in [param list], or null.
static func find(list: Array, id: int) -> GSBotContact:
	for c in list:
		if c is GSBotContact and (c as GSBotContact).id == id:
			return c
	return null


func describe() -> Dictionary:
	return {"sounds": sounds.size(), "waypoints": waypoints().size()}
