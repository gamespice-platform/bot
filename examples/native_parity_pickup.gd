extends RefCounted

## GSBotPickup's native choice (GSSimBotMind.pickup_choose over GSBotWorld.drop_table) against script, to the bit:
## two pickups walk one bot through a world of weapons that come and go (some missing slot, value or ammo, loadouts
## with empty, odd and dry slots, skips, sight that hides some, ranges, replans and stale gaps) for many steps, every
## other one on a worker thread; every plan, every field the pickup keeps and every sight asked must agree.

const STEPS := 6000
const TICK := 1.0 / 30.0


## An empty string when every step matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	if not GSBotBrain._pickup_available():
		stats["skipped"] = true
		return ""
	var brain := GSBotBrain.new(5)
	var mind: Object = brain._pickup_mind()
	if mind == null:
		stats["skipped"] = true
		return ""
	var dice := RandomNumberGenerator.new()
	dice.seed = 23
	var drops: Array = []
	var asked: Array = []
	var world := GSBotWorld.new()
	world.drops_fn = func() -> Array: return drops
	world.line_of_sight_fn = func(from: Vector3, to: Vector3) -> bool:
		asked.append([from, to])
		return fmod(absf(to.x * 7.3 + to.z * 3.1), 1.0) > 0.3
	var me := GSBotContact.new()
	me.id = 5
	me.alive = true
	var p := GSBotProfile.new()
	p.pickup_weapons = 1.0
	p.reaction = 0.2
	var native := GSBotPickup.new()
	var script := GSBotPickup.new()
	var now := 0.0
	var chosen := 0
	var used := 0
	var worker := 0
	var sights := 0
	for t in STEPS:
		now += TICK if dice.randf() > 0.01 else 0.7  # now and then a gap past STALE
		world.contacts_version = t
		if t % 400 == 0:
			p.pickup_range = [12.0, 25.0, 60.0][dice.randi_range(0, 2)]
			p.through_walls = [0.0, 0.0, 1.0][dice.randi_range(0, 2)]
			p.replan_every = [0.0, 0.25][dice.randi_range(0, 1)]
			me.loadout = _loadout(dice)
		if t % 37 == 0 or drops.is_empty():
			_shuffle_drops(drops, dice, me.position)
		var goal := native.goal()
		if goal != -1 and dice.randf() < 0.05:
			for d: Dictionary in drops:
				if int(d["id"]) == goal:
					me.position = d["position"] + Vector3(dice.randf_range(-0.5, 0.5), 0.0, dice.randf_range(-0.5, 0.5))
		else:
			me.position += Vector3(dice.randf_range(-0.6, 0.6), 0.0, dice.randf_range(-0.6, 0.6))
		var quiet := dice.randf() > 0.03
		var plans := [{}]
		asked.clear()
		if t % 2 == 1:
			var task := WorkerThreadPool.add_task(func() -> void: plans[0] = native.step(me, world, p, now, quiet, mind))
			WorkerThreadPool.wait_for_task_completion(task)
			worker += 1
		else:
			plans[0] = native.step(me, world, p, now, quiet, mind)
		var native_asked := asked.duplicate()
		asked.clear()
		var plan := script.step(me, world, p, now, quiet)
		if goal == -1 and native.goal() != -1:
			chosen += 1
		if bool(plan.get("use", false)):
			used += 1
		sights += asked.size()
		var n := [plans[0], native._goal, native._noticed_at, native._pressed_at, native._last, native._skip, native._look_next, native_asked]
		var s := [plan, script._goal, script._noticed_at, script._pressed_at, script._last, script._skip, script._look_next, asked]
		if n != s:
			return "pickup step %d: native %s, script %s" % [t, n, s]
	if world.drop_table() == null:
		return "pickup: no drop table, so nothing native was compared"
	if chosen < 50 or used < 20 or sights < 500:
		return "too little fetched to compare: %d chosen, %d used, %d sights over %d steps" % [chosen, used, sights, STEPS]
	stats["steps"] = STEPS
	stats["chosen"] = chosen
	stats["used"] = used
	stats["sights"] = sights
	stats["worker"] = worker
	return ""


## Slots 0-3: empty, a weapon (some dry), or something a pickup must not read as one (no dictionary, a string key).
static func _loadout(dice: RandomNumberGenerator) -> Dictionary:
	var out := {}
	for slot in 4:
		match dice.randi_range(0, 4):
			0:
				pass
			1:
				out[slot] = {"value": dice.randf(), "ammo": dice.randf_range(0.0, 0.4)}
			2:
				out[slot] = {"value": dice.randf()}
			3:
				out[slot] = 7
			_:
				out[slot] = {"value": dice.randf(), "ammo": dice.randf()}
	out["spare"] = {"value": 0.0, "ammo": 0.0}
	return out


## Some drops go, some come: ids may repeat across time, fields may be missing.
static func _shuffle_drops(drops: Array, dice: RandomNumberGenerator, near: Vector3) -> void:
	for i in range(drops.size() - 1, -1, -1):
		if dice.randf() < 0.3:
			drops.remove_at(i)
	for _k in dice.randi_range(1, 6):
		var d := {"id": dice.randi_range(1, 40),
			"position": near + Vector3(dice.randf_range(-30.0, 30.0), dice.randf_range(-1.0, 1.0), dice.randf_range(-30.0, 30.0))}
		if dice.randf() > 0.1:
			d["slot"] = dice.randi_range(0, 4)
		if dice.randf() > 0.1:
			d["value"] = dice.randf()
		if dice.randf() > 0.2:
			d["ammo"] = dice.randf()
		drops.append(d)
