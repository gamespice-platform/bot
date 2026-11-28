extends "gs_bot_brain_state.gd"

## [GSBotBrain]'s rows to and from its native mind (GSSimBotMind): the fight step and the roaming steer packed
## into one call each, and the answer unpacked into the aim, the stream and the intent as the script would have
## left them. Split out of gs_bot_brain.gd for file size; nothing outside the brain names this script.

static var _sight_lod_known := -1
## The sight LOD last handed to [member _mind] (GSBotWorld.sight_far, sight_far_reuse).
var _lod_far := 0.0
var _lod_reuse := 0.0
## The [member GSBotWorld.contacts_version] whose packed scan [member _mind] holds ([method par_ready]); -1 none.
var _held_version := -1
## The perceive row [method think_mt_row] gave GSSimBotThinkMt this tick, and its answer ([method think_mt_put]).
var _mt_key := PackedFloat64Array()
var _mt_r := PackedInt32Array()
## Perceives answered from the threaded pass; and rows it answered that the brain then asked differently
## (always 0: a miss would mean the pass grew the sight cache on its own).
var mt_hits := 0
var mt_misses := 0
static var _mt_known := -1


## Whether the gs_sim extension's GSSimBotMind applies the sight LOD itself (sight_cached_far, set_sight_lod).
static func _sight_lod_available() -> bool:
	if _sight_lod_known < 0:
		_sight_lod_known = 1 if ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"sight_cached_far") else 0
	return _sight_lod_known == 1


## Whether gs_sim has GSSimBotThinkMt (perceive_all), the threaded perceive pass.
static func think_mt_available() -> bool:
	if _mt_known < 0:
		_mt_known = 1 if ClassDB.class_exists(&"GSSimBotThinkMt") and ClassDB.class_has_method(&"GSSimBotThinkMt", &"perceive_all") else 0
	return _mt_known == 1


## Hands [member _mind] the world's sight LOD when it changed.
func _lod_sync(world: GSBotWorld) -> void:
	if _sight_lod_available() and (world.sight_far != _lod_far or world.sight_far_reuse != _lod_reuse):
		_lod_far = world.sight_far
		_lod_reuse = world.sight_far_reuse
		_mind.set_sight_lod(_lod_far, _lod_reuse)


## The 13 numbers (GSSimBotThinkMt.ROW) [method think] will hand GSSimBotMind.perceive_held this tick, for the
## threaded perceive pass; call on the main thread after [method par_ready], before [method think]. Empty when
## this tick's perceive is not a held one (dead, just respawned, blind, script). Does what think does first, all
## of it repeatable: the view, the LOD and the expired sight blockers.
func think_mt_row(me: GSBotContact, world: GSBotWorld, now: float) -> PackedFloat64Array:
	_mt_key = PackedFloat64Array()
	if me == null or not me.alive or not _was_alive or now < _blind_until or _mind == null or world == null:
		return _mt_key
	if _held_version < 0 or _held_version != world.contacts_version or not think_mt_available():
		return _mt_key
	if _scan_waits(world):
		return _mt_key
	aim.view_from(me.view_yaw, me.view_pitch)
	_lod_sync(world)
	world.prune_sight_blockers(now)
	var p := settings.profile
	var eye := me.eye()
	var flags := (1 if _visible else 0) | (2 if p.through_walls >= 0.5 else 0) | (4 if world.pair_sight_on() else 0)
	_mt_key = PackedFloat64Array([me.id, me.team, eye.x, eye.y, eye.z, aim.yaw, aim.pitch, p.fov * 0.5, p.sight,  # perf-lint: allow alloc the row this call answers to the threaded pass, one per bot per tick
		target_id, flags, now, world.sight_stamp()])
	return _mt_key


## The native mind (GSSimBotMind) GSSimBotThinkMt.perceive_all perceives for, beside [method think_mt_row]'s row.
func think_mt_mind() -> Object:
	return _mind


## The pass's answer to [method think_mt_row]: [chosen row, target dead], or -2s when it could not (think asks itself).
func think_mt_put(r: PackedInt32Array) -> void:
	if r.size() == 2 and r[0] != -2:
		_mt_r = r
	else:
		_mt_key = PackedFloat64Array()


## GSSimBotMind.perceive_held, or the threaded pass's answer when it was asked exactly this.
func _perceive_held_mt(me_id: int, me_team: int, eye: Vector3, half: float, sight: float, flags: int, now: float, stamp: int, los: Callable) -> PackedInt32Array:
	var key := _mt_key
	if not key.is_empty():
		_mt_key = PackedFloat64Array()
		# Field by field rather than building the 13-number row again just to compare it (same values, no array per tick).
		if (key.size() == 13 and key[0] == me_id and key[1] == me_team and key[2] == eye.x and key[3] == eye.y
				and key[4] == eye.z and key[5] == aim.yaw and key[6] == aim.pitch and key[7] == half and key[8] == sight
				and key[9] == target_id and key[10] == flags and key[11] == now and key[12] == stamp):
			mt_hits += 1
			return _mt_r
		mt_misses += 1
	return _mind.perceive_held(me_id, me_team, eye, aim.yaw, aim.pitch, half, sight, target_id, flags, now, stamp, los)


## Whether the native mind may steer now; GSBotBrain answers it ([member GSBotBrain.native_act]).
func _act_on() -> bool:
	return false


