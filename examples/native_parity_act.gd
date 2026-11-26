extends RefCounted

## GSBotBrain's roaming steer native (GSSimBotMind.steer) against script, to the bit: two brains of one id walk
## (along routes with no world: straight at the place), hold a post (facing a point, or none and drifting) and
## drift with nowhere to go, over many thinks of mixed lengths (thinned thinks, a zero dt), some glancing, some
## not, some native steps on a worker thread, and spans with GSBotBrain.native_act off (the glance the mind keeps
## comes back to the script and goes in again); the view, the legs, the glance and the stream's counter must agree.

const THINKS := 4000
const TICK := 1.0 / 30.0


## An empty string when every think matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	var was_on := GSBotBrain.native_act
	var err := _compare(stats, was_on)
	GSBotBrain.native_act = was_on
	return err


static func _step(b: GSBotBrain, out: GSBotIntent, mode: int, me: GSBotContact, p: GSBotProfile, dest: Vector3, now: float, dt: float, rate: float) -> void:
	match mode:
		0:
			b._walk(me, null, p, dest, now, dt, out)
		1:
			b._hold(me, p, now, dt, out)
		_:
			b._drift(rate, dt)


static func _compare(stats: Dictionary, was_on: bool) -> String:
	if not GSBotBrain._act_available():
		stats["skipped"] = true
		return ""
	var dice := RandomNumberGenerator.new()
	dice.seed = 23
	var me := GSBotContact.new()
	me.id = 9
	me.alive = true
	var p := GSBotProfile.new()
	var native := GSBotBrain.new(me.id)
	var script := GSBotBrain.new(me.id)
	script.leave_native()
	if native.aim._n == null:
		stats["skipped"] = true
		return ""
	var dest := Vector3.ZERO
	var face := Vector3.INF
	var now := 0.0
	var counts := [0, 0, 0]
	var glances := 0
	var worker := 0
	var handed := 0
	for t in THINKS:
		# 40 thinks of every 500 in script: the glance moves out of the mind and back.
		GSBotBrain.native_act = was_on and t % 500 < 460
		if t % 500 == 460:
			handed += 1
		var dt: float = TICK * float([1.0, 1.0, 1.0, 3.0, 7.5, 0.0][dice.randi_range(0, 5)])
		now += dt
		if t % 400 == 0:
			p.glance = [0.0, 0.2, 0.6, 1.0][int(float(t) / 400.0) % 4]
		if dice.randf() < 0.02:
			dest = me.position + Vector3(dice.randf_range(-30.0, 30.0), 0.0, dice.randf_range(-30.0, 30.0))
		if dice.randf() < 0.02:
			face = Vector3.INF if dice.randf() < 0.3 else me.position + Vector3(dice.randf_range(-20.0, 20.0), 1.0, dice.randf_range(-20.0, 20.0))
		if dice.randf() < 0.01:
			# Something else turned the head (a fight, a look at a sound): both the same.
			var jolt := Vector2(dice.randf_range(-180.0, 180.0), dice.randf_range(-40.0, 40.0))
			native.aim.yaw = jolt.x
			native.aim.pitch = jolt.y
			script.aim.yaw = jolt.x
			script.aim.pitch = jolt.y
		var mode := 0 if dice.randf() < 0.7 else (1 if dice.randf() < 0.6 else 2)
		var rate := dice.randf_range(-60.0, 60.0)
		native.goal.face = face
		script.goal.face = face
		var no := GSBotIntent.new()
		var so := GSBotIntent.new()
		var step := func(b: GSBotBrain, out: GSBotIntent) -> void: _step(b, out, mode, me, p, dest, now, dt, rate)
		var before := native._rng._counter
		if t % 3 == 2:
			var task := WorkerThreadPool.add_task(step.bind(native, no))
			WorkerThreadPool.wait_for_task_completion(task)
			worker += 1
		else:
			step.call(native, no)
		step.call(script, so)
		if native.aim._n == null:
			return "steer think %d: the native mind fell back to script (mode %d)" % [t, mode]
		counts[mode] += 1
		native._glance_sync()
		if native._rng._counter != before:
			glances += 1
		var n := [native.aim.yaw, native.aim.pitch, no.move, native._glance_next, native._glance_until, native._glance_off, native._rng._counter]
		var s := [script.aim.yaw, script.aim.pitch, so.move, script._glance_next, script._glance_until, script._glance_off, script._rng._counter]
		if n != s:
			return "steer think %d (mode %d, dt %s): native %s, script %s" % [t, mode, dt, n, s]
		# Both walk the same way, so the next think starts from the same place.
		me.position += Vector3(so.move.x, 0.0, so.move.y) * dt * 4.0
	if glances < 20:
		return "too few glances to compare: %d of %d thinks" % [glances, THINKS]
	stats["thinks"] = THINKS
	stats["walk"] = counts[0]
	stats["hold"] = counts[1]
	stats["drift"] = counts[2]
	stats["glances"] = glances
	stats["worker"] = worker
	stats["handed"] = handed
	return ""
