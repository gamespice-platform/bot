extends "res://examples/selftest/style_tests.gd"

## gs-bot's suite (`godot --headless --path . res://examples/bot_selftest.tscn`): presets, cvars, names, roster, and a bot's senses, aim and fights measured rather than read.
## The numbers a player feels are measured per preset (time to first shot, aim error, turn speed, K/D against one fixed opponent); the bands are what the presets promise.

const CHECKS := 730

## Of CHECKS, the ones that need GameSpice SQL and the SQLite extension linked into this project.
const SQL_CHECKS := 0

## Of CHECKS, the ones that need gs_sim's native sight scan (contact rows); a project without the library runs the rest.
const NATIVE_CHECKS := 3

var _native_ran := false

## Sections entered against sections that ran to their last line. A runtime error inside a
## section aborts that function and nothing says so.
const SECTIONS := 68


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("gs-bot self-test")
	print("")

	_test_profile()
	_test_settings()
	_test_cvars()
	_test_console()
	_test_names()
	_test_personas()
	_test_roster()
	_test_intent()
	_test_think_tier()
	_test_think_tier_near_person()
	_test_aim()
	_test_fire_mode()
	_test_senses()
	_test_contact_rows()
	_test_contact_table()
	_test_target_first()
	_test_turning()
	_test_reaction_and_aim()
	_test_duels()
	_test_hiding()
	_test_search()
	_test_unstick()
	_test_stranded()
	_test_route()
	await _test_nav()
	await _test_nav_cache()
	await _test_nav_tiles()
	await _test_nav_parse_slices()
	await _test_nav_cell()
	_test_surf()
	await _test_ride_edges()
	await _test_drop_behind_wall()
	await _test_links()
	await _test_stitches()
	await _test_join_sliced()
	await _test_join_prep()
	await _test_unlock_export()
	await _test_ladders()
	await _test_climb_down()
	await _test_door_then_ladder()
	await _test_kill_avoidance()
	_test_harvest_verify()
	await _test_harvest_store()
	_test_ride_book()
	_test_ride_quantise()
	_test_harvest_piloted()
	await _test_ride_book_cache()
	await _test_ride_tracking_agrees()
	_test_harvest_sliced()
	await _test_ride_book_store()
	_test_ride_pick()
	_test_aim_solver()
	_test_humanisation()
	_test_tricks()
	_test_objective()
	_test_utility_grenades()
	_test_sight_lod()
	_test_phase_timers_threaded()
	_test_pickup()
	_test_arms()
	await _test_heatmap()
	await _test_aim_stats()
	await _test_bc_export()
	_test_mlp()
	_test_eval_gate()
	_test_policy()
	_test_style_table()
	_test_style_play()

	_report()


func _report() -> void:
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	print("%d of %d sections ran to their last line" % [_completed, _entered])

	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	var expected := CHECKS - (0 if _sql_ran else SQL_CHECKS) - (0 if _native_ran else NATIVE_CHECKS)
	if _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, expected])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## GSBotAim on its own, the way a game with its own decisions uses it.
