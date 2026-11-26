extends RefCounted

## gs-bot's API level. The rule for bumping it is on [GSAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: GSBotProfile (presets as bundles of settings), GSBotSettings (bot_difficulty and the
#    bot_* cvars, server and solo), GSBotBrain, GSBotAim, GSBotWorld, GSBotContact, GSBotIntent,
#    GSBotNames, GSBotRoster.
# 2: GSBotNav (a navigation mesh baked from colliders), GSBotHiding (spots scored by sight
#    lines, picked apart), GSBotSearch (a seeker's memory of the places).
# 3: GSBotNav.bake_in_background, is_baking (a mesh baked on a worker thread).
# 4: surfing. GSBotSurfCourse, GSBotSurfPlanner, GSBotSurfPilot, GSBotSurfRide; ride edges:
#    GSBotNav.add_ride, rides, clear_rides, route (points and rides), islands, island_at,
#    polygon_at, on_island; GSBotWorld.route_detail_fn and route_detail; GSBotIntent.ride;
#    GSBotBrain.ride_ended; GSBotSurfCourse.unsupported_fn, toward_goal; GSBotSurfPlanner.trace.
# 5: the demonstration recorder. GSBotDemoSchema, GSBotDemoEpisode, GSBotDemoRecorder,
#    GSBotDemoConfig (bind_cvars), GSBotDemoStore, GSBotDemoStoreMemory.
# 6: the recorder (the level-5 GSBotDemo* classes) moved to the addon gs-bot-record with the same
#    names. Level 5 was never delivered to a game, so OLDEST stays 1: nothing built at 1 to 4 names
#    a recorder class. A game that records links gs-bot-record (its own requires entry).
# 7: GSBotNav.joined (whether a walk between two points can exist, from the islands and rides,
#    without a path query that errors between islands).
# 8: GSBotBrain.blind_for, is_blind (a flashed bot sees nothing for its seconds); GSBotWorld.add_sight_blocker,
#    remove_sight_blocker, prune_sight_blockers (smoke: line of sight through a sphere is refused).
# 9: ladders: GSBotLinks.ladders / ladder_of, GSBotWorld.ladder_fn (a game assigns links.ladder_of).
# 10: GSBotLinks.link_ladders (boxes and a nav in, links out; assign its ladder_of to ladder_fn).
# 11: GSBotClimb (one ladder ride as a step function; the brain uses it, a game steering its own stand-ins can too).
# 12: GSBotUnstick (no-progress detection and escalation, in the brain for every state); GSBotWorld.walkable_fn and walkable_near.
# 13: GSBotNav.spread_points and GSBotWorld.extra_waypoints (waypoints from the mesh); roaming bots hunt toward the nearest enemy.
# 14: GSBotThinkTier (think-rate tiers: which bots think every tick and which every few, for a crowd).
# 15: GSBotWorld.contacts_version, native_enabled, native_available, senses (the sight scan in gs-sim when loaded).
# 16: GSBotThinkTier.engaged_far_every, engaged_range, load_scale (fighting bots out of sight thin out; the tiers stretch under load).
# 17: GSBotBrain.target_first (a bot that sees its target tests it before scanning every body; same choice, a switch for comparing).
# 18: GSBotWorld.contact_of (the contact for an id out of this tick's list; a world that indexes its contacts overrides it, the brain asks it instead of walking the list).
# 19: GSBotObjective, GSBotGoal, GSBotWorld.objective, GSBotBrain.goal, GSBotPersona.role_bias; profile rows role_defend, role_attack, role_support, objective_focus, defend_radius (team jobs in a flag mode); GSBotObjective.set_point (the same jobs around a hill).
# 20: GSBotPersona.scale, spread, derive_into, shapes_skill; GSBotSettings.derived, sync; GSBotPersonaPool.deal, given; GSBotProfile.set_number, copy_from (each bot its own persona).
# 21: GSBotThinkTier.idle_view_every and period(..., idle) (an idle bot a person only sees thins out; idle defaults false, so callers that do not pass it are unchanged).
# 22: GSBotThinkTier.body_near_every, body_far_every, body_period, body_counts (body tiers: the game may tick an unseen near or far bot's motor every few ticks; off by default).
# 23: GSBotNav.bake / bake_in_background agent keys `cell` and `cell_height` (per-bake cell size, in the cache digest and the map's cell size; defaults CELL, CELL_HEIGHT unchanged).
# 24: GSBotThinkTier.body_above; body tiers on by default (body_near_every 2, body_far_every 4) above 24 players.
# 25: GSBotWorld.sight_far, sight_far_reuse (sight LOD: a far body not seen keeps that answer longer; off by default).
# 26: GSBotLinks.join_step, GSBotNav.held, begin_edges, step_edges (a map's drop, hop and stitch search over several frames, the nav held unready until done; join unchanged).
# 27: GSBotThinkTier.schedule, native, is_native (one think's period, beat and body period from one classification; gs-sim's GSSimThinkTier answers when loaded).
# 28: GSBotProfile.is_hard_max; set_field refuses under the minimum and over a fact-maximum, allows over a guide maximum with a warning (was a silent clamp).
# 29: GSBotWorld.sounds_into; GSBotBrain.phase_timers, PHASES, phase_us (a think's time per phase); GSBotPickup.NONE; profile row replan_every (0, every think, unchanged).
# 30: GSBotThinkTier.max_period reaches gs-sim's native tier (any value, 0 unlimited; a negative one is an error); a native library older than this runs the script tier for a non-default value.
# 31: GSBotNav bakes a map over the engine's 30 million cell limit in tiles joined into one mesh (agent key `tile`, metres, 0 auto; a bad size fails loudly); GSBotNavTiles; describe() reports tiles and tile.
# 32: Weapon play styles: GSBotStyle, a weighted table of styles per weapon class (sniper, marksman, rifle, smg, shotgun, pistol, heavy, launcher, melee, throw); GSBotContact weapon_class and magazine; cvars bot_styles, bot_style_file, bot_style_weights (0 styles is the generic bot to the bit); describe() reports style and style_phase.
# 33: GSBotNav sets its map's edge-merge cell (agent key `merge_scale`, a share of the mesh cell from 0.01 to 0.1, 0 the engine's default 0.1 that the project setting does not reach; outside the range fails loudly); merge_scale_used; describe() reports merge_scale.
# 34: GSBotBrain.par_ready (a brain about to think on a worker keeps its native mind, which perceives over a scan handle taken on the main thread; replaces leave_native for threaded callers).
# 35: GSBotWorld.sight_callable (what a native mind asks sight through, line_of_sight unless a game hands one answering the same; GSBotBrain asks it every native perceive).
# 36: GSBotClimb rides a ladder down as well as up (a `to` more than a metre under the feet: push in to grab, back out down, done at the foot).
# 37: GSBotWorld.set_rows hands the native sight scan the contact table a game filled in its own contact loop (rows_of builds it, rows_enabled switches it off); see docs/native-bot-brain.md.
# 38: GSBotLinks.slice_usec (a join_step with no deadline searches that long, 0 unlimited); GSBotNav.native_join (the join's edge passes through gs-sim's GSSimNavJoin when loaded, false keeps the script); the join's islands and polygon grid are built a slice at a time.
# 39: GSBotTricks.native_enabled (apply runs in gs-sim's GSSimBotMind.tricks when the brain has a mind and the library has it; the same choices to the bit) and apply's optional mind argument.
# 40: GSBotBrain.phase_us times brains on worker threads too: each brain has a GSBotClock, the caller of threaded thinks calls GSBotBrain.merge_phases(brains) on the main thread after the join; PHASES adds the world queries (bq_*) and GSBotBrain.phase_calls counts laps and queries. (39 is taken by nightly/fc-bots-native-2.)
# 41: GSBotBrain.native_hear (_hear's loop runs in gs-sim's GSSimBotMind.hear when the brain has a mind and the library has it; the same sounds and draws to the bit) and GSBotWorld.sound_rows (the sounds packed, SOUND_STRIDE each).
# 42: GSBotBrain.native_act (the roaming steer of _walk, _hold and _drift, look, glance, turn and legs, runs in gs-sim's GSSimBotMind.steer when the aim has a mind and the library has it; the same to the bit) and the act phase's parts in GSBotBrain.PHASES (ba_*, inside bb_act, timed with --brain-us).
const LEVEL := 42
const OLDEST := 1
