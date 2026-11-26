This is the plan for moving a game's whole bot think into gs-sim, so that the main thread hands over tables and gets tables back. It covers what is measured, the tables, the order of the port and its gates. The first slice is the contact table (API 37). The web build stays on script throughout, because no extension loads there.

## Where the time goes

Fatal Contact sim host on PH: `perf_bench.sh --box ph --headless -- --sim-host 1 --bots 31 --mode ffa --seconds 60 --sim_sections 2`, bot_threads 4, native brain and loop. Times are ms per tick.

| Section | ms | Thread |
| --- | --- | --- |
| `srv_bots` | 4.9 to 5.2 | the whole bot step |
| `bot_brain` | 1.6 to 1.8 | wall time of the brains on 4 workers |
| `bot_refresh` | 0.96 | main: contacts, tiers, near cells |
| `br_contacts` | 0.78 | main: the contact loop (`brc_loadout` 0.20, `brc_weapon` 0.13) |
| `bot_after` / `ba_tail` | 0.48 / 0.4 | main: commands from intents |
| `bt_coast`, `bt_setup`, `bt_gate` | 0.36 to 0.44, 0.14 to 0.26, 0.18 | main: think_begin / think_finish glue |

About two thirds of `srv_bots` is serial main-thread GDScript around the brain, not the brain itself. A brain piece ported on the workers saves about its cost divided by 4 in wall time. Measured at 63 bots on one thread with the script brain, the pieces cost:

| Piece | ms at 63 bots, threads 0 |
| --- | --- |
| `bb_perceive` | 1.6 (native since API 33) |
| `bb_act` | 1.4 to 1.9 (fight step native since API 30) |
| `bb_tricks` | 0.55 |
| `bb_hear` | 0.3 to 0.4 |
| `bb_setup` | 0.25 |
| `bb_unstick`, `bb_goal` | 0.08 each |

At 31 bots on 4 workers with `--brain-us` (API 40 times brains on workers too), in thread-ms per tick summed over the workers: `bb_act` 0.5 to 0.9, spread over the steering script around the native fight step with no single hot call; `bb_perceive` about 0.45; `bb_hear` about 0.3, of which the world's `bq_sounds` is 0.07 and the rest the loop over the sound dictionaries. `bb_hear` is native from API 41.

Noise on `srv_bots` between two runs on the same box is about 0.27 ms. A slice smaller than that is judged by its own section and by not being slower, never by `srv_bots` alone.

## The contact table (API 37)

The table is one row per body, in the order `GSBotWorld.contacts()` returns them. It has seven columns:

| # | Column | Type | Value |
| --- | --- | --- | --- |
| 0 | sensed | `Array` of `GSBotContact` | the bodies, so a scan index maps back to a contact |
| 1 | ids | `PackedInt64Array` | `id` |
| 2 | points | `PackedVector3Array` | `position + Vector3.UP * aim_height` (`aim_point()`) |
| 3 | teams | `PackedInt32Array` | `team` |
| 4 | alive | `PackedByteArray` | 1 or 0 |
| 5 | eyes | `PackedVector3Array` | `position + Vector3.UP * eye_height` (`eye()`) |
| 6 | positions | `PackedVector3Array` | `position` |

The calls:

- `GSBotWorld.set_rows(version, sensed, ids, points, teams, alive, eyes, positions)`. The game hands the table it filled in its own contact loop, for one `contacts_version`. `senses()` then loads the native scan from it and does not walk the bodies a second time on the main thread.
- `GSBotWorld.rows_of(all)` builds the same table from contacts. It is what `senses()` uses when no table was handed for this version, and what a check compares a game's table against.
- `GSBotWorld.rows_enabled` (static, on by default) can turn the handed table off. In a game the cvar `bot_native_think` (0 or 1) does this. Fatal Contact's cvar instead stops handing the table, so the game also works on a gs-bot older than 37.

A handed table must equal `rows_of` of the same bodies to the bit. Write the aim point and eye in the same expression form as `GSBotContact`. A table handed for an older version is ignored. Do not change the arrays after handing them: the scan keeps the last arrays it loaded.

