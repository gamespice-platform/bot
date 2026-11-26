class_name GSBotBrain
extends "gs_bot_brain_native.gd"

## One bot's decisions: whom it sees, where it looks, when it pulls the trigger and how it
## moves, as a [GSBotIntent] each tick.
##
## [b]Built to look like a person, not to win.[/b] The four things that make a bot read as a
## machine are the four this models before anything else:
##
## [codeblock]
## 1. seeing through walls      it sees only inside its view cone, past a line-of-sight test
##                              the world answers; anything else it can only hear
## 2. reacting on the tick      bot_reaction, plus bot_notice for somebody off to the side;
##                              half of it for a target it was already pre-aiming
## 3. snapping its aim          the view turns at most bot_turn_rate, closing smoothly
##                              (bot_turn_smooth) and tracking motion only as well as
##                              bot_prediction lets it
## 4. hitting the first shot    aim starts bot_aim_error off, settles by half every
##                              bot_aim_settle seconds to bot_aim_floor, and a hit adds
##                              bot_flinch back
## [/codeblock]
##
## Then the fight itself: a preferred range, strafing that changes direction irregularly,
## bursts at range and a held trigger up close, standing still or crouching for a long burst,
## backing out when badly hurt, pre-aiming and re-peeking a corner a target went behind, a
## grenade at somebody who just took cover, turning to a gunshot or to whoever hit it, and
## roaming toward where it last knew of an enemy. Every one of those is a [GSBotProfile] field.
## The first four are [GSBotAim], which a game with decisions of its own uses by itself.
##
## [b]Pure.[/b] It reads a [GSBotContact] for itself and a [GSBotWorld], and returns an
## intent; it moves nothing. Its randomness is a [GSRandomStream] seeded from [member id], so
## two runs of the same inputs play the same bot, which is what lets a suite hold a bot still.
##
## [codeblock]
## var brain := GSBotBrain.new(bot_id, GSBotSettings.of(game))
## var intent := brain.think(me, world, now)
## intent.write_move(move_command)
## intent.write_fire(fire_command)
## [/codeblock]

## Whether a bot that sees its target tests that body alone before scanning every body (the same
## choice either way); a suite turns it off to compare.
static var target_first: bool = true

## Whether brains perceive natively (GSSimBotMind.perceive over the world's native sight scan)
## when they can; off, they perceive in script. The two choose the same to the bit.
static var native_perceive := true
static var _perceive_known := -1

## Per-phase microseconds of [method think] while [member phase_timers] is on: [constant PHASES], the think's phases (bb_*)
## then the world queries it asked (bq_*, inside the phase that asked). [member phase_calls]: laps and queries counted.
## Each brain times into its own [GSBotClock], so brains on worker threads time too: a think on the main thread adds its
## clock here at once, and the caller of threaded thinks calls [method merge_phases] on the main thread after the join.
## Off by default: each lap and query is two clock reads. A profile tool turns it on and reads, then clears, [member phase_us].
static var phase_timers := false:
	set(v):
		phase_timers = v
		GSBotClock.on = v
const PHASES: Array[StringName] = [&"bb_setup", &"bb_perceive", &"bb_hear", &"bb_goal", &"bb_act", &"bb_tricks", &"bb_unstick",
		&"bq_sight", &"bq_route", &"bq_ladder", &"bq_walkable", &"bq_waypoints", &"bq_wall", &"bq_sounds", &"bq_drops", &"bq_projectile",
		&"ba_fight", &"ba_fight_io", &"ba_style", &"ba_search", &"ba_listen", &"ba_roam", &"ba_pickup", &"ba_walk", &"ba_toward", &"ba_turn"]
static var phase_us := _zeros()
static var phase_calls := _zeros()

