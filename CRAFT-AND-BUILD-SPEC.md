# Craft & Build — the Three-Biome Spec

*(Jeff, 2026-07-18: "how much crafting and building do we have spec'd out?
…step back and review any work we have done in this area and make sure it
fits with the other changes… I'd like the spec for all three biomes."
Status: v1, written against the v0.9.3 codebase. WORLD-SPEC owns the laws;
this doc makes them buildable — every table here is a data-file change, not
a code feature, except where marked.)*

---

## Part 0 — The audit: what exists today (v0.9.3)

**Spec'd (WORLD-SPEC, still sound):** two-track itemization (Track 1 fair
tree: bronze → reef-iron → tidebrass; Track 2 legends as hunts, never on
the tree); the Works law (every buildable belongs to a god, use is worship,
favor tiers gate set depth); church progression (shrine → chapel → church →
basilica); the Sanctum; grim recipes arriving corruptly; storm-as-reroll.

**Implemented and healthy:**
- 21 works: 6 neutral tier-0, Halor 5, Maren 4, Neris 2, Vessa 1, Ghal 1,
  Ur-Noth 2 (grim). Favor-tier gating live. Tending/in-use favor live.
- 11 recipes — ALL biome-1: 2 weapons + 1 legend, 2 armor, foods, votive,
  rope, salt. Craft menu, build menu, stations (workbench, smokehouse),
  worked nodes with hit counts, the stores economy, the armory.
