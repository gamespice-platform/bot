class_name GSBotClimb
extends RefCounted

## One ladder ride, shared by the brain and any game that steers its own stand-ins: face the ladder, push forward so the controller's ladder mode climbs, hop off at the top onto the landing (walking away while on it would descend).
##
## [method step] each tick with the feet position; apply the result to the command, and drop the climb when [code]done[/code].

## Longest a ladder is climbed before it is given up, seconds, and the longest spent stepping off the top.
const TIMEOUT := 20.0
const EXIT := 1.5

var box := AABB()
var to := Vector3.ZERO
var since := 0.0
var exit_since := NAN

## Seconds a descent pushes into the ladder's face to grab it before backing down, and the rise under the feet that makes a ride a descent.
const GRAB := 0.4
const DOWN := 1.0

var _down := false
var _started := false


## [param ladder] is a [method GSBotLinks.ladder_of] answer.
static func begin(ladder: Dictionary, now: float) -> GSBotClimb:
	var c := GSBotClimb.new()
	c.box = ladder["box"]
	c.to = ladder["to"]
	c.since = now
	return c


## `{"yaw": degrees, "move": Vector2, "jump": bool, "done": bool}`; with done set the rest is to be ignored.
func step(pos: Vector3, now: float) -> Dictionary:
	if now - since > TIMEOUT:
		return {"done": true}
	if not _started:
		_started = true
		_down = to.y < pos.y - DOWN
	if _down:
		return _step_down(pos, now)
	var target := to
	var hop := false
	if pos.y >= minf(to.y - 0.1, box.end.y + 0.02) and is_nan(exit_since):
		exit_since = now
		hop = true
	if is_nan(exit_since):
		target = _face(pos)
	elif Vector2(to.x - pos.x, to.z - pos.z).length() < 0.5 or now - exit_since > EXIT:
		return {"done": true}
	var flat := Vector2(target.x - pos.x, target.z - pos.z)
	var yaw := rad_to_deg(atan2(-flat.x, -flat.y)) if flat.length() > 0.01 else NAN
	return {"yaw": yaw, "move": Vector2(0.0, 1.0), "jump": hop, "done": false}


## A descent: push into the face until the controller has the climber on (the top of a ladder is walked into), then back down it; done at the foot.
func _step_down(pos: Vector3, now: float) -> Dictionary:
	if pos.y <= to.y + 0.3:
		return {"done": true}
	var target := _face(pos)
	var flat := Vector2(target.x - pos.x, target.z - pos.z)
	var yaw := rad_to_deg(atan2(-flat.x, -flat.y)) if flat.length() > 0.01 else NAN
	var push := now - since < GRAB
	return {"yaw": yaw, "move": Vector2(0.0, 1.0 if push else -1.0), "jump": false, "done": false}


## The point of the ladder's face to push into: along the box's long side as far as the climber already is, and on the middle of its
## thin axis, since the controller takes the thin axis for the face's normal (aiming at the near edge of an end walked up to goes along the face).
func _face(pos: Vector3) -> Vector3:
	var at := Vector3(clampf(pos.x, box.position.x, box.end.x), 0.0, clampf(pos.z, box.position.z, box.end.z))
	var mid := box.get_center()

	if box.size.x < box.size.z:
		at.x = mid.x
	else:
		at.z = mid.z

	return at
