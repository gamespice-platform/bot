class_name GSBotStyle
extends RefCounted

## How one bot plays the weapon in its hand: a sniper finds an angle, holds it, peeks, ducks back
## into cover and moves after a kill; a shotgun rushes or flanks; a rifle strafes at mid range and
## reloads behind something.
##
## [b]A table of weighted styles per weapon class.[/b] [constant DEFAULTS] lists, for each class the
## game names in [member GSBotContact.weapon_class], a few styles with a weight. A bot rolls one
## per class from its own stream and keeps it (it is that bot's way with a sniper), picking again on
## a respawn with chance `bot_style_variety`. A server changes the table with `bot_style_file` (a
## JSON file in the same shape) and `bot_style_weights` (`sniper.camper=6,smg.flanker=0`), see
## [method GSBotSettings.style_table].
##
## [b]A style is numbers, then a few phases.[/b] The numbers scale or bias the profile the brain
## already uses (preferred range, reach, strafing, bursts; the per-engagement stop, crouch,
## aggression and peek chances), so the generic fight still runs underneath. The phases take the
## legs for a while: [constant HIDE] (back into cover), [constant RETURN] (sneak back to the peek
## spot), [constant MOVE] (to a new vantage) and [constant HOLD] (watch it). A rusher's fight turns
## the legs toward the target with a flank to one side.
##
## [b]Life to life.[/b] Each spawn jitters the style's range, strafing, aggression, patience and
## peek timing by up to `bot_style_variety`, so two snipers with the same style still differ.
##
## [b]Cheap.[/b] Per tick: a string compare and a few branches. Cover is looked for once per peek
## (up to six rays), a vantage once per hold (up to eighteen rays), from this bot's own
## [GSRandomStream] ([code]dot_bot_style[/code]), so the brain's own stream is untouched and a bot
## with no weapon class, or `bot_styles 0`, plays exactly as before.

const CHANNEL := "dot.bot"

## Phases.
const NONE := 0
const HIDE := 1
const RETURN := 2
const MOVE := 3
const HOLD := 4
const PHASE_NAMES: PackedStringArray = ["", "hide", "return", "move", "hold"]

## A fight closer than this is fought where it stands: no hiding, no flank.
const CLOSE := 5.0
## Metres from a spot that count as there.
const ARRIVE := 1.3
## Seconds a walk to a spot may take before it is given up.
const TRAVEL_MAX := 12.0
## Metres a vantage may be from the bot.
const VANTAGE_FAR := 60.0

## What a style row means when it leaves a key out: the generic fight.
const NEUTRAL := {
	"name": "generic", "weight": 1.0, "fight": "duel", "roam": "walk",
	"range": 1.0, "reach": 1.0, "strafe": 1.0, "burst": 1.0,
	"stop": 0.0, "crouch": 0.0, "aggression": 0.0, "peek_chance": 0.0,
	"peek": [1.0, 2.0], "hide": [1.0, 2.5], "patience": [6.0, 14.0],
	"reposition": 0.0, "sneak": 0.0, "flank": 0.0, "cover_reload": 0.0,
}