- 1 complete legend (Maren's Own Harpoon: 3 placed verses → rite-craft).

**Drift found (the reason this doc exists):**
1. **Orphaned materials.** coralwood, reef-iron, pearl, tidebrass,
   storm-glass, trench-pearl, god-water all exist as items and biome
   resource lists — and NOTHING uses them. Zero B2/B3 recipes, stations,
   or work costs. The tree stops at bronze.
2. **`work-beast-pen` collides with Part III's `work-kennel`.** Same god,
   same job. RESOLVED BELOW: beast-pen is renamed/reworked INTO the kennel
   (data edit; it has never been buildable in play — no save migration
   needed).
3. **Four gods have no altar works** (Neris/Vessa/Ghal/Ur-Noth) — the
   Sanctum system supports them; the data was never written. Ur-Noth's is
   not merely missing, it's a spec'd set-piece (the Reliquary).
4. **Three of four legends have no hunt content** (Lantern, Hourglass,
   Crown are items with no fragments/rumors/placement).
5. **The village task economy knows 4 goods** (food/wood/salt/bronze —
   `NEED_TARGETS`/`TASK_ITEM`/`CLASS_SUIT` in main.gd). B2/B3 gathering
   needs those tables extended (code change, small).
6. **New-system seams that all held** (checked, no action): favor gating
   vs Godhead (works feed *favor*, worship feeds *Godhead* — cleanly
   parallel, no double-dipping); the armory + stores-take (test-era
   communism means players can outrace the dawn armory claim — accepted
   until the ownership pass); drill-yard/memorial/altars all follow the
   Works law; Part III beasts hook Ghal's set exactly where it was thin.

---

## Part 1 — Laws (two new, the rest inherited)

1. **Stations are god-neutral; god works are advantages.** The metal chain
   (workbench → reef-forge → trench-works) is Track-1 progression and
   Track 1 is *fair* — nobody is walled by their patron choice. Gods keep
   their premium domain stations (smokehouse already Halor's: food quality,
   not progression — that stays). NEW LAW, resolves a latent conflict
   between "every buildable belongs to a god" and "no one is ever walled."
2. **One tool per tier, best-in-pack.** B1 nodes need bare hands (current
   behavior, preserved). B2 nodes need a bronze mattock; B3 nodes need a
   reef-iron mattock. Same best-in-pack rule as weapons — no toolbelt UI.
3. Inherited and binding: use-is-worship; grim alternatives never required;
   legends never on the tree; discovery-unlock recipes (see a material →
   learn its recipes); show the numbers.

## Part 2 — Track 1: the tree, biome by biome

### Biome 1 — Salt Shallows (mostly live; completeness pass)
- **Materials (live):** driftwood, wreck-timber, rope, salt, bronze
  salvage, ship-cloth.
- **Stations (live):** hands → workbench; smokehouse (Halor).
- **NEW to complete the tier:**
  | Recipe | @ | Numbers |
  |---|---|---|
  | Bronze Spear | workbench | dmg 23 (club 15 / knife 19 / spear 23 / harpoon-legend 26) |
  | Bronze Mattock | workbench | tool tier 2 — opens B2 nodes |
  | Ship-Cloth Bindings | hands | armor 5, cheap middle step (cloak 3 / bindings 5 / vest 7) |
- Gods at this depth: **Halor, Maren (live), + Neris comes online** (her
  tide-bell and healing-bath are already in data — she needs only her
  fallen shrine placed and `work-altar-neris`).

### Biome 2 — Reef Forest
- **Materials:** coralwood (timber-2), reef-iron (metal-2), pearl,
  anemone silk (NEW item), dye (NEW, cosmetic/offering).
- **Gather gates:** all B2 nodes need the Bronze Mattock. Coralwood 6
  hits, reef-iron 5, pearl beds 4, silk 3.
- **Station:** **Reef-Forge** (neutral; costs coralwood 8 + bronze 6 +
  rope 4). Smelts/works reef-iron. Bootstrap is Valheim-honest: B1 metal
  + B2 timber build the thing that works B2 metal.
- **Recipes:**
  | Recipe | @ | Numbers |
  |---|---|---|
  | Reef-Iron Blade | reef-forge | dmg 30 |
  | Reef-Iron Pike | reef-forge | dmg 34 (slow, reach — the eel-wolf answer) |
  | Reef-Iron Mattock | reef-forge | tool tier 3 — opens B3 nodes |
  | Anemone-Silk Wrap | workbench | armor 10, light |
  | Reef-Iron Scale | reef-forge | armor 13 |
  | Pearl Votive | workbench | offering — Neris craves, Vessa accepts |
  | Smoked Urchin / Reef Chowder | smokehouse | the B2 food step (numbers with the food pass) |
- **Enemy scaling rule:** B2 hostiles hit for ~2× B1 so the armor ladder
  stays honest under the subtract-min-1 model.
- Gods at this depth: **Vessa + Ghal shrines** are found here (roads
  through the reef; the wild proper). Their altars land with them.

### Biome 3 — The Drop
- **Materials:** tidebrass, storm-glass, trench-pearl, god-water (trade
  from Brinefolk — never mined), god-vault relics (placed, not nodes).
- **Gather gates:** Reef-Iron Mattock everywhere; storm-glass keeps its
  storm-event sourcing too (live already).
- **Station:** **Trench-Works** (neutral; reef-iron 8 + storm-glass 3 +
  coralwood 6). The last bench.
- **Recipes:**
  | Recipe | @ | Numbers |
  |---|---|---|
  | Tidebrass Falx | trench-works | dmg 42 |
  | Tidebrass Warpick | trench-works | dmg 46 (slow) |
  | Tidebrass Plate | trench-works | armor 18 |
  | Lantern-Oil Cakes | smokehouse | food + a light-duration buff (the Drop is dark) |
  | Trench-Pearl Votive | trench-works | offering — Ur-Noth craves, Neris accepts |
- Gods at this depth: **Ur-Noth's fallen shrine** — attunement to the
  forbidden patron is *found in his country*, B3. (His grim WORKS remain
  buildable from B1 via corrupt recipes — the law holds: the works arrive
  uninvited; the god waits below.)

## Part 3 — The Works: every god grows one work per biome

Favor tiers (existing thresholds 0/25/75/150 = T0/T1/T2/T3):

| God | B1 (live/new) | B2 | B3 |
|---|---|---|---|
| **Halor** | hearth, smokehouse T0 · salt-cellar T1 · memorial, altar | Granary T1 (bigger stores cap) · Coral-Block Wall T2 (stronger blocks) | The Bulwark Gate T3 (village gate, storm-proof) |
| **Maren** | lightning-rod, storm-cistern, drill-yard T0 · altar | Bellows T1 (reef-forge companion: +1 output per smith day) · Wind-Shutters T2 (buildings shrug the storm) | Storm-Anchor T3 (calls ONE storm early — the reroll on demand, once per real week) |
| **Neris** | tide-bell T0 · healing-bath T1 · **altar (NEW)** | Water-Clock T1 (villager schedules tighten: +1 work hour) · Rest-Pool T2 (sleep heals double) | The Returning-Pool T3 (downed timer 30→45s in village radius — she buys time; Ur-Noth still owns death) |
| **Vessa** | way-beacon T0 · **altar (NEW, B2 arrival)** | Board-Roads T1 (**villager leash +25% along roads** — plugs straight into the risk-leash dial) · Porter's Post T2 (a villager task: hauls stores between camps) | Way-Gate pair T3 (two gates, one link — the game's only fast travel, village-to-village) |
| **Ghal** | ~~beast-pen~~ → **Kennel T0** (Part III home; rename in data) · **altar (NEW, B2 arrival)** | Taming-Post T1 (trust meals count double at post) · Stable T2 (houses 4 beasts, mood floor) | Leviathan-Yard T3 (apex beasts live here; storm-carcass harvest doubles) |
| **Ur-Noth** | salt-wheel T0, rendering-vat T1 (grim, live) | Drain-Pumps T1 grim (drains a Brinefolk pool: offerings windfall, Brink damage — the Peoples ledger's sharpest tool) · Lightless Lure T2 grim (night enemies path to IT, not you) | **The Reliquary T2** (his altar — the grim Sanctum mirror, WORLD-SPEC set-piece) |

Neutral tier-0 set stays as-is (tent, walls, cot, workbench, yoke-post,
chapel) + reef-forge and trench-works join it (Law 1).

## Part 4 — Track 2: legends, one per biome per line (EA scope)

Live: **Maren's Own Harpoon** (B1, complete — the template). To write, using
its exact 3-fragment → event-material → ritual-craft structure:
- **Lighthouse-Keeper's Lantern** (B1, Halor-line): verses in the beached
  fleet, storm-exposed wreck fragment; material from a storm carcass.
- **Neris's Hourglass** (B2, Neris-line): the spec'd drowned-town chapel
  fragments — three chapels under the reef canopy.
- **The Unlit Crown** (B3, Ur-Noth-line): god-vault placed; costs what
  you'd expect (the recipe consumes a remnant — the third road for one).
- Salt-Father's Hearthstone (post-EA, stays an item until the village
  spoilage system deepens).