The world's own members for this are named `_handed_rows`, `_handed_version` and `_load_rows`. A game's `GSBotWorld` subclass cannot declare a member its parent has (Fatal Contact's world had a `_rows`, and the first try did not parse), so new private members of `GSBotWorld` take names a game is unlikely to use.

## The intent table (planned)

The brain's answer is one row per bot, in the order of the bots handed in. It holds the `GSBotIntent` fields as packed columns:

| Column | Type |
| --- | --- |
| yaw, pitch | `PackedFloat32Array` (f64 in GDScript today; the native side must round exactly as the script does, so they stay `PackedFloat64Array` until parity says otherwise) |
| move | `PackedVector2Array` |
| buttons | `PackedInt32Array` bit set: fire 1, crouch 2, jump 4, walk 8, air_jump 16, throw 32, use 64, stranded 128 |
| ride, target_id | `PackedInt64Array` |
| state | `PackedInt32Array` index into a state name table handed once |

`GSSimBotMind.fight` already returns a flat row (r[0..14]), which is the precedent. The game's finish step (Fatal Contact's `think_finish`: recoil compensation, coast, the command write) then reads columns and does not touch `GSBotIntent` objects.

## Port order

Cheapest win first. Each step lands alone with its parity gate and a PH bench.

| # | Slice | Expected gain at 31 bots | Measured by |
| --- | --- | --- | --- |
| 1 | Contact table (API 37, done): the game fills the columns in its loop | 0.02 to 0.05 ms main (one walk of 32 contacts and 3 method calls each) | `br_contacts` plus `bot_brain`, `srv_bots` not slower |
| 2 | Finish glue: cache `GSWeaponRecoilRules.seed_for` per definition (it loops over the id's bytes every shot), reuse the coast command instead of two `duplicate_command` calls and a new array | 0.2 to 0.3 ms main (`bt_coast` 0.4, part of `ba_tail`) | `bt_coast`, `ba_tail` |
| 3 | One native finish over the intent table (recoil, coast, write) | a further 0.2 to 0.4 ms main | `bot_after`, `srv_bots` |
| 4 | Contacts from state columns once fc-server-packed-1 gives `GSFpsMotorBatch` columns: refresh copies columns, with no per-player GDScript | 0.4 to 0.6 ms main (`br_contacts` without loadout/weapon) | `bot_refresh` |
| 5 | Brain pieces into GSSimBotMind: tricks (API 39, done: `GSSimBotMind.tricks`), hear (API 41, done: `GSSimBotMind.hear` over `GSBotWorld.sound_rows`, switch `GSBotBrain.native_hear`), goal/style, unstick | 1.0 ms at threads 0, about 0.25 wall on 4 workers | `bb_*` with `bot_threads 0`, then `bot_brain` |
| 6 | Whole native think: one call per tick (begin, think and finish for every bot) over contact and intent tables, on gs-sim's own threads | the rest of `srv_bots` glue, target under 2 ms | `srv_bots` |

Measurement: PH, `--headless`, the command above. Run before and after on the same box, at least two runs each, and read `srv_bots` and the slice's own sections. Pieces in step 5 are timed with `--bot_threads 0`, where the workers do not hide their cost.

## Parity

`examples/native_parity.tscn` is the whole-intent harness. Each round gives the same seed and world to a native brain on the main thread, a script brain, and a native brain on a worker. It runs 12 rounds of 14 s at 30 Hz with 6 bystanders. Every tick it compares the intent and the aim's private state to the bit, per bot. From API 37, odd rounds hand one native side a contact table filled field by field, as a game does, and check it against `rows_of`. Every slice above adds its side to this harness before it lands. A slice that cannot match to the bit does not ship.

In a game, the suite with bots (Fatal Contact's `headless_bots`) runs with the cvar both ways.

## The cvar

`bot_native_think` is 1 by default. It turns on what has been ported of the native think, which today is the contact table. At 0, or on a gs-bot or gs-sim without the slice, the script path runs as before. The web build never loads gs-sim, so it always takes the script path. Steps 3 and 6 put their native calls behind the same cvar.

## Coordination

| Work | What it means here |
| --- | --- |
| gs-player-controller packed `GSFpsState` `_f` (API 36, landed) | the source of the positions, velocities and views that step 4 copies |
| fc-server-packed-1 (`GSFpsMotorBatch` columns, `GSSimControllerBatch.tick`, cvar `sv_native_controller`) | step 4 waits for it. The contact table then becomes a view of its columns plus aim and eye heights |
| `GSSimMotorBatch.run_cols` | the same column layout: positions as `PackedVector3Array`, ids as `PackedInt64Array`, so tables pass through without copies |
| gs-sim figure work | no overlap; it shares the rule that the pure crates hold the logic and gdext only binds |
| fc-bots-hard-turnrate-1 | changes the aim's turn rate inside GSSimBotMind and its script twin. Steps 5 and 6 rebase on it, and parity covers both |
