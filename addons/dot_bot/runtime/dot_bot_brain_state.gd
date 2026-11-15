extends RefCounted

## [DotBotBrain]'s state and its movement: the fields every decision reads, and how a bot walks, roams, searches and climbs.
## Split out of dot_bot_brain.gd for file size; nothing outside the brain names this script.

## A hunting bot heads for the place nearest its prey, or the prey itself if no place is this close.
const HUNT_PLACE_NEAR := 6.0

const CHANNEL := "dot.bot"

## Within this distance a body is noticed whatever way the bot faces: somebody touching you.
const CLOSE_NOTICE := 2.0

## Health fraction under which a bot that rolled [member DotBotProfile.cover] backs out.
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

var id: int = 0
var settings: DotBotSettings = null

## The view, the aim error, the reaction and the trigger.
var aim: DotBotAim = null

## The latest intent, for describe().
var last: DotBotIntent = null

# The target, as perceived.
var target_id: int = -1
var _visible: bool = false

## Per target id: [time asked, answer] of the last line-of-sight test, see [constant SIGHT_REUSE].
var _sight_cache: Dictionary = {}
var _roll_stop: bool = false
var _roll_crouch: bool = false
var _roll_cover: bool = false

## Slide, wall run and the rest; the scenario and the target's height over the bot are set by whichever of fight, search, listen or roam ran this tick.
var tricks := DotBotTricks.new()
var _scene: StringName = &"roam"
var _scene_up: float = 0.0

var _last_seen_pos: Vector3 = Vector3.INF
var _last_seen_vel: Vector3 = Vector3.ZERO
var _last_seen_at: float = -INF
var _lost_at: float = -INF
var _peeking: bool = false
var _chase_lost: bool = false
var _grenade_ready: bool = false
## Fetching a better weapon from the floor; see [DotBotPickup].
var pickup := DotBotPickup.new()
## The job in a flag mode, planned from [member DotBotWorld.objective]; idle without one.
var goal: DotBotGoal = null
## The cloned policy, or null; it drives this bot only when [method DotBotPolicy.active] says so (`bot_policy` above 0, a passing gate for the map).
var policy: DotBotPolicy = null

# Sound and pain.
var _heard_pos: Vector3 = Vector3.INF
var _heard_at: float = -INF
var _chase_sound: bool = false
var _heard_seq: int = 0
## The sounds of the last hearing, one array kept for every think.
var _heard: Array[Dictionary] = []
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
var _climb: DotBotClimb = null
var _unstick: DotBotUnstick = null

var _now: float = NAN
var _was_alive: bool = true
var _rng: DotRandomStream = null
var _fight_io := PackedFloat64Array()


## How long a lost target or a sound holds the bot's attention: its whole memory when it is
## going after it or re-peeking, and a glance otherwise. A bot that stands staring at a wall
## for four seconds because it heard a shot behind it reads as stuck, not as cautious.
func _hold_time(p: DotBotProfile, committed: bool) -> float:
	return p.memory if committed else minf(p.memory, GLANCE)


