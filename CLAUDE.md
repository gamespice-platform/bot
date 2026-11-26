# GameSpice Bot

**Player bots.** A brain that decides what a bot would press each tick (view, movement, trigger, crouch, jump, throw) as the content of the commands a client sends; difficulty presets that are bundles of about thirty individual settings, each a cvar; a name pool; and a roster that adds or removes bots to reach a count.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to bots. The reasoning is in [docs/](docs/README.md).

**Depends on GameSpice Core alone.** It names no other addon: GameSpice Server's cvars, GameSpice Console's console, GameSpice Player Controller's and GameSpice Weapon's commands are all reached by duck typing, so a game with none of them can still use it. Keep it that way.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | why a separate addon, what the brain may know, the fight, the view, determinism |
| [docs/surfing.md](docs/surfing.md) | anything in `runtime/surf/`, ride edges, `GSBotIntent.ride` |
| [docs/demonstration-recorder.md](docs/demonstration-recorder.md) | recording players for bots to learn from; the recorder itself is the addon [GameSpice Bot Record](../gs-bot-record/CLAUDE.md), the ride harvest and `GSBotDemoHeatmap`, `GSBotAimStats` and `GSBotDemoExport` here are built |
| [docs/presets.md](docs/presets.md) | changing a preset's number or adding a setting; what each preset is meant to be, and the measured numbers |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/gs_bot/core/gs_bot_profile.gd` | `GSBotProfile`: every setting, `SPEC` (one row per setting: range, four presets, help) |
| `addons/gs_bot/core/gs_bot_settings.gd` | `GSBotSettings`: the live values of one game, `bot_difficulty`, overrides, `bind_cvars` (server), `bind_console` (solo) |
| `addons/gs_bot/core/gs_bot_contact.gd`, `gs_bot_intent.gd` | what the brain reads (a body) and returns (what it would press) |
| `addons/gs_bot/core/gs_bot_names.gd` | `GSBotNames`: the name pool |
| `addons/gs_bot/core/gs_bot_persona.gd`, `runtime/gs_bot_persona_pool.gd` | `GSBotPersona` (profile kind `bot`: a hunt/loot/hold/support/scout mix, a pool weight, a difficulty, skill override, relative `scale` and per-bot `spread`; `derive_into` writes one bot's profile; `pick` never returns idle) and `GSBotPersonaPool` (the weighted draw per bot or an even `deal`, a per-server `id:weight` override, built from a GameSpice Profile set by duck typing) |
| `addons/gs_bot/runtime/gs_bot_world.gd` | `GSBotWorld`: all a brain may know (bodies, line of sight, waypoints, sounds) |
| `addons/gs_bot/runtime/gs_bot_aim.gd` | `GSBotAim`: the view, the aim error, the reaction and the trigger; the brain's, and a game with its own decisions uses it alone |
| `addons/gs_bot/runtime/gs_bot_brain.gd` | `GSBotBrain`: perceive, then fight, search, listen or roam |
| `addons/gs_bot/runtime/gs_bot_aim_stats.gd`, `tools/aim_suggest.gd` | `GSBotAimStats`: `engage` episodes folded into percentile sketches (cheat floor, `include_fn`), `suggest` onto `GSBotProfile.SPEC`; the tool prints the suggested table from a JSON store for a person to review |
| `addons/gs_bot/runtime/gs_bot_demo_export.gd`, `tools/demo_export.gd` | `GSBotDemoExport`: verified episodes of one schema to `manifest.json` (format `gsbot-bc` version 1) and `shard_N.f32` (raw little-endian float32 rows, observation then action), split train/held-out by episode per map version; `load_manifest` and `read_shard` check an untrusted directory (name pattern, sizes, hashes, finite values); [format](docs/demonstration-recorder.md) |
| `addons/gs_bot/runtime/gs_bot_mlp.gd` | `GSBotMlp`: the behaviour-cloning net. `load_file` reads `<stem>.gsmlp` (JSON header, format `gsbot-mlp` version 1) and `<stem>.f32` (float32 weights then biases per layer) as untrusted (size limits, SHA-256, finite floats, shape and schema checks); `forward` is deterministic and allocates nothing; `encode` writes the pair; [format](docs/demonstration-recorder.md) |
| `addons/gs_bot/runtime/gs_bot_eval_gate.gd`, `tools/demo_eval.gd` | `GSBotEvalGate`: replays the export manifest's held-out starts on a duck-typed host (`eval_start/observe/baseline/step/done/score`), a `GSBotMlp` against the baseline, `seeds` seeded perturbations; per map the paired gain must beat `max(min_margin, spread_k * stdev across seeds)`; success only when every map passes, `report` (`policy_on` = maps where the policy may default on) either way, `report_text()` is the file to commit beside the weights; the tool takes a host script |
| `addons/gs_bot/runtime/gs_bot_policy.gd` | `GSBotPolicy`: a `GSBotMlp` on `GSBotBrain.policy`, off unless `bot_policy` (0 in every preset, a share of bots) is above 0 AND the gate report passed AND lists the map (`allow_from_report`, `map_key`); the action fields `move`, `look` (held to `bot_turn_rate`), `fire` (only with a target in sight), `crouch`, `jump`, `walk`, `use`, `throw` are read by name from the host schema; [design](docs/demonstration-recorder.md#FC-host-for-the-gate-and-the-policy-design) |
| `addons/gs_bot/runtime/gs_bot_objective.gd`, `gs_bot_goal.gd` | `GSBotObjective` (on `GSBotWorld.objective`: the flags or the hill (`set_point`) the game writes each tick, team roles by `bot_role_defend/attack/support` and a persona's `role_bias`) and `GSBotGoal` (per brain: capture, return, intercept, grab, escort, hold, defend, and around a hill; `bot_objective_focus`, `bot_defend_radius`) |
| `addons/gs_bot/runtime/gs_bot_pickup.gd` | `GSBotPickup`: a quiet bot fetches a better weapon lying about with the use key (`bot_pickup_weapons`, `bot_pickup_range`); [design](docs/design.md) |
| `addons/gs_bot/runtime/gs_bot_style.gd` | `GSBotStyle`: per-weapon-class play styles (sniper cover/peek/vantage, shotgun rush, rifle strafe...), weighted random per bot and life; `bot_styles`, `bot_style_variety`, `bot_style_file`, `bot_style_weights`; [design](docs/design.md) |
| `addons/gs_bot/runtime/gs_bot_arms.gd` | `GSBotArms`: damage-per-second weapon rating, `loadout_of(arsenal)` for `GSBotContact.loadout`, `wire(world, drops_source, arsenal_source)` for `drops_fn`; duck typed over GameSpice Weapon's arsenal and drops, so a game wires pickup in two lines |
| `addons/gs_bot/runtime/gs_bot_loadout.gd` | `GSBotLoadout` (API 48): one player's loadout kept between ticks; `of(arsenal, rater)` rebuilds only on gs-weapon's `weapons_revision()` (API 59) and patches the ammo fractions in place; `incremental` (fallback) and `verify`/`misses` (parity) statics |
| `addons/gs_bot/runtime/gs_bot_tricks.gd` | `GSBotTricks`: slide, slide-jump, wall run, wall jump, cover duck and the air-jump, by scenario and `bot_slide`, `bot_wall_run`, `bot_air_jump`, `bot_trick_chain`, `bot_trick_delay`, `bot_cover_crouch`; [design](docs/design.md#movement-tricks) |
| `addons/gs_bot/runtime/gs_bot_roster.gd` | `GSBotRoster`: from the bots there are to the number wanted, named |
| `addons/gs_bot/runtime/gs_bot_nav.gd`, `gs_bot_hiding.gd`, `gs_bot_search.gd` | for hiding games: a navigation mesh baked from a map's colliders; places scored by sight lines and picked apart; a seeker's memory of the places |
| `addons/gs_bot/runtime/gs_bot_links.gd` | `GSBotLinks`: a converted map's teleports (one-way nav edges), lethal hurt volumes (carved out of the bake through `GSBotNav.avoid`) touch doors and the buttons/triggers that enable a disabled teleport (`gadgets`, `next_gadget`), read by duck typing from the map world; `join_step` runs `join` over several frames with `GSBotNav.held` keeping the nav unready until done; `join_step` keeps to its deadline or `slice_usec` (0 unlimited): the islands, polygon grid and edge sides it reads are built a slice at a time by `gs_bot_nav_prep.gd`, natively through gs-sim's `GSSimNavJoin` unless `GSBotNav.native_join` is off |
| `addons/gs_bot/runtime/gs_bot_unstick.gd` | `GSBotUnstick`: a bot that pushes and gets nowhere for a second escalates (re-plan and hop, crouch-hop and side-step, then a walk toward `GSBotWorld.walkable_near`, set through `walkable_fn`); it cannot cross a gap between nav islands, so a game also joins them with `GSBotLinks.join` (drops and hops); `GSBotNav.find_stitches` (id `GSBotLinks.STITCH_ID`, 6000000, not a ladder) pairs neighbouring islands only within a jump's reach (rise <= 0.9 m, gap 3 m falling to 1.5 m at that rise) |
| `addons/gs_bot/runtime/surf/` | surf bots: `GSBotSurfCourse` (one ride), `GSBotSurfPlanner` (the search on the motor, the cache's repair rounds), `GSBotSurfPilot` (the run-time policy and veto), `GSBotSurfRide` (one bot riding one edge while it aims) |
| (GameSpice Bot Record) | the demonstration recorder, schema and stores were here until API level 6 and are now their own addon, `GSBotDemo*` names unchanged. GameSpice Bot reaches a store, schema or episode untyped (`Variant`), never by class name, so it compiles without it; the suite links `addons/gs_bot_record` |
| `addons/gs_bot/soak/` | `GSBotSoak` (headless soak runner, JSON report, pass/fail reasons) and `GSBotSoakConfig` (thresholds); [docs/soak.md](docs/soak.md); suite `examples/soak_selftest.tscn` |
| `addons/gs_bot/runtime/gs_bot_nav_tiles.gd` | `GSBotNavTiles`: a bake over the engine's 30M-cell limit cut into tiles and joined into one mesh (agent key `tile`, 0 auto); `GSBotNav` owns one |
| `examples/bot_selftest.tscn` | the suite: presets, cvars, names, roster, senses, turn rate, reaction and aim measured, duels, hiding, searching, a baked path, a surf ride on a toy simulator, a ride edge, the demonstration recorder |

## Running and testing

- Link `addons/gs_core` from its repo once ([development setup](../../docs/development-setup.md)), then the family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)) and `timeout 180 godot --headless --path . res://examples/bot_selftest.tscn`.
- **A change to the brain or a preset is not done until game-fatal-contact's `headless_bots` passes**: it plays every preset in the real game and holds each to a K/D band, no blind shot and no turn above `bot_turn_rate`. Then the other games that use it (game-zombie-zone, mg-prop-hunt). [presets](docs/presets.md#measured)
- **Look at it.** No suite reaches whether a bot looks human: game-fatal-contact's `tools/render_bots.sh [preset]` photographs one from over its shoulder and logs what it was doing. [presets](docs/presets.md#measured)

## Rules that bite

- The brain is pure: it reads a `GSBotContact` and a `GSBotWorld` and returns a `GSBotIntent`. It moves nothing and holds no node. [design](docs/design.md#the-brain-is-pure)
- It knows of a body only through sight (view cone, sight range, the world's line of sight, unless `bot_through_walls`) or a sound. Never hand it a position it could not have seen. [design](docs/design.md#what-a-bot-may-know)
- `through_walls` is 0 in every preset and exists for tests only.
- A setting is a row of `GSBotProfile.SPEC` AND an `@export var` of the same name, with medium's value as its default; the suite checks every row names a property and a new profile equals medium. [presets](docs/presets.md#adding-a-setting)
- Every field must be read by the brain; a setting nothing reads is decoration. [presets](docs/presets.md#adding-a-setting)
- An override outlives a preset change; the cvars always hold the value in use. Waiting config values are all read before the preset is applied. [design](docs/design.md#presets-and-overrides)
- Settings live on the game as metadata (`GSBotSettings.of(node)`), never in `GSRegistry`: two servers in one process. [design](docs/design.md#presets-and-overrides)
- A cvar validator is a static method, never a lambda: a lambda's script can be gone before the console at teardown (GameSpice Server's `GSBotQuota` found it).
- Sounds are heard by sequence number, never by time. [history](docs/history.md)
- A target killed in view is forgotten, not searched for; a sound or a lost target the bot is not going after holds it for `GLANCE` (1.2 s), not its whole memory. [design](docs/design.md#the-fight)
- A caller of `GSBotAim` engages every tick it sees its target; a gap over 0.25 s is a lost target (a re-sight within 1.5 s reacts in half the time), over that a new engagement. [design](docs/design.md#the-fight)
- Randomness is the bot's own `GSRandomStream` (seeded from its id), never `randf`; the clock is the caller's `now`. [design](docs/design.md#determinism)
- Nightmare's reaction stays above 0.1 s and its aim floor above 0. [presets](docs/presets.md#what-each-preset-is)
- `GSBotNav.bake` gets the bodies that never move (a door baked shut is a wall on the mesh) and runs synchronous iterations, so it answers on the tick it baked and a seeded round replays the same. [design](docs/design.md#hiding-and-searching)
- `GSBotNav.bake_in_background` is for a map too big to bake in a tick (seconds); it gives up that determinism, and is `bake` without threads. [design](docs/design.md#hiding-and-searching)
- `GSBotSearch` crosses a place off only when the seeker has had it in view; nothing tells it where a hider is. [design](docs/design.md#hiding-and-searching)
- The surf simulator is duck typed (GameSpice Player Controller's `GSFpsSimulator`); `runtime/surf/` names no other addon. A cache is planned by a tool, never at map load, and replanned after a movement or collision change. [surfing](docs/surfing.md)
- A riding bot's legs are the pilot's, its view and trigger the brain's: `GSBotSurfRide.steer` writes the move for the intent's own yaw and never crouches or walks. [surfing](docs/surfing.md#riding-while-fighting)
- Never `(dict[k] as PackedInt32Array).append(x)`: the cast is a copy and the append is lost. [surfing](docs/surfing.md#traps)

## Where a game plugs in

| To change | Where |
| --- | --- |
| What a bot may know | `GSBotWorld`: subclass, or set `contacts_fn`, `line_of_sight_fn`, `waypoints_fn`, `projectile_speed_fn`; `extra_waypoints` (e.g. `GSBotNav.spread_points`) adds mesh-derived places beyond spawns |
| What it hears | `GSBotWorld.emit_sound(position, loudness, source, now)` from the game's shots and steps |
| That it was hit | `GSBotBrain.hurt(from, now)` |
| How it plays | `bot_difficulty` and the `bot_*` settings, or a `GSBotSettings` of a game's own per bot |
| How a bot with a game's own decisions aims and shoots | `GSBotAim`: `view_from`, `engage` every tick it sees the target, `track` or `look_at_point`, `trigger`, `hurt` |
| Its commands | `GSBotIntent.write_move` / `write_fire` (a game's throw button by constant name) |
| Its name | `GSBotNames.pick`, or `GSBotRoster.pool` / `prefix` |
| Hiding and seeking | `GSBotNav` (paths), `GSBotHiding.survey` / `choose` / `flee_spot`, `GSBotSearch` |
| Surfing | `GSBotSurfCourse` (a game's course: goals, pits, or override `event_at`), `GSBotSurfPlanner.build` in a tool, `GSBotNav.add_ride` + `GSBotWorld.route_detail_fn`, `GSBotSurfRide` per bot |
| How many | GameSpice Server's `GSBotQuota` for the number, `GSBotRoster.keep` to reach it; `solo_wanted` for one person |

Deliberately not here: pathfinding inside the brain (it walks straight at waypoints and hops when stuck; a game with a graph hands it nearer waypoints, and a hiding game paths with `GSBotNav` itself), weapon choice, game-specific roles (hide, seek, race, survive; each game's own brain builds on this one), chat.