func _test_aim() -> void:
	_section("GSBotAim on its own")

	var s := GSBotSettings.new()
	var aim := GSBotAim.new(5, s)
	var eye := Vector3(0, 1.6, 0)
	var chest := Vector3(0, 1.25, -12)
	_check(aim.engage(9, eye, chest, 0.0), "a first sight starts an engagement")
	_check(not aim.engage(9, eye, chest, 0.05), "seeing it again next tick continues it")
	_check(not aim.engage(9, eye, chest, 0.05 + 0.2), "and at 5 ticks a second too (no new reaction every tick)")
	var react := aim.react_at
	var t := 0.25
	var fired_early := false
	var first := NAN
	while t < 3.0:
		var _seen := aim.engage(9, eye, chest, t)
		var _v := aim.track(eye, chest, Vector3.ZERO, t, 1.0 / 64.0)
		var down := aim.trigger(t, 12.0)
		if down and t < react:
			fired_early = true
		if down and is_nan(first):
			first = t
		t += 1.0 / 64.0
	_check(not fired_early and not is_nan(first), "never fires before its reaction, then does", "%.3f vs %.3f" % [first, react])

	aim.release()
	_check(not aim.engage(9, eye, chest, 3.5) and aim.react_at - 3.5 <= s.profile.reaction * 0.6,
		"back in sight within 1.5 s: the same engagement, half the reaction", "%.3f" % (aim.react_at - 3.5))
	_check(aim.engage(9, eye, chest, 9.0), "back after its memory: a new engagement")

	# Bursts beyond burst_range: the trigger comes and goes.
	var far := Vector3(0, 1.25, -30)
	var _e := aim.engage(10, eye, far, 20.0)
	var changes := 0
	var was := false
	t = 20.0
	while t < 24.0:
		var _v := aim.track(eye, far, Vector3.ZERO, t, 1.0 / 64.0)
		var down := aim.trigger(t, 30.0)
		if down != was:
			changes += 1
		was = down
		t += 1.0 / 64.0
	_check(changes >= 6, "beyond burst_range it fires in bursts", "%d changes" % changes)

	var settled := aim.error_deg(24.0)
	aim.hurt()
	_check(aim.error_deg(24.0) > settled + s.profile.flinch * 0.9, "a hit adds bot_flinch to the aim error")
	_done()


## A bot at the origin facing -Z, and one enemy.
func _test_contact_rows() -> void:
	_section("contact rows: the table a game hands the native sight scan")

	var a := GSBotContact.make(4, Vector3(1, 0, 2))
	var b := GSBotContact.make(7, Vector3(-3, 1, 0))
	b.team = 2
	b.alive = false
	var all: Array = [a, "not a body", b]
	var rows := GSBotWorld.rows_of(all)
	_check(rows.size() == 7 and rows[0] == [a, b] and rows[1] == PackedInt64Array([4, 7]) and rows[3][1] == 2 and rows[4] == PackedByteArray([1, 0]),
		"rows_of keeps only bodies, in order, with id, team and alive columns", str(rows))
	_check(rows[2][1] == b.aim_point() and rows[5][0] == a.eye() and rows[6][1] == b.position, "and aim point, eye and position columns")

	if not GSBotWorld.native_available():
		print("  (no native sight scan loaded: set_rows not exercised)")
		_done()
		return
	_native_ran = true
	var world := GSBotWorld.new()
	world.contacts_fn = func() -> Array: return all
	var handed: Array = rows.duplicate()
	handed[0] = [a, b]
	world.set_rows(5, handed[0], handed[1], handed[2], handed[3], handed[4], handed[5], handed[6])
	world.contacts_version = 5
	world.senses(all)
	_check(is_same(world.sensed(), handed[0]), "a table handed for this contacts_version is the one the scan loads")
	world.contacts_version = 6
	world.senses(all)
	_check(not is_same(world.sensed(), handed[0]) and world.sensed() == [a, b], "a table from an older version is not: the scan builds its own")
	GSBotWorld.rows_enabled = false
	world.set_rows(7, handed[0], handed[1], handed[2], handed[3], handed[4], handed[5], handed[6])
	world.contacts_version = 7
	world.senses(all)
	GSBotWorld.rows_enabled = true
	_check(not is_same(world.sensed(), handed[0]), "with rows_enabled off (cvar bot_native_think 0) the handed table is ignored")
	_done()