## This brain's GSSimBotMind (the aim's, kept when the aim falls back to script): it holds the
## sight cache, and perceives when the world packed a native scan this tick. Null: all in script.
var _mind: Object = null
static var _sight_lod_known := -1
## The sight LOD last handed to [member _mind] (GSBotWorld.sight_far, sight_far_reuse).
var _lod_far := 0.0
var _lod_reuse := 0.0
## The [member GSBotWorld.contacts_version] whose packed scan [member _mind] holds ([method par_ready]); -1 none.
var _held_version := -1
static var _held_known := -1
## Whether brains hear natively (GSSimBotMind.hear over [method GSBotWorld.sound_rows]) when they
## can; off, they hear in script. The two hear the same sounds and draw the same numbers, to the bit.
static var native_hear := true
static var _hear_known := -1
## Whether brains steer natively (GSSimBotMind.steer: the walking or standing look, the glance, the turn and the
## legs of [method _walk], [method _hold] and [method _drift]) when they can; off, in script. The same, to the bit.
static var native_act := true
static var _act_known := -1


static func _zeros() -> PackedInt64Array:
	var a := PackedInt64Array()
	a.resize(GSBotClock.SLOTS)
	return a


func _init(p_id: int = 0, p_settings: GSBotSettings = null) -> void:
	id = p_id
	settings = p_settings if p_settings != null else GSBotSettings.new()
	aim = GSBotAim.new(p_id, settings)
	_rng = GSRandomStream.new(p_id).stream(&"gs_bot")  # a seed key, not a name: renaming it reshuffles every bot
	aim._set_brain_key(_rng._key)
	if aim._n != null and _perceive_available():
		_mind = aim._n
	_unstick = GSBotUnstick.new(_rng)
	style = GSBotStyle.new(p_id)
	goal = GSBotGoal.new(p_id)
	_unstick.clock = _clock
	style.clock = _clock
	goal.clock = _clock
	pickup.clock = _clock
	tricks.clock = _clock
	aim.clock = _clock


## Moves this brain wholly into script (the aim's state, and no native perceive or sight cache from
## here on). [method par_ready] does this itself when the gs_sim library cannot think on workers.
func leave_native() -> void:
	aim._demote()
	_mind = null
	_held_version = -1


## Gets this brain ready to think on a worker thread this tick; call it on the main thread after the world's contacts are in
## ([member GSBotWorld.contacts_version] bumped) and before [method think]. The native mind takes a handle on the world's packed sight scan
## (a worker must not bind it while others do); a gs_sim library without that handle (GSSimBotMind.hold_senses) falls back to script, as [method leave_native].
func par_ready(world: GSBotWorld) -> void:
	_held_version = -1
	if phase_timers:
		_clock.fold(phase_us, phase_calls)
	if not _held_available():
		leave_native()
		return
	if _mind == null or world == null:
		return
	var senses := world.senses(world.contacts())
	if senses == null:
		return
	_mind.hold_senses(senses)
	_held_version = world.contacts_version


## What this bot does this tick.
func think(me: GSBotContact, world: GSBotWorld, now: float) -> GSBotIntent:
	if phase_timers:
		_clock.start()
	var p := settings.profile
	var dt := 0.0 if is_nan(_now) else clampf(now - _now, 0.0, MAX_STEP)
	_now = now
	var out := GSBotIntent.new()

	if me == null or not me.alive:
		return _dead(out)
	if not _was_alive:
		_respawned()

	aim.view_from(me.view_yaw, me.view_pitch)
	style.refresh(me, settings)
	aim.reach_k = style.reach_k
	aim.burst_k = style.burst_k

	_notice_hurt(now)

	if world != null:
		world.prune_sight_blockers(now)
	var all := world.contacts() if world != null else []
	if phase_timers:
		_clock.lap(0)
	var seen := _perceive(me, all, world, p, now)
	if phase_timers:
		_clock.lap(1)
	if world != null:
		_hear(me, all, world, p, now)
		if phase_timers:
			_clock.lap(2)
		if world.objective != null and goal.due(now):
			goal.plan(me, world.objective, world, p, _rng, now)
	if phase_timers:
		_clock.lap(3)
	_act(me, seen, world, p, now, dt, out)
	out.yaw = aim.yaw
	out.pitch = aim.pitch
	if phase_timers:
		_clock.lap(4)
	tricks.apply(me, world, p, _rng, _scene, _scene_up, aim.yaw, now, dt, out, _mind if _mind != null else aim._n)
	out.target_id = target_id if _visible else -1
	if policy != null and _climb == null and _ride_reached < 0 and policy.active(p, id):
		policy.apply(me, world, p, dt, out)
		# The view stays the brain's: its aim carries on from where the policy turned it.
		aim.yaw = out.yaw
		aim.pitch = out.pitch
	if phase_timers:
		_clock.lap(5)
	if _climb != null:
		_climb_step(me, now, out)
		_unstick.reset(me.position, now)
	else:
		_free_if_stuck(me, world, now, out)
	if phase_timers:
		_clock.lap(6)
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			_clock.fold(phase_us, phase_calls)
	out.ride = _ride_reached
	_ride_reached = -1
	last = out
	return out


