# Survival Game — Working Spec v0.2

*Status: world locked — **The Dried Sea** (see WORLD-SPEC.md for setting, pantheon, biomes, itemization). This doc stays systems-focused.*

## Vision

A stylized open-world survival-crafting game in the Valheim / Windrose lineage, built in Unreal Engine by one person + AI. Small deliberate scope: the Early Access target is **3 biomes, one full progression arc, co-op multiplayer** (Valheim-style small-server, PvP as a server option). The bet being tested: AI carries production (code, assets, audio); Jeff carries taste (art direction, game feel, scope discipline).

### Pillars
1. **The loop is the game** — venture out, gather, barely make it home, craft, build, push further. Every system serves that rhythm.
2. **Stylized, coherent, readable** — a committed low-fi art style. This is an aesthetic choice *and* the de-risking choice: stylization hides AI-generation artifacts and keeps 300 assets looking like one game.
3. **Weight over volume** — few systems that feel good beat many systems that feel floaty. Combat/movement feel gets standing iteration time in every milestone.
4. **Procedural world, authored moments** — PCG generates the terrain and scatter; hand-authored (AI-drafted) points of interest give it teeth.

## Core loops

- **Moment-to-moment:** move / harvest / fight / flee. Stamina is the shared currency across all three.
- **Session:** expedition → inventory pressure → return → craft/cook/build → next expedition slightly deeper.
- **Meta:** biome gates progression (Valheim model): each biome has a signature resource, threat tier, and a boss/keystone that unlocks the tools for the next.

## Systems inventory (priority-tiered)

### P0 — Vertical slice (greybox, no final art)
| System | Notes |
|---|---|
| Character controller | Third-person, Enhanced Input, stamina-coupled sprint/dodge |
| Harvesting | Tool-gated resource nodes (tree/rock/plant), respawn rules |
| Inventory | Grid + weight or slot cap (decide in slice), containers |
| Crafting | Recipe unlock-by-discovery (Valheim model), crafting stations |
| Building | Snap-grid modular pieces, structural-integrity-lite, hammer preview |
| Day/night + basic weather | Drives danger level and mood; UE Sky Atmosphere + curves |
| One enemy archetype | Melee AI: patrol/aggro/attack/flee via Behavior Tree or StateTree |
| Hunger/health/stamina | Food-as-buffs (Valheim model) rather than starvation punishment |
| Save/load | SaveGame-based; versioned from day one |
| Co-op foundations | All P0 systems replicated; 2-player listen-server smoke test is an M1 exit criterion |

