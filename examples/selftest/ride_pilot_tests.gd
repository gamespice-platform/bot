extends "res://examples/selftest/harvest_tests.gd"
## The piloted-replay section of the bot suite: rides quantised to pilot actions, the ride book's cache and tracking, and harvests sliced across ticks.


# The piloted replay's toy: a point mass flying at 8 m/s from 6 m up, 20 m/s^2 along the wish; the platform is x from 10 to 13.

class PilotToyState:
	extends RefCounted
	var position := Vector3(0.0, 6.0, 0.0)
	var velocity := Vector3(8.0, 0.0, 0.0)

	func duplicate_state() -> PilotToyState:
		var c := PilotToyState.new()
		c.position = position
		c.velocity = velocity
		return c


class PilotToyCommand:
	extends RefCounted
	var yaw := 0.0
	var move := Vector2.ZERO
	var jump := false


class PilotToySim:
	extends RefCounted
	var delta := 1.0 / 64.0

	func command(yaw: float, move: Vector2, jump: bool) -> PilotToyCommand:
		var c := PilotToyCommand.new()
		c.yaw = yaw
		c.move = move
		c.jump = jump
		return c

	func step(state: PilotToyState, cmd: PilotToyCommand) -> int:
		var v := deg_to_rad(cmd.yaw)
		var wish := Vector2(cos(v), -sin(v)) * cmd.move.x + Vector2(-sin(v), -cos(v)) * cmd.move.y
		state.velocity.x += wish.x * 20.0 * delta
		state.velocity.z += wish.y * 20.0 * delta
		state.velocity.y -= 9.8 * delta
		state.position += state.velocity * delta
		if state.position.y > 0.0:
			return DotBotSurfCourse.EVENT_NONE
		return DotBotSurfCourse.EVENT_GOAL if state.position.x >= 10.0 and state.position.x <= 13.0 else DotBotSurfCourse.EVENT_PIT


class PilotToyOpenHost:
	extends RefCounted

	func replay_start(_ep: DotBotDemoEpisode) -> PilotToyState:
		return PilotToyState.new()

	func replay_command(sim: Variant, action: PackedFloat32Array, _state: Variant) -> PilotToyCommand:
		return sim.command(action[0], Vector2(action[1], action[2]), action[3] > 0.5)

	func landing(_state: Variant, event: int, _ep: DotBotDemoEpisode) -> int:
		if event == DotBotSurfCourse.EVENT_GOAL:
			return DotBotRideHarvest.LANDED
		return DotBotRideHarvest.FAILED if event != 0 else DotBotRideHarvest.GOING

	func perturb(state: PilotToyState, rng: DotRandomStream, _metres: float, speed: float) -> PilotToyState:
		var c := state.duplicate_state()
		c.velocity.x += rng.next_range_f(-speed, speed)
		return c


class PilotToyHost:
	extends PilotToyOpenHost
	var asked := 0

	func pilot_setup(pilot: DotBotSurfPilot, _ep: DotBotDemoEpisode) -> void:
		asked += 1
		pilot.reference_yaw = -90.0
		pilot.score = func(s: PilotToyState) -> float: return -absf(s.position.x - 11.5)


func _pilot_schema() -> DotBotDemoSchema:
	var s := DotBotDemoSchema.make("ride", 1)
	s.add_observation("position", 3).add_observation("velocity", 3)
	s.add_action("yaw", 1).add_action("move", 2).add_action("jump", 1, 1.0, true)
	return s


## A player who thrusts forward for [param thrust_ticks] ticks, recorded at 16 Hz from the toy simulator.
func _pilot_episode(thrust_ticks: int, key: String = "1>2") -> DotBotDemoEpisode:
	var sim := PilotToySim.new()
	var s := PilotToyState.new()
	var e := _demo_episode("surf_toy", "v1", "ride", key)
	e.start = {}
	e.rate = 16.0
	e.frame_size = 10
	e.ticks = PackedFloat32Array()
	var t := 0
	while true:
		var on := t < thrust_ticks
		if t % 4 == 0:
			e.ticks.append_array(PackedFloat32Array([s.position.x, s.position.y, s.position.z, s.velocity.x, s.velocity.y, s.velocity.z,
				-90.0, 0.0, 1.0 if on else 0.0, 0.0]))
		if sim.step(s, sim.command(-90.0, Vector2(0.0, 1.0 if on else 0.0), false)) != 0:
			break
		t += 1
	return e


