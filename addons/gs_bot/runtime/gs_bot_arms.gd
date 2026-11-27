class_name GSBotArms
extends RefCounted

## The generic half of feeding [GSBotPickup]: rates weapons by damage per second and builds a contact's [member GSBotContact.loadout] and the world's [member GSBotWorld.drops_fn]
## from a GameSpice Weapon arsenal and drop set. Duck typed (no GameSpice Weapon class is named), so GameSpice Bot compiles without it.
## Wire it with [code]GSBotArms.wire(world, drops_fn, arsenal_fn)[/code] and [code]contact.loadout = GSBotArms.loadout_of(player.arsenal)[/code].

## Damage per second that rates 1.0.
const FULL_DPS := 12.0 * 20.0
## Ticks per second the weapon definition's intervals are in.
const TICK_RATE := 20.0


## Damage per second of a weapon definition, 0 to 1: crude on purpose, a game with a better idea
## passes its own rating to [method loadout_of] and [method drops_of].
static func rate(def: Object) -> float:
	if def == null:
		return 0.0
	var damage := 10.0
	var pellets := 1.0
	var tuning: Variant = def.get("tuning")  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	if tuning is Object:
		var t: Object = tuning
		var d: Variant = t.get("damage")  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		if d != null:
			damage = float(d)
		var p: Variant = t.get("pellets")  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		if p != null:
			pellets = float(p)
	var interval := maxi(int(def.get("use_interval_ticks")), 1)  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	return clampf(damage * pellets * TICK_RATE / float(interval) / FULL_DPS, 0.0, 1.0)


## Fraction of a full load a weapon has: magazine plus reserve against its caps.
static func ammo_fraction(def: Object, magazine: int, reserve: int) -> float:
	if def == null or bool(def.get("infinite_reserve")):  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		return 1.0
	var full := int(def.get("magazine")) + int(def.call("reserve_cap"))  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	return clampf(float(magazine + reserve) / float(maxi(full, 1)), 0.0, 1.0)


## [code]{slot: {value, ammo}}[/code] for what [param arsenal] carries; empty when it has none.
## [param rater] is [code]Callable(def) -> float[/code], [method rate] when invalid.
static func loadout_of(arsenal: Object, rater: Callable = Callable()) -> Dictionary:
	var out := {}
	if arsenal == null:
		return out
	var ammo: Object = arsenal.call("ammo")  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	var custom := rater.is_valid()
	for slot in range(1, 10):
		var held: Object = arsenal.call("slot_at", slot)  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		if held == null:
			continue
		var def: Object = held.get("def")  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		if def == null:
			continue
		var type: StringName = def.get("ammo_type")  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		var reserve: int = int(ammo.call("count", type)) if ammo != null and type != &"" else 0  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		out[slot] = {"value": rater.call(def) if custom else rate(def),
			"ammo": ammo_fraction(def, int(held.get("magazine")), reserve)}  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	return out


## The weapons lying in [param drops] in the shape [member GSBotWorld.drops_fn] wants; the
## definitions come from [param arsenal]'s catalogue.
static func drops_of(drops: Object, arsenal: Object, rater: Callable = Callable()) -> Array:
	var out := []
	var catalogue: Object = arsenal.get("catalogue") if arsenal != null else null  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	if drops == null or catalogue == null:
		return out
	var custom := rater.is_valid()
	for d: Dictionary in drops.call("snapshot"):  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		var state: Dictionary = d["state"]
		var def: Object = catalogue.call("get_def", StringName(state["id"]))  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		if def == null:
			continue
		out.append({"id": d["id"], "position": (d["at"] as Transform3D).origin, "slot": int(def.get("slot")),
			"value": rater.call(def) if custom else rate(def),  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
			"ammo": ammo_fraction(def, int(state.get("magazine", 0)), int(state.get("reserve", 0)))})  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	return out


## Sets [member GSBotWorld.drops_fn]. [param drops_source] returns the drop set (or null),
## [param arsenal_source] any arsenal whose catalogue knows the weapons.
static func wire(world: GSBotWorld, drops_source: Callable, arsenal_source: Callable, rater: Callable = Callable()) -> void:
	world.drops_fn = func() -> Array: return drops_of(drops_source.call(), arsenal_source.call(), rater)
	world.drop_table_fn = func() -> Variant: return pack_drops(drops_source.call(), arsenal_source.call(), rater)


## gs-sim's native drop pack, reached by name (GSSimBotDrops.pack).
const DROPS_CLASS := &"GSSimBotDrops"
## 1 when the library has the pack, 0 not, -1 not asked yet.
static var _drops_known := -1


## [method drops_of] as [GSBotWorld]'s drop table columns ([code][ids, at, rows][/code]) in one native call
## (GSSimBotDrops.pack): the same columns to the bit, each weapon read once per pack rather than once per drop.
## null when the library has no pack or refuses an entry; the world then packs [method drops_of] in script.
static func pack_drops(drops: Object, arsenal: Object, rater: Callable = Callable()) -> Variant:
	if _drops_known < 0:
		_drops_known = 1 if ClassDB.class_exists(DROPS_CLASS) and ClassDB.class_has_method(DROPS_CLASS, &"pack") else 0
	if _drops_known == 0:
		return null
	var catalogue: Object = arsenal.get("catalogue") if arsenal != null else null  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	if drops == null or catalogue == null:
		return [PackedInt64Array(), PackedVector3Array(), PackedFloat64Array()]
	# What drops_of reads of a weapon: slot, value, the rounds when full ([method ammo_fraction]) and whether infinite.
	var def_row := func(id: Variant) -> PackedFloat64Array:
		var def: Object = catalogue.call("get_def", StringName(id))  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		if def == null:
			return PackedFloat64Array()
		var infinite := bool(def.get("infinite_reserve"))  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		var full := 0 if infinite else int(def.get("magazine")) + int(def.call("reserve_cap"))  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		var value: Variant = rater.call(def) if rater.is_valid() else rate(def)  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
		return PackedFloat64Array([float(int(def.get("slot"))), float(value), float(full), 1.0 if infinite else 0.0])
	var packed: Array = ClassDB.class_call_static(DROPS_CLASS, &"pack", drops.call("snapshot"), def_row)  # perf-lint: allow dynamic_call duck typed: GameSpice Bot names no weapon addon
	return packed if packed.size() == 3 else null
