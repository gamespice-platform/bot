extends RefCounted

## [GSBotBrain]'s state and its movement: the fields every decision reads, and how a bot walks, roams, searches and climbs.
## Split out of gs_bot_brain.gd for file size; nothing outside the brain names this script.

## A hunting bot heads for the place nearest its prey, or the prey itself if no place is this close.
const HUNT_PLACE_NEAR := 6.0

const CHANNEL := "gs.bot"

## Within this distance a body is noticed whatever way the bot faces: somebody touching you.
const CLOSE_NOTICE := 2.0

## Health fraction under which a bot that rolled [member GSBotProfile.cover] backs out.
const RETREAT_HEALTH := 0.35
## Seconds a bot may fight within [constant STALE_MOVE] metres of one spot, against anybody, before it pushes in.
const STALE_FIGHT := 8.0
## How far a fighting bot has to get from where it stood for its fight to count as moving, metres.
const STALE_MOVE := 3.0
## How close a pushing bot walks in, metres.
const STALE_CLOSE := 3.0

## Seconds a bot that is not going after a sound or a lost target spends looking toward it.
const GLANCE := 1.2

## How long a line-of-sight answer for one target is reused, seconds. Sight is the dearest part of
## a tick (up to two ray casts per enemy in the cone), and a person's eyes do not change their
## mind about a doorway in 40 ms either.
const SIGHT_REUSE := 0.045

var _one: Array = [null]

## Longest gap between thinks that is integrated as one step, seconds.
const MAX_STEP := 0.25

## Metres from a route's corner at which it counts as passed.
const CORNER := 1.0

## [method _steer_native]'s modes (gs_sim_brain::act::mode).
const STEER_WALK := 0
const STEER_HOLD := 1
const STEER_DRIFT := 2

var id: int = 0
var settings: GSBotSettings = null

## The view, the aim error, the reaction and the trigger.
var aim: GSBotAim = null
## This brain's GSSimBotMind (the aim's, kept when the aim falls back to script): it holds the
## sight cache, and perceives when the world packed a native scan this tick. Null: all in script.
var _mind: Object = null

## The latest intent, for describe().
var last: GSBotIntent = null

# The target, as perceived.
var target_id: int = -1
var _visible: bool = false
## Thinks counted for [member GSBotWorld.scan_every] (the perception stride).
var _scan_turn: int = 0
## The body this brain thinks for, as the last perceive was told (pair sight asks by id).
var _me_id: int = 0

## Per target id: [time asked, answer] of the last line-of-sight test, see [constant SIGHT_REUSE].
var _sight_cache: Dictionary = {}
var _roll_stop: bool = false
var _roll_crouch: bool = false
var _roll_cover: bool = false

## Slide, wall run and the rest; the scenario and the target's height over the bot are set by whichever of fight, search, listen or roam ran this tick.
## This brain's profile clock ([GSBotClock]), handed to its parts that ask the world; see [member GSBotBrain.phase_us].
var _clock := GSBotClock.new()
var tricks := GSBotTricks.new()
var _scene: StringName = &"roam"
var _scene_up: float = 0.0

var _last_seen_pos: Vector3 = Vector3.INF
var _last_seen_vel: Vector3 = Vector3.ZERO
var _last_seen_at: float = -INF
var _lost_at: float = -INF
var _peeking: bool = false
var _chase_lost: bool = false
var _grenade_ready: bool = false
## Fetching a better weapon from the floor; see [GSBotPickup].
var pickup := GSBotPickup.new()
## The job in a flag mode, planned from [member GSBotWorld.objective]; idle without one.
var goal: GSBotGoal = null
## The cloned policy, or null; it drives this bot only when [method GSBotPolicy.active] says so (`bot_policy` above 0, a passing gate for the map).
var policy: GSBotPolicy = null

# Sound and pain.
var _heard_pos: Vector3 = Vector3.INF
var _heard_at: float = -INF
var _chase_sound: bool = false
var _heard_seq: int = 0
## The sounds of the last hearing, one array kept for every think.
var _heard: Array[Dictionary] = []
## [method _pick_waypoint]'s places over 3 m away, kept between thinks; only its first n slots are this pick's.
var _far := PackedVector3Array()
var _hurt_from: Vector3 = Vector3.INF
var _hurt_at: float = -INF
var _hurt_pending_at: float = INF
var _hurt_pending_from: Vector3 = Vector3.INF
var _known_enemy: Vector3 = Vector3.INF
var _blind_until: float = -INF