## [method _fight] in one call to the aim's native mind: the same arithmetic, rolls and random
## draws, so the intent, the aim and the stream come back as the script would have left them.
## False (the script then runs) if the mind refused the call.
func _fight_native(me: GSBotContact, c: GSBotContact, eye: Vector3, speed: float, p: GSBotProfile, now: float, dt: float, push: bool, out: GSBotIntent) -> bool:
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var io := _fight_io
	_fight_io = PackedFloat64Array()  # one owner, so the writes below do not copy
	if io.size() != 36:
		io.resize(36)
	io[0] = aim.yaw
	io[1] = aim.pitch
	io[2] = aim.react_at
	io[3] = aim.engaged_at
	io[4] = aim.first_shot_at
	io[5] = aim.first_shot_error
	io[6] = _rng._counter
	io[7] = now
	io[8] = dt
	io[9] = speed
	io[10] = me.health
	io[11] = 1.0 if _roll_stop else 0.0
	io[12] = 1.0 if _roll_crouch else 0.0
	io[13] = 1.0 if _roll_cover else 0.0
	io[14] = _hesitate_until
	io[15] = _strafe
	io[16] = _strafe_until
	io[17] = _strafe_eased
	io = aim._pack_profile(io, 18)
	io[30] = p.range * style.range_k
	io[31] = p.strafe * style.strafe_k
	io[32] = p.strafe_jitter
	io[33] = p.strafe_time
	io[34] = p.jump
	io[35] = 1.0 if push else 0.0
	_fight_io = io
	var r: PackedFloat64Array = aim._n.fight(eye, c.aim_point(), c.velocity, me.position, c.position, io)
	if t:
		GSBotClock.add(_clock, GSBotClock.A_FIGHT_IO, t)
	if r.size() < 15:
		aim._demote()
		return false
	aim.yaw = r[0]
	aim.pitch = r[1]
	aim.first_shot_at = r[2]
	aim.first_shot_error = r[3]
	_rng._counter = int(r[4])
	out.fire = r[5] != 0.0
	out.crouch = r[6] != 0.0
	out.jump = r[7] != 0.0
	out.move = Vector2(r[8], r[9])
	var retreat := r[11] != 0.0
	out.state = &"retreat" if retreat else &"fight"
	_scene = &"flee" if r[10] == 2.0 else (&"close" if r[10] == 1.0 else &"fight")
	_scene_up = c.position.y - me.position.y
	_strafe = r[12]
	_strafe_until = r[13]
	_strafe_eased = r[14]
	return true


## The native mind that holds the glance (_glance_next, _glance_until, _glance_off) between steers, or null: the
## script vars hold it.
var _glance_held: Object = null


## One roaming steer on the aim's native mind (GSSimBotMind.steer_step, or steer_drift): [param mode] STEER_WALK
## along the flat direction in [param aim_at] (x, y), STEER_HOLD facing the point [param aim_at] (INF: none), or
## STEER_DRIFT at [param rate] deg/s (no legs, [param out] unused). The glance stays in the mind between steers.
## False, nothing changed, when it cannot; the script then steers.
func _steer_native(mode: int, me: GSBotContact, p: GSBotProfile, aim_at: Vector3, rate: float, now: float, dt: float, out: GSBotIntent) -> bool:
	var n: Object = aim._n
	if n == null or not _act_on():
		if _glance_held != null:
			_glance_back()
		return false
	var turn := aim.settings.profile
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var r: PackedFloat64Array
	if mode == STEER_DRIFT:
		r = n.steer_drift(aim.yaw, aim.pitch, rate, dt, turn.prediction, turn.turn_smooth, turn.turn_rate)
		if t:
			GSBotClock.add(_clock, GSBotClock.A_TURN, t)
		if r.size() < 2:
			aim._demote()
			_glance_back()
			return false
		aim.yaw = r[0]
		aim.pitch = r[1]
		return true
	if n != _glance_held:
		_glance_hand_to(n)
	var at := Vector2(aim_at.x, aim_at.y)
	if mode == STEER_HOLD:
		at = Vector2(NAN if aim_at == Vector3.INF else aim_at.x, aim_at.z)
	r = n.steer_step(mode, aim.yaw, aim.pitch, me.eye(), at, now, dt, id, p.glance, _rng._counter,
		turn.prediction, turn.turn_smooth, turn.turn_rate)
	if t:
		GSBotClock.add(_clock, GSBotClock.A_TURN, t)
	if r.size() < 5:
		aim._demote()
		_glance_back()
		return false
	aim.yaw = r[0]
	aim.pitch = r[1]
	_rng._counter = int(r[2])
	out.move = Vector2(r[3], r[4])
	return true


## Moves the glance into [param mind] (from the script vars, or from the mind that held it).
func _glance_hand_to(mind: Object) -> void:
	_glance_sync()
	mind.glance_load(PackedFloat64Array([_glance_next, _glance_until, _glance_off]))
	_glance_held = mind


## Copies the glance a native mind holds into the script vars (a test reads them); the mind keeps it.
func _glance_sync() -> void:
	if _glance_held == null:
		return
	var g: PackedFloat64Array = _glance_held.glance_state()
	_glance_next = g[0]
	_glance_until = g[1]
	_glance_off = g[2]


## Takes the glance back into the script vars: the script steers from now on.
func _glance_back() -> void:
	_glance_sync()
	_glance_held = null
