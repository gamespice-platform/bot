extends RefCounted

## GSBotBrain._hear native (GSSimBotMind.hear) against script, to the bit: two brains of one id hear the
## same world's sounds (shots and steps from enemies, friends, free-for-all bodies, unknown sources and
## their own, near and far, some expired) for many thinks, once over the main thread's packed bodies and
## once over held ones as on a worker; every field _hear writes and the stream's counter must agree.

const THINKS := 4000
const TICK := 1.0 / 30.0


## An empty string when every think matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	if not GSBotBrain._hear_available() or not GSBotWorld.native_available():
		stats["skipped"] = true
		return ""
	var dice := RandomNumberGenerator.new()
	dice.seed = 11
	var world := GSBotWorld.new()
	var all: Array = []
	for i in 12:
		var c := GSBotContact.new()
		c.id = i + 1
		c.team = [0, 1, 2][i % 3]
		c.alive = true
		c.position = Vector3(dice.randf_range(-40.0, 40.0), 0.0, dice.randf_range(-40.0, 40.0))
		all.append(c)
	world.contacts_fn = func() -> Array: return all
	var me: GSBotContact = all[4]
	var p := GSBotProfile.new()
	var native := GSBotBrain.new(me.id)
	var script := GSBotBrain.new(me.id)
	script.leave_native()
	if native._mind == null:
		stats["skipped"] = true
		return ""
	var now := 0.0
	var heard := 0
	var held := 0
	for t in THINKS:
		now += TICK
		world.contacts_version = t
		me.position += Vector3(dice.randf_range(-0.5, 0.5), 0.0, dice.randf_range(-0.5, 0.5))
		me.team = [0, 1, 2][int(float(t) / 500.0) % 3]
		for _k in dice.randi_range(0, 4):
			var source := dice.randi_range(0, 14)  # 0 and 13+ are no body; 5 is the listener
			var at := me.position + Vector3(dice.randf_range(-60.0, 60.0), dice.randf_range(-2.0, 2.0), dice.randf_range(-60.0, 60.0))
			world.emit_sound(at, [0.3, 1.0, 2.0][dice.randi_range(0, 2)], source, now - dice.randf_range(0.0, 0.2))
		var before := native._rng._counter
		var newest := world.last_sound()
		if newest != native._heard_seq:
			# _hear's own path, asserted native: a silent fall back to script would compare script with script.
			var ok := [false]
			if t % 2 == 1 and GSBotBrain._held_available():
				# As a worker thinks: the bodies held on the main thread, the hearing on a worker (no packed senses there).
				native.par_ready(world)
				var task := WorkerThreadPool.add_task(func() -> void: ok[0] = native._hear_native(me, all, world, p, now, newest))
				WorkerThreadPool.wait_for_task_completion(task)
				held += 1
			else:
				ok[0] = native._hear_native(me, all, world, p, now, newest)
			if not ok[0]:
				return "hear think %d: the native mind did not hear (held %s)" % [t, t % 2 == 1]
		script._hear(me, all, world, p, now)
		if native._rng._counter != before:
			heard += 1
		var n := [native._heard_seq, native._heard_pos, native._heard_at, native._chase_sound, native._known_enemy, native._rng._counter]
		var s := [script._heard_seq, script._heard_pos, script._heard_at, script._chase_sound, script._known_enemy, script._rng._counter]
		if n != s:
			return "hear think %d: native %s, script %s" % [t, n, s]
	if heard * 8 < THINKS:
		return "too little heard to compare: %d of %d thinks" % [heard, THINKS]
	stats["thinks"] = THINKS
	stats["heard"] = heard
	stats["held"] = held
	return ""