## The styles per weapon class. Keys of a row: [code]fight[/code] (duel: the generic strafe and
## shoot; peek: shoot for a moment, back into cover, come back; rush: close in, flanking),
## [code]roam[/code] (walk: the brain's roaming; camp: walk to a vantage, hold it), scales of the
## profile ([code]range[/code] bot_range, [code]reach[/code] bot_max_range, [code]strafe[/code],
## [code]burst[/code] longer bursts and shorter pauses above 1), biases added to the per-engagement
## chances ([code]stop[/code], [code]crouch[/code], [code]aggression[/code],
## [code]peek_chance[/code] bot_peek), seconds as [lo, hi] ([code]peek[/code] exposed before hiding,
## [code]hide[/code] in cover, [code]patience[/code] holding a vantage), and chances
## ([code]reposition[/code] moving after a peek or kill rather than coming back, [code]sneak[/code]
## walking quietly there, [code]flank[/code] rushing in from the side, [code]cover_reload[/code]
## hiding to reload).
const DEFAULTS := {
	"sniper": [
		{"name": "camper", "weight": 4.0, "fight": "peek", "roam": "camp", "range": 2.6, "reach": 2.2, "strafe": 0.3, "stop": 0.5, "crouch": 0.35, "aggression": -0.35, "peek_chance": 0.4, "peek": [1.2, 2.6], "hide": [1.2, 3.0], "patience": [8.0, 20.0], "reposition": 0.55, "sneak": 0.85, "cover_reload": 0.9},
		{"name": "roamer", "weight": 2.0, "fight": "peek", "roam": "walk", "range": 2.2, "reach": 2.0, "strafe": 0.5, "stop": 0.4, "crouch": 0.2, "aggression": -0.15, "peek_chance": 0.3, "peek": [0.8, 1.8], "hide": [0.8, 2.0], "reposition": 0.8, "sneak": 0.6, "cover_reload": 0.7},
		{"name": "aggressive", "weight": 1.0, "fight": "duel", "roam": "walk", "range": 1.6, "reach": 1.8, "strafe": 1.2, "stop": 0.2, "aggression": 0.2},
	],
	"marksman": [
		{"name": "anchor", "weight": 3.0, "fight": "peek", "roam": "walk", "range": 2.0, "reach": 1.6, "strafe": 0.5, "stop": 0.4, "crouch": 0.25, "peek_chance": 0.3, "peek": [1.0, 2.2], "hide": [1.0, 2.2], "reposition": 0.4, "sneak": 0.5, "cover_reload": 0.8},
		{"name": "roamer", "weight": 2.0, "fight": "duel", "roam": "walk", "range": 1.7, "reach": 1.5, "strafe": 0.9, "stop": 0.2},
		{"name": "camper", "weight": 1.0, "fight": "peek", "roam": "camp", "range": 2.2, "reach": 1.7, "strafe": 0.4, "stop": 0.4, "crouch": 0.3, "aggression": -0.25, "patience": [6.0, 14.0], "reposition": 0.5, "sneak": 0.7, "cover_reload": 0.8},
	],
	"rifle": [
		{"name": "strafer", "weight": 3.0, "fight": "duel", "roam": "walk", "range": 1.2, "strafe": 1.25, "burst": 0.8, "cover_reload": 0.7},
		{"name": "anchor", "weight": 2.0, "fight": "peek", "roam": "walk", "range": 1.5, "strafe": 0.6, "burst": 0.8, "stop": 0.25, "crouch": 0.2, "peek": [1.5, 3.0], "hide": [1.0, 2.0], "reposition": 0.3, "sneak": 0.4, "cover_reload": 0.9},
		{"name": "pusher", "weight": 1.5, "fight": "rush", "roam": "walk", "range": 0.8, "strafe": 1.2, "aggression": 0.3, "flank": 0.3, "cover_reload": 0.3},
	],
	"smg": [
		{"name": "rusher", "weight": 3.0, "fight": "rush", "roam": "walk", "range": 0.45, "strafe": 1.3, "burst": 1.5, "stop": -0.5, "crouch": -0.3, "aggression": 0.4, "flank": 0.25},
		{"name": "flanker", "weight": 2.0, "fight": "rush", "roam": "walk", "range": 0.5, "strafe": 1.1, "burst": 1.3, "stop": -0.4, "aggression": 0.2, "flank": 0.9, "sneak": 0.7},
		{"name": "skirmisher", "weight": 1.5, "fight": "duel", "roam": "walk", "range": 0.7, "strafe": 1.4, "burst": 1.2, "stop": -0.3, "cover_reload": 0.5},
	],
	"shotgun": [
		{"name": "rusher", "weight": 3.0, "fight": "rush", "roam": "walk", "range": 0.25, "reach": 0.6, "strafe": 1.2, "stop": -0.6, "crouch": -0.3, "aggression": 0.45, "flank": 0.2},
		{"name": "flanker", "weight": 2.0, "fight": "rush", "roam": "walk", "range": 0.3, "reach": 0.6, "strafe": 1.1, "stop": -0.5, "aggression": 0.25, "flank": 0.9, "sneak": 0.8},
		{"name": "ambusher", "weight": 1.0, "fight": "duel", "roam": "camp", "range": 0.3, "reach": 0.6, "strafe": 0.8, "stop": -0.3, "aggression": -0.2, "peek_chance": 0.3, "patience": [5.0, 12.0], "sneak": 0.9},
	],
	"pistol": [
		{"name": "duelist", "weight": 3.0, "fight": "duel", "roam": "walk", "range": 0.9, "strafe": 1.3, "burst": 1.2, "cover_reload": 0.5},
		{"name": "rusher", "weight": 1.5, "fight": "rush", "roam": "walk", "range": 0.5, "strafe": 1.2, "stop": -0.3, "aggression": 0.3, "flank": 0.4},
	],
	"heavy": [
		{"name": "suppressor", "weight": 2.0, "fight": "duel", "roam": "walk", "range": 1.4, "strafe": 0.5, "burst": 1.8, "stop": 0.4, "crouch": 0.3},
		{"name": "walker", "weight": 1.5, "fight": "rush", "roam": "walk", "range": 0.9, "strafe": 0.6, "burst": 1.6, "aggression": 0.2, "flank": 0.1},
	],
	"launcher": [
		{"name": "lobber", "weight": 2.0, "fight": "duel", "roam": "walk", "range": 1.5, "strafe": 0.9, "aggression": -0.1, "cover_reload": 0.6},
		{"name": "peeker", "weight": 1.5, "fight": "peek", "roam": "walk", "range": 1.4, "strafe": 0.7, "peek": [0.6, 1.4], "hide": [1.0, 2.0], "reposition": 0.4, "cover_reload": 0.8},
	],
	"melee": [
		{"name": "charger", "weight": 2.0, "fight": "rush", "roam": "walk", "range": 0.05, "reach": 0.15, "strafe": 0.8, "stop": -1.0, "crouch": -1.0, "aggression": 0.6, "flank": 0.15},
		{"name": "zigzag", "weight": 1.5, "fight": "rush", "roam": "walk", "range": 0.05, "reach": 0.15, "strafe": 1.6, "stop": -1.0, "crouch": -1.0, "aggression": 0.5, "flank": 0.6},
	],
	"throw": [
		{"name": "lobber", "weight": 1.0, "fight": "duel", "roam": "walk", "range": 1.2, "aggression": -0.1},
	],
}

