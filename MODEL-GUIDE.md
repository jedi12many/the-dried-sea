# Model Targeting Guide — Survival Game Project

*Written 2026-07-14. Context: Fable 5 access ends ~2026-07-21. After that the working lineup is **Opus 4.8**, **Sonnet 5**, and **Haiku 4.5**. Goal: maximize token value without quality cliffs.*

*(2026-07-14 update — the Soul Build decision: 2D-first in Godot before any UE work. This makes the guide below CHEAPER to follow: Godot/GDScript + data-table work sits comfortably in Sonnet's lane, headless testing lets agents verify their own work, and the UE-specific rows apply only if/when the 3D build is greenlit. The Fable-week priorities are unchanged and MORE valuable — engine-agnostic schemas are now the project's spine.)*

## The one-week Fable plan (do these before access ends)

Spend the remaining Fable window exclusively on **durable, high-leverage artifacts** — things every future (cheaper) session will inherit. Do NOT burn it on routine implementation.

1. **World-spec pass** — once the world idea lands, upgrade GAME-SPEC.md to v0.2 with Fable: biome definitions, creature roster, progression arc. Design quality here compounds forever.
2. **Architecture doc + repo scaffold** — module layout, the C++-first/thin-Blueprint contract, data-asset schemas (items/recipes/buildables), save-format versioning strategy, authority boundaries for future co-op. The single most leveraged artifact.
3. **CLAUDE.md for the new repo** — conventions, build commands, MCP usage, verification workflow, style rules. This file is what makes Sonnet perform above its weight class later; write it with the best model available.
4. **The two riskiest system designs** (design, not full implementation): building/snapping system and PCG world-gen skeleton. These are the systems where a subtle early mistake costs months.
5. **Style bible v1** — the art-direction document and prompt-kit for concept→3D consistency.

## Task → model map (post-Fable)

| Task | Model | Why |
|---|---|---|
| Architecture decisions, system design docs, tricky tradeoffs | **Opus 4.8** (plan mode) | Design errors are the most expensive errors; pay up front |
| Gnarly debugging (replication, save corruption, PCG edge cases, build breaks that resist one Sonnet attempt) | **Opus 4.8** | Escalate after Sonnet stalls once — don't let Sonnet grind tokens on a wall |
| Combat/movement feel iteration (reading your feedback, adjusting curves/timings) | **Opus 4.8** | Taste-translation is subtle; cheap models over-literalize feedback |
| Day-to-day C++ implementation of a designed system | **Sonnet 5** | The workhorse; with a good CLAUDE.md + architecture doc it's ~Opus-quality on scoped tasks at far lower cost |
| MCP editor driving (placing actors, wiring Blueprints, PIE test runs) | **Sonnet 5** | Tool-use-heavy, many turns — token count matters more than peak IQ |
| UI/UMG work, menus, HUD | **Sonnet 5** | |
| Content buildout: DataTable rows, recipes, item defs, spawn tables | **Haiku 4.5** | Pure mechanical table-filling against a schema Fable/Opus designed |
| Asset pipeline batch work: renaming, import settings, metadata, folder hygiene | **Haiku 4.5** | |
| Log triage, crash-dump first-pass, "what changed" summaries | **Haiku 4.5** | Escalate findings, not raw logs |
| Research (tool comparisons, UE API lookups, forum spelunking) | **Sonnet 5** or Explore subagents from an Opus session | Fan out cheap, synthesize expensive |

## Workflow patterns that stretch tokens

- **Opus plans, Sonnet builds.** Run plan mode on Opus for each milestone-sized chunk; hand the approved plan to a Sonnet session for implementation. This is the single best cost/quality pattern.
- **Escalate on the second failure, not the fifth.** A Sonnet session that has failed the same fix twice is burning tokens; restate the problem fresh to Opus.
- **Fat CLAUDE.md, thin prompts.** Every convention captured in CLAUDE.md is context Sonnet doesn't have to rediscover (and get wrong) each session.
- **Subagent fan-out for search.** Codebase/API questions go to Explore agents; the main session keeps its context clean for the actual work.
- **Keep sessions scoped to one system.** Long mixed-topic sessions degrade every model and waste compaction; one session per system keeps context tight and cheap.
- **Data-driven design is a cost strategy.** Every gameplay knob moved into a DataTable converts future Opus-priced code work into Haiku-priced table edits.

## Non-Claude model lanes (for completeness)

| Lane | Tool | Notes |
|---|---|---|
| Concept art / style frames | Gemini image gen (existing what-inlet recipe) or Midjourney | Consistency prompt-kit lives in the style bible |
| 3D assets — bulk props | Meshy 6 / Tripo (subs ~$20–50/mo) | Tripo fastest + auto-rig; Meshy most balanced |
| 3D assets — hero pieces | Rodin Gen-2 | Cleanest production topology |
| 3D assets — free bulk fallback | Hunyuan3D (self-hosted, needs GPU) | Worth testing before paying for volume |
| Rigging | Tripo auto-rig / AccuRIG | Humanoids easy; tails/antlers need care |
| Animation | Mixamo (base) + Cascadeur (combat polish) | Cascadeur 2026.1 has UE Live Link + root motion |
| Music / SFX | Suno / ElevenLabs SFX | P1 concern |
