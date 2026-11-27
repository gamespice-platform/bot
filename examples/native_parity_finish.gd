extends RefCounted

## GSBotIntentTable.finish natively (GSSimBotFinish.write) against its script twin, to the bit: tables of random
## intents (sticks short, long, zero, tiny and huge; every button combination; maps with shared and empty bits),
## every row also checked against GSBotIntent's own arithmetic (move.limit_length(1.0), one bit per button).

const STEPS := 400


static func run(stats: Dictionary) -> String:
	if not GSBotIntentTable.native_available():
		stats["skipped"] = true
		return ""
	var dice := RandomNumberGenerator.new()
	dice.seed = 52
	var rows := 0
	for t in STEPS:
		var intents: Array = []
		for i in dice.randi_range(0, 40):
			intents.append(_intent(dice) if dice.randf() > 0.05 else null)
		var move_map := PackedInt32Array()
		var fire_map := PackedInt32Array()
		for k in GSBotIntentTable.BITS:
			move_map.append(0 if dice.randf() < 0.3 else 1 << dice.randi_range(0, 9))
			fire_map.append(0 if dice.randf() < 0.3 else 1 << dice.randi_range(0, 9))
		var native := GSBotIntentTable.new()
		native.pack(intents)
		native.finish(move_map, fire_map)
		var script := GSBotIntentTable.new()
		script.pack(intents)
		script.finish(move_map, fire_map, false)
		if native.digest() != script.digest():
			return "finish: step %d, %d rows: native and script tables differ" % [t, intents.size()]
		for i in intents.size():
			var intent: GSBotIntent = intents[i]
			if intent == null:
				continue
			var want := intent.move.limit_length(1.0)
			if var_to_bytes(native.cmd_move[i]) != var_to_bytes(want):
				return "finish: step %d row %d: stick %s, want %s" % [t, i, native.cmd_move[i], want]
			var bits := GSBotIntentTable.bits_of(intent)
			var mb := 0
			var fb := 0
			for k in GSBotIntentTable.BITS:
				if bits & (1 << k):
					mb |= move_map[k]
					fb |= fire_map[k]
			if native.move_buttons[i] != mb or native.fire_buttons[i] != fb:
				return "finish: step %d row %d: buttons %d/%d, want %d/%d" % [t, i, native.move_buttons[i], native.fire_buttons[i], mb, fb]
		rows += intents.size()
	stats["rows"] = rows
	return ""


static func _intent(dice: RandomNumberGenerator) -> GSBotIntent:
	var it := GSBotIntent.new()
	it.yaw = dice.randf_range(-720.0, 720.0)
	it.pitch = dice.randf_range(-89.0, 89.0)
	var kind := dice.randi_range(0, 4)
	var scale := [0.0, 1e-7, 1.0, 3.0, 1e6][kind] as float
	it.move = Vector2(dice.randf_range(-1.0, 1.0), dice.randf_range(-1.0, 1.0)) * scale
	if dice.randf() < 0.1:
		it.move = Vector2(1.0, 0.0) if dice.randf() < 0.5 else Vector2(0.6, 0.8)
	it.fire = dice.randf() < 0.5
	it.crouch = dice.randf() < 0.5
	it.jump = dice.randf() < 0.5
	it.walk = dice.randf() < 0.5
	it.air_jump = dice.randf() < 0.5
	it.throw = dice.randf() < 0.5
	it.use = dice.randf() < 0.5
	it.stranded = dice.randf() < 0.5
	it.ride = dice.randi_range(-1, 3)
	it.target_id = dice.randi_range(-1, 64)
	it.state = [&"roam", &"fight", &"hide", &"chase"][dice.randi_range(0, 3)]
	return it