# Movement.
var _strafe: float = 0.0
var _strafe_until: float = -INF
var _strafe_eased: float = 0.0
var _hesitate_until: float = -INF
# Where the bot has been fighting since when, for a standoff that never moves; reset by a pause in the fighting.
var _fight_spot: Vector3 = Vector3.INF
var _fight_since: float = -INF
var _fight_last: float = -INF
var _glance_next: float = 0.0
var _glance_until: float = -INF
var _glance_off: float = 0.0
var _waypoint: Vector3 = Vector3.INF
# The world's route to where the bot is walking, corner by corner, and the goal it was asked for.
var _route: PackedVector3Array = PackedVector3Array()
# Per corner of _route, the ride edge that starts there, or -1.
var _route_rides: PackedInt32Array = PackedInt32Array()
var _route_goal: Vector3 = Vector3.INF
# The ride a corner just reached, for this tick's intent.
var _ride_reached: int = -1
# The ladder being climbed, or null.
var _climb: GSBotClimb = null
var _unstick: GSBotUnstick = null
## How this bot plays the weapon in its hand (neutral when the game names no class).
var style: GSBotStyle = null

var _now: float = NAN
var _was_alive: bool = true
var _rng: GSRandomStream = null
var _fight_io := PackedFloat64Array()
## The native hear's input row, reused across thinks.
var _hear_io := PackedFloat64Array()


## How long a lost target or a sound holds the bot's attention: its whole memory when it is
## going after it or re-peeking, and a glance otherwise. A bot that stands staring at a wall
## for four seconds because it heard a shot behind it reads as stuck, not as cautious.
func _hold_time(p: GSBotProfile, committed: bool) -> float:
	return p.memory if committed else minf(p.memory, GLANCE)


func _search(me: GSBotContact, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> void:
	out.state = &"search"
	_scene = &"cover" if _peeking else &"chase"
	var since := now - _lost_at
	# Where it went, as far as the bot can guess: along the way it was moving, for a moment.
	var guess := _last_seen_pos + _last_seen_vel * minf(since, 1.0) * p.prediction * 0.5
	var flat := Vector2(guess.x - me.position.x, guess.z - me.position.z)
	var dist := flat.length()

	if _grenade_ready and since >= 0.4 and since <= 3.0 and dist >= 6.0 and dist <= 25.0:
		# Lobbed: a little above the spot, so it carries.
		var _v := aim.look_at_point(me.eye(), guess + Vector3.UP * (1.0 + dist * 0.15), dt)
		out.throw = true
		_grenade_ready = false
		return

	if dist < 1.5:
		_last_seen_pos = Vector3.INF
		return

	var dir := flat / dist if dist > 0.01 else Vector2.ZERO
	if _peeking:
		# Pre-aimed at the corner, shuffling in and out of it.
		var _v := aim.look_at_point(me.eye(), guess + Vector3.UP * 1.25, dt)
		var side := 1.0 if fmod(since, 1.2) < 0.6 else -1.0
		_set_move(out, dir * (0.6 if _chase_lost else 0.0) + Vector2(-dir.y, dir.x) * side * 0.8)
	elif _chase_lost:
		var _v := aim.look_at_point(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y), dt)
		_set_move(out, dir)
	else:
		var _v := aim.look_at_point(me.eye(), guess + Vector3.UP * 1.25, dt)


