# CLAUDE.md — The Dried Sea

Top-down 2D survival-crafting game (Godot 4), "Soul Build" phase. The specs are
law: GAME-SPEC.md (systems), WORLD-SPEC.md (world/canon), docs/ARCHITECTURE.md
(code design). Read the relevant spec section before implementing a system.

## The portability law (never violate)
All game content and tuning lives in `data/content/` as JSON validated by
`data/schemas/`. Engine code READS data; it never hardcodes content. If you're
typing a god's name, an item stat, a drift rate, or quest text into GDScript,
stop — it belongs in data. A future Unreal build must be able to consume
`data/` unchanged.

## Commands
- `node tools/validate.mjs` — run after EVERY content edit; must pass clean.
- `node tools/economy-model.mjs` — run after ANY tuning/economy.json or invocation
  vigorCost change; spec bands are asserted (exit 1 = your tuning broke the design).
- `git commit` style: `feat(sim): ...`, `feat(data): ...`, `fix(game): ...`;
  small commits, one system per commit.
- Godot 4.7 is installed via winget WITHOUT a PATH alias. The exe:
  `$LOCALAPPDATA/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7-stable_win64_console.exe`
- Run sim tests (after any sim/ or data/ change):
  `"$GODOT" --headless --path game --script res://tests/run_tests.gd`
- If tests fail with "Identifier not declared" parse errors after adding a
  class_name: run `"$GODOT" --headless --path game --import` once to rebuild
  the global class cache, then re-run.
- GDScript gotcha: `:=` cannot infer from Dictionary member access (Variant) —
  type it explicitly (`var x: float = float(dict.key)`).
- GDScript gotcha: lambdas capture locals BY VALUE — assigning a bool/int inside
  a signal lambda does nothing outside it. Capture through an Array
  (`var seen: Array[bool] = [false]` … `seen[0] = true`) or mutate a reference type.

## Conventions
- IDs: kebab-case, globally unique, never renamed once committed (saves and
  cross-refs depend on them). `god-halor`, `work-salt-wheel`, `calling-widows-lantern`.
- All display text lives in data under `name`/`text` fields (localization-ready;
  EA is English-only but never bake strings into code).
- Working names: anything flagged `"workingName": true` is a placeholder Jeff
  hasn't taste-tested. Don't propagate working names into new prose as if final.
- Schema changes: bump `$comment` version in the schema, update ALL content to
  match in the same commit, note the migration in docs/ARCHITECTURE.md §Save/Migrations.
- GDScript layer style (M0+): sim logic in `game/sim/` is pure and headless-testable
  (no Node dependencies where avoidable); presentation in `game/scenes/` stays thin.
- Server-authoritative always: sim state changes happen host-side; clients render
  and request. No client-side state mutation, even in single-player code paths.

## Design laws (recurring — enforce in review)
- **Spells drain, works feed.** Every invocation costs its god Vigor; every
  in-use work trickles favor to its god. Idle works feed nothing.
- **Anti-shallow laws for Callings** (all five, WORLD-SPEC): a name and a wound;
  a turn; an echo; verbs wear clothes; it can look you in the eye. Law #5 = Jeff
  reads and approves every calling (`status: "curated"` is set by him, never by AI).
- **Punish paranoia, never vigilance.** Evidence-based justice is free;
  evidence-free punishment compounds.
- **Rare because the journey is long, never lottery.** No sub-1% drops anywhere.
- **The game never requires a grim work.** Every dark buildable has a
  slower, kinder alternative.
- Morality is read from ledgers (Vigor taken/returned, remnants, shepherding,
  Peoples), never from a dialogue wheel or karma meter.

## Workflow
- Content volume (traits, callings drafts, items, recipes): cheap-model work
  against schemas; always end with validate.mjs. Jeff curates.
- System design changes: update the spec FIRST, then implement.
- MODEL-GUIDE.md maps task → model. Escalate to a stronger model after the
  SECOND failed attempt at the same problem, not the fifth.
- Never mark a calling `curated`, change canon (WORLD-SPEC), or bump a save
  version without Jeff's explicit sign-off.

## Gemini art pipeline (proven 2026-07-14)
Hero assets come from Gemini (Jeff's account, via Chrome MCP or by hand):
prompt for "16-bit pixel art on a PURE WHITE background, no text, no ground
shadow, single subject" with palette hexes from docs/STYLE-BIBLE.md, download
the PNG, then:
  python tools/import_art.py <downloaded.png> <sprite_name> <target_height_px>
(flood-fill cut -> LANCZOS downscale -> accent-penalized palette quantize ->
despeckle -> game/assets/sprites/). SpriteKit picks it up by name automatically.
Regenerate programmatic sprites with tools/gen_sprites.py — note it OVERWRITES
by name; Gemini-sourced sprites win by not being in its SPRITES list (remove
name collisions there when upgrading a sprite to Gemini art).
