extends "res://examples/selftest/nav_tile_tests.gd"
## The weapon-style sections of the bot suite: the table and its config, bots that differ, a
## sniper that peeks, hides and moves, a shotgun that rushes, and no style at all being the
## generic bot to the bit.


func _test_style_table() -> void:
	_section("styles: a weighted table per weapon class, set by file and weights")
	var classes := ["sniper", "rifle", "smg", "shotgun", "pistol", "heavy", "launcher", "melee", "throw"]
	var missing := classes.filter(func(k: String) -> bool: return not GSBotStyle.DEFAULTS.has(k))
	_check(missing.is_empty(), "the built-in table has a style for every common weapon class", str(missing))
	var rows := [{"weight": 1.0}, {"weight": 0.0}, {"weight": 3.0}]
	_check(GSBotStyle.pick(rows, 0.1) == 0 and GSBotStyle.pick(rows, 0.5) == 2, "a pick follows the weights and never lands on a zero")
	_check(GSBotStyle.pick([{"weight": 0.0}], 0.5) == -1, "a class whose styles all weigh nothing has none")

	var weighted := GSBotStyle.build_table(GSBotStyle.DEFAULTS, "", "sniper.camper=0, smg.flanker=7")
	var camper: Dictionary = (weighted["table"]["sniper"] as Array)[0]
	_check(bool(weighted["ok"]) and is_zero_approx(float(camper["weight"])), "bot_style_weights sets one style's weight", str(weighted["error"]))
	_check(float((GSBotStyle.DEFAULTS["sniper"] as Array)[0]["weight"]) > 0.0, "and leaves the built-in table alone")
	var bad := GSBotStyle.build_table(GSBotStyle.DEFAULTS, "", "sniper.nobody=2")
	_check(not bool(bad["ok"]) and bad["table"] == GSBotStyle.DEFAULTS, "a weight for a style that is not there is refused", str(bad["error"]))
	var json := '{"railgun": [{"name": "lurker", "fight": "peek", "range": 3.0}], "sniper": [{"name": "camper", "range": 4.0}]}'
	var filed := GSBotStyle.build_table(GSBotStyle.DEFAULTS, json, "")
	var sniper: Array = filed["table"]["sniper"]
	_check(bool(filed["ok"]) and filed["table"].has("railgun") and is_equal_approx(float(sniper[0]["range"]), 4.0) and sniper.size() == (GSBotStyle.DEFAULTS["sniper"] as Array).size(),
		"a style file adds a game's own class and changes only the keys it names", str(filed["error"]))
	_check(not bool(GSBotStyle.build_table(GSBotStyle.DEFAULTS, "[1, 2]", "")["ok"]), "a file that is not a class table is refused")

	var s := GSBotSettings.new()
	var stamp := s.style_stamp()
	var path := "user://dot_bot_style_test.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(json)
	f.close()
	var res := s.set_style_config(path, "sniper.roamer=0")
	_check(res.ok and s.style_stamp() == stamp + 1 and s.style_table().has("railgun"), "bot_style_file and bot_style_weights reach the settings", (res.error.message if res.error else ""))
	var child := GSBotSettings.derived(s, GSBotPersona.new(), 3)
	_check(child.style_table().has("railgun") and child.style_stamp() == s.style_stamp(), "a bot's own settings read the server's table")
	_check(not s.set_style_config("user://no_such_style.json", "").ok and s.style_table().has("railgun"), "a missing file changes nothing")
	_check(s.set_style_config("", "").ok and s.style_table() == GSBotStyle.DEFAULTS, "both empty is the built-in table again")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_done()


## [param brain] fighting in [param world] for [param seconds] with its legs walked at 4 m/s.
func _walk_fight(brain: GSBotBrain, me: GSBotContact, world: GSBotWorld, seconds: float, states: Dictionary) -> void:
	var t := 0.0
	while t < seconds:
		var intent := brain.think(me, world, t)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch
		var y := deg_to_rad(intent.yaw)
		var forward := Vector3(-sin(y), 0.0, -cos(y))
		var right := Vector3(cos(y), 0.0, -sin(y))
		var speed := 2.0 if intent.walk else 4.0
		me.position += (right * intent.move.x + forward * intent.move.y) * speed * TICK
		states[intent.state] = int(states.get(intent.state, 0)) + 1
		t += TICK


