# Architecture — the Soul Build

*Authored 2026-07 (Fable pass). This is the durable spine: it outlives engines.
Layering, schemas, save/versioning, and authority rules apply verbatim to a
future Unreal build; only the Presentation column changes.*

## 1. The three layers

```
┌──────────────────────────────────────────────────────────────┐
│ PRESENTATION (game/scenes/)  — Godot nodes, tilemaps, UI,    │
│   audio, input. THIN. Renders sim state; sends intents.      │
├──────────────────────────────────────────────────────────────┤
│ SIMULATION  (game/sim/)      — pure GDScript, headless-      │
│   testable. All rules live here. Owns the authoritative      │
│   world state. Ticks on sim time, not frames.                │
├──────────────────────────────────────────────────────────────┤
│ DATA        (data/)          — engine-agnostic JSON.         │
│   Schemas are the contract. Content is the game.             │
└──────────────────────────────────────────────────────────────┘
```

Rules:
- Presentation may read sim state; it mutates nothing. It emits **intents**
  (`intent_build`, `intent_cast`, `intent_assign`) that the sim validates.
- Sim never touches Nodes/scenes. Any sim file must run under
  `godot --headless` in tests.
- Data loads once into a read-only `Registry` at boot (hot-reloadable in dev).
  Code never contains content (see CLAUDE.md portability law).

## 2. Sim systems map

One system per file; systems talk through the world state + an event bus,
never by calling each other's internals.

| System | Owns | Ticks |
|---|---|---|
| `time_system` | calendar, day/night, storm cycle & storm events | every sim-minute |
| `stats_system` | per-actor attributes (HP/stamina/hunger), effects | fast |
| `devotion_system` | per-player: attunement ranks, per-god Vigor, per-god favor; invocation casting; worship/rite progress | slow |
| `works_system` | placed buildables, in-use detection, favor trickle ("use is worship"), grim-work flags | slow |
| `village_system` | tribesmen roster: class, traits, hidden disposition, Keys, bloom, jobs/schedules, the Taken (yoke/warden coverage), expeditions | slow |
| `peoples_system` | Last Peoples settlements: Brink state, save/trade/exploit tracking incl. engineered-decline attribution | slow |
| `callings_system` | quest-graph runtime: per-player draws (weighted), step advancement, choices, echoes, Deep Calling world effects | event-driven |
| `verdict_system` | the four ledgers (gods, remnants, shepherd, peoples); lean computation; ending gates; NPC-traitor arc triggers | slow |
| `world_system` | biome bands, resource nodes, POIs, spawns | slow |
| `save_system` | serialization, versioning, migrations | on demand |
| `net_system` | host authority, replication of sim state, intent routing | frame |

**Tick design:** `SimClock` emits `fast` (each physics frame), `sim-minute`
(~1s real default), and `sim-day` signals. Disposition drift, favor trickle,
Brink decay, and Vigor recovery all run on `sim-minute` or coarser — the soul
of this game is slow variables; keep them out of the frame loop.

## 3. The data registry

- `Registry.load()` reads every file under `data/content/`, validates IDs are
  unique, resolves cross-references (fail loudly at boot, not at use).
- Content types (one schema each, `data/schemas/*.schema.json`):
  `god`, `work`, `item`, `recipe`, `trait`, `npc-class`, `calling`, `people`,
  `creature`, `biome`, plus `tuning/*` singletons (disposition, verdict, economy).
- `tools/validate.mjs` runs the same checks CLI-side plus the **design-law
  lints** (e.g., a calling missing a `turn` step or an `echo` fails validation —
  the anti-shallow laws are machine-checked where a machine can check them).

## 4. Per-player vs shared state (matters for co-op AND the Verdict)

**Per-player:** devotion ranks, per-god Vigor & favor, calling draws & progress,
ledger entries (deeds attribute to the acting player), invocation loadout.
**Shared (server-owned):** world, village & tribesmen, works, Peoples/Brink,
storm clock, god *world-strength* (the world-wide dimming a consumed remnant
causes — distinct from a player's personal standing).
**Private-by-design:** god-voice messages route only to their player. (The only
survivor of the cut player-betrayal system; cheap and it preserves dreams/whispers
as personal experiences.)

## 5. Save format & migrations

```json
{ "saveVersion": 3, "createdAtVersion": 1, "world": {...}, "players": {...} }
```
- One integer `saveVersion`, bumped on ANY breaking shape change (schema or sim
  state). `save_system` applies `migrations/` in order: pure functions
  `(saveDict) -> saveDict`, one file per version step, tested with a fixture
  save per version. Never edit a shipped migration.
- Content references in saves are by ID — another reason IDs are immutable.
- Migration log: (v1 → …) recorded here as they happen.

## 6. Networking (Godot high-level multiplayer)

- Listen server (host is authority) first; dedicated later. Target 2–8.
- All intents RPC to host; host mutates sim; state deltas replicate via
  `MultiplayerSynchronizer` for hot state and explicit RPCs for events.
- PvP is a server flag consumed by `stats_system` (damage between players)
  only — no other system branches on it.
- Single-player runs the identical host code path with a local loopback peer:
  one code path, always.

## 7. Testing

- `game/tests/` — headless sim tests (plain asserts, no framework dependency
  until one earns its place). Every sim system lands with tests for its tick
  math (drift rates, favor trickle, Vigor drain/recovery, Brink decay).
- Golden-economy test: a scripted 30-sim-day run asserting the big numbers
  (Vigor casts/day achievable, bloom vs Broken output ratio) stay inside spec
  ranges — the tuning laws from WORLD-SPEC as executable checks.
- `tools/validate.mjs` in pre-commit (advisory) and CI (blocking, once CI exists).

## 8. Unreal port note (for the future reader)

The port surface is exactly: Presentation (scenes → UMG/Niagara/world), sim
GDScript → C++ (systems map 1:1; keep this file's names), net (Godot RPC →
UE replication; same authority rules). `data/` ships unchanged. If the sim
layer stayed pure, the port is mechanical translation, not redesign.
