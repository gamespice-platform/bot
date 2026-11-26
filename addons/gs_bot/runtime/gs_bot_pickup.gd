class_name GSBotPickup
extends RefCounted

## A quiet bot with a worse or empty weapon, or low ammo, notices a better one, walks to it and presses the use key; it returns what to do and the game's own use path does the taking.
## Better is the game's rating ([member GSBotContact.loadout], [method GSBotWorld.drops]); a game with its own idea of a goal overrides [method gain].

## Least gain worth a walk.
const MIN_GAIN := 0.1
## Under this fraction of ammunition a bot wants more of the same slot.
const LOW_AMMO := 0.3
## Flat metres from the weapon at which the bot stops and presses.
const REACH := 1.1
## Seconds a goal may take before it is given up.
const GIVE_UP := 12.0
## Seconds a goal that was tried or given up is left alone.
const RETRY := 20.0
## Seconds without a step after which the plan is forgotten (a fight came between).
const STALE := 0.5
## What [method step] gives with nothing to fetch: one read-only empty plan rather than a new one every think.
const NONE := {}

## Seconds the use key stays down: past the game's hold-to-swap time.
var hold_time: float = 0.8

var _goal: int = -1
var _noticed_at: float = 0.0
var _pressed_at: float = -1.0
var _last: float = -INF
var _skip: Dictionary = {}
## When a quiet bot next looks over the drops ([member GSBotProfile.replan_every]).
var _look_next: float = -INF
## The owning brain's profile clock ([GSBotClock]); null in one made without a brain.
var clock: GSBotClock = null
## 1 when this is GSBotPickup itself (a subclass may override [method gain], which the native choice cannot see); -1 unknown.
var _plain := -1


## The plan this tick: [code]{position, use}[/code], or empty when the bot has nothing to fetch.
## [param quiet] false (a fight, a sound, a hit) cancels it.
## [param mind] a GSSimBotMind with [code]pickup_choose[/code]: the choice is made natively over [method GSBotWorld.drop_table]
## (the same drop to the bit, sight asked for the same drops); null, or no table this tick, in script.
func step(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, now: float, quiet: bool, mind: Object = null) -> Dictionary:
	if now - _last > STALE:
		cancel()
	_last = now
	if not quiet or p.pickup_weapons < 0.5 or world == null:
		cancel()
		return NONE
	if _plain < 0:
		_plain = 1 if (get_script() as Script).get_base_script() == null else 0
	var t_drops := Time.get_ticks_usec() if GSBotClock.on else 0
	var table: GSBotWorld.DropTable = world.drop_table() if mind != null and _plain == 1 else null
	var drops := world.drops() if table == null else []
	if t_drops:
		GSBotClock.add(clock, GSBotClock.Q_DROPS, t_drops)
	var at: Variant = null
	if table != null:
		var i := table.ids.find(_goal)
		if i >= 0:
			at = table.at[i]
	else:
		var d := _find(drops, _goal)
		if not d.is_empty():
			at = d["position"]
	if _goal != -1 and at == null:
		cancel()
		return NONE
	if at == null:
		if p.replan_every > 0.0:
			if now < _look_next:
				return NONE
			_look_next = now + p.replan_every
		var i := _choose_native(me, world, p, table, now, mind) if table != null else -2
		if i == -2:
			if table != null:
				drops = world.drops()
			var d := _choose(me, world, p, drops, now)
			if d.is_empty():
				return NONE
			_goal = int(d["id"])
			at = d["position"]
		elif i < 0:
			return NONE
		else:
			_goal = table.ids[i]
			at = table.at[i]
		_noticed_at = now
	if now - _noticed_at > GIVE_UP:
		return _drop(now)
	if now - _noticed_at < p.reaction:
		return NONE
	var to: Vector3 = at
	var plan := {"position": to, "use": false}
	if absf(to.y - me.position.y) < 2.0 and Vector2(to.x - me.position.x, to.z - me.position.z).length() < REACH:
		if _pressed_at < 0.0:
			_pressed_at = now
		elif now - _pressed_at > hold_time:
			return _drop(now)
		plan["use"] = true
	return plan


## How much better a drop is than what [param me] holds in its slot (0.1 is worth a walk).
func gain(me: GSBotContact, drop: Dictionary) -> float:
	var mine: Variant = me.loadout.get(int(drop.get("slot", 0)))
	var value := float(drop.get("value", 0.0))
	if not (mine is Dictionary):
		return value
	var g := value - float(mine.get("value", 0.0))
	if float(mine.get("ammo", 1.0)) < LOW_AMMO and float(drop.get("ammo", 0.0)) > float(mine.get("ammo", 1.0)) + 0.3:
		g = maxf(g, -0.05) + 0.15
	return g


func cancel() -> void:
	_goal = -1
	_pressed_at = -1.0


## The weapon being fetched, or -1.
func goal() -> int:
	return _goal


func _drop(now: float) -> Dictionary:
	_skip[_goal] = now + RETRY
	cancel()
	return NONE


func _choose(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, drops: Array, now: float) -> Dictionary:
	var best := {}
	var best_score := -INF
	for d: Dictionary in drops:
		if float(_skip.get(int(d["id"]), -INF)) > now:
			continue
		var at: Vector3 = d["position"]
		var dist := me.position.distance_to(at)
		if dist > p.pickup_range:
			continue
		var g := gain(me, d)
		if g < MIN_GAIN:
			continue
		if p.through_walls < 0.5:
			var t_sight := Time.get_ticks_usec() if GSBotClock.on else 0
			var sees := world.line_of_sight(me.eye(), at + Vector3.UP * 0.3)
			if t_sight:
				GSBotClock.add(clock, GSBotClock.Q_SIGHT, t_sight)
			if not sees:
				continue
		var score := g - dist * 0.02
		if score > best_score:
			best_score = score
			best = d
	return best


## [method _choose] in one native call (GSSimBotMind.pickup_choose) over [param table]: the row chosen, -1 none, -2 the mind
## refused (the script then chooses). The loadout's dictionary slots and the skipped drops go packed; sight is
## [method GSBotWorld.sight_callable], asked for the drops and in the order the script asks.
func _choose_native(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, table: GSBotWorld.DropTable, now: float, mind: Object) -> int:
	var mine := PackedFloat64Array()
	for slot: Variant in me.loadout:
		var held: Variant = me.loadout[slot]
		if slot is int and held is Dictionary:
			mine.push_back(float(slot))
			mine.push_back(float(held.get("value", 0.0)))
			mine.push_back(float(held.get("ammo", 1.0)))
	var skip_ids := PackedInt64Array()
	var skip_until := PackedFloat64Array()
	for id: int in _skip:
		skip_ids.push_back(id)
		skip_until.push_back(float(_skip[id]))
	return int(mind.pickup_choose(table.ids, table.at, table.rows, mine, skip_ids, skip_until, me.position, me.eye(),
			p.pickup_range, not (p.through_walls < 0.5), now, world.sight_callable()))


static func _find(drops: Array, id: int) -> Dictionary:
	for d: Dictionary in drops:
		if int(d["id"]) == id:
			return d
	return NONE