# --- The table ------------------------------------------------------------------

## [param base] with [param json_text] (a dictionary of class -> list of style rows, replacing
## those classes; a row naming a style already there changes only the keys it gives) and then
## [param weights] ([code]class.style=weight[/code], comma separated) applied. Returns
## `{ok, table, error}`; on an error the table is [param base] untouched.
static func build_table(base: Dictionary, json_text: String, weights: String) -> Dictionary:
	var table := base.duplicate(true)
	if json_text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string(json_text)
		if not (parsed is Dictionary):
			return {"ok": false, "table": base, "error": "the style file is not a JSON object of class -> [styles]"}
		var given: Dictionary = parsed
		for klass: Variant in given:
			var rows: Variant = given[klass]
			if not (rows is Array):
				return {"ok": false, "table": base, "error": "styles for '%s' are not a list" % str(klass)}
			var have: Array = table.get(str(klass), [])
			for row: Variant in rows:
				if not (row is Dictionary):
					return {"ok": false, "table": base, "error": "a style for '%s' is not an object" % str(klass)}
				var named := str((row as Dictionary).get("name", ""))
				var merged := false
				for old: Dictionary in have:
					if named != "" and str(old.get("name", "")) == named:
						old.merge(row, true)
						merged = true
						break
				if not merged:
					have.append((row as Dictionary).duplicate(true))
			table[str(klass)] = have
	for item in weights.split(",", false):
		var pair := item.strip_edges().split("=", false)
		var path := pair[0].strip_edges().split(".", false) if pair.size() == 2 else PackedStringArray()
		if path.size() != 2 or not pair[1].strip_edges().is_valid_float():
			return {"ok": false, "table": base, "error": "bot_style_weights wants class.style=weight, not '%s'" % item}
		var found := false
		for row: Dictionary in table.get(path[0], []):
			if str(row.get("name", "")) == path[1]:
				row["weight"] = maxf(0.0, pair[1].to_float())
				found = true
		if not found:
			return {"ok": false, "table": base, "error": "no style '%s' for class '%s'" % [path[1], path[0]]}
	return {"ok": true, "table": table, "error": ""}