func _notice_hurt(now: float) -> void:
	if now >= _hurt_pending_at:
		# The shooter is only noticed a moment after the hit: pain first, then the turn.
		_hurt_from = _hurt_pending_from
		_hurt_at = now
		_known_enemy = _hurt_pending_from
		_hurt_pending_at = INF


func _act(me: GSBotContact, seen: GSBotContact, world: GSBotWorld, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> void:
	# A carrier runs home and a defender keeps to its post rather than chase what it lost.
	var tethered := goal.urgent or goal.strays(me.position)

	_scene = &"roam"
	_scene_up = 0.0
	if seen != null or not _quiet(now, p):
		pickup.cancel()
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	if seen != null:
		_fight(me, seen, world, p, now, dt, out)
		if t:
			GSBotClock.add(_clock, GSBotClock.A_FIGHT, t)
		if style.active:
			var t_style := Time.get_ticks_usec() if t else 0
			style.after_fight(self, me, seen, world, now, dt, out)
			if t_style:
				GSBotClock.add(_clock, GSBotClock.A_STYLE, t_style)
	elif style.active and _lead(me, world, now, dt, out, not tethered and goal.dest == Vector3.INF):
		pass
	elif not tethered and _last_seen_pos != Vector3.INF and now - _last_seen_at <= _hold_time(p, _peeking or _chase_lost):
		t = Time.get_ticks_usec() if t else 0
		_search(me, p, now, dt, out)
		if t:
			GSBotClock.add(_clock, GSBotClock.A_SEARCH, t)
	elif not tethered and maxf(_heard_at, _hurt_at) > -INF and now - maxf(_heard_at, _hurt_at) <= _hold_time(p, _chase_sound or _hurt_at >= _heard_at):
		t = Time.get_ticks_usec() if t else 0
		_listen(me, world, p, now, dt, out)
		if t:
			GSBotClock.add(_clock, GSBotClock.A_LISTEN, t)
	else:
		t = Time.get_ticks_usec() if t else 0
		_roam(me, world, p, now, dt, out)
		if t:
			GSBotClock.add(_clock, GSBotClock.A_ROAM, t)


## [method GSBotStyle.lead], timed as ba_style.
func _lead(me: GSBotContact, world: GSBotWorld, now: float, dt: float, out: GSBotIntent, free: bool) -> bool:
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var led := style.lead(self, me, world, now, dt, out, free)
	if t:
		GSBotClock.add(_clock, GSBotClock.A_STYLE, t)
	return led


func _dead(out: GSBotIntent) -> GSBotIntent:
	_was_alive = false
	_forget_target()
	tricks.reset()
	out.state = &"dead"
	out.yaw = aim.yaw
	out.pitch = aim.pitch
	last = out
	return out


# A respawn: a new life starts with no target, no plan and the view the spawn gave.
func _respawned() -> void:
	_was_alive = true
	_forget_target()
	_waypoint = Vector3.INF
	_route_goal = Vector3.INF
	_ride_reached = -1
	_climb = null
	_heard_at = -INF
	_hurt_at = -INF
	_hurt_pending_at = INF
	goal.reset()
	style.respawn(settings)


## Adds the clocks of [param brains] (that thought on worker threads this tick) into [member phase_us] and
## [member phase_calls]; call it on the main thread after the join, once a tick. A no-op while [member phase_timers] is off.
static func merge_phases(brains: Array) -> void:
	if not phase_timers:
		return
	for b: Variant in brains:
		var brain := b as GSBotBrain
		if brain != null:
			brain._clock.fold(phase_us, phase_calls)


## The game's rider is done with a ride ([member GSBotIntent.ride]): [param arrived] or not, the
## route is asked for again from where the bot is now, because a ride lands anywhere on the far
## platform (or, failing, wherever the pit sent it).
func ride_ended(_arrived: bool) -> void:
	_route_goal = Vector3.INF
	_route = PackedVector3Array()
	_route_rides = PackedInt32Array()
	_unstick.reset()


## Being hit. [param from] is where the shot came from (INF when unknown).
func hurt(from: Vector3, now: float) -> void:
	aim.hurt()
	if from != Vector3.INF and settings.profile.hurt_delay > 0.0:
		_hurt_pending_from = from
		_hurt_pending_at = now + settings.profile.hurt_delay * (0.6 + 0.8 * _rng.next_unit())
	elif from != Vector3.INF:
		_hurt_from = from
		_hurt_at = now
		_known_enemy = from


## Flashed: sees nothing for [param seconds] (hearing and pain still work). [param from] is where the
## flash went off, so the bot turns toward it afterwards (INF when unknown).
func blind_for(now: float, seconds: float, from: Vector3 = Vector3.INF) -> void:
	_blind_until = maxf(_blind_until, now + seconds)
	if from != Vector3.INF:
		_known_enemy = from


func is_blind(now: float) -> bool:
	return now < _blind_until


## The current or last engagement, for a suite: when the target was first seen, when the bot
## could first fire, when it first did, and how far off the target its view was then.
func engagement() -> Dictionary:
	var out := aim.engagement()
	out["aim_error_deg"] = aim.error_deg(_now if not is_nan(_now) else 0.0)
	return out


# --- Seeing ---------------------------------------------------------------------

func _perceive(me: GSBotContact, all: Array, world: GSBotWorld, p: GSBotProfile, now: float) -> GSBotContact:
	if now < _blind_until:
		if _visible:
			_lose(p, now)
		return null
	var eye := me.eye()
	var half := p.fov * 0.5
	var through := p.through_walls >= 0.5 or world == null
	# The native mind scans, keeps or picks and asks sight in one call when the world packed this
	# tick's bodies for the native scan (main thread only); else the script does it all.
	# On a worker the world hands out no scan; the mind then reads the one [method par_ready] held.
	var senses := world.senses(all) if world != null and _mind != null else null
	var held := senses == null and _mind != null and world != null and _held_version >= 0 and _held_version == world.contacts_version
	var chosen: GSBotContact = null
	var picked := false
	if senses != null or held:
		var los := world.sight_callable()
		if _sight_lod_available() and (world.sight_far != _lod_far or world.sight_far_reuse != _lod_reuse):
			_lod_far = world.sight_far
			_lod_reuse = world.sight_far_reuse
			_mind.set_sight_lod(_lod_far, _lod_reuse)
		var flags := (1 if _visible else 0) | (2 if through else 0)
		var r: PackedInt32Array
		if held:
			r = _mind.perceive_held(me.id, me.team, eye, aim.yaw, aim.pitch, half, p.sight, target_id, flags, now, world.sight_stamp(), los)
		else:
			r = _mind.perceive(senses, me.id, me.team, eye, aim.yaw, aim.pitch, half, p.sight, target_id, flags, now, world.sight_stamp(), los)
		if r.size() == 2:
			picked = true
			if r[1] != 0:
				_target_down()
			if r[0] >= 0:
				chosen = world.sensed()[r[0]]
	if not picked:
		chosen = _choose(me, all, world, p, eye, half, through, now)

	if chosen == null:
		if _visible:
			_lose(p, now)
		return null

	if aim.engage(chosen.id, eye, chosen.aim_point(), now):
		# A new engagement: how this fight will go, rolled once.
		_roll_stop = _rng.next_unit() < p.stop_to_shoot + style.stop_b
		_roll_crouch = _rng.next_unit() < p.crouch + style.crouch_b
		_roll_cover = _rng.next_unit() < p.cover
		if p.hesitate > 0.0:
			_hesitate_until = now + p.hesitate * (0.3 + 0.7 * _rng.next_unit())
		style.engage()
		GSLog.trace(CHANNEL, "bot acquires a target", {"bot": id, "target": chosen.id})

	_visible = true
	target_id = chosen.id
	_last_seen_pos = chosen.position
	_last_seen_vel = chosen.velocity
	_last_seen_at = now
	_known_enemy = chosen.position
	return chosen


## [method _hear]'s loop in the native mind: the same sounds heard, the same guesses and the same draws
## on [member _rng] as the script. False when it cannot (no hear in the library, [member native_hear]
## off, no packed bodies for the sources' teams, or sound rows out of step); the script then hears.
func _hear_native(me: GSBotContact, all: Array, world: GSBotWorld, p: GSBotProfile, now: float, newest: int) -> bool:
	if not _hear_available():
		return false
	var senses := world.senses(all)
	if senses == null and not (_held_version >= 0 and _held_version == world.contacts_version):
		return false
	var rows := world.sound_rows()
	if rows.is_empty():
		return false
	var here := me.position
	var io := _hear_io
	_hear_io = PackedFloat64Array()  # one owner, so the writes below do not copy
	if io.size() != 10:
		io.resize(10)
	io[0] = _heard_seq
	io[1] = now
	io[2] = here.x
	io[3] = here.y
	io[4] = here.z
	io[5] = p.hearing
	io[6] = me.id
	io[7] = me.team
	io[8] = p.aggression + style.aggression_b
	io[9] = _rng._counter
	_hear_io = io
	var r: PackedFloat64Array = _mind.hear(senses, rows, io)
	if r.size() != 6:
		return false
	_heard_seq = newest
	_rng._counter = int(r[5])
	if r[0] != 0.0:
		_heard_pos = Vector3(r[1], r[2], r[3])
		_heard_at = now
		_chase_sound = r[4] != 0.0
		_known_enemy = _heard_pos
	return true


## Whether the gs_sim extension's GSSimBotMind steers (and [member native_act] lets it).
static func _act_available() -> bool:
	if _act_known < 0:
		_act_known = 1 if ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"steer") else 0
	return native_act and _act_known == 1


