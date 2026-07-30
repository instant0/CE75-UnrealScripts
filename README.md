# UnrealEngine-75

Cheat Engine 7.5 Lua scripts for inspecting Unreal Engine 4/5 games.

**`UnrealEngine-75.LUA`** — generic UE core. Autorun in CE. Discovers GEngine, FName pool, property offsets, player chain. Adds an "Unreal Engine" menu for player properties and structure dissect.

**`Scripts/g1r/`** — Gothic 1 Remake plugin. Loaded on demand via `Load Game Plugin → Gothic 1 Remake`. Adds inventory snapshot, item classification, live tracking, and display name lookup.

See `docs/SPLIT-PLAN.md` for architecture. Research notes in `research/` and `Scripts/g1r/research/`.

Made with the assistance of Opencode BigPickle. 