## Index of the row [param u] (0..1) picks from [param rows] by weight; -1 when all weigh nothing.
static func pick(rows: Array, u: float) -> int:
	var total := 0.0
	for row: Dictionary in rows:
		total += maxf(0.0, float(row.get("weight", 1.0)))
	if total <= 0.0:
		return -1
	var at := u * total
	for i in rows.size():
		at -= maxf(0.0, float((rows[i] as Dictionary).get("weight", 1.0)))
		if at < 0.0:
			return i
	return rows.size() - 1


# --- One bot ----------------------------------------------------------------------

## True while a style plays (a class with a style, bot_styles above 0).
var active: bool = false
var klass: String = ""
## The style row in play, NEUTRAL's keys filled in.
var row: Dictionary = {}

## The scales and biases the brain reads, 1 and 0 when inactive.
var range_k: float = 1.0
var reach_k: float = 1.0
var strafe_k: float = 1.0
var burst_k: float = 1.0
var stop_b: float = 0.0
var crouch_b: float = 0.0
var aggression_b: float = 0.0
var peek_b: float = 0.0

var phase: int = NONE
var phase_until: float = -INF
var phase_since: float = -INF
## Where the phase goes (cover, vantage) and where the bot peeked from.
var spot: Vector3 = Vector3.INF
var peek_spot: Vector3 = Vector3.INF
## Where the threat was when the bot hid, and what a vantage faces.
var threat: Vector3 = Vector3.INF
var face: Vector3 = Vector3.INF

## Counts for a suite: phases entered by name.
var entered: Dictionary = {}

var _rng: GSRandomStream = null
## class -> picked row index, kept across lives.
var _picked: Dictionary = {}
var _settings_rev: int = -1
var _table_stamp: int = -1
## Whether this life's jitter is rolled.
var _rolled: bool = false
## This life's jitter.
var _j_range: float = 1.0
var _j_strafe: float = 1.0
var _j_aggr: float = 0.0
var _j_patience: float = 1.0
var _j_peek: float = 1.0
## This engagement's.
var _exposed_since: float = -INF
var _shots: int = 0
var _peek_len: float = 1.5
var _flank: float = 0.0
var _reload_hide: bool = false
var _killed: bool = false
var _sneak: bool = false
var _hold_crouch: bool = false
var _vantage_next: float = -INF


func _init(id: int = 0) -> void:
	_rng = GSRandomStream.new(id).stream(&"dot_bot_style")


func label() -> String:
	return "%s/%s" % [klass, str(row.get("name", ""))] if active else ""


func phase_name() -> String:
	return PHASE_NAMES[phase]


