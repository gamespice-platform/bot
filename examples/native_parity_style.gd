extends RefCounted

## GSBotStyle's places native (GSSimBotMind.style_cover, style_vantage) against script, to the bit:
## two streams with the same seed, the same positions, threats and worlds, many calls; the spot
## (or `{at, face}`) and the stream's counter after must match. Sight and the standable snap are
## hashes of the asked points, so a point asked off by one ulp answers differently and shows.

const CALLS := 6000


## An empty string when every call matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	if not GSBotStyle._native_places(ClassDB.instantiate(&"GSSimBotMind") if ClassDB.class_exists(&"GSSimBotMind") else null):
		stats["skipped"] = true
		return ""
	var mind: Object = ClassDB.instantiate(&"GSSimBotMind")
	var streams: Array[GSRandomStream] = [GSRandomStream.new(53).stream(&"gs_bot_style"), GSRandomStream.new(53).stream(&"gs_bot_style")]
	var dice := RandomNumberGenerator.new()
	dice.seed = 11
	var open_share := [0.6]
	var world := GSBotWorld.new()
	world.line_of_sight_fn = func(from: Vector3, to: Vector3) -> bool:
		return float(hash([from, to]) % 1000) / 1000.0 < open_share[0]
	var snapping := world.walkable_fn
	var snap := func(at: Vector3) -> Vector3:
		if hash(at) % 5 == 0:
			return Vector3.INF
		return Vector3(snappedf(at.x, 0.25), at.y - 0.3, snappedf(at.z, 0.25))
	var held: Array[PackedVector3Array] = [PackedVector3Array()]  # a lambda captures a packed array by value
	world.waypoints_fn = func() -> PackedVector3Array:
		return held[0]
	var counts := {"cover": 0, "cover_snapped": 0, "cover_back": 0, "vantage": 0, "vantage_found": 0, "vantage_empty": 0}
	for call in CALLS:
		var here := Vector3(dice.randf_range(-40.0, 40.0), dice.randf_range(-3.0, 3.0), dice.randf_range(-40.0, 40.0))
		open_share[0] = [0.2, 0.6, 0.95, 1.0][dice.randi() % 4]
		if call % 2 == 0:
			world.walkable_fn = snap if dice.randf() < 0.6 else snapping
			var threat := here + Vector3(dice.randf_range(-30.0, 30.0), dice.randf_range(-2.0, 2.0), dice.randf_range(-30.0, 30.0))
			if dice.randf() < 0.05:
				threat = Vector3(here.x, threat.y, here.z)
			var eye := threat + Vector3.UP * 1.6
			var got: Array[Vector3] = []
			for i in 2:
				got.append(GSBotStyle.cover_near(here, threat, eye, world, streams[i], null, null if i == 0 else mind))
			if got[0] != got[1] or streams[0]._counter != streams[1]._counter:
				return "cover call %d: script %s (counter %d), native %s (counter %d)" % [call, got[0], streams[0]._counter, got[1], streams[1]._counter]
			counts["cover"] += 1
			if world.walkable_fn.is_valid():
				counts["cover_snapped"] += 1
			if got[0].distance_to(here) > 4.9 and got[0].distance_to(here) < 5.1 or got[0] == here:
				counts["cover_back"] += 1
		else:
			var points := PackedVector3Array()
			for _k in [0, 1, 4, 12, 40][dice.randi() % 5]:
				points.append(here + Vector3(dice.randf_range(-80.0, 80.0), dice.randf_range(-6.0, 6.0), dice.randf_range(-80.0, 80.0)))
			held[0] = points
			var away := Vector3.INF if dice.randf() < 0.3 else here + Vector3(dice.randf_range(-6.0, 6.0), 0.0, dice.randf_range(-6.0, 6.0))
			var got: Array[Dictionary] = []
			for i in 2:
				got.append(GSBotStyle.vantage(here, away, world, streams[i], null, null if i == 0 else mind))
			if got[0] != got[1] or streams[0]._counter != streams[1]._counter:
				return "vantage call %d (%d points): script %s (counter %d), native %s (counter %d)" % [call, points.size(), got[0], streams[0]._counter, got[1], streams[1]._counter]
			counts["vantage"] += 1
			counts["vantage_found" if not got[0].is_empty() else "vantage_empty"] += 1
	if counts["vantage_found"] == 0 or counts["vantage_empty"] == 0 or counts["cover_back"] == 0 or counts["cover_snapped"] == 0:
		return "style parity did not reach every case: %s" % counts
	stats.merge(counts)
	return ""
