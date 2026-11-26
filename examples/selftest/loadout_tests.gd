extends "res://examples/selftest/duel_tests.gd"

## GSBotLoadout: the kept loadout against a fresh GSBotArms.loadout_of every tick of a scripted fight.


class FakeCountAmmo extends RefCounted:
	var counts := {}

	func count(t: StringName) -> int:
		return int(counts.get(t, 0))


## An arsenal with GameSpice Weapon's two revisions: revision() for any change, weapons_revision() for the weapon set.
class FakeRevArsenal extends FakeArsenal:
	var rev := 0
	var weapons_rev := 0
	var pouch := FakeCountAmmo.new()

	func ammo() -> Object:
		return pouch

	func revision() -> int:
		return rev

	func weapons_revision() -> int:
		return weapons_rev


## One scripted fight of [param ticks] on a kept loadout: shots, reloads, ammunition and weapons picked up and
## dropped. Returns [mismatching ticks, rebuilds, patches, ticks the dictionary was replaced on an ammo change].
func _loadout_fight(ticks: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var arsenal := FakeRevArsenal.new()
	var rifle := FakeDef.new()
	var shotgun := FakeDef.new()
	shotgun.slot = 3
	shotgun.ammo_type = &"shell"
	shotgun.magazine = 6
	var a := FakeHeld.new()
	a.def = rifle
	arsenal.held[2] = a
	arsenal.pouch.counts = {&"bullet": 30, &"shell": 12}
	var kept := GSBotLoadout.new()
	var rater := func(d: Object) -> float: return GSBotArms.rate(d)
	var bad := 0
	var replaced := 0
	var built0 := GSBotLoadout.rebuilds
	var patched0 := GSBotLoadout.patches
	var last: Dictionary = kept.of(arsenal, rater)
	for t in ticks:
		var roll := rng.randi_range(0, 99)
		var weapons_moved := false
		var slots: Array = arsenal.held.keys()
		var held: FakeHeld = arsenal.held[slots[rng.randi_range(0, slots.size() - 1)]] if not slots.is_empty() else null
		if roll < 50 and held != null and held.magazine > 0:
			held.magazine -= 1
			arsenal.rev += 1
		elif roll < 62 and held != null:
			var type: StringName = held.def.get(&"ammo_type")
			var take := mini(int(held.def.get(&"magazine")) - held.magazine, int(arsenal.pouch.counts[type]))
			held.magazine += take
			arsenal.pouch.counts[type] = int(arsenal.pouch.counts[type]) - take
			arsenal.rev += 1
		elif roll < 70:
			arsenal.pouch.counts[&"bullet"] = int(arsenal.pouch.counts[&"bullet"]) + rng.randi_range(1, 20)
			arsenal.rev += 1
		elif roll < 74:
			if arsenal.held.has(3):
				arsenal.held.erase(3)
			else:
				var s := FakeHeld.new()
				s.def = shotgun
				s.magazine = rng.randi_range(0, 6)
				arsenal.held[3] = s
			weapons_moved = true
		elif roll < 75:
			var swap := FakeHeld.new()
			swap.def = rifle if rng.randf() < 0.5 else FakeDef.new()
			arsenal.held[2] = swap
			weapons_moved = true
		if weapons_moved:
			arsenal.rev += 1
			arsenal.weapons_rev += 1
		var now: Dictionary = kept.of(arsenal, rater)
		if now != GSBotArms.loadout_of(arsenal, rater):
			bad += 1
		if not weapons_moved and not is_same(now, last):
			replaced += 1
		last = now
	return [bad, GSBotLoadout.rebuilds - built0, GSBotLoadout.patches - patched0, replaced]


func _test_loadout() -> void:
	_section("loadout: kept between ticks, rebuilt on a weapon-set change, ammunition patched in place")
	var was := GSBotLoadout.incremental
	GSBotLoadout.incremental = true
	var fight := _loadout_fight(600)
	_check(fight[0] == 0, "600 ticks of a scripted fight: the kept loadout equals a fresh loadout_of every tick (%d differ)" % fight[0])
	_check(fight[2] > 300 and fight[1] < 60, "shots and reloads patch the ammunition (%d patches), only weapon-set changes rebuild (%d)" % [fight[2], fight[1]])
	_check(fight[3] == 0, "a patch keeps the same dictionary, a reader holding it sees the new ammunition")
	GSBotLoadout.incremental = false
	var full := _loadout_fight(600)
	_check(full[0] == 0 and full[2] == 0 and full[1] > 300, "incremental off (the cvar fallback) rebuilds on every revision, same loadouts (%d rebuilds)" % full[1])
	GSBotLoadout.incremental = was

	var kept := GSBotLoadout.new()
	var plain := FakeArsenal.new()
	var h := FakeHeld.new()
	h.def = FakeDef.new()
	plain.held[2] = h
	var first := kept.of(plain)
	_check(not is_same(first, kept.of(plain)) and kept.of(plain) == GSBotArms.loadout_of(plain), "an arsenal without revision() is built whole on every call")
	_check(kept.of(null).is_empty(), "no arsenal, empty loadout")

	GSBotLoadout.verify = true
	var misses0 := GSBotLoadout.misses
	var arsenal := FakeRevArsenal.new()
	arsenal.held[2] = h
	arsenal.pouch.counts = {&"bullet": 15}
	kept.of(arsenal)
	h.magazine -= 1  # a shot that forgets to move revision(): the kept loadout is now stale
	kept.of(arsenal)
	GSBotLoadout.verify = false
	_check(GSBotLoadout.misses == misses0 + 1, "verify counts a loadout that differs from a fresh build")
	_done()
