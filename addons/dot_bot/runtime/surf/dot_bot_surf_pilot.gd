class_name DotBotSurfPilot
extends "dot_bot_surf_pilot_cache.gd"

## Rides a surf ramp from what [DotBotSurfPlanner] found: it does what the nearest remembered
## state did, and looks a second and a half ahead before trusting that.
##
## The cache is every tick of every planned ride ([method nearest] finds the entry closest in
## position plus velocity times [constant VELOCITY_SECONDS]); [member tracking] repairs a sparse
## cache; the veto runs the policy [member horizon] ticks ahead and swaps in a surviving action;
## [member rolling] keeps that future instead of recomputing it. Numbers and reasoning:
## docs/surfing.md, "The pilot".
##
## A simulator is duck typed (dot-player-controller's [code]DotFpsSimulator[/code]):
## `step(state, command) -> int`, `command(yaw, move, jump)`, `delta`; states have
## `position`, `velocity`, `duplicate_state()`. So this addon names no other.
## The cache, its lookup and the actions are in dot_bot_surf_pilot_cache.gd, split out for file size.

# No log channel: the game that rides says what happened.

## The simulator tracking and the veto run on. Without one the pilot only copies actions.
var sim: Variant = null
## `func(state) -> float`, higher is further along. The course's [code]score[/code].
var score: Callable = Callable()

## Ticks each tracked action is held, and whether to track at all.
var track_every: int = 8
var tracking: bool = false
## How often a fresh future is asked for, how far ahead it looks (ticks), and whether it is
## kept and extended instead (see the class notes). [member horizon] 0 turns the veto off.
var check_every: int = 24
var horizon: int = 192
var rolling: bool = true
## Most simulator steps one tick spends on a fresh forecast (0 = all of it in one tick). The rest
## resumes on the next ticks and the veto is judged once the forecast completes.
var forecast_budget: int = 24
## The same for a veto (up to eight futures, about 2,000 steps, ~300 ms in one tick).
## The veto starts the ticks it will be late ahead of the real state; 0 runs it all in one tick. 40 (it was 48) takes five riders on surf_ski_2 from about 24 to about 20 ms tick p95 with as many rides landed; 32 was cheaper again but landed fewer (its answer comes later).
## See docs/surfing.md.
var veto_budget: int = 40

## Statistics: futures run afresh, vetoes taken, how many of those found no way out, and how
## often a kept forecast stopped matching.
var checks: int = 0
var vetoes: int = 0
var hopeless: int = 0
var resyncs: int = 0
## Simulated ticks spent looking ahead (the forecast, or the plain check's future) and spent on
## vetoes (every action's future when the policy's falls): the run-time cost, split.
var lookahead_ticks: int = 0
var veto_ticks: int = 0

var _override: int = -1
var _override_left: int = 0
var _tracked: int = -1
var _tracked_left: int = 0
var _following: int = -1
var _tick: int = 0

# The kept forecast: positions and velocities after each future tick from _pred_head on, the
# state at its far end and how many override ticks that end still had to run.
var _pred_p: PackedVector3Array = PackedVector3Array()
var _pred_v: PackedVector3Array = PackedVector3Array()
var _pred_head: int = 0
var _end: Variant = null
var _end_override: int = -1
var _end_override_left: int = 0
var _end_event: int = 0
var _cooldown: int = 0
var _hopeless_streak: int = 0
var _forecast_tick: int = -1000
var _fc_left: int = 0
var _fc_pending: bool = false
# A veto in progress: the state it started from, the action being tried, that action's future so
# far and the best found.
var _vt_pending: bool = false
var _vt_state: Variant = null
var _vt_a: int = 0
var _vt_s: Variant = null
var _vt_t: int = 0
var _vt_best: int = -1
var _vt_best_score: float = -INF
var _vt_longest: int = -1
var _vt_longest_t: float = -1.0


## Uses [param other]'s cache, without copying it: many bots riding one ramp share one lookup.
## Neither may load into it afterwards (reload makes new arrays, so the other keeps the old).
func share_cache(other: DotBotSurfPilot) -> DotBotSurfPilot:
	entries = other.entries
	_ride_end = other._ride_end
	_grid = other._grid
	_coarse = other._coarse
	_near = other._near
	_rings = other._rings
	_shells = other._shells
	_sparse = other._sparse
	reference_yaw = other.reference_yaw
	return self
# Riding.