func _test_style_play() -> void:
	_section("styles: bots differ, a sniper peeks and hides, a shotgun rushes, no style is the generic bot")
	# Twenty-four snipers off the built-in table.
	var labels := {}
	var ranges := {}
	for i in 24:
		var b := GSBotBrain.new(100 + i)
		var me := GSBotContact.make(100 + i, Vector3.ZERO)
		me.weapon_class = &"sniper"
		var _o := b.think(me, null, 0.0)
		labels[b.style.label()] = true
		ranges[snappedf(b.style.range_k, 0.001)] = true
	_check(labels.size() >= 2 and ranges.size() >= 12, "two dozen snipers play more than one style, and each its own range", "%s, %d ranges" % [labels.keys(), ranges.size()])
	var b0 := GSBotBrain.new(100)
	var me0 := GSBotContact.make(100, Vector3.ZERO)
	me0.weapon_class = &"sniper"
	var _o0 := b0.think(me0, null, 0.0)
	var first := b0.style.range_k
	me0.alive = false
	var _d := b0.think(me0, null, 1.0)
	me0.alive = true
	var _r := b0.think(me0, null, 2.0)
	_check(not is_equal_approx(first, b0.style.range_k), "a new life plays it a little differently", "%.3f then %.3f" % [first, b0.style.range_k])

	# A camping sniper 30 m from a standing enemy, a pillar to its east (x > 1.5 hides it), and
	# waypoints for vantages.
	var s := GSBotSettings.new()
	var _cfg := s.set_style_config("", "sniper.roamer=0,sniper.aggressive=0")
	var brain := GSBotBrain.new(7, s)
	var me := GSBotContact.make(1, Vector3.ZERO)
	me.weapon_class = &"sniper"
	var enemy := GSBotContact.make(2, Vector3(0.0, 0.0, -30.0))
	var world := GSBotWorld.new()
	world.contacts_fn = func() -> Array: return [me, enemy]
	world.line_of_sight_fn = func(a: Vector3, b: Vector3) -> bool: return a.x <= 1.5 and b.x <= 1.5
	world.waypoints_fn = func() -> PackedVector3Array:
		return PackedVector3Array([Vector3(-12.0, 2.0, 0.0), Vector3(-6.0, 0.0, 12.0), Vector3(0.0, 0.0, -30.0), Vector3(-14.0, 0.0, -24.0), Vector3(1.0, 0.0, 6.0)])
	var states := {}
	_walk_fight(brain, me, world, 40.0, states)
	var entered := brain.style.entered
	_check(brain.style.label() == "sniper/camper", "the weights chose the camper", brain.style.label())
	_check(int(entered.get("hide", 0)) >= 2 and states.has(&"cover"), "the sniper ducks into cover after its peeks", "%s %s" % [entered, states.keys()])
	_check(int(entered.get("return", 0)) + int(entered.get("move", 0)) >= 2, "and comes back to peek or moves to another angle", str(entered))
	_check(states.get(&"fight", 0) > 0 and states.size() >= 3, "between fighting from its peek", str(states))

	# A shotgun rusher 20 m off closes in.
	var g := GSBotSettings.new()
	var _gcfg := g.set_style_config("", "shotgun.flanker=0,shotgun.ambusher=0")
	var rusher := GSBotBrain.new(9, g)
	var me2 := GSBotContact.make(1, Vector3.ZERO)
	me2.weapon_class = &"shotgun"
	var foe := GSBotContact.make(2, Vector3(0.0, 0.0, -20.0))
	var open := GSBotWorld.new()
	open.contacts_fn = func() -> Array: return [me2, foe]
	open.line_of_sight_fn = func(_a: Vector3, _b: Vector3) -> bool: return true
	var rstates := {}
	_walk_fight(rusher, me2, open, 3.0, rstates)
	_check(rstates.has(&"rush") and me2.position.distance_to(foe.position) < 12.0, "a shotgun rusher closes in", "%.1f m, %s" % [me2.position.distance_to(foe.position), rstates.keys()])

	# No class, and a class with bot_styles 0: the same intents as each other, tick for tick.
	var runs: Array = []
	for mode in 2:
		var ps := GSBotSettings.new()
		if mode == 1:
			var _sv := ps.set_value("styles", "0")
		var nb := GSBotBrain.new(11, ps)
		var sc := _scene(Vector3(3.0, 0.0, -18.0))
		var m: GSBotContact = sc[0]
		if mode == 1:
			m.weapon_class = &"sniper"
		var trace := PackedStringArray()
		for intent: GSBotIntent in _run_bot(nb, m, sc[2], 3.0):
			trace.append("%s %s %.4f %.4f %s %s" % [intent.state, intent.move, intent.yaw, intent.pitch, intent.fire, intent.crouch])
		runs.append(trace)
	_check(runs[0] == runs[1], "bot_styles 0 with a class plays exactly as no class at all")
	_done()
