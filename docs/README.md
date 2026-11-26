# GameSpice Bot docs

| File | What it covers |
| --- | --- |
| [design.md](design.md) | why a separate addon; what a bot may know; the brain and its states; the view and the aim; presets and overrides; determinism; hiding and searching (`GSBotNav`, `GSBotHiding`, `GSBotSearch`) |
| [surfing.md](surfing.md) | bots that ride surf ramps: the search on the motor, the cache, the pilot and its veto, riding while fighting, ride edges in the mesh |
| [demonstration-recorder.md](demonstration-recorder.md) | design, not yet built: recording real players server-side (schema per game, adaptive rate, JSON or SQL store), surf rides verified on the motor, statistics for presets, behaviour cloning, privacy, the task breakdown |
| [native-bot-brain.md](native-bot-brain.md) | the plan for a native bot think: where the time goes, the contact table (API 37), the intent table, the port order, parity, the `bot_native_think` cvar |
| [presets.md](presets.md) | what each preset is meant to be, the measured numbers, how to change one or add a setting |
| [soak.md](soak.md) | the soak harness: a headless run of a game's bots that samples stuck, leaks, tick cost and kills and fails with reasons |
| [history.md](history.md) | bugs found building it, and how each looked |