## Start over (a new ride): nothing held, no forecast.
func reset() -> void:
	_override = -1
	_override_left = 0
	_tracked = -1
	_tracked_left = 0
	_following = -1
	_tick = 0
	_cooldown = 0
	_hopeless_streak = 0
	_forecast_tick = -1000
	_vt_pending = false
	_vt_state = null
	_drop_forecast()


## The action the nearest remembered state took, or 0 (coast) with no entries.
func policy(state: Variant) -> int:
	var i := nearest(state)
	return 0 if i < 0 else int(entries[i * STRIDE + 6])


## This tick's action for a player in [param state]. Call once a tick, in order.
func action(state: Variant) -> int:
	if _vt_pending:
		_veto_run()
		if not _vt_pending and rolling:
			_forecast(state, _override, _override_left)
	elif sim != null and horizon > 0 and not tracking:
		if rolling:
			_keep_forecast(state)
		elif _override_left <= 0 and _tick % check_every == 0:
			_check(state)
	elif sim != null and horizon > 0 and _override_left <= 0 and _tick % check_every == 0:
		_check(state)
	_tick += 1
	if _cooldown > 0:
		_cooldown -= 1
	if _override_left > 0:
		_override_left -= 1
		return _override
	if tracking and sim != null:
		if _tracked_left <= 0:
			_tracked = _track(state)
			_tracked_left = track_every
		_tracked_left -= 1
		return _tracked
	return policy(state)


## This tick's command for a player in [param state], the view along the heading.
func command(state: Variant) -> Object:
	return command_for(sim, action(state), state, reference_yaw)


## Rides from [param start] (not changed) on [param ride_sim] for at most [param max_ticks].
## Returns `{"event": int, "ticks": int, "trail": Array}`, the trail a copy of the state every
## [param keep_every] ticks (the first is the start), which is where the planner's repair starts
## looking from.
func ride(start: Variant, ride_sim: Variant, max_ticks: int, keep_every: int = 16) -> Dictionary:
	reset()
	var s: Variant = start.duplicate_state()
	var trail: Array = []
	var event := 0
	var t := 0
	while t < max_ticks and event == 0:
		if t % keep_every == 0:
			trail.append(s.duplicate_state())
		event = ride_sim.step(s, command_for(ride_sim, action(s), s, reference_yaw))
		t += 1
	return {"event": event, "ticks": t, "trail": trail}


# The future.

## Runs the policy [param ticks] ahead from a copy of [param state], first holding
## [param first] for [member check_every] ticks when it is not -1. Returns
## `[survived: bool, score (survived) or ticks survived (fell)]`.
func future(state: Variant, first: int, ticks: int) -> Array:
	var s: Variant = state.duplicate_state()
	for t in range(ticks):
		var a := first if first >= 0 and t < check_every else policy(s)
		var event: int = sim.step(s, command_for(sim, a, s, reference_yaw))
		if first >= 0:
			veto_ticks += 1
		else:
			lookahead_ticks += 1
		if event == DotBotSurfCourse.EVENT_GOAL:
			return [true, INF]
		if event != DotBotSurfCourse.EVENT_NONE:
			return [false, float(t)]
	return [true, float(score.call(s)) if score.is_valid() else 0.0]


## The veto: when the policy's own future falls, the action whose future survives best.
func _check(state: Variant) -> void:
	checks += 1
	var plain := future(state, -1, horizon)
	if bool(plain[0]):
		return
	_veto(state)


func _veto(state: Variant) -> void:
	vetoes += 1
	_vt_pending = true
	_vt_state = state.duplicate_state()
	if veto_budget > 0:
		_advance_for_latency(_vt_state)
	_vt_a = 0
	_vt_s = null
	_vt_best = -1
	_vt_best_score = -INF
	_vt_longest = -1
	_vt_longest_t = -1.0
	_veto_run()


## A spread veto answers about VETO_STEPS / [member veto_budget] ticks late, so it starts that many
## ticks ahead (the held action, then the policy) and its answer fits the state it lands on.
func _advance_for_latency(s: Variant) -> void:
	var late := mini(ceili(float(VETO_STEPS) / float(veto_budget)), check_every)
	for i in late:
		var a := _override if i < _override_left else policy(s)
		if sim.step(s, command_for(sim, a, s, reference_yaw)) != DotBotSurfCourse.EVENT_NONE:
			return


## A veto, then the forecast again from its action; with the veto unfinished the forecast waits for it.
func _veto_then_forecast(state: Variant) -> void:
	_veto(state)
	if not _vt_pending:
		_forecast(state, _override, _override_left)


