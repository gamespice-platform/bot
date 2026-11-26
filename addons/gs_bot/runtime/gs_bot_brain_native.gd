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


## One roaming steer on the aim's native mind (layout gs_sim_brain::act::io): [param mode] STEER_WALK along the flat
## direction in [param aim_at] (x, y), STEER_HOLD facing the point [param aim_at] (INF: none), or STEER_DRIFT at
## [param rate] deg/s (no legs, [param out] unused). False, nothing changed, when it cannot; the script then steers.
func _steer_native(mode: int, me: GSBotContact, p: GSBotProfile, aim_at: Vector3, rate: float, now: float, dt: float, out: GSBotIntent) -> bool:
	if aim._n == null or not _act_on():
		return false
	var io := _steer_io
	_steer_io = PackedFloat64Array()  # one owner, so the writes below do not copy
	if io.size() != 22:
		io.resize(22)
	io[0] = mode
	io[1] = aim.yaw
	io[2] = aim.pitch
	if me != null:
		var eye := me.eye()
		io[3] = eye.x
		io[4] = eye.y
		io[5] = eye.z
	if mode == STEER_HOLD:
		io[6] = NAN if aim_at == Vector3.INF else aim_at.x
		io[7] = aim_at.z
	else:
		io[6] = aim_at.x
		io[7] = aim_at.y
	io[8] = now
	io[9] = dt
	io[10] = id
	io[11] = p.glance if p != null else 0.0
	io[12] = _glance_next
	io[13] = _glance_until
	io[14] = _glance_off
	io[15] = _rng._counter
	var turn := aim.settings.profile
	io[16] = turn.prediction
	io[17] = turn.turn_smooth
	io[18] = turn.turn_rate
	io[19] = rate
	_steer_io = io
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var r: PackedFloat64Array = aim._n.steer(io)
	if t:
		GSBotClock.add(_clock, GSBotClock.A_TURN, t)
	if r.size() < 22:
		aim._demote()
		return false
	aim.yaw = r[1]
	aim.pitch = r[2]
	_glance_next = r[12]
	_glance_until = r[13]
	_glance_off = r[14]
	_rng._counter = int(r[15])
	if out != null:
		out.move = Vector2(r[20], r[21])
	return true