## Part 5 — Threading the new systems (the fit-check, made binding)

- **Arms armory:** the dawn claim already takes best-in-stock — the B2/B3
  gear ladders above ARE the villager progression; no new code. A Warrior
  10 in tidebrass plate is the endgame the leveling curve promises.
- **Beasts (Part III):** kennel rename lands with the beast slice; the
  Taming-Post/Stable/Leviathan-Yard rows above are Ghal's B2/B3 growth.
- **Godhead:** biome-boss kill = biome cleared = cap +30 (wired) +
  keystone dedication +8 to ONE god (M3, decided). No craft interplay
  otherwise — works feed favor, worship feeds Godhead, cleanly parallel.
- **Sanctum:** the four missing altars are data; appetite tables for the
  new offerings (pearl votive, trench-pearl votive, dye, god-water) extend
  each god's craves/accepts/offends lanes.
- **Village economy (code, small):** extend NEED_TARGETS/TASK_ITEM/
  CLASS_SUIT with coralwood + reef-iron tasks when B2 lands; Porter's Post
  adds its task the same way. The risk-leash and Board-Roads multiply.

## Part 6 — Milestones

- **M2.75 — the B1 completeness pass (craft-only, no world gen):** spear,
  mattock, bindings, Neris shrine + altar + her two live works reachable,
  Lantern hunt, 4 missing altars' data written (even if 3 gods' shrines
  wait). Cheap, all data.
- **M3 — Reef Forest:** B2 gen + materials + reef-forge + recipes, Vessa/
  Ghal arrivals, Board-Roads/leash wiring, Anglermother + keystone moment,
  Reefkin/Brink, Hourglass hunt, beast slice lands here too.
- **M4 — the Drop:** B3 everything above + Ur-Noth attunement + Reliquary
  + Crown + the Drowned Priest.

## Decisions taken (2026-07-18, this doc)

- **Stations are god-neutral** (Law 1) — resolves works-law vs
  fair-tree conflict in favor of fairness.
- **One tool per tier, best-in-pack** — minimal gate, no toolbelt.
- **beast-pen → kennel** — one Ghal home, not two.
- **God arrival order: Halor/Maren/Neris (B1) → Vessa/Ghal (B2) →
  Ur-Noth (B3)** — the forbidden patron is found in his country.
- **Damage/armor ladders as tabled** — first guesses, tuned in play like
  everything else.

## Open questions (for Jeff)

11. **Way-Gates (Vessa T3)** — the game's only fast travel. In, or does
    walking-the-world stay sacred? Lean: in at T3 — by then the walk has
    been earned many times over, and it's village-to-village only.
12. **Storm-Anchor (Maren T3)** — player-called storms are a big lever
    (reroll on demand). Weekly cooldown enough, or too much agency over
    the world's one rhythm? Lean: ship it gated, watch it.
13. **Enemy-damage ×2 per biome band** — steep by design (armor min-1
    model needs it). Confirm against M3 playtest feel.
