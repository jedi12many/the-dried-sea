# Villagers & Godhead — Working Spec v0.1

*Status: DESIGN — nothing here is implemented. Two interlocking systems: (I) the
individual villager — combat classes, levels, gear, and the road; (II) Godhead —
world-level god health that caps all granted magic. They meet in the Acolyte.
Plugs into WORLD-SPEC (tribesmen, Vigor economy, the Sanctum, the Verdict) and
extends `village_system` / `devotion_system`; it replaces nothing.*

---

# Part I — The Individual Villager

## Design intent

The disposition sim already gives villagers an inner life (traits, Keys, bloom,
drift). This spec gives them an **outer** one: a villager you rescue in the
Salt Shallows should be able to walk beside you into the Drop, forty levels of
world later, wearing gear you forged, swinging a class kit they earned. The
fantasy is Valheim's homestead crossed with a warband you *raised*: not
hirelings — people, with the save-file scars to prove it.

Design laws (inherited, still binding):
- **Origin is a door, not a destiny** — any villager can take up arms; class is
  chosen, not rolled.
- **Bloom beats Broken over any long run** — a bloomed villager must out-level a
  Broken one; kindness compounds here too.
- **The village is the character sheet** — training, arming, and losing
  villagers all read in the village itself.

## 1. Two tracks: the Trade and the Arms

Every villager holds up to two classes, one per track:

| Track | What it is | Examples | Where it lives today |
|---|---|---|---|
| **Trade** (exists) | The village-economy job | Salvager, Smith, Brinewife, Warden, Reef-Runner, Priest | `npc-classes.json`, `village_system` |
| **Arms** (new) | The combat kit — who they are when the bell rings or the road calls | **Warrior**, **Archer**, **Acolyte** at EA | this spec |

