class_name GSBotAimSolver
extends RefCounted

## Optional aim solver for simulated bullets (drop and flight time): returns the point to aim at so a
## bullet meets a moving target. Off unless a game assigns [member GSBotAim.aim_solver].

const STEP := 1.0 / 120.0
const GRAVITY := 9.8
const MAX_TIME := 15.0



## Reads muzzle_velocity, bullet_gravity and drag off [param tuning] by duck typing (a gs-weapon
## GSWeaponBallistics fits, so does any Object or Dictionary with those names). Null or
## muzzle_velocity <= 0 means hitscan: [param target] comes back unchanged, as it does when no solution exists.
static func solve(muzzle: Vector3, target: Vector3, velocity: Vector3, tuning: Variant) -> Vector3:
	var v0 := _read(tuning, "muzzle_velocity", 0.0)
	if v0 <= 0.0:
		return target
	var g := GRAVITY * _read(tuning, "bullet_gravity", 1.0)
	var drag := _read(tuning, "drag", 0.0)
	var aim := target
	var t := 0.0
	for i in 5:
		var flat := Vector2(aim.x - muzzle.x, aim.z - muzzle.z).length()
		var h := aim.y - muzzle.y
		var sol := _pitch(v0, g, drag, flat, h)
		if sol.is_empty():
			return target
		t = sol[1]
		aim = target + velocity * t
	var r := Vector2(aim.x - muzzle.x, aim.z - muzzle.z).length()
	if r < 0.001:
		return target
	var last := _pitch(v0, g, drag, r, aim.y - muzzle.y)
	if last.is_empty():
		return target
	return Vector3(aim.x, muzzle.y + tan(last[0]) * r, aim.z)


## Launch pitch (radians, absolute) that reaches horizontal [param r] at height [param h], and the
## flight time; empty when out of reach.
static func _pitch(v0: float, g: float, drag: float, r: float, h: float) -> Array:
	var lo := -0.6
	var hi := 1.0
	var at_hi := _height_at(v0, g, drag, hi, r)
	if is_nan(at_hi.x) or at_hi.x < h:
		return []
	for i in 24:
		var mid := (lo + hi) * 0.5
		var res := _height_at(v0, g, drag, mid, r)
		if is_nan(res.x) or res.x < h:
			lo = mid
		else:
			hi = mid
	var best := _height_at(v0, g, drag, hi, r)
	if is_nan(best.x) or absf(best.x - h) > 0.25 + r * 0.01:
		return []
	return [hi, best.y]


## (height, time) when a bullet launched at [param pitch] passes horizontal [param r]; (NAN, NAN) if it
## never does. A Vector2 rather than an array: a value, so no heap allocation per call (_pitch makes 26
## per solve), and no shared state, since games may run bot brains, and so this solver, on worker threads.
static func _height_at(v0: float, g: float, drag: float, pitch: float, r: float) -> Vector2:
	var x := 0.0
	var y := 0.0
	var vx := cos(pitch) * v0
	var vy := sin(pitch) * v0
	var t := 0.0
	while t < MAX_TIME:
		vy -= g * STEP
		var s := sqrt(vx * vx + vy * vy)
		if s > 0.0 and drag > 0.0:
			var k := maxf(0.0, 1.0 - drag * s * STEP)
			vx *= k
			vy *= k
		var nx := x + vx * STEP
		if nx >= r:
			var f := (r - x) / maxf(nx - x, 0.000001)
			return Vector2(y + vy * STEP * f, t + STEP * f)
		x = nx
		y += vy * STEP
		t += STEP
		if vx < 1.0:
			break
	return Vector2(NAN, NAN)


static func _read(tuning: Variant, key: String, fallback: float) -> float:
	if tuning is Dictionary:
		return float(tuning.get(key, fallback))
	if tuning is Object and key in tuning:
		return float(tuning.get(key))
	return fallback