## Runs up to [member forecast_budget] steps of the pending veto: every action's future in turn.
func _veto_run() -> void:
	var n := veto_budget if veto_budget > 0 else 1 << 30
	while _vt_a < ACTIONS.size() and n > 0:
		if _vt_s == null:
			_vt_s = _vt_state.duplicate_state()
			_vt_t = 0
		var a := _vt_a if _vt_t < check_every else policy(_vt_s)
		var event: int = sim.step(_vt_s, command_for(sim, a, _vt_s, reference_yaw))
		veto_ticks += 1
		n -= 1
		_vt_t += 1
		var ended := true
		if event == DotBotSurfCourse.EVENT_GOAL or (event == DotBotSurfCourse.EVENT_NONE and _vt_t >= horizon):
			var sc: float = INF if event == DotBotSurfCourse.EVENT_GOAL else (float(score.call(_vt_s)) if score.is_valid() else 0.0)
			if sc > _vt_best_score:
				_vt_best_score = sc
				_vt_best = _vt_a
		elif event != DotBotSurfCourse.EVENT_NONE:
			if float(_vt_t - 1) > _vt_longest_t:
				_vt_longest_t = float(_vt_t - 1)
				_vt_longest = _vt_a
		else:
			ended = false
		if ended:
			_vt_a += 1
			_vt_s = null
			if _vt_best_score == INF:
				# Reaching the goal scores INF and only a higher score replaces the best: no later
				# action can, so the rest are not run.
				_vt_a = ACTIONS.size()
	if _vt_a >= ACTIONS.size():
		_vt_pending = false
		_vt_state = null
		_veto_apply()


func _veto_apply() -> void:
	var best := _vt_best
	if best < 0:
		# No way out in sight: put the fall off as long as possible, which is the most time for
		# the next check to find one.
		hopeless += 1
		_hopeless_streak += 1
		best = _vt_longest
	else:
		_hopeless_streak = 0
	if best >= 0:
		_override = best
		_override_left = check_every
		_tracked_left = 0
	# After a veto that found no way out, the next waits longer (twice, four times, at most eight
	# times as long): a doomed ride vetoing every check_every ticks was most of a hard edge's cost.
	_cooldown = check_every * (1 << mini(_hopeless_streak, 3))


## The rolling veto: keeps the forecast while the real state is on it, extends it by a tick at
## the far end, and vetoes when the far end falls. See the class notes.
func _keep_forecast(state: Variant) -> void:
	if _fc_pending:
		# The real state moves on while the forecast catches up; the head follows it.
		_pred_head += 1
		_run_forecast()
		if not _fc_pending:
			_judge(state)
		return
	var on_it := false
	if _end != null and _pred_head < _pred_p.size():
		var p: Vector3 = state.position
		var v: Vector3 = state.velocity
		on_it = p.distance_to(_pred_p[_pred_head]) <= FORECAST_SLACK and v.distance_to(_pred_v[_pred_head]) <= FORECAST_SLACK * 10.0
		_pred_head += 1
	if _end != null and not on_it and _tick > 0:
		resyncs += 1
	if not on_it:
		if _end != null and (_cooldown > 0 or _tick - _forecast_tick < RESYNC_GAP):
			# Just vetoed, or just forecast: wait, as the plain check does.
			return
		if state.has_method(&"is_grounded") and state.is_grounded():
			# Walking to the ramp: nothing to fall from yet, and the forecast follows when it leaves.
			_drop_forecast()
			return
		_forecast(state, _override if _override_left > 0 else -1, _override_left)
		if not _fc_pending:
			_judge(state)
		return
	# On the forecast: one more tick at the far end, unless it already ended.
	if _end_event != DotBotSurfCourse.EVENT_NONE:
		if _end_event != DotBotSurfCourse.EVENT_GOAL and _cooldown <= 0:
			_veto_then_forecast(state)
		return
	var a: int
	if _end_override_left > 0:
		a = _end_override
		_end_override_left -= 1
	else:
		a = policy(_end)
	_end_event = sim.step(_end, command_for(sim, a, _end, reference_yaw))
	lookahead_ticks += 1
	_push(_end)
	if _pred_head > 512:
		_pred_p = _pred_p.slice(_pred_head)
		_pred_v = _pred_v.slice(_pred_head)
		_pred_head = 0
	if _end_event != DotBotSurfCourse.EVENT_NONE and _end_event != DotBotSurfCourse.EVENT_GOAL and _cooldown <= 0:
		_veto_then_forecast(state)


