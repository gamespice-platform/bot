class_name GSBotLoadout
extends RefCounted

## One player's [member GSBotContact.loadout] kept between ticks (API 48). [method of] rebuilds it with
## [method GSBotArms.loadout_of] only when the arsenal's weapon set changes (GameSpice Weapon's
## [code]weapons_revision()[/code], API 59) and patches the [code]"ammo"[/code] fractions in place when only magazines or
## reserves moved (a shot, a reload, a pickup of ammunition), so a bot's loadout is no longer rebuilt after every shot.
## The dictionary returned is the same object across patches: a reader holding it sees the new ammunition.
## Ratings are kept from the last rebuild, so the rater must depend on the definition alone. Duck typed like GSBotArms.

## False rebuilds whole on every [code]revision()[/code] change, the behaviour before API 48 (a game's cvar fallback).
static var incremental := true
## True compares every result with a fresh [method GSBotArms.loadout_of] and counts each difference in [member misses] (a parity test).
static var verify := false
## Results that differed from a fresh build while [member verify] was on.
static var misses := 0
## Whole builds and in-place patches since start, for tests and probes.
static var rebuilds := 0
static var patches := 0

var _arsenal_id := 0
var _rev := -1
var _weapons_rev := -1
var _out: Dictionary = {}
## [code][entry, held slot, def][/code] per carried weapon, the entry being the [code]{value, ammo}[/code] in [member _out].
var _rows: Array = []


## The loadout of [param arsenal], kept while its [code]revision()[/code] holds. [param rater] as in
## [method GSBotArms.loadout_of]. An arsenal without [code]revision()[/code] is built whole on every call.
func of(arsenal: Object, rater: Callable = Callable()) -> Dictionary:
	if arsenal == null:
		forget()
		return _out
	var id := arsenal.get_instance_id()
	# Kept for this arsenal (_rev is only kept for one with revision()): no has_method a player a tick.
	if id == _arsenal_id and _rev >= 0:
		var rev: int = arsenal.call(&"revision")
		if rev != _rev:
			if incremental and _weapons_rev >= 0 and int(arsenal.call(&"weapons_revision")) == _weapons_rev:
				_patch(arsenal)
				_rev = rev
			else:
				_rebuild(arsenal, rater, id, rev)
	else:
		_rebuild(arsenal, rater, id, int(arsenal.call(&"revision")) if arsenal.has_method(&"revision") else -1)
	if verify and _out != GSBotArms.loadout_of(arsenal, rater):
		misses += 1
	return _out


## Drops what is kept; the next [method of] builds whole.
func forget() -> void:
	_arsenal_id = 0
	_rev = -1
	_weapons_rev = -1
	_out = {}
	_rows.clear()


func _rebuild(arsenal: Object, rater: Callable, id: int, rev: int) -> void:
	rebuilds += 1
	var weapons: int = int(arsenal.call(&"weapons_revision")) if rev >= 0 and arsenal.has_method(&"weapons_revision") else -1
	# A new dictionary: a reader that kept the old one keeps the old weapon set, as with GSBotArms.loadout_of.
	_out = GSBotArms.loadout_of(arsenal, rater)
	_rows.clear()
	for slot: int in _out:
		var held: Object = arsenal.call(&"slot_at", slot)
		_rows.append([_out[slot], held, held.get(&"def")])
	_arsenal_id = id
	_rev = rev
	_weapons_rev = weapons


func _patch(arsenal: Object) -> void:
	patches += 1
	var ammo: Object = arsenal.call(&"ammo")
	for row: Array in _rows:
		var held: Object = row[1]
		var def: Object = row[2]
		var type: StringName = def.get(&"ammo_type")
		var reserve: int = int(ammo.call(&"count", type)) if ammo != null and type != &"" else 0
		(row[0] as Dictionary)["ammo"] = GSBotArms.ammo_fraction(def, int(held.get(&"magazine")), reserve)