## [method _steer_native]'s switch: [method _act_available].
func _act_on() -> bool:
	return _act_available()


## Whether the gs_sim extension's GSSimBotMind hears (and [member native_hear] lets it).
static func _hear_available() -> bool:
	if _hear_known < 0:
		_hear_known = 1 if ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"hear") else 0
	return native_hear and _hear_known == 1


## Whether the gs_sim extension's GSSimBotMind perceives (and [member native_perceive] lets it).
static func _perceive_available() -> bool:
	if _perceive_known < 0:
		_perceive_known = 1 if ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"perceive") else 0
	return native_perceive and _perceive_known == 1


## Whether the gs_sim extension's GSSimBotMind can perceive on a worker over a held scan (hold_senses,
## perceive_held) and its objects may be called off the main thread at all (worker_safe: not on the web).
static func _held_available() -> bool:
	if _held_known < 0:
		_held_known = 0
		if ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"perceive_held") \
				and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"worker_safe") \
				and ClassDB.class_call_static(GSBotAim.MIND_CLASS, &"worker_safe"):
			_held_known = 1
	return _held_known == 1


## Whether the gs_sim extension's GSSimBotMind applies the sight LOD itself (sight_cached_far, set_sight_lod).
static func _sight_lod_available() -> bool:
	if _sight_lod_known < 0:
		_sight_lod_known = 1 if ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"sight_cached_far") else 0
	return _sight_lod_known == 1


