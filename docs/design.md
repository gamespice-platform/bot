# Design

## Why a separate addon

A bot here is a **player**: it has a session id, a loadout, a score, a body that moves through the game's own movement code and a gun that fires through the game's own arsenal. Each tick it decides what a person would press, and the game turns that into the same commands a client sends. That is a different thing from an NPC, which gs-npc places, paths and budgets and gs-npc-ai's behaviour trees decide for.

GameSpice NPC AI was the alternative, and it already has the shape to borrow (a character table, a turn-rate limit, aim error, reaction time, `npc_skill`). It was not used because it depends on GameSpice NPC, and a game whose bots are players (every game in the family that has bots) would then have to install the NPC runtime to get them; and because the two difficulty knobs answer different questions. `npc_skill` moves a horde of monsters toward easier or harder; `bot_difficulty` is how good the players you are matched against are, setting by setting, which a server owner wants to tune one number at a time. They stay separate cvars on purpose.

So GameSpice Bot depends on GameSpice Core alone and names no other addon: GameSpice Server's cvars (`bind_cvars` takes `GSModule.add_cvar`), GameSpice Console's console (`bind_console` takes anything with `add_var`), and the command classes (`GSBotIntent.write_move` reads the button bits from the command's own constants) are all reached by duck typing.

## The brain is pure

`GSBotBrain.think(me, world, now)` reads a `GSBotContact` for itself and a `GSBotWorld`, and returns a `GSBotIntent`. It holds no node and moves nothing. The game builds the contacts once a tick (`FcBots.World.refresh` in game-fatal-contact), and every bot reads the same list. The clock is the caller's `now` (game-fatal-contact passes the tick over the tick rate), never the engine's.

## What a bot may know

Everything is in `GSBotWorld`: the bodies, a line-of-sight answer, places to walk to and the way there, how fast the held weapon's shot flies, and the sounds made. A bot knows of another body only when:

- it is inside the view cone (`bot_fov`) and within `bot_sight`, and the world says the line from the bot's eye to that body's chest or eye is clear; or it is within 2 m, which a person feels whatever way they face; or the bot is already fighting it and it is within 90 degrees (the bot is turning after it);
- or it made a sound the bot heard: within `bot_hearing` times the sound's loudness (1 for a gunshot, about 0.3 for a swing or a step). A sound gives a rough position (the further, the vaguer), never a target;
- or it hit the bot (`hurt(from, now)`), which gives the shooter's position and turns the bot toward it.

`bot_through_walls` exists for tests and is 0 in every preset. "No shooting through walls" is then structural: the brain cannot fire at what it has not seen, and game-fatal-contact's `headless_bots` counts every trigger pull without line of sight (zero, over thousands of shots per preset).


### Flashes and smoke (API level 8)

`GSBotBrain.blind_for(now, seconds, from)` makes a bot see nothing for its seconds: it loses a visible target, while hearing and pain still work, and `from` (where the flash went off, or `Vector3.INF`) is where it turns afterwards. `is_blind(now)` asks. `GSBotWorld.add_sight_blocker(center, radius, until)` makes `line_of_sight` refuse any segment through that sphere until game time `until` (smoke) and returns an id for `remove_sight_blocker(id)`; the brain prunes ended ones each think through `prune_sight_blockers(now)`. A game's grenade code calls these; the addon names no grenade. A consumer that must still load against an older GameSpice Bot guards with `GSAddonApi.build_level("gs_bot") >= 8`.

## The states

Each tick the brain perceives first, then does one of the states below. Perceiving while a target is in sight tests that target alone (range, cone, line of sight) and scans every body only when it fails: a seen target is kept whoever else is in view, so the choice is the same and most thinks of a fight skip the scan. `GSBotBrain.target_first = false` scans always; the self-test plays a crowd both ways and compares every intent.

The states:

- **fight**: a target is in sight. Aim, fire when the view is on the aim and the reaction time has passed, keep `bot_range`, strafe, burst at range, maybe stand still or crouch for a long burst, maybe jump up close, back out when badly hurt (`bot_cover`). A bot that has fought within `STALE_MOVE` of one spot for `STALE_FIGHT` seconds, whoever the target, walks in to `STALE_CLOSE` instead of trading misses from there.
- **search**: the target went out of sight within `bot_memory`. Pre-aim where it went and shuffle in and out of the corner (`bot_peek`), or walk after it (`bot_aggression`), or hold and look; maybe throw at it (`bot_grenades`).
- **listen**: a sound or a hit within memory. Turn to it; walk to it if the bot rolled to go after it.
- **pickup** (inside roam, `GSBotPickup`): a quiet bot whose slot holds a worse weapon, nothing, or low ammunition notices a drop within `bot_pickup_range` that it can see, after its `reaction` delay, walks to it and holds the use key for about 0.8 s, so the game's own hold-to-swap or tap path takes it; nothing is teleported. The game supplies `GSBotContact.loadout` and `GSBotWorld.drops_fn`, both rated 0 to 1 by the game. A drop still there after a try is left alone for 20 s; any fight, sound or hit cancels the plan. `bot_pickup_weapons` 0 turns it off.
- **roam**: walk between the world's waypoints, glancing from side to side, toward where it last knew of an enemy when `bot_map_knowledge` says so; hop and pick another waypoint when it has not moved in 1.5 s. Where the world has a route (`GSBotWorld.route`, a game's navigation graph), the bot walks it corner by corner, asked once per goal; with none, straight at the waypoint, which is enough on an open floor and walks into the wall on a map with corners. Going after a sound walks the same way.
- **team job** (instead of roam, `GSBotGoal`): in a flag mode the game fills `GSBotWorld.objective` (`GSBotObjective`) each tick and gives each bot a role when it joins a team, by the shares `bot_role_defend`, `bot_role_attack`, `bot_role_support` and a persona's lean (`GSBotPersona.role_bias`). Every 0.75 s (spread by id) the bot plans: a carrier runs home (`capture`, urgent: no pickups, sounds or searches, it fights on the move); defenders and supporters, and anybody near it, go for their own flag when it is dropped (`return`) or carried (`intercept`); attackers `grab` the enemy flag or `escort` a carrier; supporters escort or `hold` ground between the bases facing the enemy's; defenders patrol within `bot_defend_radius` of home and do not chase a sound or a lost target beyond twice that. In a hill mode the game sets `GSBotObjective.set_point` instead: defenders hold on the hill (leashed to it), attackers take it while another team holds it and hunt while their own does, supporters hold a ring around it facing in. `bot_objective_focus` is how often it keeps to the job; the rest it roams a few seconds. The state it reports is the job's name. No objective, or all shares 0: roam as before.
- **one character per bot** (`GSBotPersona`, `GSBotPersonaPool.deal`, `GSBotSettings.derived`): a game deals each bot a persona, spread by weight so a team of eight is not five of one kind, and gives the bot its own settings derived from the game's: the persona's difficulty or the server's, its `skill` values, its `scale` multipliers (relative, so the persona follows `bot_difficulty`), then a per-bot seeded jitter of up to `spread` on reaction and aim. `turn_rate` never rises above the server's `bot_turn_rate`. `sync()` re-derives when the game's settings change (one int compare otherwise), and the persona's `role_bias` steers its team job.