- The Trade is assigned as today (nearest job on rescue, reassignable). The Arms
  is **trained**: build a **Drill-Yard** (a Maren work — of course the
  Storm-Mother owns the sparring post) and assign a villager for N days.
  Retraining to a different Arms class is allowed; the old class's levels bank
  (see §2 — you keep earned levels per class, Valheim-skill style, so switching
  isn't erasure).
- Some arrivals come pre-trained: Wardens arrive as Warrior 1; a god's priest
  arrives as Acolyte 1 of that god.
- **Acolyte prerequisite:** faith ≥ 50 and a patron god (they channel, not
  cast — see Part II §5). A `trait-agnostic` villager can never take Acolyte;
  a `trait-bitter` one can, and that should be a little frightening.

### The EA trio (kits, first pass)

| Class | Fantasy | Kit at ignition tiers (3 / 6 / 9 — see §2) |
|---|---|---|
| **Warrior** | Shield-line; stands where you put them | 3: *Hold-fast* (taunt pulse, +block) · 6: *Shield-wall* (adjacent allies +armor) · 9: *Breakwater* (once/fight AoE knockback — a small, mortal Call-the-Squall) |
| **Archer** | Overwatch; kills what the warrior holds | 3: *Marked prey* (+dmg vs. taunted) · 6: *Long eye* (range +, reveals stealth) · 9: *Storm of shafts* (once/fight volley) |
| **Acolyte** | A lens for their patron — village-scale god-magic | 3: *Lesser invocation* (a weak copy of the patron's rank-1 invocation) · 6: *Patron's ward* (party blessing, the god's passive at reduced strength) · 9: *Intercession* (once/fight, the patron's rank-2 invocation) — **all magnitudes × Godhead** (Part II) |

Kits are data (`arms-classes.json`); adding a fourth class post-EA (Ghal
beast-handler? Ur-Noth cultist, with everything that implies for the ledger?)
is a content patch, not code.

## 2. Leveling

**Shape:** per-Arms-class level 1–10, XP-driven, quadratic-ish curve
(`xpToLevel(n) = 25 · n²` first guess — L2 costs 100, L10 costs 2 500).
Trade classes do NOT level (output already scales via traits/bloom/expression;
two parallel progression ladders on the same person is bloat).

**Talents ignite at 3 / 6 / 9** — deliberately the same rhythm as the player's
Six Virtues. Villager growth is the player-side Tally read into an NPC: same
theology, opposite side of the ledger. No talent points, no choices to make for
them — the class IS the tree. (Their *traits* are where individuality lives;
the class is where competence lives. Don't blur them.)

**Per-level baseline:** +8% max HP, +2% class-primary (Warrior: melee dmg &
block · Archer: ranged dmg & crit · Acolyte: channel strength & cast range).
Numbers to `tuning/villagers.json`, asserted by the economy model.

### XP sources (first guesses)

| Source | XP | Notes |
|---|---|---|
| Kill assist (on the road or defending walls) | 5–25 by threat tier | The main verb |
| Expedition survived (returned home) | 40 | Flat; *returning* is the achievement |
| Village defense survived | 20 | Walls count as the road, discounted |
| Drill-Yard training day | 8 | Slow, safe, offline — the catch-up lane |
| Acolyte only: rite led at their patron's church | 15 | Worship is their sparring |

**Multipliers:** bloomed ×1.5 (bloom beats Broken, enforced) · Broken ×0.75
(obedient, diminished) · `slacking`/`fearful` expression ×0.5 (a grieving
villager trains badly — disposition leaks into growth, as it should).

**Show the numbers:** the villager panel gets a class line — `Warrior 4 —
610/625 XP`, talent pips lit at 3/6/9, next-talent tooltip. Same UI law as
Godhead: no hidden math.

## 3. Equipment — the full paper doll

Six slots, **identical to the player's** (one schema, one equip code path, and
the Sanctum precedent holds — altars, players, and villagers all wear the same
doll):

```
main-hand · off-hand · head · body · feet · charm
```

- **Source of gear:** the village stores / armory chest. Hand-assign per
  villager (drag onto the doll), plus an **"arm themselves"** toggle per
  villager: at dawn they claim the best stores item their class allows, wardens'
  current dawn-claiming behavior generalized (that code becomes this system).
- **Class gating:** data-driven `allowedClasses` on items. Warriors: heavy;
  Archers: light + bows; Acolytes: robes + charms, no shields — their off-hand
  wants a **relic-charm of their patron** (a new minor item line; NOT the
  altar's quest-singular relics — those stay on altars).
- **Trait hooks (cheap, characterful):** `trait-sticky-fingers` — assigned gear
  occasionally "wanders" to their pocket until bloomed, then never again ·
  `trait-forge-sense` — gear they wear degrades slower · `trait-dark-fearing` —
  refuses night expeditions without a lantern in a slot. One-line effects in
  `traits.json`, big personality yield.
- **On death, gear drops where they fell.** Retrieving a dead companion's
  sword is a corpse-run with feelings. This is intentional.

## 4. The road — villagers as companions

- **Party cap 2** at EA (netcode + pathing sanity; a co-op pair + 2 each = 6
  bodies on screen, plenty). Recruit at the village gate ("Walk with me");
  they eat from the village larder on departure (a provisioning cost, worded
  as packing food).
- **Willingness is disposition-read:** `steady`+ villagers accept; `fearful`
  refuse dangerous biomes below their level band; `mutinous` refuse you
  outright (and the refusal is a tell you should notice); bloomed villagers
  *volunteer* — the one who runs TOWARD the storm-bell finally gets to.
- **Behavior (2D, keep it dumb and readable):** follow at heel → engage at
  aggro → **break at 25% HP and run to you** (not home). Warrior holds ground
  longer; Archer keeps range; Acolyte channels from behind you. Three
  parameters per class, no behavior trees.
- **Downed, then dead:** at 0 HP a villager is **downed 30s**; revive by
  standing over them (channel, interruptible). If the fight or the clock takes
  them: **permadeath.** A death on the road writes `shepherd −4` if reckless
  (sent under-leveled below their band) or `+0, mourned` if honest; the village
  runs a **grief condition** for 3 days (drift table entry, like fear-days);
  their name goes on a **memorial work** (a Halor piece — build it and the
  grief days halve; the homestead god keeps the dead).
- **Why bring anyone?** They fight, they carry (+1 pack each), trait synergies
  travel (`keen-eyes` boosts expedition finds *live*, `wanderlust` blooms out
  here), and an Acolyte is a walking, Godhead-capped second spell slot. The
  road is also the *fast* XP lane — the drill-yard is the safe one.

## 5. Data & system deltas (Part I)

- **New:** `data/content/arms-classes.json` + schema (id, primaries, talent
  ignitions with effects[], allowedGear tags, behavior params) ·
  `tuning/villagers.json` (XP curve, sources, multipliers, party cap, downed
  timer) · drill-yard + memorial entries in `works.json` · relic-charm line in
  `items.json`.
- **Schema changes:** villager record (village_system) gains
  `arms: {class_id, levelsByClass: {}, xp}`, `equipment: {6 slots}`,
  `on_road: bool`. `items.json` gains optional `equip: {slot, allowedClasses,
  tier}` — the player's own equipment should migrate onto this same block.
- **Systems:** leveling/XP/equipment live in `village_system` (it owns the
  roster); road-party AI in `villager.gd` scene layer reading sim state;
  XP grants flow through the event bus (kills already emit). Save: villager
  records grow; version-bump + migration (default `arms: none`).

---

# Part II — Godhead: the health of the gods

## Concept

The Withdrawal nearly killed the pantheon. Every god now has **Godhead** — a
world-level health bar, 0–100%, that measures how much of them is *left*. It
is the campaign-scale companion to Vigor:

| | **Vigor** (exists) | **Godhead** (new) |
|---|---|---|
| Scope | Per-player, per-god | **World-level**, per-god — one value, shared by all players |
| Timescale | Hours — spent in casts, refilled by rites | The whole campaign — a savefile-long recovery |
| Metaphor | The god's *breath* | The god's *body* |
| At zero | Dormant (for you, briefly) | **Guttered** (for everyone — see §4) |

**Godhead multiplies every effect a god grants.** Vigor decides *whether* you
can cast; Godhead decides *how much god shows up when you do*. Feed the gods
all game and the same invocation you learned on day one grows with the world —
progression you earned by worship, not by patch notes.

## 1. The cap: biomes are the ceiling

Gods heal only as far as the world lets them — their strength returns as the
descent reopens their domains:

```
GodheadCap = 10% + 30% × (biome keystones defeated)
```

| World state | Cap | Note |
|---|---|---|
| Campaign start | **10%** | The pantheon at a flicker — magic barely works, on purpose |
| Salt Shallows keystone down | **40%** | ← the current test build's ceiling |
| Reef Forest keystone down | **70%** | |
| The Drop keystone down | **100%** | Full godhead is endgame material |

The cap is global (one world-progress clock, all gods share it). Within the
cap, *where each god sits* is entirely a function of how the players have
treated that god. Boss keystones therefore do two things at once: raise every
god's ceiling +30%, and (§3) hand you a one-time chunk to give to one of them —
the ceiling is the world's gift; the filling is yours.

## 2. The one formula — and show the numbers

```
effective = base_magnitude × blessing_dim(vigor) × godhead
```

`blessing_dim` is the existing curve (invocations use 1.0 — they fire full or
not at all); `godhead` is the new term and applies to **everything granted**:
invocation magnitudes, durations, radii*, passive blessings, Acolyte channels.
(*radii scale at half-weight — `1 − (1−godhead)/2` — so a 10% squall is
pathetic but not invisible.)

Worked examples, Maren at the test cap (Godhead 40%):

| Grant | At 100% | At 40% | At 10% (day one) |
|---|---|---|---|
| Call the Squall — lightning strikes | 3 strikes | 1 strike (floor: ceil, min 1) | 1 weak strike |
| Call the Squall — knockdown radius | 8 m | 5.6 m | 4.4 m |
| Wind-Wall duration | 12 s | 4.8 s | 1.2 s |
| Storm-Sense (blessing) warning | 60 s ahead | 24 s | 6 s |

**The UI law: the numbers are always on screen.** Nothing in this system is
hidden — watching the numbers grow IS the reward loop:

- God panel: `MAREN — Godhead 34% ▮▮▮░░ (cap 40%)`, with the cap segment
  visibly locked ("the Reef holds the rest of her").
- Cast bar / invocation tooltip: `Call the Squall — 34% strength · 1 strike ·
  5.4m` — live-computed, updates as godhead moves.
- Rites and offerings print their yield: `Rite of the Squall: Maren +0.8%
  Godhead`. The Sanctum modal's annotation pattern extends here verbatim.

## 3. Feeding a god (sources) and bleeding one (sinks)

Godhead moves slowly — it's a campaign bar, not a mana bar. First guesses,
all to `tuning/godhead.json`, all asserted by `tools/economy-model.mjs`
(target: a faithfully-worshipped god rides ~5–8% under cap; an ignored one
sits near floor):

**Sources**
| Source | Δ Godhead | Notes |
|---|---|---|
| Daily rite at that god's church | +0.2–0.6% by church tier | × Splendor (the Sanctum multiplies god-healing — that was always its job) |
| Dawn tithe (Sanctum) | +0.05% per craved item taken | The passive trickle |
| Restore a fallen shrine of theirs (world POI) | +2% one-time | Exploration heals gods; ~4–6 shrines per god per biome |
| Boss keystone **dedicated** to one god | +8% one-time | The kneel-at-the-altar choice after each boss; one god only — a real favorite-picking moment |
| Their Deep Callings completed | +3–5% | Big quests are big meals |
| Devout villager trickle | +0.01%/day each | The congregation matters, barely but truly |
| **Player death** (Ur-Noth ONLY) | +0.4%, ×0.6 per repeat in 3 days, floor +0.05% | The Waker's tithe — see §5; the one source no one has to choose |

**Sinks**
| Sink | Δ Godhead | Notes |
|---|---|---|
| Casting | **0** | Casting spends Vigor (yours), never Godhead — players must never feel that using magic hurts their god, or they'll hoard it |
| Ur-Noth's grim rites | −0.5% per rite from a god of your choice | The grim mirror made literal: his Splendor multiplies the *theft*. Every use is a Verdict ledger entry |
| Consumed remnant (Verdict) | that god → 0, permanently | Already promised in WORLD-SPEC — now it has a stat to zero |
| Offense laid on their altar | −0.1% | The Offertory's `offends` lane gets teeth |
| Neglect | −0.05%/day, floor 5% | Only below cap/2 and only with zero worship that day — absence cools, it doesn't kill. **Guttering (0%) is only ever reachable by deliberate acts**, never by forgetting to pray |

## 4. Zero: the Guttering, and the God-Death quests

At 0% a god **gutters**: world-wide and for every player — invocations dead,
blessings dark, their priest kneeling in a cold chapel (rites still function —
that's the road back), their works still *work* but feed no favor. The
god-voice goes silent; one line before it does. The 2D read: their shrine
flames literally out.

**And then the knife appears.** A guttered god can be *killed*. A **God-Death
Calling** opens — findable, not pushed (Ur-Noth's priests know the way; so do
the Unlit's letters): a multi-step Calling chain ending at the god's First
Shrine, where a mortal hand can finish what the Withdrawal started. Killing a
guttered god:

- yields their **remnant** — feeding directly into the Verdict economy that
  already exists (enshrine / trade / **consume**). This is where remnants
  *come from*; the Verdict system finally gets its supply chain.
- kills their domain **world-wide, for everyone**: their works go inert, their
  priest leaves or breaks, their Acolytes lose their class (grief-drift for
  every villager whose patron dies), their invocations become memory. Death
  holds until the **Waking** (below) — it becomes *forever* only if the
  remnant is then consumed (the WORLD-SPEC promise, now precise: consume the
  Tide-Keeper and the tide-rhythm buffs die world-wide, permanently).
- writes the heaviest single entry the `gods` ledger will ever take.

The mercy path is the mirror quest: a **Rekindling** chain to haul a guttered
god back over 10% by hand — long, expensive, and the ledger remembers that
too. Both quests are authored Callings content (2 per god is too much for EA;
ship God-Death for 2 gods + Rekindling generic, grow the rest post-EA).

In co-op, god-death is Verdict-grade: **vote-or-host**, same rule as the fork.

### The Waking — death is not the end; consumption is

*(Decision 2026-07-17: losing a god forever in a many-hour save is too cruel
to leave un-doored — but the door must be earned, and ONE act must still close
it for good.)*

A dead god is not gone **while their remnant survives**. The remnant is the
god's seed, and the three Verdict verbs now mean exactly what they say:

| Remnant fate | Can the god return? |
|---|---|
| **Enshrined** (or sitting in your stores) | Yes — via the Waking, below |
| **Traded away** | Yes — but first win it back (the buyer knows what they hold, and the price has gone up) |
| **Consumed** | **Never. This is the game's one truly irreversible act**, and the UI says so in exactly those words at the moment of choice — a full-stop confirmation, the only one in the game |

**The Rite of Waking** is an endgame-scale project chain (authored Calling,
one generic spine reskinned per god), deliberately priced like building a
basilica, not like buying a potion:

1. **Carry the remnant to the god's First Shrine** — the same site where the
   God-Death ended; the walk itself is a pilgrimage, and the remnant in your
   pack draws the dark biomes' attention (Ur-Noth wants it back on the market).
2. **Rebuild the shrine** — a one-off construction stage using that god's
   deepest-tier work materials.
3. **Lay the feast** — a Splendor gate: an altar at that shrine stocked to a
   high threshold with the god's craved offerings, plus one relic of their
   affinity line surrendered permanently (the only relic sink in the game).
4. **Hold the vigil** — N in-game days of attended rites; a priest of that god
   if any survives (one always wanders back for this), every willing Acolyte
   of theirs kneeling. The village literally prays a god back to life.

**What wakes is not quite what died.** The god returns at 10% Godhead — the
flicker again, cap wherever the world's keystones currently hold it — with
their domain effects, works, priest, and Acolytes restored (Acolytes regain
their class; their levels were banked, per Part I §1). But a woken god
*remembers*: permanent voice/dialogue pool shift, and the ledger carries both
entries forever — the hand that killed them and the hand that woke them,
which may be the same hand. That arc (kill a god for the remnant's power,
keep the remnant, wake them later in regret) is the Verdict system's best
redemption story and it emerges from these rules for free.

Waking needs no vote in co-op — restoration is never gated; only destruction
is.

## 5. The Waker of the Drowned — player death powers Ur-Noth

*(Jeff, 2026-07-17. This answers GAME-SPEC design question #2 — the death
penalty is "patron-flavored: your god pulls you back... for a price" — with
the twist that makes it this game: it is always the WRONG god.)*

Every player death in the Dried Sea ends the same way: the dark takes you,
and **Ur-Noth hands you back**. The Withdrawal broke the other gods' claim on
the drowned; the Unlit is the lone god with the power — and the appetite — to
restore a dead player. Respawn stops being a mechanic and becomes *his*
mechanic: the rest-point system stays exactly as built (bind a tent or
hearth), reframed as *where he lays you down*. He has been doing this since
your first death. You just never asked who was carrying you.

**The whisper.** Every wake, one line, before the screen fully lightens.
Whisper pools live in `ur-noth.json` (`wakerWhispers`), keyed to lifetime
death count — **early** (curious: *"Light again. How brief."*), **familiar**
(he knows your habits: *"The hounds, again. You lead with the left."*),
**proprietary** (*"I have carried you more often than any lover will."*) —
plus milestone lines and occasional nudges toward whatever grim option is
nearest your current situation. Pure data; growing the pools is a content
patch, and the writing budget here is the best flavor spend in the game.

**The feed — the world cost.** Every death is a meal. On the death screen,
in numbers (the UI law holds even here — *especially* here):

```
THE DARK TAKES YOU.        UR-NOTH  +0.4% Godhead  (now 23.1%)
```

Per-player diminishing decay so the feed can't be farmed: first death +0.4%,
each subsequent death by the same player within a 3-day window ×0.6 (so
+0.24%, +0.14%, …), floor +0.05%. Window resets after 3 deathless days.
Economy-model assertion: a full day of deliberate suicide-diving feeds
Ur-Noth less than one grim rite — death-farming is *allowed* (it's a
legitimately dark Unlit-build lever) but never the efficient road.

**The scar — the personal diminishing returns.** Ur-Noth's magic always
draws on the vessel, and resurrection is his biggest spell. Each wake adds a
**Drowning-Scar**: −10% max HP, stacking to 5. One scar lifts per dawn slept
at your rest point; any priest can cleanse them for offerings (the existing
"cleanse Ur-Noth scarring" service — it was always this system). So a bad
night compounds: wake at 90%, die again, wake at 80%... each time there is a
little less of you, because he keeps a little as payment. This is the real
limit on respawn-usefulness: corpse-runs (gear still drops where you fell)
get harder the more you need them.

**The debt — the story fun.** At lifetime-death milestones (5 / 15 / 30) the
whisper becomes a **Calling** — Ur-Noth asks for something, always refusable,
always grim-adjacent. Refusal costs nothing and he keeps waking you anyway:
*he is not kind, he is patient.* Design law: **dying is ledger-neutral** —
being bad at the game is not a moral failing, and the ledgers never count
deaths. Only *accepting his asks* writes ink.

**Killing the Waker.** Guttering Ur-Noth is nearly impossible — every death
anywhere feeds him back above zero. **You cannot keep the dark down while
anyone still drowns**; the only quiet is the knife (God-Death), and only
consumption makes it forever. A world without Ur-Noth still returns its
dead — the honest gods take up the burden, at the honest price:

- Each death drains your **highest-attuned living god −1% Godhead** and
  empties your Vigor pool with them. They can do what he did; they just
  can't do it cheaply. Dying now taxes the gods you kept.
- No attuned gods left? You wash up anyway — at 25% HP with 2 scars and
  **no whisper**. The silence after his voice is the story beat: you never
  liked the whispers, and now the wake is so much worse without them.

**Co-op:** scars, decay windows, and death counts are per-player; the feed
is global (per-player decay keeps one dying player from carrying the farm).
Death of *villagers* feeds nothing — Ur-Noth collects players; the village's
dead go to their own gods, and the memorial (Part I §4) keeps them.

## 6. The interlock: Acolytes are Godhead made visible

Villager Acolytes channel their patron — so **their magnitudes ride the same
godhead multiplier**, live. Feed Maren and every Maren-sworn Acolyte in the
village hits harder that same day; let her gutter and they are just people in
robes, kneeling. The village doesn't just *display* your theology (works,
altars) — it now *performs* at the strength of it. One number, three systems
deep: your spells, their spells, the world's weather-tells. That's the whole
pitch.

## 7. Data & system deltas (Part II)

- **New:** `game/sim/godhead_system.gd` (one system per file; owns the per-god
  0–100 value + cap; subscribes to keystone/rite/tithe/shrine/verdict/
  player-death events; emits `godhead_changed`, `god_guttered`,
  `god_rekindled`) · `tuning/godhead.json` (base, perBiomeCap, all
  source/sink rates, floor, plus a `waker` block: feed/decay/window,
  scar depth+cap+heal rate, debt milestones, no-waker fallback costs) ·
  `wakerWhispers` pools in `ur-noth.json` (early/familiar/proprietary/
  milestones/nudges).
- **Touch points:** `devotion_system.cast()` and `blessing_strength()` multiply
  by `godhead_system.strength(god_id)` · sanctum tithe forwards a godhead
  share · `verdict_system` consume-remnant sets 0 and flags permanent ·
  God-Death/Rekindling chains are `callings` content (`gods/*.json` gain
  `firstShrinePoiId`).
- **Save:** one small world-level dict (`godhead: {god_id: pct}`, plus
  `keystones_defeated`); trivially replicated — host-authoritative like
  everything else.
- **Economy model:** extend `tools/economy-model.mjs` with a godhead sheet —
  assert the 5–8%-under-cap band, assert neglect can't gutter, assert Ur-Noth
  theft-per-benefit stays tempting-but-costly.

---

## Milestone placement

- **M2 (the Soul):** Godhead core (cap, formula, rite/tithe sources, UI
  numbers) — it deepens the worship loop M2 exists to prove. **The Waker
  (§5) core ships here too**: whisper-on-wake, the feed, Drowning-Scars —
  it's cheap (respawn already exists; this is one event handler + flavor
  data) and it makes every death on day one already mean something. Villager
  Arms classes + leveling + equipment, party-of-1 road test.
- **M3:** party cap 2, downed/death/memorial, shrine-restoration POIs, first
  keystone dedication moment, debt-milestone Callings.
- **M4:** God-Death + Rekindling + the Waking Callings, guttered- and
  dead-god world states (including the no-Waker death fallback), Acolyte
  Intercession tier.

## Decisions taken (2026-07-17)

- **Villager permadeath is permanent** — no softer "carried home" tier. Dead
  is dead; the memorial work and the corpse-run for their gear are the whole
  of the consolation.
- **God death is NOT permanent — consumption is.** A killed god can be woken
  via the Rite of Waking so long as their remnant survives; consuming the
  remnant is the game's one truly irreversible act, said in exactly those
  words at the moment of choice.
- **Player death powers Ur-Noth (the Waker, §5)** — he alone restores dead
  players, whispering as they wake; the world cost is his Godhead feed
  (per-player diminishing, floored), the personal cost is Drowning-Scars.
  This closes GAME-SPEC design question #2 (death penalty): corpse-run +
  patron-flavored resurrection, by the wrong patron.

## Open questions (for Jeff)

1. **Keystone dedication** — +8% to ONE god per boss is a strong
   favorite-picking moment; or split-allowed (weaker moment, kinder to broad
   builds)? Lean: one god, no split — the game is better when it makes you
   choose. *(Jeff: no opinion yet — parked.)*
2. **Godhead per-player vs. world:** spec'd world-level (it's the god's body,
   and co-op sharing one pantheon is the point). Confirm you don't want
   per-player godhead — it would read as six private gods.
3. **Acolyte trio at EA** — Warrior/Archer/Acolyte enough, or is a 4th
   (Ghal handler) worth the slice cost?
4. **Level cap 10 with 3/6/9 ignition** — or 20 with 5/10/15/20 for a longer
   tail? Lean: 10; villagers should max out and *be* maxed companions, not
   treadmills.
5. **Party cap 2** at EA — confirm (4 doubles pathing + netcode surface).
6. **Waking vigil length** — how many attended in-game days? Lean 5: long
   enough to be a story, short enough to not be a second job.
7. **Scar depth** — −10% max HP per stack, cap 5 (worst wake = half of you)?
   Or shallower (−5%, cap 4) if playtests show death spirals? The scar is
   the anti-zerg lever, so tune it against boss retry feel in M3.
8. **Does high Ur-Noth Godhead do anything AMBIENT?** His feed means careless
   servers fatten him passively. Options: nothing (he's just ready when his
   faithful call — cheapest, fine); or a soft pressure tell (darker nights,
   +whisper frequency, villager susceptibility drift +) so a fat Ur-Noth is
   *felt*. Lean: the tell — the world should know what it's been feeding.