## Follows the weapon in hand and the settings; one compare a tick when nothing changed.
func refresh(me: GSBotContact, settings: GSBotSettings) -> void:
	var held := String(me.weapon_class)
	var stamp := settings.style_stamp()
	if held == klass and settings.revision == _settings_rev and stamp == _table_stamp:
		return
	var p := settings.profile
	if not _rolled:
		_roll_life(p.style_variety)
	var restyle := held != klass or stamp != _table_stamp
	klass = held
	_settings_rev = settings.revision
	if stamp != _table_stamp:
		_picked.clear()
	_table_stamp = stamp
	if restyle:
		_end()
	if held == "" or p.styles <= 0.0:
		_set_row({}, p)
		return
	var rows: Array = settings.style_table().get(held, [])
	if not _picked.has(held):
		_picked[held] = pick(rows, _rng.next_unit())
	var i: int = _picked[held]
	_set_row(rows[i] if i >= 0 and i < rows.size() else {}, p)


## A new life: perhaps a new style per class, and this life's jitter.
func respawn(settings: GSBotSettings) -> void:
	var p := settings.profile
	_end()
	_vantage_next = -INF
	if p.style_variety > 0.0:
		for held: String in _picked.keys():
			if _rng.next_unit() < p.style_variety:
				_picked.erase(held)
	_roll_life(p.style_variety)
	klass = "\n"  # re-read on the next refresh
	_settings_rev = -1


func _roll_life(v: float) -> void:
	_rolled = true
	_j_range = 1.0 + v * (2.0 * _rng.next_unit() - 1.0)
	_j_strafe = 1.0 + v * (2.0 * _rng.next_unit() - 1.0)
	_j_aggr = 0.5 * v * (2.0 * _rng.next_unit() - 1.0)
	_j_patience = maxf(0.2, 1.0 + 2.0 * v * (2.0 * _rng.next_unit() - 1.0))
	_j_peek = maxf(0.2, 1.0 + 2.0 * v * (2.0 * _rng.next_unit() - 1.0))


func _set_row(given: Dictionary, p: GSBotProfile) -> void:
	active = not given.is_empty()
	row = NEUTRAL.duplicate()
	row.merge(given, true)
	var s := p.styles if active else 0.0
	range_k = maxf(0.02, lerpf(1.0, float(row["range"]), s) * (_j_range if active else 1.0))
	reach_k = maxf(0.05, lerpf(1.0, float(row["reach"]), s))
	strafe_k = maxf(0.0, lerpf(1.0, float(row["strafe"]), s) * (_j_strafe if active else 1.0))
	burst_k = maxf(0.1, lerpf(1.0, float(row["burst"]), s))
	stop_b = float(row["stop"]) * s
	crouch_b = float(row["crouch"]) * s
	aggression_b = float(row["aggression"]) * s + (_j_aggr if active else 0.0)
	peek_b = float(row["peek_chance"]) * s


## A new engagement: which side to flank, whether to reload in cover, how long to peek.
func engage() -> void:
	if not active:
		return
	_exposed_since = -INF
	_shots = 0
	_flank = 0.0
	if _rng.next_unit() < float(row["flank"]):
		_flank = 1.0 if _rng.next_unit() < 0.5 else -1.0
	_reload_hide = _rng.next_unit() < float(row["cover_reload"])
	_peek_len = _between(row["peek"]) * _j_peek


## The target went down: a peeker or camper may move on to another angle once nothing is in sight.
func on_kill() -> void:
	if active:
		_killed = true


# --- Steering ---------------------------------------------------------------------