func _listen(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> void:
	out.state = &"listen"
	_scene = &"chase" if _chase_sound else &"cover"
	var at := _hurt_from if _hurt_at >= _heard_at else _heard_pos
	if at == Vector3.INF:
		return
	var _v := aim.look_at_point(me.eye(), at + Vector3.UP * 1.25, dt)
	var flat := Vector2(at.x - me.position.x, at.z - me.position.z)
	if (_chase_sound or _hurt_at >= _heard_at) and flat.length() > 2.0:
		_set_move(out, _toward(me, world, at))
	elif flat.length() <= 2.0:
		_heard_at = -INF
		_hurt_at = -INF


func _roam(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> void:
	out.state = &"roam"
	var here := Vector2(me.position.x, me.position.z)
	if not goal.urgent and _fetch(me, world, p, now, dt, out):
		return

	if goal.dest != Vector3.INF:
		out.state = goal.kind
		if goal.arrived(me.position) and not goal.urgent:
			_hold(me, p, now, dt, out)
			return
		_walk(me, world, p, goal.dest, now, dt, out)
		return

	if _waypoint == Vector3.INF or here.distance_to(Vector2(_waypoint.x, _waypoint.z)) < 2.0:
		_waypoint = _pick_waypoint(me, world, p)

	if _waypoint == Vector3.INF:
		# Nowhere to go: look about.
		_drift(40.0, dt)
		return
	_walk(me, world, p, _waypoint, now, dt, out)


## A roaming steer in Rust; GSBotBrain overrides this ([member GSBotBrain.native_act]). False: steer in script.
func _steer_native(_mode: int, _me: GSBotContact, _p: GSBotProfile, _aim_at: Vector3, _rate: float, _now: float, _dt: float, _out: GSBotIntent) -> bool:
	return false


## Walks toward [param dest], looking where it goes.
func _walk(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, dest: Vector3, now: float, dt: float, out: GSBotIntent) -> void:
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var dir := _toward(me, world, dest)
	if _steer_native(STEER_WALK, me, p, Vector3(dir.x, dir.y, 0.0), 0.0, now, dt, out):
		if t:
			GSBotClock.add(_clock, GSBotClock.A_WALK, t)
		return
	# Looking where it walks, with the glance to either side a person checking corners has.
	var look := GSBotAim.angles_to(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y))
	look.x += 25.0 * sin(now * 0.8 + float(id % 97))
	look.y = 0.0
	if p.glance > 0.0:
		if now >= _glance_next and now >= _glance_until:
			# Turn the head to one side, hold the look, then carry on: a person checking a doorway.
			_glance_off = (1.0 if _rng.next_unit() < 0.5 else -1.0) * (35.0 + 70.0 * _rng.next_unit())
			_glance_until = now + 0.35 + 0.6 * _rng.next_unit()
			_glance_next = _glance_until + (1.5 + 4.0 * _rng.next_unit()) / (0.3 + p.glance)
		if now < _glance_until:
			look.x += _glance_off
	aim.turn_to(look, dt)
	_set_move(out, dir)
	if t:
		GSBotClock.add(_clock, GSBotClock.A_WALK, t)


## Turns the view [param rate] deg/s on for [param dt] seconds. A thinned bot thinks every few ticks, and the
## smoothing in [method GSBotAim.turn_to] is quadratic in dt, so a long dt runs as steps of at most 1/60 s:
## the turn per elapsed second is the same however often the bot thinks (one step, as before, up to 1/60 s).
func _drift(rate: float, dt: float) -> void:
	if _steer_native(STEER_DRIFT, null, null, Vector3.ZERO, rate, 0.0, dt, null):
		return
	var n := maxi(1, ceili(dt * 60.0 - 0.01))
	var sub := dt / float(n)
	for _i in n:
		aim.turn_to(Vector2(aim.yaw + rate * sub, 0.0), sub)


## At its post: stands, watching the way an enemy would come, glancing to either side.
func _hold(me: GSBotContact, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> void:
	if _steer_native(STEER_HOLD, me, p, goal.face, 0.0, now, dt, out):
		return
	var look := Vector2(aim.yaw, 0.0)
	if goal.face == Vector3.INF:
		_drift(30.0, dt)
		_set_move(out, Vector2.ZERO)
		return
	if goal.face != Vector3.INF:
		look = GSBotAim.angles_to(me.eye(), Vector3(goal.face.x, me.eye().y, goal.face.z))
		look.y = 0.0
		look.x += 50.0 * sin(now * 0.5 + float(id % 89)) * (0.3 + p.glance)
	aim.turn_to(look, dt)
	_set_move(out, Vector2.ZERO)


## The native mind that chooses a weapon off the floor, or null (script); GSBotBrain answers it ([member GSBotBrain.native_pickup]).
func _pickup_mind() -> Object:
	return null


## The native mind that keeps the unstick state: [member _mind], else the aim's, null for the script (GSBotUnstick checks the library and [member GSBotUnstick.native_enabled]).
func _unstick_mind() -> Object:
	return _mind if _mind != null else (aim._n if aim != null else null)


## True when a weapon on the floor has this tick: walk to it, look at it, press use near it.
func _fetch(me: GSBotContact, world: GSBotWorld, p: GSBotProfile, now: float, dt: float, out: GSBotIntent) -> bool:
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var plan := pickup.step(me, world, p, now, true, _pickup_mind())
	if t:
		GSBotClock.add(_clock, GSBotClock.A_PICKUP, t)
	if plan.is_empty():
		return false
	var at: Vector3 = plan["position"]
	out.state = &"pickup"
	var _v := aim.look_at_point(me.eye(), at + Vector3.UP * 0.2, dt)
	if bool(plan["use"]):
		out.use = true
		_set_move(out, Vector2.ZERO)
	else:
		_set_move(out, _toward(me, world, at))
	return true


## No enemy in mind: nothing seen, remembered, heard or felt lately.
func _quiet(now: float, p: GSBotProfile) -> bool:
	if _last_seen_pos != Vector3.INF and now - _last_seen_at <= _hold_time(p, _peeking or _chase_lost):
		return false
	var last_noise := maxf(_heard_at, _hurt_at)
	return not (last_noise > -INF and now - last_noise <= _hold_time(p, _chase_sound or _hurt_at >= _heard_at))


func _pick_waypoint(me: GSBotContact, world: GSBotWorld, p: GSBotProfile) -> Vector3:
	var t_way := Time.get_ticks_usec() if GSBotClock.on else 0
	var points := world.waypoints() if world != null else PackedVector3Array()
	if t_way:
		GSBotClock.add(_clock, GSBotClock.Q_WAYPOINTS, t_way)
	# The places over 3 m away, in _far's first n slots: it only grows, so a pick allocates nothing.
	if _far.size() < points.size():
		_far.resize(points.size())
	var n := 0
	for point in points:
		if point.distance_to(me.position) > 3.0:
			_far[n] = point
			n += 1
	if n == 0:
		return Vector3.INF
	if _known_enemy != Vector3.INF and _rng.next_unit() < p.map_knowledge:
		var best := _far[0]
		for i in n:
			if _far[i].distance_to(_known_enemy) < best.distance_to(_known_enemy):
				best = _far[i]
		_known_enemy = Vector3.INF
		return best
	# Hunting: no lead, but a body somewhere on the map; head for the place nearest the closest one.
	if _rng.next_unit() < p.map_knowledge * 0.4:
		var prey := _nearest_enemy(me, world)
		if prey != Vector3.INF:
			var near := _far[0]
			for i in n:
				if _far[i].distance_to(prey) < near.distance_to(prey):
					near = _far[i]
			# A sparse mesh leaves the nearest place far from the prey; walk at the prey then.
			return near if near.distance_to(prey) <= HUNT_PLACE_NEAR else prey
	return _far[_rng.next_range_i(0, n - 1)]


func _nearest_enemy(me: GSBotContact, world: GSBotWorld) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	var t := world.table()
	if t != null:
		var at := t.positions
		for i in t.size():
			if t.live_enemy(i, me):
				var d := at[i].distance_to(me.position)
				if d < best_d:
					best_d = d
					best = at[i]
		return best
	for item in world.contacts():
		var c := item as GSBotContact
		if c == null or not c.alive or not me.is_enemy(c):
			continue
		var d := c.position.distance_to(me.position)
		if d < best_d:
			best_d = d
			best = c.position
	return best


## The flat direction to walk toward [param goal]: along the world's route to it when the world
## has one ([method GSBotWorld.route]), straight at it when not. The route is asked for once per
## goal and walked corner by corner; a corner within [constant CORNER] metres is passed.
func _toward(me: GSBotContact, world: GSBotWorld, goal: Vector3) -> Vector2:
	var t := Time.get_ticks_usec() if GSBotClock.on else 0
	var dir := _toward_route(me, world, goal)
	if t:
		GSBotClock.add(_clock, GSBotClock.A_TOWARD, t)
	return dir


func _toward_route(me: GSBotContact, world: GSBotWorld, goal: Vector3) -> Vector2:
	if goal != _route_goal:
		_route_goal = goal
		var t_route := Time.get_ticks_usec() if GSBotClock.on else 0
		var detail := world.route_detail(me.position, goal) if world != null else {}
		if t_route:
			GSBotClock.add(_clock, GSBotClock.Q_ROUTE, t_route)
		_route = detail.get("points", PackedVector3Array())
		_route_rides = detail.get("rides", PackedInt32Array())
	var here := Vector2(me.position.x, me.position.z)
	while not _route.is_empty() and here.distance_to(Vector2(_route[0].x, _route[0].z)) < CORNER:
		# A corner that starts a ride edge: say so, and the game takes the legs from here.
		if not _route_rides.is_empty():
			var ride := _route_rides[0]
			var t_ladder := Time.get_ticks_usec() if GSBotClock.on else 0
			var ladder := world.ladder(ride) if ride >= 0 and world != null else {}
			if t_ladder:
				GSBotClock.add(_clock, GSBotClock.Q_LADDER, t_ladder)
			if not ladder.is_empty():
				_climb = GSBotClimb.begin(ladder, _now)
			elif ride >= 0:
				_ride_reached = ride
			_route_rides.remove_at(0)
		_route.remove_at(0)
		if _climb != null:
			break
	var at := _route[0] if not _route.is_empty() else goal
	var flat := Vector2(at.x, at.z) - here
	return flat.normalized() if flat.length() > 0.01 else Vector2.ZERO


## A bot that pushes and does not move, in any state: re-plan, hop, crouch-hop and side-step, then walk to the nearest standable point.
func _free_if_stuck(me: GSBotContact, world: GSBotWorld, now: float, out: GSBotIntent) -> void:
	# A duel strafes on the spot by design; only travelling can be stuck.
	var pushing := out.move.length() > 0.3 and out.state != &"dead" and out.state != &"fight" and out.state != &"retreat"
	if _unstick.step(me.position, pushing, now, world, settings.profile.stranded_sec, _unstick_mind()) == 0:
		return
	if _unstick.stranded:
		out.stranded = true
		GSLog.warn(CHANNEL, "bot stranded: stuck with every unstick step tried, the game should respawn it", {"bot": id, "at": me.position, "after": settings.profile.stranded_sec})
	if _unstick.replan:
		_waypoint = Vector3.INF
		_route_goal = Vector3.INF
	out.jump = out.jump or _unstick.jump
	out.crouch = out.crouch or _unstick.crouch
	if _unstick.strafe != 0.0:
		out.move = Vector2(_unstick.strafe, out.move.y).limit_length(1.0)
	if _unstick.nudge_to != Vector3.INF:
		var d := Vector2(_unstick.nudge_to.x, _unstick.nudge_to.z) - Vector2(me.position.x, me.position.z)
		if d.length() > 0.01:
			_set_move(out, d.normalized())


## Overrides this tick's legs while a ladder is climbed; the view and trigger stay the brain's.
func _climb_step(me: GSBotContact, now: float, out: GSBotIntent) -> void:
	var r := _climb.step(me.position, now)
	if r["done"]:
		_end_climb()
		return
	if not is_nan(float(r["yaw"])):
		aim.view_from(float(r["yaw"]), 0.0)
	out.yaw = aim.yaw
	out.pitch = 0.0
	out.move = r["move"]
	out.jump = r["jump"]
	out.crouch = false
	out.state = &"climb"


func _end_climb() -> void:
	_climb = null
	_route_goal = Vector3.INF


func _set_move(out: GSBotIntent, world_dir: Vector2) -> void:
	var y := deg_to_rad(aim.yaw)
	var forward := Vector2(-sin(y), -cos(y))
	var right := Vector2(cos(y), -sin(y))
	out.move = Vector2(world_dir.dot(right), world_dir.dot(forward)).limit_length(1.0)


func describe() -> Dictionary:
	return {
		"id": id,
		"difficulty": settings.profile.preset_name,
		"state": last.state if last != null else &"",
		"target": target_id,
		"visible": _visible,
		"yaw": snappedf(aim.yaw, 0.1),
		"aim_error_deg": snappedf(aim.error_deg(_now if not is_nan(_now) else 0.0), 0.01),
		"role": goal.role,
		"goal": goal.kind,
		"style": style.label(),
		"style_phase": style.phase_name(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	for key in d:
		out.append("%s: %s" % [key, str(d[key])])
	return out


## Whether this think skips the scan for a new target ([member GSBotWorld.scan_every]): only when no
## target is visible, so a brain in a fight always checks its target. Reads [member _scan_turn]
## without counting it, so [method think_mt_row] asks the same question the think will.
func _scan_waits(world: GSBotWorld) -> bool:
	return not _visible and world != null and world.scan_every > 1 and (_scan_turn + id) % world.scan_every != 0