func _test_ride_quantise() -> void:
	_section("ride quantiser: commands become the nearest pilot action for the velocity")
	var v := Vector3(8.0, 0.0, 0.0)
	_check(DotBotRideQuantiser.action_for(-90.0, Vector2(0.0, 1.0), false, v, -90.0) == 4, "forward along the velocity is the 0 degree action")
	_check(DotBotRideQuantiser.action_for(-90.0, Vector2(-1.0, 0.0), false, v, -90.0) == 7, "the left key is the +90 action")
	_check(DotBotRideQuantiser.action_for(-90.0, Vector2(1.0, 0.0), false, v, -90.0) == 1, "the right key is the -90 action")
	_check(DotBotRideQuantiser.action_for(-90.0, Vector2(0.0, 0.0), false, v, -90.0) == 0, "no key is coasting")
	_check(DotBotRideQuantiser.action_for(-90.0, Vector2(0.0, 1.0), true, v, -90.0) == DotBotRideQuantiser.JUMP_ACTION, "a held jump is the jump action")
	_check(DotBotRideQuantiser.action_for(0.0, Vector2(0.0, 1.0), false, v, -90.0) == 7, "a view turned 90 degrees makes the same stick another wish: +90 from the heading")
	_check(DotBotRideQuantiser.action_for(-90.0, Vector2(0.0, 1.0), false, Vector3.ZERO, -90.0) == 4, "too slow to have a heading, the reference yaw is used")
	_check(DotBotRideQuantiser.action_for(-60.0, Vector2(0.0, 1.0), false, v, -90.0) == 5, "a wish 30 degrees off the heading is the 30 degree action")
	var ep := _pilot_episode(8)
	var rows := DotBotRideQuantiser.entries(ep, _pilot_schema(), -90.0)
	var actions := PackedInt32Array()
	for i in rows.size() / DotBotSurfPilot.STRIDE:
		actions.append(int(rows[i * DotBotSurfPilot.STRIDE + 6]))
	_check(rows.size() == ep.sample_count() * DotBotSurfPilot.STRIDE and actions.slice(0, 4) == PackedInt32Array([4, 4, 0, 0]), "a ride becomes one cache row a sample, thrust then coast", str(actions))
	_check(is_equal_approx(rows[0], 0.0) and is_equal_approx(rows[3], 8.0), "rows carry the recorded position and velocity")
	var bad := DotBotDemoSchema.make("ride", 1).add_observation("position", 3).add_action("yaw", 1)
	_check(not DotBotRideQuantiser.layout(bad).ok and DotBotRideQuantiser.entries(ep, bad, 0.0).is_empty() and DotBotRideQuantiser.layout(_pilot_schema()).ok, "a schema without the fields is refused, not guessed")
	_done()


func _pilot_harvest(host: Variant, cfg: DotBotRideConfig = null) -> DotBotRideHarvest:
	return DotBotRideHarvest.new(cfg if cfg != null else DotBotRideConfig.new(), _pilot_schema(), PilotToySim.new(), host)


func _test_harvest_piloted() -> void:
	_section("ride harvest: the pilot replays the quantised ride, tracking and vetoing")
	var host := PilotToyHost.new()
	var cfg := DotBotRideConfig.new()
	cfg.perturb_speed = 0.5
	var h := _pilot_harvest(host, cfg)
	var good := _pilot_episode(8)
	var coast := _pilot_episode(0)
	var over := _pilot_episode(32)
	_check(h.is_piloted() and not _pilot_harvest(PilotToyOpenHost.new()).is_piloted(), "a host with pilot_setup is replayed through the pilot, one without open loop")
	var _gate := h.ready()
	var v := h.verify([good, coast, over])
	_check(v[0]["ok"] and not v[1]["ok"] and not v[2]["ok"], "the ride that lands is kept; coasting and overshooting are rejected")
	_check(h.piloted_replays == h.replays and h.replays > 0 and host.asked == 3, "every replay was piloted, the pilot set up once a ride", "%d replays, %d setups" % [h.replays, host.asked])
	_check(float(v[0]["score"]) > 0.0 and int(v[0]["starts"]) == cfg.starts, "the kept ride is scored from the perturbed starts", "%.2f" % float(v[0]["score"]))
	var again := _pilot_harvest(PilotToyHost.new(), cfg).verify([_pilot_episode(8)])
	_check(is_equal_approx(float(again[0]["score"]), float(v[0]["score"])), "the same seed gives the same score")
	# The same ride from a start the commands were not recorded for: the pilot follows the line, the commands do not.
	var wide := DotBotRideConfig.new()
	wide.perturb_speed = 2.2
	wide.starts = 24
	var piloted_score := float(_pilot_harvest(PilotToyHost.new(), wide).verify([_pilot_episode(8)])[0]["score"])
	var open := DotBotRideConfig.new()
	open.perturb_speed = 2.2
	open.starts = 24
	var open_score := float(_pilot_harvest(PilotToyOpenHost.new(), open).verify([_pilot_episode(8)])[0]["score"])
	print("       from perturbed starts: piloted %.2f, open loop %.2f" % [piloted_score, open_score])
	_check(piloted_score > open_score, "from perturbed starts the pilot lands more often than the raw commands", "%.2f against %.2f" % [piloted_score, open_score])
	var off := DotBotRideConfig.new()
	off.piloted = false
	_check(not _pilot_harvest(PilotToyHost.new(), off).is_piloted(), "piloted = false replays open loop even when the host could")
	var fell := _pilot_harvest(PilotToyHost.new())
	fell.sim = PilotToySim.new()
	var empty := _pilot_episode(8)
	empty.ticks = PackedFloat32Array()
	_check(fell.verify([empty])[0]["ok"] == false, "a ride with no samples is rejected")
	_done()