func _test_senses() -> void:
	_section("senses: no walls, a view cone, hearing")

	var s := GSBotSettings.new()
	s.set_difficulty("nightmare")

	var sc := _scene(Vector3(0, 0, -15), true)
	var brain := GSBotBrain.new(1, s)
	var intents := _run_bot(brain, sc[0], sc[2], 3.0)
	_check(intents.all(func(i: GSBotIntent) -> bool: return not i.fire and i.target_id == -1),
		"a nightmare bot never targets or fires at somebody behind a wall in front of it")

	sc = _scene(Vector3(0, 0, 15))
	brain = GSBotBrain.new(1, s)
	intents = _run_bot(brain, sc[0], sc[2], 0.5)
	_check((intents[0] as GSBotIntent).target_id == -1, "somebody directly behind, in the open, is not seen on the first tick")

	sc = _scene(Vector3(0, 0, 15))
	var world: GSBotWorld = sc[2]
	brain = GSBotBrain.new(1, s)
	var _first := brain.think(sc[0], world, 0.0)
	world.emit_sound(Vector3(0, 0, 15), 1.0, 2, 0.01)
	intents = _run_bot(brain, sc[0], world, 2.0, TICK)
	var turned := intents.any(func(i: GSBotIntent) -> bool: return i.target_id == 2)
	_check(turned, "a gunshot behind turns it round, and then it sees who fired")

	# Made on the same timestamp as the bot's last think: a time comparison missed this one, and
	# a bot with its back to the shooter died without turning (the duel below found it).
	sc = _scene(Vector3(0, 0, 15))
	world = sc[2]
	brain = GSBotBrain.new(1, s)
	_first = brain.think(sc[0], world, 0.5)
	world.emit_sound(Vector3(0, 0, 15), 1.0, 2, 0.5)
	_check(brain.think(sc[0], world, 0.5 + TICK).state == &"listen", "a sound made on the tick the bot last thought is still heard")

	sc = _scene(Vector3(0, 0, 100))
	world = sc[2]
	brain = GSBotBrain.new(1, s)
	_first = brain.think(sc[0], world, 0.0)
	world.emit_sound(Vector3(0, 0, 100), 1.0, 2, 0.01)
	intents = _run_bot(brain, sc[0], world, 0.5, TICK)
	_check(intents.all(func(i: GSBotIntent) -> bool: return i.state == &"roam"), "a gunshot past its hearing is not heard")

	sc = _scene(Vector3(0, 0, -15))
	brain = GSBotBrain.new(1, s)
	var a := _run_bot(brain, sc[0], sc[2], 1.0)
	sc = _scene(Vector3(0, 0, -15))
	var b := _run_bot(GSBotBrain.new(1, s), sc[0], sc[2], 1.0)
	var same := true
	for k in range(a.size()):
		same = same and (a[k] as GSBotIntent).yaw == (b[k] as GSBotIntent).yaw and (a[k] as GSBotIntent).fire == (b[k] as GSBotIntent).fire
	_check(same, "the same id and inputs play the same bot")

	# Killed in plain view: the bot moves on rather than pre-aiming the body.
	sc = _scene(Vector3(0, 0, -10))
	brain = GSBotBrain.new(1, s)
	intents = _run_bot(brain, sc[0], sc[2], 1.0)
	(sc[1] as GSBotContact).alive = false
	intents = _run_bot(brain, sc[0], sc[2], 0.2, 1.0)
	_check((intents.back() as GSBotIntent).state == &"roam", "a target killed in view is not searched for", str((intents.back() as GSBotIntent).state))

	var hurt := _scene(Vector3(0, 0, 40), true)
	brain = GSBotBrain.new(1, s)
	_first = brain.think(hurt[0], hurt[2], 0.0)
	brain.hurt(Vector3(0, 0, 40), 0.0)
	intents = _run_bot(brain, hurt[0], hurt[2], 1.0, TICK)
	_check((intents.back() as GSBotIntent).state == &"listen" and absf(wrapf((intents.back() as GSBotIntent).yaw - 180.0, -180.0, 180.0)) < 10.0,
		"being shot from behind turns it toward the shooter without seeing them")
	_done()


