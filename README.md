# The Dried Sea (working title)

A survival-crafting game where the ocean left and the gods it powered are dying.
Valheim's loop · Soulmask's village · Conan's magic restraint · a deed-driven,
Baldur's-Gate-style verdict — held together by one original system: dying gods
you feed, or eat.

**Strategy: the Soul Build.** The game's differentiating systems are simulation +
data, so we build the soul first as a top-down 2D game (Godot 4), at 10× the
iteration speed of a 3D build. All content and tuning live as engine-agnostic
JSON (`data/`) so a future Unreal build consumes them unchanged. Shipping the 2D
game *as the game* is a legitimate outcome — decided at M2.

## Reading order
1. [GAME-SPEC.md](GAME-SPEC.md) — systems, priorities, milestones, risks
2. [WORLD-SPEC.md](WORLD-SPEC.md) — the Dried Sea: pantheon, biomes, peoples, the Verdict
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — code layers, data flow, save/net design
4. [MODEL-GUIDE.md](MODEL-GUIDE.md) — which AI model does which work
5. [CLAUDE.md](CLAUDE.md) — working conventions for AI sessions

## Layout
```
data/schemas/    JSON Schemas — the contract for ALL game content (engine-agnostic)
data/content/    The content itself: gods, works, traits, callings, tuning
tools/           validate.mjs — schema + cross-ref + design-law checks
game/            Godot 4 project (the 2D Soul Build)
docs/            Architecture + design docs
```

## Commands
```
node tools/validate.mjs        # validate all content against schemas + design laws
```
