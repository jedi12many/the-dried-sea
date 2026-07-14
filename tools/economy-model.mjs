#!/usr/bin/env node
/**
 * economy-model.mjs — expected-value model of the Vigor economy.
 * Answers: at each stage of the game, how often can a player afford a clutch cast?
 * Spec law (WORLD-SPEC): magic saves your life ~once per pickle — if a player can
 * cast daily on a shrine-tier setup, we tuned it wrong. Deterministic (no RNG):
 * this is a spreadsheet with opinions, not a simulation.
 *
 * Usage: node tools/economy-model.mjs
 * Exits 1 if any profile lands outside its spec band (so it can gate CI).
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(import.meta.url), "..", "..");
const econ = JSON.parse(readFileSync(join(ROOT, "data/content/tuning/economy.json"), "utf8"));

const AVG_CAST_COST_FRAC = 0.37; // mean vigorCost across seeded invocations (validator keeps these honest)
const MAX_VIGOR = econ.vigor.defaultMax;

/** Sustainable casts/day for one god = daily Vigor income / avg cast cost. */
function sustainableCastsPerDay({ churchTier, priestRank, devoutVillagers, offeringMult }) {
  const rite = econ.worship.riteRecoveryPerDayByChurchTier[churchTier] ?? 0;
  const priestMult = econ.worship.priestRankMult[priestRank - 1] ?? 1.0;
  const trickle = devoutVillagers * econ.worship.devoutVillagerTricklePerDay;
  const daily = rite * priestMult * (offeringMult ?? 1.0) + trickle;
  return daily / (AVG_CAST_COST_FRAC * MAX_VIGOR);
}

const profiles = [
  // name, setup, spec band [min,max] casts/day, rationale
  { name: "Early game — found shrine, no priest, no village",
    setup: { churchTier: "shrine", priestRank: 1, devoutVillagers: 0 },
    band: [0.05, 0.2], why: "magic should feel like a miracle you save for weeks" },
  { name: "Mid game — chapel + priest r1, 3 devout villagers",
    setup: { churchTier: "chapel", priestRank: 1, devoutVillagers: 3 },
    band: [0.2, 0.45], why: "a clutch cast every 2-4 days: 'once per pickle'" },
  { name: "Late game — church + priest r2, 6 devout villagers",
    setup: { churchTier: "church", priestRank: 2, devoutVillagers: 6 },
    band: [0.5, 0.9], why: "approaching one/day but never free-flowing" },
  { name: "Endgame devoted — basilica + priest r3, 8 devout, offerings maxed",
    setup: { churchTier: "basilica", priestRank: 3, devoutVillagers: 8, offeringMult: econ.worship.offeringBuydownMaxMult },
    band: [2.0, 3.2], why: "Tidebringer-campaign tempo: rites at scale, still not spammable" },
  { name: "Broad build — 3 gods on chapels, priest r1, 2 devout each (PER GOD)",
    setup: { churchTier: "chapel", priestRank: 1, devoutVillagers: 2 },
    band: [0.15, 0.4], why: "breadth: more total pools but each recovers slower (worship time splits)" },
];

let failed = 0;
console.log("Vigor economy — sustainable clutch casts per day\n");
for (const p of profiles) {
  const v = sustainableCastsPerDay(p.setup);
  const ok = v >= p.band[0] && v <= p.band[1];
  if (!ok) failed++;
  console.log(`${ok ? "  ok " : "  FAIL"}  ${v.toFixed(2)} /day  [${p.band[0]}–${p.band[1]}]  ${p.name}`);
  console.log(`        ${p.why}`);
}

// Dormancy check: how deep does one cast cut, and how long to climb out of dormant?
const midDaily = sustainableCastsPerDay(profiles[1].setup) * AVG_CAST_COST_FRAC * MAX_VIGOR;
const daysToFullFromDormant = (MAX_VIGOR - econ.vigor.dormantThreshold) / midDaily;
console.log(`\nMid-game recovery from Dormant to full: ${daysToFullFromDormant.toFixed(1)} sim-days`);
if (daysToFullFromDormant < 4 || daysToFullFromDormant > 12) {
  failed++;
  console.log("  FAIL  spec wants dormancy to hurt for ~a week of play (4–12 days)");
} else {
  console.log("  ok    dormancy is a real consequence, not a timeout");
}

console.log(`\n${failed ? `${failed} profile(s) OUTSIDE spec bands` : "all profiles inside spec bands"}`);
process.exit(failed ? 1 : 0);