## The fight

The view, the aim error, the reaction and the trigger are `GSBotAim`, which the brain holds and a game with decisions of its own (a co-op stand-in, a hunter sweeping a room) uses by itself: it calls `view_from` with the body's view going into the tick, `engage` every tick it sees its target, `track` toward the target (or `look_at_point` toward anything else), and `trigger` for the button. Asked again within 0.25 s, an engagement simply continues, so a game ticking twenty times a second does not restart the reaction every tick.

**The view is turned, never set.** The brain closes on where it wants to look smoothly (`bot_turn_smooth`), carrying half of a moving target's motion plus `bot_prediction` of the rest, and the whole step is clamped to `bot_turn_rate`. A target outside the view takes visible time to turn onto.

**The aim starts off and settles.** An engagement opens `bot_aim_error` degrees off (scaled 0.75 to 1.25 per engagement), in a direction that drifts, halves every `bot_aim_settle` seconds down to `bot_aim_floor`, and swings between about half and all of that. A hit adds `bot_flinch`. A target re-acquired within 1.5 s continues the same engagement (the error keeps settling) and reacts in half the time, which is what a held angle is.

**The trigger has gates**: reaction passed (`bot_reaction`, plus `bot_notice` scaled by how far off the view the target was), the view within `bot_fire_cone` of where it means to aim, and within `bot_max_range`. Beyond `bot_burst_range` it fires `bot_burst` seconds on, `bot_burst_pause` off.