func _test_ride_book_cache() -> void:
	_section("ride book: a verified recording rides as the pilot cache it was verified as")
	var store := DotBotDemoStoreMemory.new()
	var ep := _pilot_episode(8)
	ep.verified = true
	ep.score = 0.9
	var _a := await store.append([ep])
	var book := _book()
	var n: DotResult = await book.load_edge(store, "ride", "1>2", _pilot_schema(), 64.0, -90.0)
	var entry: Dictionary = book.ranked("1>2")[0]
	var data: Dictionary = entry["data"]
	_check(n.ok and n.value == 1 and data.has("cache") and is_equal_approx(float(data["reference_yaw"]), -90.0), "with a reference yaw the recording carries its pilot cache")
	var plain: DotResult = await _book().load_edge(store, "ride", "1>2", _pilot_schema(), 64.0)
	_check(plain.ok, "and without one it is the raw actions as before")
	var course := DotBotSurfCourse.new()
	course.goals.append(AABB(Vector3(10.0, -1.0, -5.0), Vector3(3.0, 2.0, 10.0)))
	course.floor_y = -5.0
	var _s := course.settle()
	var sim := PilotToySim.new()
	var ride := DotBotSurfRide.new().begin_picked(entry, DotBotSurfPilot.new(), course, sim, 0)
	_check(ride.recorded.is_empty() and not ride.pilot.tracking and ride.pilot.size() == (ep.sample_count() - 1) * 4 + 1, "begin_picked rides it on a pilot of its own, with the default tracking (off), a row a tick")
	var state := PilotToyState.new()
	var intent := DotBotIntent.new()
	var status := DotBotSurfRide.RIDING
	for t in 400:
		status = ride.steer(state, intent, t)
		if status != DotBotSurfRide.RIDING:
			break
		if sim.step(state, sim.command(intent.yaw, intent.move, intent.jump)) != 0:
			status = DotBotSurfRide.LANDED if state.position.x >= 10.0 and state.position.x <= 13.0 else DotBotSurfRide.FELL
			break
	_check(status == DotBotSurfRide.LANDED, "a bot riding the picked recording lands on the far platform", str(status))
	_done()


class CountingHost:
	extends PilotToyHost
	var landings := 0

	func landing(state: Variant, event: int, ep: DotBotDemoEpisode) -> int:
		landings += 1
		return super.landing(state, event, ep)


## Rides the book's pick of [param ep] on the toy; the ride's status.
func _ride_picked(ep: DotBotDemoEpisode, tracking: bool) -> Array:
	var store := DotBotDemoStoreMemory.new()
	ep.verified = true
	ep.score = 0.9
	var _a := await store.append([ep])
	var cfg := DotBotRideConfig.new()
	cfg.pilot_tracking = tracking
	var book := _book(cfg)
	var _n: DotResult = await book.load_edge(store, "ride", "1>2", _pilot_schema(), 64.0, -90.0)
	var course := DotBotSurfCourse.new()
	course.goals.append(AABB(Vector3(10.0, -1.0, -5.0), Vector3(3.0, 2.0, 10.0)))
	course.floor_y = -5.0
	var _s := course.settle()
	var sim := PilotToySim.new()
	var ride := DotBotSurfRide.new().begin_picked(book.ranked("1>2")[0], DotBotSurfPilot.new(), course, sim, 0)
	var state := PilotToyState.new()
	var intent := DotBotIntent.new()
	var status := DotBotSurfRide.RIDING
	for t in 400:
		status = ride.steer(state, intent, t)
		if status != DotBotSurfRide.RIDING:
			break
		if sim.step(state, sim.command(intent.yaw, intent.move, intent.jump)) != 0:
			status = DotBotSurfRide.LANDED if state.position.x >= 10.0 and state.position.x <= 13.0 else DotBotSurfRide.FELL
			break
	return [status, ride.pilot.tracking]