## [GSBotContactTable]: columns equal to the bodies, views written lazily, handed only for its version, and the crowd thinks the same with it.
func _test_contact_table() -> void:
	_section("contact table: packed columns stand in for the contact objects")
	var bodies: Array = []
	for i in range(4):
		var c := GSBotContact.make(i + 1, Vector3(i, 0.0, -i), 1 + i % 2)
		c.velocity = Vector3(0.5 * i, 0.0, 1.0)
		c.health = 100.0 - 10.0 * i
		c.view_yaw = 30.0 * i
		c.alive = i != 2
		c.grounded = i != 1
		bodies.append(c)
	var t := GSBotContactTable.from_contacts(7, bodies)
	var same := t.size() == 4
	for i in range(4):
		var c: GSBotContact = bodies[i]
		same = same and t.ids[i] == c.id and t.positions[i] == c.position and t.velocities[i] == c.velocity \
			and t.teams[i] == c.team and bool(t.alive[i]) == c.alive and t.flags[i] == GSBotContactTable.flags_of(c) \
			and t.row_of(c.id) == i and t.contact_by_id(c.id) == c
	_check(same, "from_contacts packs ids, positions, velocities, teams, alive and flags row for row")
	var views: Array = []
	for i in range(4):
		views.append(GSBotContact.new())
	var u := GSBotContactTable.new()
	u.take(7, views, t.ids, t.positions, t.velocities, t.floats, t.teams, t.flags, t.points, t.eyes, t.alive)
	_check(u.digest() == t.digest(), "a taken table digests the same as the one packed from objects")
	var v: GSBotContact = u.contact(1)
	_check(v.id == 2 and v.position == Vector3(1, 0, -1) and not v.grounded and is_equal_approx(v.health, 90.0)
		and is_equal_approx(v.view_yaw, 30.0) and (views[3] as GSBotContact).id != 4,
		"contact(i) writes that row into its view and leaves the others unwritten")
	_check(u.contacts().size() == 4 and (views[3] as GSBotContact).id == 4 and not (views[2] as GSBotContact).alive,
		"contacts() writes every view")
	var w := GSBotWorld.new()
	w.contacts_version = 7
	w.set_table(u)
	_check(w.table() == u and w.contact_of([], 3) == views[2], "the world hands the table for its version and finds contacts by id in it")
	w.contacts_version = 8
	_check(w.table() == null, "and not for a newer tick")
	w.contacts_version = 7
	GSBotWorld.table_enabled = false
	_check(w.table() == null, "nor with table_enabled off")
	GSBotWorld.table_enabled = true
	var objects := _crowd_intents(true, false)
	var packed := _crowd_intents(true, true)
	var differs := -1
	for i in range(mini(objects.size(), packed.size())):
		if objects[i] != packed[i]:
			differs = i
			break
	_check(objects.size() == packed.size() and differs < 0, "six bots among eight bodies press the same through the table as through the objects",
		"first difference at think %d of %d" % [differs, objects.size()])
	_done()


## The same crowd thought through with and without [member GSBotBrain.target_first].
func _test_target_first() -> void:
	_section("target first: testing the held target alone changes no intent")
	var fast := _crowd_intents(true)
	var full := _crowd_intents(false)
	GSBotBrain.target_first = true
	var differs := -1
	for i in range(mini(fast.size(), full.size())):
		if fast[i] != full[i]:
			differs = i
			break
	_check(fast.size() == full.size() and differs < 0, "six bots among eight bodies press the same with and without it, every think",
		"first difference at think %d of %d" % [differs, fast.size()])
	var fights := 0
	var targets := {}
	for row: Array in fast:
		if row[13] == &"fight":
			fights += 1
		targets[row[12]] = true
	_check(fights > fast.size() / 4, "and they fought for much of it", "%d of %d thinks" % [fights, fast.size()])
	_check(targets.size() >= 4, "against several targets, lost and found again", "%d targets" % targets.size())
	_done()


