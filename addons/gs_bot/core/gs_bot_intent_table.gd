class_name GSBotIntentTable
extends RefCounted

## The brains' answers of one tick as packed columns, one row per bot in the order handed in (docs/native-bot-brain.md, step 3).
## [method pack] copies [GSBotIntent]s in; [method finish] then makes the command columns a game copies into its own commands
## ([member cmd_move], [member move_buttons], [member fire_buttons]), in one native call (GameSpice Sim's
## [code]GSSimBotFinish.write[/code]) when the library has it and [member native_enabled] is on, else in script, to the bit the same.
## The button maps are the game's: per intent bit, the command bit it sets, so this addon names no command class.

# No log channel: a record.

## [member buttons] bits.
const FIRE := 1
const CROUCH := 2
const JUMP := 4
const WALK := 8
const AIR_JUMP := 16
const THROW := 32
const USE := 64
const STRANDED := 128
## Intent bits a map has an entry for, in bit order (FIRE first).
const BITS := 8

## gs-sim's finish, reached by name.
const NATIVE_CLASS := &"GSSimBotFinish"
## Off: [method finish] runs in script (a game's cvar, Fatal Contact's [code]bot_native_think[/code]).
static var native_enabled := true
## 1 when the library has the finish, 0 not, -1 not asked yet.
static var _native_known := -1

## Names [member state] indexes, handed once; a state not in it is added on first sight.
var state_names: Array[StringName] = []
var _state_index: Dictionary = {}

var yaw := PackedFloat64Array()
var pitch := PackedFloat64Array()
var move := PackedVector2Array()
var buttons := PackedInt32Array()
var ride := PackedInt64Array()
var target_id := PackedInt64Array()
var state := PackedInt32Array()

## [method finish]'s output: the stick limited to length 1, and the command buttons through the maps.
var cmd_move := PackedVector2Array()
var move_buttons := PackedInt32Array()
var fire_buttons := PackedInt32Array()


## Whether [method finish] can run natively in this build.
static func native_available() -> bool:
	if _native_known < 0:
		_native_known = 1 if ClassDB.class_exists(NATIVE_CLASS) and ClassDB.class_has_method(NATIVE_CLASS, &"write") else 0
	return _native_known == 1


## [param intent]'s bits.
static func bits_of(intent: GSBotIntent) -> int:
	var b := 0
	if intent.fire:
		b |= FIRE
	if intent.crouch:
		b |= CROUCH
	if intent.jump:
		b |= JUMP
	if intent.walk:
		b |= WALK
	if intent.air_jump:
		b |= AIR_JUMP
	if intent.throw:
		b |= THROW
	if intent.use:
		b |= USE
	if intent.stranded:
		b |= STRANDED
	return b


## [param count] rows, all zero.
func resize(count: int) -> void:
	yaw.resize(count)
	pitch.resize(count)
	move.resize(count)
	buttons.resize(count)
	ride.resize(count)
	target_id.resize(count)
	state.resize(count)


## One table of [param intents] (a null row: no buttons, a zero stick and view, ride, target_id and state -1). [param full] false packs only what [method finish]
## reads (yaw, pitch, move, buttons) and does not write ride, target_id and state: a game's finish needs no more.
func pack(intents: Array, full := true) -> void:
	resize(intents.size())
	for i in intents.size():
		var intent: GSBotIntent = intents[i]
		if intent == null:
			yaw[i] = 0.0
			pitch[i] = 0.0
			move[i] = Vector2.ZERO
			buttons[i] = 0
			ride[i] = -1
			target_id[i] = -1
			state[i] = -1
		elif full:
			set_row(i, intent)
		else:
			yaw[i] = intent.yaw
			pitch[i] = intent.pitch
			move[i] = intent.move
			buttons[i] = bits_of(intent)


## Row [param i] from [param intent].
func set_row(i: int, intent: GSBotIntent) -> void:
	yaw[i] = intent.yaw
	pitch[i] = intent.pitch
	move[i] = intent.move
	buttons[i] = bits_of(intent)
	ride[i] = intent.ride
	target_id[i] = intent.target_id
	state[i] = state_of(intent.state)


## [param name]'s index in [member state_names], added on first sight.
func state_of(name: StringName) -> int:
	var at: Variant = _state_index.get(name)
	if at == null:
		at = state_names.size()
		state_names.append(name)
		_state_index[name] = at
	return at


## The command columns of every row: [member cmd_move] is [code]move.limit_length(1.0)[/code], [member move_buttons] and
## [member fire_buttons] the OR of [param move_map] and [param fire_map] ([constant BITS] entries each, the command bit
## for FIRE, CROUCH, ... STRANDED; 0 for none) over the row's set bits. Natively when it can; [param native] false forces script.
func finish(move_map: PackedInt32Array, fire_map: PackedInt32Array, native := true) -> void:
	if native and native_enabled and native_available():
		var out: Array = ClassDB.class_call_static(NATIVE_CLASS, &"write", move, buttons, move_map, fire_map)
		if out.size() == 3:
			cmd_move = out[0]
			move_buttons = out[1]
			fire_buttons = out[2]
			return
	var n := move.size()
	cmd_move.resize(n)
	move_buttons.resize(n)
	fire_buttons.resize(n)
	for i in n:
		cmd_move[i] = move[i].limit_length(1.0)
		var b := buttons[i]
		var mb := 0
		var fb := 0
		for k in BITS:
			if b & (1 << k):
				mb |= move_map[k]
				fb |= fire_map[k]
		move_buttons[i] = mb
		fire_buttons[i] = fb


## Hash of every column, the intent's and the command's: a native finish digests as the script one.
func digest() -> int:
	return hash(var_to_bytes([yaw, pitch, move, buttons, ride, target_id, state, cmd_move, move_buttons, fire_buttons]))
