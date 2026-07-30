# UnrealEngine-75

Cheat Engine 7.5 Lua scripts for inspecting Unreal Engine 4/5 games.

**`UnrealEngine-75.LUA`** — generic UE core. Autorun in CE. Discovers GEngine, FName pool, property offsets, player chain via `UEngine_findCharacter`. Adds an "Unreal Engine" menu with player address list (grouped by category with safety tiers), structure dissect auto-naming for UE objects, and generic inventory property search.

**`Scripts/g1r/`** — Gothic 1 Remake plugin. Loaded on demand via `Load Game Plugin → Gothic 1 Remake`. Adds inventory snapshot (bag + equipped via 3 signal sources), item classification by `ItXX_` prefix, live tracking timer, real display name lookup (Alkimia loc map), and session checklist.

## Quick start

1. Attach CE to any UE4/UE5 process
2. Autorun `UnrealEngine-75.LUA` or paste into Lua Engine → Execute
3. Wait for "Unreal Engine" menu to appear (discovery runs in background)
4. Use `Add / Refresh Player` to inspect character properties
5. For G1R: `Load Game Plugin → Gothic 1 Remake`, then `Add / Refresh Inventory Items`

## Features

| Core (any UE game) | G1R Plugin |
|---|---|
| GEngine + FName pool discovery | Inventory chain walk (`Char+0x7B0`) |
| FProperty offset auto-discovery | Gothic `ItXX_` item classification |
| Player/Character chain walk | 3-source equipped item union |
| Player address list (sorted, tiered) | Real item names via Alkimia loc |
| Structure dissect auto-naming | Live tracking timer |
| Generic inventory property keyword scan | Display helper loading |

## Docs

- `docs/SPLIT-PLAN.md` — architecture, file layout, lifecycle
- `research/` — CE 7.5 API reference, crash postmortems, UX design notes
- `Scripts/g1r/research/` — G1R inventory chain, loc pipeline, equipped items analysis
