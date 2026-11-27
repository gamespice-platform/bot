extends RefCounted

## GSBotUnstick native (GSSimBotMind.unstick_step, its state kept in the mind) against script, to
## the bit: two unsticks with the same stream fed the same positions, pushes, clocks and worlds for
## many ticks, every level reached and cleared, the stranded report and both nudges (toward a
## standable point and the random one); now and then the native side steps in script, so the
## state moves out of the mind and back, and now and then both reset.

const TICKS := 20000
const TICK := 1.0 / 30.0


## An empty string when every tick matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	if not GSBotUnstick._native_available():
		stats["skipped"] = true
		return ""
	var mind: Object = ClassDB.instantiate(&"GSSimBotMind")
	var sides: Array[GSBotUnstick] = [GSBotUnstick.new(GSRandomStream.new(41).stream(&"gs_bot")), GSBotUnstick.new(GSRandomStream.new(41).stream(&"gs_bot"))]
	var dice := RandomNumberGenerator.new()
	dice.seed = 7
	var near := [Vector3.INF]
	var world := GSBotWorld.new()
	world.walkable_fn = func(_at: Vector3) -> Vector3:
		return near[0]
	var levels := {}
	var counts := {"stranded": 0, "nudges": 0, "handbacks": 0, "resets": 0}
	var pos := Vector3(dice.randf_range(-50.0, 50.0), dice.randf_range(-5.0, 5.0), dice.randf_range(-50.0, 50.0))
	var walking := false
	var pushing := true
	var now := 0.0
	for tick in TICKS:
		now += TICK
		# Stretches stuck against a wall, stretches walking freely, idle spells, small jitters.
		if dice.randf() < 0.01:
			walking = not walking
		if dice.randf() < 0.02:
			pushing = dice.randf() < 0.85
		if walking:
			pos += Vector3(dice.randf_range(0.05, 0.3), 0.0, dice.randf_range(-0.1, 0.1))
		elif dice.randf() < 0.3:
			pos += Vector3(dice.randf_range(-0.02, 0.02), 0.0, dice.randf_range(-0.02, 0.02))
		if dice.randf() < 0.05:
			var r := dice.randf()
			near[0] = Vector3.INF if r < 0.4 else (pos + Vector3(0.1, 0.0, 0.1) if r < 0.6 else pos + Vector3(dice.randf_range(-4.0, 4.0), 0.0, dice.randf_range(-4.0, 4.0)))
		var w: GSBotWorld = null if dice.randf() < 0.05 else world
		var after := 0.0 if dice.randf() < 0.1 else 4.0
		if dice.randf() < 0.0015:
			var at := Vector3.INF if dice.randf() < 0.5 else pos
			for s in sides:
				s.reset(at, now)
			counts["resets"] += 1
		var in_script := dice.randf() < 0.02
		if in_script:
			counts["handbacks"] += 1
		var got: Array[int] = []
		for i in 2:
			got.append(sides[i].step(pos, pushing, now, w, after, null if i == 0 or in_script else mind))
		var a := sides[0]
		var b := sides[1]
		if got[0] != got[1] or a.jump != b.jump or a.crouch != b.crouch or a.strafe != b.strafe or a.replan != b.replan or a.stranded != b.stranded or a.total != b.total or a.nudge_to != b.nudge_to:
			return "unstick tick %d (t %.3f): script level %d jump %s crouch %s strafe %s replan %s stranded %s total %d nudge %s; native level %d jump %s crouch %s strafe %s replan %s stranded %s total %d nudge %s" % [tick, now, got[0], a.jump, a.crouch, a.strafe, a.replan, a.stranded, a.total, a.nudge_to, got[1], b.jump, b.crouch, b.strafe, b.replan, b.stranded, b.total, b.nudge_to]
		levels[got[0]] = true
		if a.stranded:
			counts["stranded"] += 1
		if a.nudge_to != Vector3.INF:
			counts["nudges"] += 1
	if not levels.has(0) or not levels.has(4) or counts["stranded"] == 0 or counts["nudges"] == 0:
		return "unstick parity did not reach every case: levels %s, %s" % [levels.keys(), counts]
	stats.merge(counts)
	stats["levels"] = levels.size()
	return ""