## A fresh forecast from [param state]: [param first] held for [param first_left] ticks, then the
## policy, [member horizon] ticks or until it ends.
func _forecast(state: Variant, first: int, first_left: int) -> void:
	checks += 1
	_forecast_tick = _tick
	_drop_forecast()
	_end = state.duplicate_state()
	_end_override = first
	_end_override_left = first_left if first >= 0 else 0
	_fc_left = horizon
	_fc_pending = true
	_run_forecast()


## Vetoes when a completed forecast ends in a fall, then forecasts again from the veto's action.
func _judge(state: Variant) -> void:
	if _end_event != DotBotSurfCourse.EVENT_NONE and _end_event != DotBotSurfCourse.EVENT_GOAL and _cooldown <= 0:
		_veto_then_forecast(state)


## Runs up to [member forecast_budget] steps of the pending forecast.
func _run_forecast() -> void:
	var n := forecast_budget if forecast_budget > 0 else _fc_left
	while _fc_left > 0 and n > 0:
		n -= 1
		_fc_left -= 1
		var a: int
		if _end_override_left > 0:
			a = _end_override
			_end_override_left -= 1
		else:
			a = policy(_end)
		_end_event = sim.step(_end, command_for(sim, a, _end, reference_yaw))
		lookahead_ticks += 1
		_push(_end)
		if _end_event != DotBotSurfCourse.EVENT_NONE:
			_fc_left = 0
	_fc_pending = _fc_left > 0


func _push(s: Variant) -> void:
	_pred_p.append(s.position)
	_pred_v.append(s.velocity)


func _drop_forecast() -> void:
	_pred_p = PackedVector3Array()
	_pred_v = PackedVector3Array()
	_pred_head = 0
	_end = null
	_end_event = DotBotSurfCourse.EVENT_NONE
	_end_override_left = 0
	_fc_left = 0
	_fc_pending = false


# Tracking.

## The action whose [member track_every]-tick future ends nearest where the nearest remembered
## ride was that many ticks later. One that reaches the goal wins outright; one that falls is
## never chosen while another does not.
func _track(state: Variant) -> int:
	var i := _follow(state)
	if i < 0:
		return 0
	var target := mini(i + track_every, _ride_end[i] - 1)
	var best := int(entries[i * STRIDE + 6])
	var best_d := INF
	for a in range(ACTIONS.size()):
		var s: Variant = state.duplicate_state()
		var event := 0
		for _t in range(track_every):
			event = sim.step(s, command_for(sim, a, s, reference_yaw))
			if event != 0:
				break
		if event == DotBotSurfCourse.EVENT_GOAL:
			return a
		if event != 0:
			continue
		var d := _distance(target, s.position, s.velocity)
		if d < best_d:
			best_d = d
			best = a
	return best


## How far along its ride (entries) the followed entry may move in one look, how much nearer
## (squared distance, times) another ride must be to switch to it, and a floor under that in
## square metres so two rides a few centimetres apart do not trade places.
const FOLLOW_WINDOW := 48
const SWITCH_RATIO := 4.0
const SWITCH_SLACK := 0.25


## The entry to track from: the next stretch of the ride already being followed, unless another
## ride is much nearer. [b]Sticky, because the rides disagree.[/b] Re-matching to the globally
## nearest entry every 8 ticks hopped between rides on different lines (one face of an A-frame
## ramp and the other), and a mix of two good lines is a bad one.
func _follow(state: Variant) -> int:
	var position: Vector3 = state.position
	var velocity: Vector3 = state.velocity
	var anywhere := nearest(state)
	if anywhere < 0 or _following < 0 or _following >= size():
		_following = anywhere
		return anywhere
	var best := -1
	var best_d := INF
	var end := mini(_ride_end[_following], _following + FOLLOW_WINDOW)
	for i in range(_following, end):
		var d := _distance(i, position, velocity)
		if d < best_d:
			best_d = d
			best = i
	if best < 0 or best_d > SWITCH_RATIO * _distance(anywhere, position, velocity) + SWITCH_SLACK:
		best = anywhere
	_following = best
	return best


func describe() -> Dictionary:
	return {"entries": size(), "tracking": tracking, "horizon": horizon, "rolling": rolling,
		"checks": checks, "vetoes": vetoes, "hopeless": hopeless, "resyncs": resyncs,
		"lookahead_ticks": lookahead_ticks, "veto_ticks": veto_ticks}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray(["surf pilot  %d entries, horizon %d%s; %d futures, %d vetoes (%d hopeless), %d resyncs" % [
		d["entries"], d["horizon"], " rolling" if rolling else "", d["checks"], d["vetoes"], d["hopeless"], d["resyncs"]]])