## [method _perceive]'s choice in script: the current target while it is in sight, else the best
## score that is.
func _choose(me: GSBotContact, all: Array, world: GSBotWorld, p: GSBotProfile, eye: Vector3, half: float, through: bool, now: float) -> GSBotContact:
	var forward := GSBotAim.direction(aim.yaw, aim.pitch)
	var current: GSBotContact = null
	var best: GSBotContact = null
	var best_score := INF
	# Candidates inside range and cone come first; the sight test is the dear part, so it is
	# asked of the current target and then of the best score only until one is seen.
	var scores := PackedFloat32Array()
	# A bot that still sees its target keeps it whoever else is in view, so the target alone is
	# tested first and the scan over every body runs only when that fails (most thinks of a fight).
	if target_first and _visible:
		var held := world.contact_of(all, target_id) if world != null else GSBotWorld.find(all, target_id)
		if held != null and held.alive:
			_one[0] = held
			if not _candidates(me, _one, p, eye, forward, half, scores).is_empty() and (through or _sees(world, eye, held, now)):
				current = held
			_one[0] = null
			scores.clear()
	var cand: Array[GSBotContact] = []
	if current == null:
		var senses := world.senses(all) if world != null else null  # packed once per contacts_version
		cand = _candidates_native(senses, world, me, p, eye, forward, half, scores) if senses != null else _candidates(me, all, p, eye, forward, half, scores)
		if _visible:
			for i in cand.size():
				if cand[i].id == target_id:
					if through or _sees(world, eye, cand[i], now):
						current = cand[i]
					scores[i] = INF
					break
	if current == null:
		while true:
			var bi := -1
			best_score = INF
			for i in cand.size():
				if scores[i] < best_score:
					best_score = scores[i]
					bi = i
			if bi < 0:
				break
			if through or _sees(world, eye, cand[bi], now):
				best = cand[bi]
				break
			scores[bi] = INF

	return current if current != null else best