# [param b] is the GSBotBrain, typed by its base: the brain names this class, and a script loop
# stays in memory for good (Godot 4.7).
## After the brain's fight: the style's own legs over the generic ones.
func after_fight(b: RefCounted, me: GSBotContact, c: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent) -> void:
	var flat := Vector2(c.position.x - me.position.x, c.position.z - me.position.z)
	var dist := flat.length()
	if phase == HIDE:
		if dist < CLOSE or _at(me, spot) or now > phase_since + TRAVEL_MAX:
			# Found out in cover, or cut off on the way: fight it here.
			_end()
		else:
			_go(b, me, world, spot, false, out)
			out.state = &"cover"
			out.crouch = false
			b._scene = &"flee"
			return
	elif phase != NONE:
		_end()
	if _exposed_since == -INF:
		_exposed_since = now
	if out.fire:
		_shots += 1
	var exposed := now - _exposed_since
	if world != null and dist > CLOSE and out.state != &"retreat":
		if _reload_hide and me.magazine >= 0.0 and me.magazine < 0.2:
			_reload_hide = false
			_hide(b, me, c, world, now, dt, out, &"reload")
			return
		if row["fight"] == "peek" and exposed >= _peek_len and (_shots > 0 or exposed >= _peek_len * 2.0):
			_hide(b, me, c, world, now, dt, out, &"peek")
			return
	if row["fight"] == "rush" and dist > 3.5 and out.state != &"retreat":
		var dir := flat / dist
		var side := Vector2(-dir.y, dir.x) * _flank * 0.8 * clampf((dist - 3.5) / 6.0, 0.0, 1.0)
		b._set_move(out, (dir + side).normalized())
		out.crouch = false
		out.state = &"rush"
		b._scene = &"close"


## With nothing in sight: true when a phase takes this tick (the brain then skips its search,
## listen and roam). [param free] is false while an objective or a pickup has the bot.
func lead(b: RefCounted, me: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, free: bool) -> bool:
	_exposed_since = -INF
	_shots = 0
	if world == null:
		return false
	var eye := me.eye()
	match phase:
		HIDE:
			return _lead_hide(b, me, world, now, dt, out, free, eye)
		RETURN:
			return _lead_return(b, me, world, now, dt, out, free, eye)
		MOVE:
			return _lead_move(b, me, world, now, dt, out, free, eye)
		HOLD:
			return _lead_hold(b, me, world, now, dt, out, free, eye)
	# No phase. After a kill a peeker or camper may give up the angle it was seen on.
	if _killed:
		_killed = false
		if free and (row["fight"] == "peek" or row["roam"] == "camp") and _rng.next_unit() < float(row["reposition"]):
			_to_vantage(me, world, now, me.position)
			return phase != NONE and lead(b, me, world, now, dt, out, free)
	# A camper with nothing to do heads for an angle.
	if free and row["roam"] == "camp" and now >= _vantage_next and b._last_seen_pos == Vector3.INF and b._heard_at == -INF and b._hurt_at == -INF:
		_vantage_next = now + 3.0
		_to_vantage(me, world, now, me.position)
		return phase != NONE and lead(b, me, world, now, dt, out, free)
	return false


func _lead_hide(b: RefCounted, me: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, free: bool, eye: Vector3) -> bool:
	if now >= phase_until and (_at(me, spot) or now > phase_since + TRAVEL_MAX):
		if _killed or _rng.next_unit() < float(row["reposition"]):
			_to_vantage(me, world, now, peek_spot)
		else:
			_begin(RETURN, now, now + TRAVEL_MAX)
			spot = peek_spot
		return phase != NONE and lead(b, me, world, now, dt, out, free)
	var there := _at(me, spot)
	if not there:
		_go(b, me, world, spot, false, out)
	else:
		out.move = Vector2.ZERO
		out.crouch = _hold_crouch
	if threat != Vector3.INF:
		# Pre-aimed at where it will come out.
		var _v: Vector2 = b.aim.look_at_point(eye, threat + Vector3.UP * 1.25, dt)
	out.state = &"cover"
	b._scene = &"cover" if there else &"flee"
	return true


func _lead_return(b: RefCounted, me: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, free: bool, eye: Vector3) -> bool:
	if _at(me, spot) or now >= phase_until:
		if row["roam"] == "camp" and free:
			_begin(HOLD, now, now + _between(row["patience"]) * _j_patience)
			face = threat
			return lead(b, me, world, now, dt, out, free)
		_end()
		return false
	_go(b, me, world, spot, true, out)
	if threat != Vector3.INF:
		var _v: Vector2 = b.aim.look_at_point(eye, threat + Vector3.UP * 1.25, dt)
	out.state = &"peek"
	b._scene = &"cover"
	return true