### P1 — Early Access target
**Co-op multiplayer** (listen + dedicated server, ~2–8 players, PvP server flag) · procedural world gen (PCG depth-band biomes, wreck/POI scatter) · 3 biomes (Salt Shallows / Reef Forest / The Drop) · 6–10 enemy archetypes + 3 bosses · full Track-1 craft/build trees · **devotion & god-magic system** (multi-god attunement ranks, Vigor economy, invocations, worship-restoration rites, cheap Rededication respec pulled by legendary finds — WORLD-SPEC) · **tribesmen** (Soulmask-style: rescue/attract, classes, stations, expeditions-lite; disposition/inner-lives sim-lite with drift → betrayal spectrum + Shepherd's-ledger morality — WORLD-SPEC) · **Track-2 legendary hunts** (named artifacts, rumor system, ritual crafting) · **Callings quest system** (per-player weighted draws from a deep pool, diegetic delivery, Deep Callings with permanent world effects, five anti-shallow laws + human curation gate — WORLD-SPEC; EA target ~250–300 curated) · **the Last Peoples** (2 peaceful races w/ Brink save/trade/exploit states, macro-morality ledger — WORLD-SPEC) · storm cycle (world reroll events) · cooking/brinewife alchemy · ambient wildlife. **Sailing: cut permanently — no water traversal in this world.**

### P2 — Post-EA / probably never (write down so we don't drift)
Structured PvP (raiding/sieges/claims — the server flag ships in EA, the *systems designed around* PvP don't) · the Trench proper + the three **Verdict** path-campaigns (EA ships the fork itself; WORLD-SPEC "The Verdict") · **the Quiet Ascension** (NPC-traitor village whodunit — grows out of the tribesman system; single-player-compatible) · **the Schism** (openly declared player-vs-player Verdict endings) · pantheon politics · Vigor emergency-overdraw · dungeons/interiors beyond god-vaults · Callings pool growth toward 1000+ (standing AI content pipeline) · modding.
*(P1 addition from the Verdict system: god-remnant enshrine/trade/consume choices, echo choices, and verdict-flag tracking must exist from M3 on — the ledger has to be recording long before the fork reads it.)*

## Technical architecture

- **Engine:** UE 5.8 (experimental first-party MCP plugin = AI can drive the editor; Nanite/Lumen/PCG mature).
- **C++-first, thin Blueprint layer.** All systems, state, and logic in C++ (AI's strongest medium; diffable, testable, reviewable). Blueprints only as data-holding subclasses and designer-tunable leaf nodes. This is *the* architectural decision that maximizes AI leverage.
- **Data-driven everything:** recipes, items, buildables, spawn tables as DataTables/DataAssets backed by structs — so content buildout is table-editing (cheap AI work), not code.
- **Custom stats component, not GAS.** The Gameplay Ability System is overkill for this scope and hostile to fast iteration; a lean AttributeComponent + effects system covers hunger/stamina/buffs.
- **StateTree (or BT) for AI**, Enhanced Input, CommonUI or plain UMG.
- **Networked from day one (decision 2026-07: co-op is a requirement, not a retrofit).** Server-authoritative, UE replication + listen server (Valheim model: host-or-dedicated, ~2–8 players). Every system is built replicated from P0 — retrofitting replication is the most expensive mistake available to this project, so we pay the tax up front. **PvP ships as a server flag** (open-world damage toggle); structured raiding/sieges stay P2. Multiplayer-specific design notes: Vigor pools and devotion are per-player; churches/villages are shared; the Verdict fork in co-op is decided by vote-or-host — or openly split (the Schism, WORLD-SPEC). Player-secret betrayal was cut (Owen's critique, 2026-07); the traitor system is NPC-side, so the only remaining private-state requirement is per-player god-voice channels (cheap).
- **Verification loop:** every system lands with a functional test map + automation test where feasible; MCP drives PIE sessions for AI self-verification.

## Art pipeline

1. **Style bible first** (one doc + reference sheet, generated + curated): palette, texture resolution rules, silhouette language, tri-count budgets per asset class.
2. Concept art via image gen (consistent style prompt-kit) → **image-to-3D** (Meshy 6 / Tripo; Rodin for hero assets; Hunyuan3D self-hosted as free bulk fallback) → in-engine material treatment pass that unifies everything (shared master materials).
3. **Characters/creatures (the hard 10%):** generate mesh → auto-rig (Tripo/AccuRIG) → Mixamo base locomotion → Cascadeur (UE Live Link, root motion) for combat animations that matter. Bosses get the most human-in-the-loop time.
4. Import conventions + naming enforced by script from asset #1.
5. **Fab marketplace is allowed** — blending bought foundation packs (foliage, VFX) with AI assets is not cheating, it's what studios do. VFX (Niagara) is a known AI weak spot; budget for packs there.

## Audio pipeline
Music: Suno/Udio → stems → in-engine vertical layering. SFX: ElevenLabs SFX + freesound curation. Ambience beds per biome. This is a P1 concern; slice ships with placeholder.

## Implementation strategy — the Soul Build first (decision 2026-07-14)

**Build the game's soul in 2D before the 3D Unreal implementation.** Rationale: every differentiating system (devotion/Vigor, disposition/traits/Keys, the Brink, grim works, Callings, the Verdict) is simulation + data — engine-independent. A 2D build proves the heart at 10× iteration speed and a fraction of the asset cost; UE's bets (combat feel, atmosphere) are deferred, not abandoned.

- **Form:** top-down 2D (Necesse/Stardew/RimWorld lineage), NOT side-view — the village is the heart and reads top-down; biomes become down-slope bands and the descent survives.
- **Engine:** Godot 4 recommended (free, strong 2D, headless-testable → fast AI verification loop, Steam-ready). Final call before M0.
- **The portability law:** all schemas and content (gods, works, traits, callings, recipes, drift/favor tuning) live as engine-agnostic data (JSON/tables) from day one. The 2D build consumes them; a future UE build consumes them unchanged. Nothing narrative or numeric is ever throwaway.
- **The honest exit:** if the 2D slice is great, shipping the 2D game *as the game* is a legitimate outcome (Terraria > Valheim in units; RimWorld/Stardew/Necesse precedent). 3D becomes the sequel question, answered from revenue instead of savings. Decision gate after M2.
- Co-op requirement stands in 2D (Godot high-level multiplayer / Steam transport — dramatically cheaper than UE replication).
- The UE 5.8 material earlier in this doc remains the reference plan for the 3D implementation, whenever that decision is taken.

## Milestones

*(Revised for the Soul Build — 2D-first.)*

| # | Name | Exit criteria |
|---|---|---|
| M0 | Foundations | Repo, CLAUDE.md, engine-agnostic data schemas v1 (gods/works/traits/callings/recipes), Godot project boots, top-down controller + tilemap world feels good |
| M1 | The Loop | P0 systems playable in placeholder art: harvest→craft→build, day/night, one enemy, save/load, 2-player co-op smoke test; a stranger plays 30 min and gets it |
| M2 | The Soul | Devotion+Vigor+worship loop, first 2 gods + their works, tribesmen w/ traits+disposition (small expression set), ~20 curated Callings; **gate: does the heart beat?** (+ ship-the-2D-game decision checkpoint) |
| M3 | One true biome | Salt Shallows fully realized: gen, enemy roster, Old Shellback, Brinefolk settlement w/ Brink states, storm cycle |
| M4 | EA shape | Biomes 2–3, full pantheon, the Taken + grim works, Verdict fork, audio, menus, Steam page |

Timebox honestly: 2D moves the whole curve left — M0–M2 is a ~4–8 week part-time question (vs months in UE); M3–M4 remains the grind. Decision gates at M1 (is the loop fun?) and M2 (does the soul land? 2D-as-product vs UE-next).

## Top risks
1. **Multiplayer complexity** (promoted 2026-07 when co-op became a requirement) — replication roughly doubles every system's cost; mitigated by building replicated from P0 (never retrofit), listen-server-first, and a 2-player smoke test as a standing exit criterion.
2. **Combat/movement feel** — mitigated by standing iteration time + reference capture from Valheim.
3. **Asset coherence at scale** — mitigated by style bible + shared master materials + image-to-3D-from-concept discipline.
4. **Scope creep** — the P2 list exists to be pointed at.
5. **UE iteration speed vs. web-dev habits** — compiles and editor state make loops slower than what-inlet work; live-coding + MCP mitigate, patience required.
6. **Animation quality ceiling** — accept "good indie," not AAA; stylization buys forgiveness here too.

## Open questions — ANSWERED in v0.2
All six v0.1 world questions are resolved in WORLD-SPEC.md (bottom section): no water traversal ever; style anchors Valheim/Journey-Sable/deep-sea biolume; three depth-band biomes; night threat = the Drowned + angler-lights (light-management gameplay); building fantasy = wreck-timber homestead → walled village with a church heart; progression = descent + devotion (depth tiers × patron identity).

## Remaining design questions (for the Fable architecture pass)
1. Inventory model: weight vs. slots (decide in slice by feel).
2. Death penalty: Valheim corpse-run, softer, or patron-flavored (your god pulls you back... for a price)?
3. Vigor tuning targets: casts-per-game-day, rite duration, offering economy — needs a spreadsheet model before implementation.
4. Pantheon size at EA: all 6 patrons, or ship 4 and add 2 (Ur-Noth late = a content beat)?
5. Difficulty/onboarding: how punishing are the Shallows on night one?