## Every intent of six bots over 20 s among eight bodies that circle a wall, die, come back and fire; smoke for a while.
func _crowd_intents(target_first: bool, table := false) -> Array:
	GSBotBrain.target_first = target_first
	const PRESETS: Array[String] = ["easy", "medium", "hard", "nightmare", "hard", "medium"]
	var bodies: Array = []
	for i in range(8):
		bodies.append(GSBotContact.make(i + 1, Vector3.ZERO, 0 if i >= 6 else 1 + i % 2))
	var world := GSBotWorld.new()
	world.contacts_fn = func() -> Array: return bodies
	# A wall on x = 0 for |z| < 4: sight across it there is refused.
	world.line_of_sight_fn = func(a: Vector3, b: Vector3) -> bool:
		if (a.x < 0.0) == (b.x < 0.0):
			return true
		return absf(lerpf(a.z, b.z, a.x / (a.x - b.x))) >= 4.0
	var brains: Array[GSBotBrain] = []
	for i in range(PRESETS.size()):
		var s := GSBotSettings.new()
		s.set_difficulty(PRESETS[i])
		brains.append(GSBotBrain.new(i + 1, s))
	var out: Array = []
	var smoked := false
	for tick in range(int(20.0 / TICK)):
		var t := tick * TICK
		for i in range(bodies.size()):
			var c: GSBotContact = bodies[i]
			var w := 0.25 + 0.07 * i
			var r := 5.0 + 1.5 * i
			var phase := t * w + i * 0.9
			c.position = Vector3(cos(phase) * r, 0.0, sin(phase) * r)
			c.velocity = Vector3(-sin(phase) * r * w, 0.0, cos(phase) * r * w)
			c.alive = fmod(t + i * 1.7, 9.0) > 1.2
		if table:
			world.contacts_version = tick
			world.set_table(GSBotContactTable.from_contacts(tick, bodies))
		if not smoked and t >= 6.0:
			smoked = true
			var _id := world.add_sight_blocker(Vector3(4.0, 1.0, 0.0), 3.0, 10.0)
		for i in range(brains.size()):
			var me: GSBotContact = bodies[i]
			# Bot 6 thinks every third tick, as a staggered one does.
			if i == 5 and tick % 3 != 0:
				continue
			var intent := brains[i].think(me, world, t)
			me.view_yaw = intent.yaw
			me.view_pitch = intent.pitch
			if intent.fire:
				world.emit_sound(me.position, 1.0, me.id, t)
			out.append([me.id, intent.yaw, intent.pitch, intent.move, intent.fire, intent.crouch, intent.jump, intent.walk,
				intent.air_jump, intent.throw, intent.use, intent.ride, intent.target_id, intent.state])
	return out


func _test_turning() -> void:
	_section("the view turns no faster than bot_turn_rate")

	for preset in GSBotProfile.PRESETS:
		var s := GSBotSettings.new()
		s.set_difficulty(preset)
		var sc := _scene(Vector3(1.5, 0, 1.0))
		var brain := GSBotBrain.new(1, s)
		var intents := _run_bot(brain, sc[0], sc[2], 1.5)
		var fastest := 0.0
		for k in range(1, intents.size()):
			var step := absf(wrapf((intents[k] as GSBotIntent).yaw - (intents[k - 1] as GSBotIntent).yaw, -180.0, 180.0))
			fastest = maxf(fastest, step / TICK)
		print("       %-9s fastest turn %4.0f deg/s (limit %4.0f)" % [preset, fastest, s.profile.turn_rate])
		_check(fastest <= s.profile.turn_rate * 1.01, "%s turns at most %d deg/s" % [preset, int(s.profile.turn_rate)], str(fastest))
	_done()


