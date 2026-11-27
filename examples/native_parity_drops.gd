extends RefCounted

## GSBotWorld.drop_table's native pack (GSSimBotDrops.pack through GSBotArms.pack_drops) against the script's
## (GSBotArms.drops_of, then the loop), to the bit: drop sets that come and go over a catalogue with unknown weapons,
## infinite ones, odd caps, rounds as int, float or missing, entries the pack refuses (it then falls back), with and
## without a game rater, every third pack on a worker thread; ids, positions and rows must agree byte for byte.

const STEPS := 3000


class Def:
	extends RefCounted
	var slot := 0
	var magazine := 0
	var cap := 0
	var infinite_reserve := false
	var use_interval_ticks := 1
	var tuning: Variant = null

	func reserve_cap() -> int:
		return cap


class Tuning:
	extends RefCounted
	var damage := 10.0
	var pellets := 1.0


class Catalogue:
	extends RefCounted
	var defs := {}

	func get_def(id: StringName) -> Object:
		return defs.get(id)


class Arsenal:
	extends RefCounted
	var catalogue: Catalogue = null


class Drops:
	extends RefCounted
	var list: Array = []

	func snapshot() -> Array:
		return list


## An empty string when every pack matched, else what differed; [param stats] gets the counts.
static func run(stats: Dictionary) -> String:
	if not (ClassDB.class_exists(GSBotArms.DROPS_CLASS) and ClassDB.class_has_method(GSBotArms.DROPS_CLASS, &"pack")):
		stats["skipped"] = true
		return ""
	var dice := RandomNumberGenerator.new()
	dice.seed = 41
	var arsenal := Arsenal.new()
	arsenal.catalogue = _catalogue(dice)
	var drops := Drops.new()
	var rater := func(def: Object) -> float: return fmod(float(def.get("magazine")) * 0.037 + float(def.get("slot")) * 0.11, 1.0)
	var was := GSBotWorld.native_drops
	var packs := 0
	var native := 0
	var refused := 0
	var worker := 0
	var rows := 0
	for t in STEPS:
		if t % 500 == 0:
			arsenal.catalogue = _catalogue(dice)
		_shuffle(drops.list, dice)
		var rated := rater if t % 2 == 0 else Callable()
		var a := GSBotWorld.new()
		var b := GSBotWorld.new()
		for w: GSBotWorld in [a, b]:
			w.contacts_version = t
			GSBotArms.wire(w, func() -> Object: return drops, func() -> Object: return arsenal, rated)
		var direct: Variant = GSBotArms.pack_drops(drops, arsenal, rated)
		if direct == null:
			refused += 1
		else:
			native += 1
		GSBotWorld.native_drops = true
		var got := [null]
		if t % 3 == 0:
			var task := WorkerThreadPool.add_task(func() -> void: got[0] = a.drop_table())
			WorkerThreadPool.wait_for_task_completion(task)
			worker += 1
		else:
			got[0] = a.drop_table()
		GSBotWorld.native_drops = false
		var want := b.drop_table()
		GSBotWorld.native_drops = was
		var n: GSBotWorld.DropTable = got[0]
		var nb := [var_to_bytes(n.ids), var_to_bytes(n.at), var_to_bytes(n.rows)]
		var sb := [var_to_bytes(want.ids), var_to_bytes(want.at), var_to_bytes(want.rows)]
		if nb != sb:
			return "drops pack %d: native %s %s %s, script %s %s %s" % [t, n.ids, n.at, n.rows, want.ids, want.at, want.rows]
		packs += 1
		rows += want.ids.size()
	if native < STEPS / 2 or refused < 20 or rows < STEPS * 3:
		return "too little packed to compare: %d native, %d refused, %d rows over %d packs" % [native, refused, rows, STEPS]
	stats["packs"] = packs
	stats["native"] = native
	stats["refused"] = refused
	stats["rows"] = rows
	stats["worker"] = worker
	return ""


## Weapons w0-w11: slots, caps and ratings of all sorts, some infinite, some with tuning; w12-w14 are asked for but unknown.
static func _catalogue(dice: RandomNumberGenerator) -> Catalogue:
	var c := Catalogue.new()
	for i in 12:
		var d := Def.new()
		d.slot = dice.randi_range(0, 4)
		d.magazine = dice.randi_range(0, 40)
		d.cap = [0, 0, dice.randi_range(1, 200), -5][dice.randi_range(0, 3)]
		d.infinite_reserve = dice.randf() < 0.2
		d.use_interval_ticks = dice.randi_range(0, 12)
		if dice.randf() < 0.6:
			var tu := Tuning.new()
			tu.damage = dice.randf_range(1.0, 120.0)
			tu.pellets = float(dice.randi_range(1, 9))
			d.tuning = tu
		c.defs[StringName("w%d" % i)] = d
	return c


## Some drops go, some come; rounds may be int, float or missing; now and then one the native pack refuses (a float
## drop id, rounds as a string), which the script still packs.
static func _shuffle(list: Array, dice: RandomNumberGenerator) -> void:
	for i in range(list.size() - 1, -1, -1):
		if dice.randf() < 0.3:
			list.remove_at(i)
	for _k in dice.randi_range(0, 5):
		var weapon: Variant = "w%d" % dice.randi_range(0, 14)
		if dice.randf() < 0.3:
			weapon = StringName(weapon)
		var state := {"id": weapon}
		match dice.randi_range(0, 5):
			0:
				pass
			1:
				state["magazine"] = dice.randf_range(0.0, 40.0)
			_:
				state["magazine"] = dice.randi_range(0, 40)
		if dice.randf() > 0.2:
			state["reserve"] = dice.randi_range(0, 300) if dice.randf() > 0.2 else dice.randf_range(0.0, 300.0)
		var id: Variant = dice.randi_range(1, 1000)
		if dice.randf() < 0.01:
			id = float(id)
		elif dice.randf() < 0.01:
			state["reserve"] = str(dice.randi_range(0, 9))
		var at := Transform3D(Basis.from_euler(Vector3(0.0, dice.randf_range(-3.0, 3.0), 0.0)),
				Vector3(dice.randf_range(-80.0, 80.0), dice.randf_range(-5.0, 20.0), dice.randf_range(-80.0, 80.0)))
		list.append({"id": id, "state": state, "at": at})
