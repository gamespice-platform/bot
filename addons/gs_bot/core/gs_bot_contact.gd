class_name GSBotContact
extends RefCounted

## One body a bot might fight, or the bot itself, as the brain sees it.
## [b]A snapshot the game fills, never a node.[/b] The brain is pure: it reads these and the world's line-of-sight answer and returns an intent.
## A game with ninety players builds ninety of these a tick once, in [method GSBotWorld.contacts], and every bot reads the same list.

# No log channel: a record.

## The game's id for this body (a player id, a session id).
var id: int = 0

## Feet, world space.
var position: Vector3 = Vector3.ZERO

## Metres per second.
var velocity: Vector3 = Vector3.ZERO

## Height of the eye above [member position]. Also where a bot looks from.
var eye_height: float = 1.6

## Height of the point a bot aims at (the chest) above [member position].
var aim_height: float = 1.25

## The view, in the command's degrees: yaw 0 looks down -Z, positive yaw turns left
## ([code]atan2(-x, -z)[/code]). NAN when the game does not know, and the brain then keeps
## its own.
var view_yaw: float = NAN
var view_pitch: float = NAN

## What the body is doing, for the tricks a bot chains. The defaults are a body on the ground
## doing nothing special, which is what a game that does not fill them gets: no tricks start
## from a state the game does not report.
var grounded: bool = true
var sliding: bool = false
var wall_running: bool = false

## Whether the game would honour an air-jump press now (the move is on and off cooldown).
## The bot presses it only when this is true, so a game that has it disabled is never asked.
var air_jump_ready: bool = false

## What the body carries, by the game's slot number: [code]{value: float, ammo: float}[/code], the game's rating of the weapon (0..1) and its ammo as a fraction of full.
## An unlisted slot is empty. Read by [GSBotPickup]; a game that never fills it has bots that take nothing off the floor.
var loadout: Dictionary = {}

## The class of the weapon in hand, for [GSBotStyle]: [code]&"sniper"[/code], [code]&"rifle"[/code], [code]&"smg"[/code], [code]&"shotgun"[/code], [code]&"pistol"[/code], [code]&"heavy"[/code], [code]&"launcher"[/code], [code]&"melee"[/code], [code]&"throw"[/code], or a game's own (with a table that names it).
## Empty when the game does not say: the bot then plays the one generic way.
var weapon_class: StringName = &""

## Rounds left in the magazine in hand as a fraction of a full one, -1 when unknown. A style that
## reloads in cover reads it.
var magazine: float = -1.0

## 0..1.
var health: float = 1.0

var alive: bool = true

## 0 is no team: everybody else is an enemy.
var team: int = 0


static func make(p_id: int, p_position: Vector3, p_team: int = 0) -> GSBotContact:
	var c := GSBotContact.new()
	c.id = p_id
	c.position = p_position
	c.team = p_team
	return c


func eye() -> Vector3:
	return position + Vector3.UP * eye_height


func aim_point() -> Vector3:
	return position + Vector3.UP * aim_height


## Whether [param other] is somebody this one fights.
func is_enemy(other: GSBotContact) -> bool:
	if other == null or other.id == id:
		return false
	return team == 0 or other.team == 0 or team != other.team


func describe() -> Dictionary:
	return {"id": id, "position": position, "team": team, "alive": alive, "health": health}