func _test_ride_tracking_agrees() -> void:
	_section("ride harvest: a ride is verified and ridden with the same tracking")
	_check(not DotBotRideConfig.new().pilot_tracking, "the default is no tracking")
	for tracking in [false, true]:
		var cfg := DotBotRideConfig.new()
		cfg.pilot_tracking = tracking
		var verdict: Dictionary = _pilot_harvest(PilotToyHost.new(), cfg).verify([_pilot_episode(8)])[0]
		var ridden: Array = await _ride_picked(_pilot_episode(8), tracking)
		_check(ridden[1] == tracking, "tracking = %s: the bot rides with it" % tracking)
		_check(verdict["ok"] == (ridden[0] == DotBotSurfRide.LANDED), "tracking = %s: verified %s, ridden %s" % [tracking, verdict["ok"], ridden[0]])
		_check(verdict["ok"], "tracking = %s: the ride lands" % tracking)
	_done()


func _job_ticks(host: CountingHost, cfg: DotBotRideConfig, eps: Array) -> Dictionary:
	var h := _pilot_harvest(host, cfg)
	var job: RefCounted = h.make_job(eps)
	var ticks := 0
	var worst := 0
	while true:
		var before := host.landings
		var more: bool = job.step()
		worst = maxi(worst, host.landings - before)
		ticks += 1
		if not more or ticks > 100000:
			break
	return {"verdicts": job.verdicts, "ticks": ticks, "worst": worst, "steps": host.landings}


func _test_harvest_sliced() -> void:
	_section("ride harvest: a piloted replay is sliced across job ticks, the same verdicts")
	var eps := [_pilot_episode(8), _pilot_episode(0), _pilot_episode(32), _pilot_episode(8, "1>2")]
	for i in eps.size():
		eps[i].id = i + 1
	var whole := DotBotRideConfig.new()
	whole.budget_msec = 100000.0
	var sliced := DotBotRideConfig.new()
	sliced.slice_steps = 5
	sliced.budget_msec = 100000.0
	var a := _job_ticks(CountingHost.new(), whole, eps)
	var b := _job_ticks(CountingHost.new(), sliced, eps)
	var same: bool = a["verdicts"].size() == b["verdicts"].size()
	for i in mini(a["verdicts"].size(), b["verdicts"].size()):
		var x: Dictionary = a["verdicts"][i]
		var y: Dictionary = b["verdicts"][i]
		same = same and x["ok"] == y["ok"] and is_equal_approx(float(x["score"]), float(y["score"])) and x["landed"] == y["landed"] and x["starts"] == y["starts"]
	_check(a["verdicts"].size() == eps.size() and same, "sliced verdicts equal the unsliced ones", "%s against %s" % [a["verdicts"].size(), b["verdicts"].size()])
	_check(a["steps"] == b["steps"], "and take the same simulator steps", "%d against %d" % [a["steps"], b["steps"]])
	_check(b["worst"] <= 5 and b["ticks"] > a["ticks"], "no job tick runs more than slice_steps steps", "max %d steps a tick over %d ticks, against %d in %d" % [b["worst"], b["ticks"], a["worst"], a["ticks"]])
	print("       max steps in one tick: unsliced %d, sliced %d" % [a["worst"], b["worst"]])
	var h := _pilot_harvest(PilotToyHost.new())
	var run := h.begin_replay(eps[0], PilotToyState.new())
	var n := 0
	while run.advance(0, 3) == DotBotRideHarvest.RUNNING:
		n += 1
	_check(run.verdict == _pilot_harvest(PilotToyHost.new()).replay(eps[0], PilotToyState.new()) and n > 0, "a Run advanced three steps at a time ends on the verdict replay gives")
	_done()