## Enemies inside range and cone (or already being fought), appended to the result with their closeness score in [param scores].
func _candidates(me: GSBotContact, all: Array, p: GSBotProfile, eye: Vector3, forward: Vector3, half: float, scores: PackedFloat32Array) -> Array[GSBotContact]:
	var cand: Array[GSBotContact] = []
	for item in all:
		if not (item is GSBotContact):
			continue
		var c := item as GSBotContact
		if not c.alive and c.id == target_id and _visible:
			# Killed, by this bot or somebody else, in plain view: a person moves on, and does
			# not stand pre-aiming the body for the next four seconds.
			_target_down()
			continue
		if not c.alive or not me.is_enemy(c):
			continue
		var to := c.aim_point() - eye
		var d := to.length()
		if d > p.sight:
			continue
		var off := rad_to_deg(forward.angle_to(to)) if d > 0.01 else 0.0
		# Somebody the bot is already fighting stays seen while it turns after them; anybody
		# else has to be inside the cone, or close enough to be felt.
		var tracking := _visible and c.id == target_id and off < 90.0
		if off > half and d > CLOSE_NOTICE and not tracking:
			continue
		cand.append(c)
		scores.append(d * (1.0 + off / 60.0))
	return cand


## [method _candidates] by GameSpice Sim's native scan over the tick's packed bodies: the same list, scores and forgetting.
func _candidates_native(senses: Object, world: GSBotWorld, me: GSBotContact, p: GSBotProfile, eye: Vector3, forward: Vector3, half: float, scores: PackedFloat32Array) -> Array[GSBotContact]:
	var cand: Array[GSBotContact] = []
	var idx: PackedInt32Array = senses.call(&"candidates", me.id, me.team, eye, forward, half, p.sight, CLOSE_NOTICE, target_id, _visible)
	if senses.call(&"target_dead"):
		_target_down()
	if idx.is_empty():
		return cand
	var list := world.sensed()
	for i in idx:
		cand.append(list[i])
	scores.append_array(senses.call(&"scores"))
	return cand