func _search(me: DotBotContact, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
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


func _listen(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
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


func _roam(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
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


## Walks toward [param dest], looking where it goes.
func _walk(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, dest: Vector3, now: float, dt: float, out: DotBotIntent) -> void:
	var dir := _toward(me, world, dest)
	# Looking where it walks, with the glance to either side a person checking corners has.
	var look := DotBotAim.angles_to(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y))
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


## Turns the view [param rate] deg/s on for [param dt] seconds. A thinned bot thinks every few ticks, and the
## smoothing in [method DotBotAim.turn_to] is quadratic in dt, so a long dt runs as steps of at most 1/60 s:
## the turn per elapsed second is the same however often the bot thinks (one step, as before, up to 1/60 s).
func _drift(rate: float, dt: float) -> void:
	var n := maxi(1, ceili(dt * 60.0 - 0.01))
	var sub := dt / float(n)
	for _i in n:
		aim.turn_to(Vector2(aim.yaw + rate * sub, 0.0), sub)


## At its post: stands, watching the way an enemy would come, glancing to either side.
func _hold(me: DotBotContact, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	var look := Vector2(aim.yaw, 0.0)
	if goal.face == Vector3.INF:
		_drift(30.0, dt)
		_set_move(out, Vector2.ZERO)
		return
	if goal.face != Vector3.INF:
		look = DotBotAim.angles_to(me.eye(), Vector3(goal.face.x, me.eye().y, goal.face.z))
		look.y = 0.0
		look.x += 50.0 * sin(now * 0.5 + float(id % 89)) * (0.3 + p.glance)
	aim.turn_to(look, dt)
	_set_move(out, Vector2.ZERO)


## True when a weapon on the floor has this tick: walk to it, look at it, press use near it.
func _fetch(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> bool:
	var plan := pickup.step(me, world, p, now, true)
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
func _quiet(now: float, p: DotBotProfile) -> bool:
	if _last_seen_pos != Vector3.INF and now - _last_seen_at <= _hold_time(p, _peeking or _chase_lost):
		return false
	var last_noise := maxf(_heard_at, _hurt_at)
	return not (last_noise > -INF and now - last_noise <= _hold_time(p, _chase_sound or _hurt_at >= _heard_at))


func _pick_waypoint(me: DotBotContact, world: DotBotWorld, p: DotBotProfile) -> Vector3:
	var points := world.waypoints() if world != null else PackedVector3Array()
	var far: Array[Vector3] = []
	for point in points:
		if point.distance_to(me.position) > 3.0:
			far.append(point)
	if far.is_empty():
		return Vector3.INF
	if _known_enemy != Vector3.INF and _rng.next_unit() < p.map_knowledge:
		var best := far[0]
		for point in far:
			if point.distance_to(_known_enemy) < best.distance_to(_known_enemy):
				best = point
		_known_enemy = Vector3.INF
		return best
	# Hunting: no lead, but a body somewhere on the map; head for the place nearest the closest one.
	if _rng.next_unit() < p.map_knowledge * 0.4:
		var prey := _nearest_enemy(me, world)
		if prey != Vector3.INF:
			var near := far[0]
			for point in far:
				if point.distance_to(prey) < near.distance_to(prey):
					near = point
			# A sparse mesh leaves the nearest place far from the prey; walk at the prey then.
			return near if near.distance_to(prey) <= HUNT_PLACE_NEAR else prey
	return far[_rng.next_range_i(0, far.size() - 1)]


func _nearest_enemy(me: DotBotContact, world: DotBotWorld) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for item in world.contacts():
		var c := item as DotBotContact
		if c == null or not c.alive or not me.is_enemy(c):
			continue
		var d := c.position.distance_to(me.position)
		if d < best_d:
			best_d = d
			best = c.position
	return best


## The flat direction to walk toward [param goal]: along the world's route to it when the world
## has one ([method DotBotWorld.route]), straight at it when not. The route is asked for once per
## goal and walked corner by corner; a corner within [constant CORNER] metres is passed.
func _toward(me: DotBotContact, world: DotBotWorld, goal: Vector3) -> Vector2:
	if goal != _route_goal:
		_route_goal = goal
		var detail := world.route_detail(me.position, goal) if world != null else {}
		_route = detail.get("points", PackedVector3Array())
		_route_rides = detail.get("rides", PackedInt32Array())
	var here := Vector2(me.position.x, me.position.z)
	while not _route.is_empty() and here.distance_to(Vector2(_route[0].x, _route[0].z)) < CORNER:
		# A corner that starts a ride edge: say so, and the game takes the legs from here.
		if not _route_rides.is_empty():
			var ride := _route_rides[0]
			var ladder := world.ladder(ride) if ride >= 0 and world != null else {}
			if not ladder.is_empty():
				_climb = DotBotClimb.begin(ladder, _now)
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
func _free_if_stuck(me: DotBotContact, world: DotBotWorld, now: float, out: DotBotIntent) -> void:
	# A duel strafes on the spot by design; only travelling can be stuck.
	var pushing := out.move.length() > 0.3 and out.state != &"dead" and out.state != &"fight" and out.state != &"retreat"
	if _unstick.step(me.position, pushing, now, world) == 0:
		return
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
func _climb_step(me: DotBotContact, now: float, out: DotBotIntent) -> void:
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


func _set_move(out: DotBotIntent, world_dir: Vector2) -> void:
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
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	for key in d:
		out.append("%s: %s" % [key, str(d[key])])
	return out
