extends "gs_bot_brain_state.gd"

## [GSBotBrain]'s rows to and from its native mind (GSSimBotMind): the fight step and the roaming steer packed
## into one call each, and the answer unpacked into the aim, the stream and the intent as the script would have
## left them. Split out of gs_bot_brain.gd for file size; nothing outside the brain names this script.


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