## Whether [param c] is in line of sight from [param eye]: the chest or the head, reused for [constant SIGHT_REUSE].
func _sees(world: GSBotWorld, eye: Vector3, c: GSBotContact, now: float) -> bool:
	var stamp := world.sight_stamp()
	if _mind != null:
		# The cache lives in the mind, which may perceive natively next tick.
		var h: int
		if _sight_lod_available():
			# The same sight LOD as the script cache below, decided here so the distance is the script's.
			var reuse := 0.0
			if world.sight_far > 0.0 and c.id != target_id and eye.distance_squared_to(c.position) > world.sight_far * world.sight_far:
				reuse = world.sight_far_reuse
			h = _mind.sight_cached_far(c.id, now, stamp, reuse)
		else:
			h = _mind.sight_cached(c.id, now, stamp)
		if h >= 0:
			return h == 1
		var t_sight1 := Time.get_ticks_usec() if GSBotClock.on else 0
		var seen_n := world.line_of_sight(eye, c.aim_point()) or world.line_of_sight(eye, c.eye())
		if t_sight1:
			GSBotClock.add(_clock, GSBotClock.Q_SIGHT, t_sight1)
		_mind.sight_put(c.id, now, seen_n, stamp)
		return seen_n
	var held: Variant = _sight_cache.get(c.id)
	if not (held is Array):
		var t_sight2 := Time.get_ticks_usec() if GSBotClock.on else 0
		var first := world.line_of_sight(eye, c.aim_point()) or world.line_of_sight(eye, c.eye())
		if t_sight2:
			GSBotClock.add(_clock, GSBotClock.Q_SIGHT, t_sight2)
		_sight_cache[c.id] = [now, first, stamp]
		return first
	var row := held as Array
	var at: float = row[0]
	if row[2] == stamp and now >= at:
		if now - at < SIGHT_REUSE:
			return row[1]
		# Sight LOD: a far body behind a wall stays unseen a little longer; never the target, never a "seen".
		if not row[1] and world.sight_far > 0.0 and now - at < world.sight_far_reuse and c.id != target_id \
				and eye.distance_squared_to(c.position) > world.sight_far * world.sight_far:
			return false
	var t_sight3 := Time.get_ticks_usec() if GSBotClock.on else 0
	var seen := world.line_of_sight(eye, c.aim_point()) or world.line_of_sight(eye, c.eye())
	if t_sight3:
		GSBotClock.add(_clock, GSBotClock.Q_SIGHT, t_sight3)
	# The row is this brain's own: written in place, a sight test allocates nothing after the first.
	row[0] = now
	row[1] = seen
	row[2] = stamp
	return seen


func _lose(p: GSBotProfile, now: float) -> void:
	_visible = false
	_lost_at = now
	aim.release()
	_peeking = _rng.next_unit() < p.peek + style.peek_b
	_chase_lost = _rng.next_unit() < p.aggression + style.aggression_b
	_grenade_ready = _rng.next_unit() < p.grenades


## The target died in plain view: forgotten, and the style hears of the kill.
func _target_down() -> void:
	_forget_target()
	style.on_kill()


func _forget_target() -> void:
	target_id = -1
	_visible = false
	_last_seen_pos = Vector3.INF
	_last_seen_at = -INF
	aim.forget()


# --- Hearing --------------------------------------------------------------------

func _hear(me: GSBotContact, all: Array, world: GSBotWorld, p: GSBotProfile, now: float) -> void:
	var newest := world.last_sound()
	if newest == _heard_seq:
		return
	if _mind != null and _hear_native(me, all, world, p, now, newest):
		return
	var t_sounds := Time.get_ticks_usec() if GSBotClock.on else 0
	world.sounds_into(_heard_seq, now, _heard)
	if t_sounds:
		GSBotClock.add(_clock, GSBotClock.Q_SOUNDS, t_sounds)
	_heard_seq = newest
	var my_id := me.id
	var here := me.position
	var reach := p.hearing
	for s in _heard:
		var source := int(s.get("source", 0))
		if source == my_id:
			continue
		var at: Vector3 = s.get("position", Vector3.INF)
		if at == Vector3.INF:
			continue
		var d := here.distance_to(at)
		if d > reach * float(s.get("loudness", 1.0)):
			continue
		# Asked last: most sounds are out of earshot, and whose they are is the dear question.
		var who := world.contact_of(all, source)
		if who != null and not me.is_enemy(who):
			continue
		# A sound says roughly where, never exactly: the further, the vaguer.
		var spread := d * 0.08
		_heard_pos = at + Vector3((_rng.next_unit() - 0.5) * 2.0 * spread, 0.0, (_rng.next_unit() - 0.5) * 2.0 * spread)
		_heard_at = now
		_chase_sound = _rng.next_unit() < p.aggression + style.aggression_b
		_known_enemy = _heard_pos


