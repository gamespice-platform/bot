class_name GSBotClock
extends RefCounted

## One brain's profile clock: the microseconds of its think phases and of the world queries it asked
## ([constant GSBotBrain.PHASES]), while [member on] ([member GSBotBrain.phase_timers]) is set.
## Each brain owns one and only its own think writes it, so brains on worker threads time with no lock and no
## shared write; the main thread folds every clock into [member GSBotBrain.phase_us] once per tick
## ([method GSBotBrain.merge_phases]), or at once after a think it ran itself.
##
## A query site costs one static read while off: [code]var t := Time.get_ticks_usec() if GSBotClock.on else 0[/code],
## then [code]if t: GSBotClock.add(clock, GSBotClock.Q_SIGHT, t)[/code].

## Whether brains time. Set through [member GSBotBrain.phase_timers].
static var on := false

## Think phases, in [constant GSBotBrain.PHASES] order (bb_*).
const PHASE_COUNT := 7
## World queries (bq_*), after the phases. Their time is inside the phase that asked, not beside it.
const Q_SIGHT := 7
const Q_ROUTE := 8
const Q_LADDER := 9
const Q_WALKABLE := 10
const Q_WAYPOINTS := 11
const Q_WALL := 12
const Q_SOUNDS := 13
const Q_DROPS := 14
const Q_PROJECTILE := 15
const SLOTS := 16

## Microseconds and calls per slot not yet folded into the brain's statics; empty until first timed.
var us := PackedInt64Array()
var calls := PackedInt64Array()
## The clock read the next [method lap] measures from.
var at := 0


## Starts a think's laps.
func start() -> void:
	if us.is_empty():
		us.resize(SLOTS)
		calls.resize(SLOTS)
	at = Time.get_ticks_usec()


## Ends think phase [param phase] here.
func lap(phase: int) -> void:
	var t := Time.get_ticks_usec()
	us[phase] += t - at
	calls[phase] += 1
	at = t


## A query in [param slot] that began at [param since]; [param clock] may be null (a part made without a brain).
static func add(clock: GSBotClock, slot: int, since: int) -> void:
	if clock == null:
		return
	if clock.us.is_empty():
		clock.us.resize(SLOTS)
		clock.calls.resize(SLOTS)
	clock.us[slot] += Time.get_ticks_usec() - since
	clock.calls[slot] += 1


## Adds this clock's pending time into [param into_us] and [param into_calls] (both [constant SLOTS] long) and clears it.
func fold(into_us: PackedInt64Array, into_calls: PackedInt64Array) -> void:
	if us.is_empty():
		return
	for i in SLOTS:
		into_us[i] += us[i]
		into_calls[i] += calls[i]
	us.fill(0)
	calls.fill(0)