**A target killed in view is forgotten.** A person moves on after a kill; a bot that searched for it stood pre-aiming the body for its whole memory (seen in the first render). A sound or a lost target the bot is not going after holds it for a glance (1.2 s), not its whole memory, for the same reason: a bot staring at a wall for four seconds reads as stuck.

### Weapon styles

Each gun is played its own way (`GSBotStyle`, `runtime/gs_bot_style.gd`). The game sets `GSBotContact.weapon_class` to the class of the weapon in hand (`sniper`, `marksman`, `rifle`, `smg`, `shotgun`, `pistol`, `heavy`, `launcher`, `melee`, `throw`, or its own) and, if it can, `GSBotContact.magazine` (0..1). Each class has a weighted table of styles. A bot picks one style per class from its own random stream (`gs_bot_style`, so the brain's own draws do not change). On each respawn it picks again with chance `bot_style_variety`, and it rolls a small per-life jitter (±`bot_style_variety`) on every scale, so no two bots play one style the same way.

A style row scales what the generic fight already does:
- `range` scales the distance kept;
- `reach` scales the farthest distance it shoots from;
- `strafe` scales the strafing;
- `burst` lengthens bursts and shortens the pauses between them;
- `stop`, `crouch`, `aggression` and `peek_chance` shift the existing rolls.

The row's `fight` and `roam` add moves:
- **`peek`** (the snipers, the rifle anchor, the grenade peeker): after `peek` seconds of shooting, or after a kill, the bot finds cover from the enemy's eye. It tries short sidesteps away from the sightline first and backs off if none work. It sits in cover for `hide` seconds (state `cover`), then walks out to its old spot (`peek`), or with chance `reposition` takes another angle (`reposition`, or `sneak` walking with chance `sneak`).
- **`rush`** (shotgun, smg, melee): it closes in, strafing `flank` hard across the enemy's line (state `rush`).
- **`camp`**: a quiet bot picks a vantage among the waypoints with the longest sightlines, walks there and holds it, sweeping the view (`vantage`). It moves on when hurt or after `patience` seconds.
- **`cover_reload`**: the chance that a low magazine sends it to cover first.

The table ships in `GSBotStyle.DEFAULTS`. `bot_style_file` names a JSON file whose rows merge into it by name, and a new class adds a class. `bot_style_weights` (`sniper.camper=0, smg.flanker=3`) changes single weights.

`bot_styles` (0..2) scales all of it. 0, or an empty class, is the generic bot to the bit. Per-tick cost is a few multiplies; cover and vantage searches cast at most 6 and 18 rays, once per phase change.

### Simulated bullets

With the server's `sv_ballistics` on, a bullet drops and takes time to arrive, and a hitscan aim misses. `GSBotAim.aim_solver` is an optional callable `func(eye, point, velocity) -> Vector3` that `track` uses in place of the plain lead; unset (the default) changes nothing. `GSBotAimSolver.solve(muzzle, target, velocity, tuning)` is a ready one: it iterates flight time and bore pitch a few times, reads `muzzle_velocity`, `bullet_gravity` and `drag` off the tuning by duck typing (a gs-weapon `GSWeaponBallistics`, or a dictionary), and returns the plain point when there is no tuning or no solution. gs-bot does not depend on gs-weapon.

## Movement tricks

`GSBotTricks` (held by the brain as `tricks`) adds the slide, the slide-jump, the wall run with its wall jump, the duck in cover and the air-jump to an intent. It only presses buttons a person could, so the motor refuses what the body cannot do, and a game that has a trick off is never told its precondition (`GSBotContact.air_jump_ready` is the game's, filled each tick). The scenario (close, chase, flee, cover, roam) weights the dice; `bot_slide`, `bot_wall_run`, `bot_air_jump`, `bot_cover_crouch` say how often, `bot_trick_chain` how well one leads into the next and `bot_trick_delay` how long it takes to start. A wall run needs the slide's boost for its speed, so the chain is slide, jump, touch the wall, wall jump. Walls are found with `GSBotWorld.wall_ahead` (a game sets `wall_fn`); with none, no wall run is tried. Not done: ledges and gaps are not detected, the air-jump only reaches a target well above.

## Presets and overrides

`GSBotProfile.SPEC` is the one table: per setting its range, its value in each of the four presets, and its help line. `GSBotSettings` holds one game's live profile and its overrides:

- `bot_difficulty <preset>` writes every setting not overridden;
- any `bot_<setting>` written by hand is an override and survives the next preset;
- `bot_settings` lists every value (overrides marked `*`), `bot_settings_reset` drops the overrides.

A preset change keeping overrides is what makes a server config order-free: `bot_reaction 0.4` above `bot_difficulty hard` in a file means both. When the cvars are bound late, values a config left waiting are all read before the preset is applied, because applying it rewrites every cvar. One case it cannot see: a waiting value equal to medium's default is indistinguishable from the default and is not taken as an override.

The settings are per game, kept on a node as metadata (`GSBotSettings.of(game)`), never in `GSRegistry`, because the family runs two servers in one process in its suites.

## Determinism

Each brain draws from its own `GSRandomStream` seeded from its id, and its clock is the caller's. Two runs with the same inputs play the same bot, which is what lets `headless_bots` hold every preset to a band without flaking. A game must not seed a bot from an object's instance id (it moves between runs).

## Think-rate tiers

In a crowd (`GSBotThinkTier.above` players, 16) not every bot runs its brain every tick. The rule for what a thinned bot may skip: **its thinking, never its body.** The game keeps moving it every tick on the commands of its last think (held buttons only, the view carried towards where it last looked, a turn after a gap held to one tick's turn rate), so its walk, its hitboxes and lag compensation are the same at any period, and the brain's cost is what is saved. A bot is full rate when it fights a person within `engaged_range`, is within `close_range` of one, is among the `nearest` to one, or is in a person's view cone with a target; a bot a person just hurt thinks on the next tick whatever its tier. What thins out: a bot no person sees or nears (`near_every`, `far_every`, stretched by `load_scale` under load), a bot fighting a person far away and unseen (`engaged_far_every`), and an idle bot (no target, or dead) that a person only sees (`idle_view_every`, 2, never stretched): in sight it shows only its walk, and the tick it picks a target it is no longer idle. `bot_selftest` holds a bot near a person to the same intents, tick for tick, with and without tiers.

Body tiers (API 22) are the one exception to that, on by default since API 23 above `body_above` = 24 players (`body_near_every` 2, `body_far_every` 4; 1 turns a side off, `body_above` -1 turns them off; measured on 48 bots on staging02, windowed, 3 runs a side: ticks per second +18%, dropped ticks per second -28%, game per-tick cost -14%, frame p50 +17% because the game spends the gain on catch-up ticks): `body_period()` answers above 1 only for a bot `period()` calls near or far, that is one no person sees, nears or fights. A game that sets them runs such a bot's motor every few ticks and makes up the skipped time in one longer tick, so it walks in steps and its hitboxes jump, which no person sees; every bot anyone can see, meet or shoot keeps its body every tick. The game must still run the full tick on any edge (a jump press, a push, off the ground) and keep turning the view on the skipped ticks; game-fatal-contact's `FcPlayer.body_delta` is the reference.

Sight LOD (API 25): a brain reuses a line-of-sight answer for `SIGHT_REUSE` (45 ms), which a bot thinking every third tick at 66 Hz just outlives, so every hidden body in its cone costs two rays each think. `GSBotWorld.sight_far` (m, 0 = off) and `sight_far_reuse` (s) hold a "not seen" longer for a body farther than that. Only a "not seen", and never for the bot's current target: a far body stepping out of cover is noticed up to `sight_far_reuse` late, and nothing is ever shot without a fresh ray. The native mind (gs-sim) applies the same rule: the script decides the distance and passes the reuse to `sight_cached_far`, and native perceive gets it from `set_sight_lod` and measures to the bodies `load_positions` packed; a library without those methods keeps its plain `SIGHT_REUSE`.

Adoption (audited 2026-11-11): only game-fatal-contact runs `GSBotThinkTier`. The tiers apply above `above` = 16 players, and the other games that use gs-bot never reach that: mg-prop-hunt, game-murder-mystery (16-seat benches) and game-hide-n-seek (4) are small rounds; game-zombie-zone thins its stand-ins with its own rule (`bot_decide_every_far`, `stand_in_far`); game-hungario and game-playlot drive no `GSBotAim` loop. A game that grows a 17+ player bot crowd adopts it as FC does: `period()` per bot, `until_beat()` for the coast, the body moved every tick unless it opts into body tiers.

## Hiding and searching

Not every game's bots fight. A hiding game's bots need to know where people hide and where people look, and those are questions about the map, not about a target. Three helpers answer them, pure like the brain (everything comes in as arguments) and usable by any hiding game:

- **`GSBotNav`**: a navigation mesh baked with the engine's `NavigationServer3D` from the colliders under a node, on its own navigation map, after the map is built in code. A game passes the bodies that never move, because a door is a static body too and a door baked shut is a doorway the mesh does not cross. Its iterations are synchronous (`map_set_use_async_iterations` off, then `map_force_update`), so it answers on the tick it was baked: with asynchronous iterations a path asked for straight after the bake came back empty, and the tick it became ready depended on how the frames fell, so a seeded round played differently on every run. Random points are drawn over the polygons by area from the caller's `GSRandomStream`, never the engine's own. `bake_in_background` parses on the main thread (it must, and it is milliseconds), bakes on a worker with `bake_from_source_geometry_data_async`, and takes the mesh in on the main thread when it lands, calling back with `bake`'s result; `path` answers empty and `is_baking` is true until then, and a bake that lands after `clear` or a newer bake is dropped. It exists for game-fatal-contact's imported surf maps, 20 to 50 thousand collision vertices that took 2 to 3 s to bake against a map change of a tenth of a second. The mesh arriving when the machine finishes it is the determinism `bake` keeps, so a game that replays a seeded round from its paths uses `bake`. Without threads it is `bake`.
- **Tiled bake** (API level 31): Godot refuses a bake over 30 million cells while `navigation/baking/use_crash_prevention_checks` is on, and a wider cell is no answer (rp_southside at one baked nothing). The agent key `tile` (metres) is 0 by default = auto: a map that fits bakes as one grid exactly as before, a map over the limit bakes in 128 m tiles that are joined into one mesh (seam vertices welded, seam edges split), so a path crosses the seams. A positive `tile` always tiles at that size; a negative size, one under four borders, or one the engine would refuse is a failed `GSResult` with the reason, never clamped. A tiled bake caches in its own `.tile<mm>.nav.res` file. `tiles_used`, `tile_used` and `describe()` say what ran. The logic is `GSBotNavTiles`.
- **Edge-merge cell** (API level 33): a map from `map_create` merges polygon edges on a grid of 0.1 mesh cells whatever `navigation/3d/merge_rasterizer_cell_scale` says (the setting only reaches the World3D's own map), so two distinct edges within a tenth of a cell of each other count as one and the engine reports an edge error. The agent key `merge_scale` sets that share for GSBotNav's map (0.01 to 0.1, the engine's own range; 0 by default keeps 0.1; outside the range fails, never clamped). On gm_valley (25 tiles, 116673 polygons) 0.01 took the errors from 128 to 114; the 114 left are edges three or four baked polygons share by vertex index, which no merge cell can separate. They come from Recast inside a tile, not from `_stitch`: on the gm_valley source colliders of the annotator benchmark (41000 to 45000 polygons) baked in tiles of 40, 60 and 100 m the edges with three or more polygons number 5, 12 and 23 (none a zero-area triangle, most sloped, at ledges and steps where stacked walkable spans meet), so they grow with the tile while the seams, which grow as it shrinks, are not their source; a smaller `tile` is the lever, `merge_scale` is not; a wider tile border (6 cells, not 3) left them at 114 and took 0.1 to 136. `merge_scale_used` and `describe()` say what ran.
- **Bake cache** (opt-in): set `GSBotNav.cache_dir` (e.g. `user://nav_cache`) and `cache_id` (the map id) before `bake` or `bake_in_background`. The parse still runs; its triangles, the agent sizes and `avoid` are hashed (SHA-256), and a file for that id with the same digest supplies the mesh instead of the bake. A different digest rebakes and replaces the file. `last_bake_cached` says which happened; a failed write is a WARN and the bake stands. Both empty (the default) is off.
- **`GSBotHiding`**: a place is good when few of the map's sight lines reach it. `survey` asks the game's line of sight from a sample of watchers (points across the floor at a standing eye) to each candidate place (at a crouched head) once per map, and keeps the share that see it. `choose` scores down places near ones other hiders took (a hider caught becomes a seeker where it stands, next to anybody hidden near it) and near where seekers start, and looks further down the list the less the bot knows the map (`bot_map_knowledge`). `flee_spot` is somewhere out of a given seeker's sight, never past it.
- **`GSBotSearch`**: a seeker's memory of the places. A place is crossed off only when the seeker has had it in view; a sound puts the places near it back first; another seeker's target is scored down so two seekers split a house. It never learns where anybody is from anything but its own eyes and ears.

game-hide-n-seek's `examples/headless_bots` holds the result to bands over whole rounds; its numbers are in that game's `docs/design.md`.

## Links from a map's own entities

`GSBotLinks.read(world)` takes a built map world (gs-map's, by duck typing) and returns plain data: the teleports a runner can fire now, the hurt volumes that kill, and the movers that open by touch. `carve(nav)` puts the kill boxes into `GSBotNav.avoid` before a bake, so a path ends short of them instead of through them. `join(nav)` adds each teleport as an edge with an id at or above `TELEPORT_ID`, so a path crosses it and nothing is ridden. A volume that is disabled, filtered or not for clients is counted in `skipped` and left out; a teleport a button or trigger enables later is kept in `later`, and the buttons and triggers that lead to it (found by walking the output links backwards) in `gadgets`. `next_gadget` / `next_teleport` name the next errand, `refresh` joins a teleport once its entity is live, and a teleport box that lies off the mesh is joined through the floor above or below it (`off_mesh`). Walking to a gadget, holding there and firing it is the runner's job (mg-wipeout's `WoIoBot`). `doors_touched` names the touch doors a body overlaps so the caller can fire them.

## GSBotLinks usage

```gdscript
var links := GSBotLinks.read(map_world)
links.carve(nav)                          # before the bake: kill volumes are cut out
nav.bake_in_background(root, agent, 0, statics)
# once nav.is_ready():
links.join(nav)                           # teleports become one-way edges
# every so often: links.refresh(nav)      # teleports a button has enabled since
var g := links.next_gadget(nav, feet, done)  # a button or trigger to go and press first
for index in links.doors_touched(feet, 0.35, 1.8):  # each step: doors a body is walking into
    map_world.io.touch(index, body)
```

A teleport is added with `GSBotNav.add_ride` so a path crosses it, but nothing is ridden: the bot stands in the box and the map moves it. A volume that is disabled, filtered or not for clients is left out (and counted); one a button enables later is not known, so the path stops short of it.

Ladders. A ladder box from `world.ladder_boxes()` becomes a one-way ride (`GSBotLinks.LADDER_ID`) from a mesh point at its foot to one at its top, when the top rises at least a metre. The brain, on reaching the foot, faces the box and pushes forward (the controller's ladder mode does the climbing), then walks off toward the top point. It needs `GSBotWorld.ladder_fn = links.ladder_of`; a game that leaves it unset sees the ride as a plain one and the bot stalls at the foot.

## GSBotNav usage

```gdscript
var nav := GSBotNav.new()
var baked := nav.bake(map_node, {"radius": 0.35, "height": 0.9, "climb": 0.42})
var path := nav.path(bot_feet, goal)          # PackedVector3Array, empty when unreachable
var spot := nav.random_point(stream)
```

The family's maps are built in code, so the mesh is baked from the static colliders with the engine's `NavigationServer3D` on the spot, on a map of its own so a game's navigation is never disturbed. The radius rounds up to whole cells of `GSBotNav.CELL` (0.175 m), so a body whose radius is not a multiple passes `cell` (and `cell_height`) in the agent dictionary: a 0.4064 m radius bakes as 0.525 m at the default and is shut out of a 1.2 m door that `"cell": 0.1355` (0.4065 m) leaves open. The cell is part of the cache digest and sets the navigation map's cell size (API level 23). `random_point` weights the mesh's polygons by area so a seeded game picks the same hiding spots every run.