## The first-shot numbers, per preset, over many engagements: a stationary target appears
## 15 m away somewhere inside the view cone.
func _test_reaction_and_aim() -> void:
	_section("reaction time and aim error, measured")

	var previous_reaction := INF
	for preset in GSBotProfile.PRESETS:
		var s := GSBotSettings.new()
		s.set_difficulty(preset)
		var p := s.profile
		var reactions: Array[float] = []
		var first_errors: Array[float] = []
		var settled: Array[float] = []
		for trial in range(40):
			var off := deg_to_rad(-30.0 + 60.0 * float(trial) / 39.0)
			var at := Vector3(-sin(off), 0.0, -cos(off)) * 15.0
			var sc := _scene(at)
			var brain := GSBotBrain.new(1000 + trial, s)
			var intents := _run_bot(brain, sc[0], sc[2], 2.5)
			var e := brain.engagement()
			if not is_nan(float(e["first_shot_at"])):
				reactions.append(float(e["first_shot_at"]) - float(e["seen_at"]))
				first_errors.append(float(e["first_shot_error_deg"]))
			var me: GSBotContact = sc[0]
			var last := intents.back() as GSBotIntent
			settled.append(rad_to_deg(last.forward().angle_to((sc[1] as GSBotContact).aim_point() - me.eye())))
		var r := _mean(reactions)
		var fe := _mean(first_errors)
		var se := _mean(settled)
		print("       %-9s reaction %.3f s (setting %.2f), first-shot error %.2f deg, after 2.5 s %.2f deg (floor %.2f), %d/40 fired" % [
			preset, r, p.reaction, fe, se, p.aim_floor, reactions.size()])
		_check(reactions.size() == 40, "%s fires in every engagement" % preset, str(reactions.size()))
		_check(r >= p.reaction * 0.85 and r <= p.reaction + p.notice * 0.4 + 0.25, "%s reacts in about its bot_reaction" % preset, "%.3f" % r)
		_check(r < previous_reaction, "%s reacts faster than the preset before it" % preset)
		_check(fe <= p.aim_error * 1.25 + p.fire_cone, "%s opens no worse than its aim error allows" % preset, "%.2f" % fe)
		_check(se <= p.aim_floor * 1.1 + 0.3, "%s settles to its aim floor" % preset, "%.2f" % se)
		previous_reaction = r
	_done()


## The --brain-us profile with brains on worker threads: each brain times into its own clock (no shared write),
## and the main thread's merge_phases after the join is what lands the time in phase_us.
func _test_phase_timers_threaded() -> void:
	_section("brain phase timers on worker threads")
	const BRAINS := 4
	const TICKS := 30
	var s := GSBotSettings.new()
	s.set_difficulty("nightmare")
	var scenes: Array = []
	var brains: Array = []
	for i in BRAINS:
		scenes.append(_scene(Vector3(0, 0, -15)))
		brains.append(GSBotBrain.new(1, s))
	GSBotBrain.phase_us.fill(0)
	GSBotBrain.phase_calls.fill(0)
	GSBotBrain.phase_timers = true
	var think_all := func(i: int) -> void:
		var sc: Array = scenes[i]
		_run_bot(brains[i], sc[0], sc[2], TICKS * TICK)
	var task := WorkerThreadPool.add_group_task(think_all, BRAINS, BRAINS, true)
	WorkerThreadPool.wait_for_group_task_completion(task)
	var before := 0
	for v in GSBotBrain.phase_calls:
		before += v
	_check(before == 0, "thinks on worker threads write no shared profile before the merge", "%d calls" % before)
	GSBotBrain.merge_phases(brains)
	var bb_us := 0
	for i in GSBotClock.PHASE_COUNT:
		bb_us += GSBotBrain.phase_us[i]
	_check(bb_us > 0, "after merge_phases the threaded thinks' phases are non-zero", "%d us" % bb_us)
	_check(GSBotBrain.phase_calls[0] >= BRAINS * TICKS and GSBotBrain.phase_calls[6] == GSBotBrain.phase_calls[0],
		"every threaded think lapped every phase once", str(GSBotBrain.phase_calls))
	var merged := GSBotBrain.phase_us.duplicate()
	GSBotBrain.merge_phases(brains)
	_check(GSBotBrain.phase_us == merged, "a second merge adds nothing: each clock folds once")
	GSBotBrain.phase_timers = false
	GSBotBrain.phase_calls.fill(0)
	var sc0: Array = scenes[0]
	_run_bot(brains[0], sc0[0], sc0[2], 0.25)
	var after := 0
	for v in GSBotBrain.phase_calls:
		after += v
	_check(after == 0 and not GSBotClock.on, "with phase_timers off nothing is timed", "%d calls" % after)
	GSBotBrain.phase_us.fill(0)
	_done()