func _lead_move(b: RefCounted, me: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, free: bool, eye: Vector3) -> bool:
	if not free:
		_end()
		return false
	if _at(me, spot):
		_begin(HOLD, now, now + _between(row["patience"]) * _j_patience)
		return lead(b, me, world, now, dt, out, free)
	if now >= phase_until:
		_end()
		return false
	var dir := _go(b, me, world, spot, _sneak, out)
	var _v: Vector2 = b.aim.look_at_point(eye, eye + Vector3(dir.x, 0.0, dir.y), dt)
	out.state = &"sneak" if _sneak else &"reposition"
	b._scene = &"cover"
	return true


func _lead_hold(b: RefCounted, me: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, free: bool, eye: Vector3) -> bool:
	if not free or b._hurt_at > phase_since:
		# Shot from somewhere it is not watching: this angle is burnt.
		var burnt: bool = b._hurt_at > phase_since
		_end()
		if burnt and free and row["roam"] == "camp":
			_to_vantage(me, world, now, me.position)
			return phase != NONE and lead(b, me, world, now, dt, out, free)
		return false
	if now >= phase_until:
		_end()
		if row["roam"] == "camp":
			_to_vantage(me, world, now, me.position)
			return phase != NONE and lead(b, me, world, now, dt, out, free)
		return false
	out.move = Vector2.ZERO
	out.crouch = _hold_crouch
	var look := face
	if b._heard_at > phase_since and b._heard_pos != Vector3.INF:
		look = b._heard_pos
	if look != Vector3.INF:
		var at := look + Vector3.UP * 1.25
		var sweep: float = 18.0 * sin(now * 0.4 + float(b.id % 83))
		var dir := (at - eye).rotated(Vector3.UP, deg_to_rad(sweep))
		var _v: Vector2 = b.aim.look_at_point(eye, eye + dir, dt)
	else:
		b._drift(15.0, dt)
	out.state = &"vantage"
	b._scene = &"cover"
	return true


# --- Phases -----------------------------------------------------------------------

func _begin(next: int, now: float, until: float) -> void:
	phase = next
	phase_since = now
	phase_until = until
	var key := PHASE_NAMES[next]
	entered[key] = int(entered.get(key, 0)) + 1


func _end() -> void:
	phase = NONE
	phase_until = -INF
	spot = Vector3.INF
	_killed = false


## Back out of [param c]'s sight to cover near by, remembering where it peeked from.
func _hide(b: RefCounted, me: GSBotContact, c: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, why: StringName) -> void:
	var at := cover_near(me.position, c.position, c.eye(), world, _rng)
	peek_spot = me.position
	threat = c.position
	spot = at
	_hold_crouch = _rng.next_unit() < b.settings.profile.cover_crouch
	_begin(HIDE, now, now + _between(row["hide"]) * _j_peek)
	_go(b, me, world, spot, false, out)
	out.state = &"cover"
	out.crouch = false
	b._scene = &"flee"
	GSLog.trace(CHANNEL, "bot takes cover", {"bot": b.id, "why": why, "style": label()})


## Off to a vantage away from [param away_from]; no phase when none was found.
func _to_vantage(me: GSBotContact, world: GSBotWorld, now: float, away_from: Vector3) -> void:
	var picked := vantage(me.position, away_from, world, _rng)
	if picked.is_empty():
		_end()
		return
	spot = picked["at"]
	face = picked["face"]
	_sneak = _rng.next_unit() < float(row["sneak"])
	_hold_crouch = _rng.next_unit() < float(row["crouch"]) + 0.3
	_killed = false
	_begin(MOVE, now, now + TRAVEL_MAX + me.position.distance_to(spot) * 0.3)