# --- Doing ----------------------------------------------------------------------

func _fight(me: GSBotContact, c: GSBotContact, world: GSBotWorld, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> void:
	var eye := me.eye()
	var t_proj := Time.get_ticks_usec() if GSBotClock.on else 0
	var speed := world.projectile_speed(me) if world != null else 0.0
	if t_proj:
		GSBotClock.add(_clock, GSBotClock.Q_PROJECTILE, t_proj)
	var flat := Vector2(c.position.x - me.position.x, c.position.z - me.position.z)
	var dist := flat.length()
	var retreat := _roll_cover and me.health < RETREAT_HEALTH
	if now - _fight_last > 2.0 or me.position.distance_to(_fight_spot) > STALE_MOVE:
		_fight_spot = me.position
		_fight_since = now
	_fight_last = now
	# A standoff nobody wins, one target or several: the bot walks in instead of trading misses from one spot.
	var push := not retreat and dist > STALE_CLOSE and now - _fight_since > STALE_FIGHT
	var carrying := goal.urgent and goal.dest != Vector3.INF
	# The native mind has no flag-carrier run home; the carrier stays on the script.
	if aim._n != null and not carrying and not aim.aim_solver.is_valid() and _fight_native(me, c, eye, speed, p, now, dt, push, out):
		return
	var _view := aim.track(eye, c.aim_point(), c.velocity, now, dt, speed)

	var trigger := aim.trigger(now, dist)
	out.fire = trigger
	if trigger:
		aim.note_shot(eye, c.aim_point(), now)

	# Distance and strafing.
	var dir := flat / dist if dist > 0.01 else Vector2(0.0, -1.0)
	var forward := 0.0
	var keep := p.range * style.range_k
	if dist > keep * 1.3:
		forward = 1.0
	elif dist < keep * 0.7:
		forward = -0.7

	if push:
		forward = 1.0
	if retreat:
		forward = -1.0
	out.state = &"retreat" if retreat else &"fight"
	_scene = &"flee" if retreat else (&"close" if dist > keep * 1.3 else &"fight")
	_scene_up = c.position.y - me.position.y

	if now >= _strafe_until:
		_strafe = (1.0 if _rng.next_unit() < 0.5 else -1.0) if _rng.next_unit() < p.strafe * style.strafe_k else 0.0
		if p.strafe_jitter > 0.0:
			# Uneven lengths (many short, a few long) and now and then a stop to aim.
			var u := _rng.next_unit()
			_strafe_until = now + p.strafe_time * lerpf(0.5 + _rng.next_unit(), 0.2 + 2.0 * u * u, p.strafe_jitter)
			if _strafe != 0.0 and _rng.next_unit() < 0.25 * p.strafe_jitter:
				_strafe = 0.0
		else:
			_strafe_until = now + p.strafe_time * (0.5 + _rng.next_unit())
	var side := _strafe
	if p.strafe_jitter > 0.0:
		# A body does not reverse at once: it brakes through zero.
		_strafe_eased = move_toward(_strafe_eased, _strafe, dt * 5.0)
		side = _strafe_eased
	if now < _hesitate_until:
		forward = 0.0
		side = 0.0

	var long_burst := trigger and dist > p.burst_range * 0.6
	if long_burst and _roll_stop and not retreat and not push:
		forward = 0.0
		side = 0.0
	out.crouch = trigger and _roll_crouch and dist > p.burst_range and not retreat
	if out.crouch:
		side = 0.0
	if not out.crouch and dist < p.burst_range and dt > 0.0 and _rng.next_unit() < p.jump * dt:
		out.jump = true

	if carrying:
		# A flag carrier shoots on the move and keeps running home.
		out.crouch = false
		_set_move(out, _toward(me, world, goal.dest) + Vector2(-dir.y, dir.x) * side * 0.35)
		return
	_set_move(out, dir * forward + Vector2(-dir.y, dir.x) * side)
