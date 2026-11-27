class_name GSBotUnstick
extends RefCounted

## Notices a bot that pushes to move and gets nowhere, and escalates: re-plan and hop, then crouch-hop and side-step, then a nudge toward the nearest standable point.

## Seconds of no progress that raise the level one step, and the distance that counts as progress.
const WINDOW := 1.0
const PROGRESS := 0.45
## From this level the bot is walked toward a standable point.
const NUDGE_LEVEL := 3

## Whether [method step] runs in GameSpice Sim (GSSimBotMind.unstick_step) when the caller hands a
## mind and the library has it; off, in script. The two answer the same to the bit; the nudge's
## world query and its random fallback stay here either way.
static var native_enabled := true
static var _native_known := -1

var level: int = 0
## What the brain does this tick; read after [method step].
var jump := false
var crouch := false
var strafe := 0.0
var replan := false
var nudge_to := Vector3.INF
## Times a window ended stuck, over the bot's life.
var total: int = 0
## True for the one step [param after] of [method step] fires.
var stranded := false

var _stuck_since: float = INF

var _anchor: Vector3 = Vector3.INF
var _anchor_at: float = 0.0
var _pushed: float = 0.0
var _seen: float = 0.0
var _side: float = 1.0
var _rng: GSRandomStream = null
## The mind holding the state between steps, or null while the script vars hold it.
var _held: Object = null
## The owning brain's profile clock ([GSBotClock]); null in one made without a brain.
var clock: GSBotClock = null


func _init(p_rng: GSRandomStream = null) -> void:
	_rng = p_rng


## [param pushing] is whether the intent walks this tick. [param after] is `bot_stranded_sec` (0 never): stuck that long past the nudge level sets [member stranded] for one step. [param mind] is the brain's GSSimBotMind, or null for the script. Returns the level, 0 when free.
func step(position: Vector3, pushing: bool, now: float, world: GSBotWorld, after: float = 0.0, mind: Object = null) -> int:
	jump = false
	crouch = false
	strafe = 0.0
	replan = false
	nudge_to = Vector3.INF
	stranded = false
	if mind != null and _native_available():
		if mind != _held:
			_hand_to(mind)
		return _step_native(mind, position, pushing, now, world, after)
	if _held != null:
		_unpack(_held.unstick_state())
		_held = null
	if _anchor == Vector3.INF:
		reset(position, now)
	_seen += 1.0
	_pushed += 1.0 if pushing else 0.0
	if now - _anchor_at >= WINDOW:
		var moved := position.distance_to(_anchor)
		if _pushed / maxf(_seen, 1.0) > 0.6 and moved < PROGRESS:
			if level == 0:
				_stuck_since = _anchor_at
			level += 1
			total += 1
			_side = -_side
		elif moved >= PROGRESS * 2.0:
			level = 0
			_stuck_since = INF
		_anchor = position
		_anchor_at = now
		_pushed = 0.0
		_seen = 0.0
	if level == 0 or not pushing:
		return level
	if after > 0.0 and level >= NUDGE_LEVEL and now - _stuck_since >= after:
		# Every step has been tried for [param after] seconds: report once, then wait another interval in case the game does nothing.
		stranded = true
		_stuck_since = now
	replan = true
	jump = true
	if level >= 2:
		crouch = int(now * 4.0) % 2 == 0
		strafe = _side
	if level >= NUDGE_LEVEL and world != null:
		_nudge(position, world)
	return level


## Walks toward the nearest standable point, or a random one 3 m off when the world has none near.
func _nudge(position: Vector3, world: GSBotWorld) -> void:
	var t_walk := Time.get_ticks_usec() if GSBotClock.on else 0
	var near := world.walkable_near(position)
	if t_walk:
		GSBotClock.add(clock, GSBotClock.Q_WALKABLE, t_walk)
	if near != Vector3.INF and Vector2(near.x - position.x, near.z - position.z).length() > 0.35:
		nudge_to = near
	elif _rng != null:
		var a := _rng.next_range_f(0.0, TAU)
		nudge_to = position + Vector3(cos(a), 0.0, sin(a)) * 3.0


func _step_native(mind: Object, position: Vector3, pushing: bool, now: float, world: GSBotWorld, after: float) -> int:
	var r: int = mind.unstick_step(position, pushing, now, world != null, after)
	level = r >> 8
	if r & 64:
		total += 1
	jump = (r & 1) != 0
	crouch = (r & 2) != 0
	replan = (r & 4) != 0
	stranded = (r & 8) != 0
	if r & 16:
		strafe = -1.0 if r & 32 else 1.0
	if r & 128:
		_nudge(position, world)
	return level


static func _native_available() -> bool:
	if _native_known < 0:
		_native_known = 1 if ClassDB.class_exists(&"GSSimBotMind") and ClassDB.class_has_method(&"GSSimBotMind", &"unstick_step") else 0
	return native_enabled and _native_known == 1


## Moves the state into [param mind] (from the script vars, or from the mind that held it).
func _hand_to(mind: Object) -> void:
	if _held != null:
		_unpack(_held.unstick_state())
	mind.unstick_load(PackedFloat64Array([float(level), _stuck_since, _anchor.x, _anchor.y, _anchor.z, _anchor_at, _pushed, _seen, _side]))
	_held = mind


func _unpack(st: PackedFloat64Array) -> void:
	level = int(st[0])
	_stuck_since = st[1]
	_anchor = Vector3(st[2], st[3], st[4])
	_anchor_at = st[5]
	_pushed = st[6]
	_seen = st[7]
	_side = st[8]


## Forget the history: a respawn, a teleport, a finished ride or ladder.
func reset(position: Vector3 = Vector3.INF, now: float = 0.0) -> void:
	level = 0
	_stuck_since = INF
	_anchor = position
	_anchor_at = now
	_pushed = 0.0
	_seen = 0.0
	if _held != null:
		_held.unstick_reset(position, now)