## Walks toward [param dest] (quietly when [param quiet]); the flat direction taken.
func _go(b: RefCounted, me: GSBotContact, world: GSBotWorld, dest: Vector3, quiet: bool, out: GSBotIntent) -> Vector2:
	var dir: Vector2 = b._toward(me, world, dest)
	b._set_move(out, dir)
	out.walk = quiet
	return dir


func _at(me: GSBotContact, where: Vector3) -> bool:
	return where == Vector3.INF or Vector2(where.x - me.position.x, where.z - me.position.z).length() < ARRIVE


func _between(pair: Variant) -> float:
	if pair is Array and (pair as Array).size() == 2:
		return lerpf(float(pair[0]), float(pair[1]), _rng.next_unit())
	return float(pair)


# --- Places -----------------------------------------------------------------------

## Directions tried for cover, degrees off straight away from the threat, and how far.
const COVER_TURNS: PackedFloat32Array = [0.0, 55.0, 110.0]
const COVER_REACH: PackedFloat32Array = [3.5, 7.0]
const COVER_RAYS := 6

## A standable spot near [param here] that [param threat_eye] cannot see (a crouched head), tried
## away from the threat and to either side; failing that, a few metres straight back.
static func cover_near(here: Vector3, threat_pos: Vector3, threat_eye: Vector3, world: GSBotWorld, rng: GSRandomStream) -> Vector3:
	var away := Vector2(here.x - threat_pos.x, here.z - threat_pos.z)
	away = away.normalized() if away.length() > 0.01 else Vector2(0.0, 1.0)
	var flip := 1.0 if rng.next_unit() < 0.5 else -1.0
	var snaps := world.walkable_fn.is_valid()
	var rays := 0
	for reach in COVER_REACH:
		for turn in COVER_TURNS:
			for sgn in 2:
				if turn == 0.0 and sgn == 1:
					continue
				var d := away.rotated(deg_to_rad(turn) * flip * (1.0 if sgn == 0 else -1.0))
				var at := here + Vector3(d.x, 0.0, d.y) * reach
				if snaps:
					at = world.walkable_near(at)
					if at == Vector3.INF:
						continue
				rays += 1
				if not world.line_of_sight(threat_eye, at + Vector3.UP * 0.9):
					return at
				if rays >= COVER_RAYS:
					return _back_off(here, away, world, snaps)
	return _back_off(here, away, world, snaps)


static func _back_off(here: Vector3, away: Vector2, world: GSBotWorld, snaps: bool) -> Vector3:
	var at := here + Vector3(away.x, 0.0, away.y) * 5.0
	if snaps:
		var snapped := world.walkable_near(at)
		return snapped if snapped != Vector3.INF else here
	return at


## A vantage: a waypoint that sees other waypoints far off, higher the better, not too near
## [param away_from]. `{at, face}` or empty.
static func vantage(here: Vector3, away_from: Vector3, world: GSBotWorld, rng: GSRandomStream) -> Dictionary:
	var points := world.waypoints()
	var n := points.size()
	if n == 0:
		return {}
	var best: Dictionary = {}
	var best_score := -INF
	for _i in 6:
		var at := points[mini(n - 1, int(rng.next_unit() * n))]
		var far := at.distance_to(here)
		if far > VANTAGE_FAR or (away_from != Vector3.INF and at.distance_to(away_from) < 4.0):
			continue
		var eye := at + Vector3.UP * 1.6
		var seen := 0
		var face := Vector3.INF
		for _j in 3:
			var q := points[mini(n - 1, int(rng.next_unit() * n))]
			var gap := q.distance_to(at)
			if gap < 8.0 or gap > 70.0:
				continue
			if world.line_of_sight(eye, q + Vector3.UP * 1.2):
				seen += 1
				if face == Vector3.INF:
					face = q
		var score := float(seen) + (at.y - here.y) * 0.1 - far * 0.02 + rng.next_unit() * 0.5
		if score > best_score:
			best_score = score
			best = {"at": at, "face": face}
	return best


func describe() -> Dictionary:
	return {"style": label(), "phase": phase_name()}
