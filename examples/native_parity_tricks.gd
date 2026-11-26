extends RefCounted

## GSBotTricks native (GSSimBotMind.tricks_step, its state kept in the mind) against script, to the
## bit: two tricks with the same stream fed the same bodies, intents, scenarios and walls for many
## ticks, every phase reached; the sides take turns going first, and now and then the native side
## thinks a tick in script, so the state moves out of the mind and back.
## The brain parity's bodies never run fast enough to slide, so this drives the tricks alone.

const TICKS := 6000
const TICK := 1.0 / 30.0
const SCENES: Array[StringName] = [&"close", &"chase", &"flee", &"roam", &"cover", &"fight"]


## An empty string when every tick matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	if not GSBotTricks._native_available():
		stats["skipped"] = true
		return ""
	var key_stream := GSRandomStream.new(41).stream(&"gs_bot")
	var mind: Object = ClassDB.instantiate(&"GSSimBotMind")
	mind.set_keys(0, key_stream._key)
	var rngs: Array[GSRandomStream] = [GSRandomStream.new(41).stream(&"gs_bot"), GSRandomStream.new(41).stream(&"gs_bot")]
	var sides: Array[GSBotTricks] = [GSBotTricks.new(), GSBotTricks.new()]
	var p := GSBotProfile.new()
	p.jump = 0.6
	p.trick_chain = 0.6
	p.cover_crouch = 0.6
	p.trick_delay = 0.2
	p.air_jump = 0.5
	p.wall_run = 0.8
	p.slide = 0.9
	var world := GSBotWorld.new()
	var dice := RandomNumberGenerator.new()
	dice.seed = 7
	var wall := [false, Vector3.ZERO]
	world.wall_fn = func(_from: Vector3, dir: Vector3, _reach: float) -> Dictionary:
		if not wall[0]:
			return {}
		return {"normal": wall[1] if wall[1] != Vector3.ZERO else -dir, "distance": 1.0 + absf(dir.x)}
	var me := GSBotContact.new()
	me.grounded = true
	var scene: StringName = &"close"
	var up := 0.0
	var now := 0.0
	for tick in TICKS:
		now += TICK
		# The body drifts: each field changes now and then, so phases run their course.
		if dice.randf() < 0.08:
			var speed := dice.randf_range(0.0, 13.0)
			var a := dice.randf_range(-PI, PI)
			me.velocity = Vector3(cos(a) * speed, 0.0, sin(a) * speed)
		if dice.randf() < 0.06:
			me.grounded = dice.randf() < 0.75
		if dice.randf() < 0.06:
			me.wall_running = dice.randf() < 0.4
		if dice.randf() < 0.05:
			me.air_jump_ready = dice.randf() < 0.5
			me.health = dice.randf()
		if dice.randf() < 0.04:
			scene = SCENES[dice.randi() % SCENES.size()]
			up = dice.randf_range(0.0, 4.0)
		if dice.randf() < 0.05:
			wall[0] = dice.randf() < 0.6
			wall[1] = Vector3(dice.randf_range(-1, 1), dice.randf_range(-0.5, 0.5), dice.randf_range(-1, 1)).normalized() if dice.randf() < 0.5 else Vector3.ZERO
		if dice.randf() < 0.01:
			for s in sides:
				s.reset()
		var move := Vector2(dice.randf_range(-1, 1), dice.randf_range(-1, 1)) if dice.randf() < 0.8 else Vector2.ZERO
		var yaw := dice.randf_range(-180.0, 180.0)
		var jump := dice.randf() < 0.05
		var crouch := dice.randf() < 0.05
		var dt := TICK if dice.randf() < 0.95 else 0.0
		var outs: Array[GSBotIntent] = [GSBotIntent.new(), GSBotIntent.new()]
		var in_script := dice.randf() < 0.01
		for j in 2:
			var i := j if tick % 2 == 0 else 1 - j
			var out := outs[i]
			out.move = move
			out.yaw = yaw
			out.jump = jump
			out.crouch = crouch
			sides[i].apply(me, world, p, rngs[i], scene, up, yaw, now, dt, out, mind if i == 0 and not in_script else null)
		sides[0].sync_out()
		var diff := _diff(sides[0], sides[1], rngs[0], rngs[1], outs[0], outs[1])
		if diff != "":
			return "tricks tick %d: %s" % [tick, diff]
	stats.merge(sides[0].counts)
	for k: StringName in sides[0].counts:
		if int(sides[0].counts[k]) == 0:
			return "tricks: no %s in %d ticks, a branch went untested" % [k, TICKS]
	return ""


static func _diff(a: GSBotTricks, b: GSBotTricks, ra: GSRandomStream, rb: GSRandomStream, oa: GSBotIntent, ob: GSBotIntent) -> String:
	var fields := [
		["phase", a._phase, b._phase], ["at", a._at, b._at], ["until", a._until, b._until],
		["look_at", a._look_at, b._look_at], ["quiet_until", a._quiet_until, b._quiet_until],
		["wall", a._wall, b._wall], ["chain", a._chain, b._chain], ["duck_until", a._duck_until, b._duck_until],
		["duck_next", a._duck_next, b._duck_next], ["air_next", a._air_next, b._air_next],
		["was_crouch", a._was_crouch, b._was_crouch], ["counter", ra._counter, rb._counter],
		["move", oa.move, ob.move], ["jump", oa.jump, ob.jump], ["crouch", oa.crouch, ob.crouch],
		["air_jump", oa.air_jump, ob.air_jump], ["counts", a.counts, b.counts],
	]
	for f: Array in fields:
		# Exact: == on floats and vectors here is the bit comparison this suite is for.
		if not (f[1] == f[2]) and not (f[1] is float and is_nan(f[1]) and is_nan(f[2])):
			return "%s native %s script %s" % [f[0], f[1], f[2]]
	return ""
