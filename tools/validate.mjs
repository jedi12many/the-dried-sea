#!/usr/bin/env node
/**
 * validate.mjs — dependency-free content validator.
 * Structural checks per type + cross-reference resolution + design-law lints.
 * (Full JSON Schema files in data/schemas/ are the documentation contract;
 * this script enforces the practically-checkable subset plus the laws no
 * schema language can express.)
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(import.meta.url), "..", "..");
const CONTENT = join(ROOT, "data", "content");
const errors = [];
const warns = [];
const err = (f, m) => errors.push(`${f}: ${m}`);
const warn = (f, m) => warns.push(`${f}: ${m}`);

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (name.endsWith(".json")) yield p;
  }
}

// ---- load everything -------------------------------------------------------
const docs = []; // {file, data}
for (const p of walk(CONTENT)) {
  const file = relative(ROOT, p).replaceAll("\\", "/");
  try {
    const data = JSON.parse(readFileSync(p, "utf8"));
    docs.push({ file, data });
  } catch (e) {
    err(file, `invalid JSON — ${e.message}`);
  }
}

const byId = new Map(); // id -> file
const entities = []; // {file, obj}
for (const { file, data } of docs) {
  if (file.includes("/tuning/")) continue;
  const list = Array.isArray(data) ? data : [data];
  for (const obj of list) {
    entities.push({ file, obj });
    if (!obj.id) { err(file, `entity missing id (${obj.name ?? "?"})`); continue; }
    if (!/^[a-z0-9-]+$/.test(obj.id)) err(file, `id not kebab-case: ${obj.id}`);
    if (byId.has(obj.id)) err(file, `duplicate id ${obj.id} (also in ${byId.get(obj.id)})`);
    byId.set(obj.id, file);
  }
}

const idsWith = (prefix) => [...byId.keys()].filter((k) => k.startsWith(prefix));
const exists = (id) => byId.has(id);
const type = (id) => id?.split("-")[0];

// ---- per-type checks --------------------------------------------------------
const REQUIRED = {
  god: ["name", "title", "domain", "voice", "blessing", "invocations", "priest"],
  work: ["name", "godId", "category", "buildCost", "text"],
  item: ["name", "category", "text"],
  recipe: ["track", "output", "inputs"],
  trait: ["name", "axis", "text", "discovery"],
  class: ["name", "text"],
  calling: ["title", "tier", "source", "giver", "steps", "echo", "status"],
  people: ["name", "biomeId", "brink", "wealth", "reactions", "lore"],
  creature: ["name", "biomeId", "archetype", "stats", "text"],
  biome: ["name", "band", "text"],
  virtue: ["name", "godId", "text", "talents"],
  arms: ["name", "text", "primaries", "hpPerLevelPct", "primaryPerLevelPct", "talents", "behavior"],
  inv: null, // sub-entities, skipped
};

// effect objects (common.schema.json #/$defs/effect) — the practically-checkable shape
const EFFECT_KEYS = new Set(["type", "magnitude", "duration", "radius", "target", "params"]);
function checkEffects(file, owner, effects, ctx) {
  for (const eff of effects ?? []) {
    if (!eff.type) err(file, `${owner}/${ctx} effect missing 'type'`);
    for (const k of Object.keys(eff))
      if (!EFFECT_KEYS.has(k)) err(file, `${owner}/${ctx} effect has unknown key '${k}'`);
  }
}

const refFields = []; // [file, id, refId, context]
const ref = (file, owner, refId, ctx) => refId && refFields.push([file, owner, refId, ctx]);

for (const { file, obj } of entities) {
  const t = type(obj.id);
  const req = REQUIRED[t];
  if (req === undefined) { warn(file, `unknown entity type '${t}' for ${obj.id}`); continue; }
  if (req === null) continue;
  for (const k of req) if (obj[k] === undefined) err(file, `${obj.id} missing required '${k}'`);

  if (t === "work") {
    if (obj.godId !== "neutral") ref(file, obj.id, obj.godId, "godId");
    for (const c of obj.buildCost ?? []) ref(file, obj.id, c.itemId, "buildCost");
    if (obj.grim && !obj.grimRules) err(file, `${obj.id} grim=true requires grimRules (kinder alternative is a design LAW)`);
    if (obj.grim && obj.godId !== "god-ur-noth") warn(file, `${obj.id} is grim but not Ur-Noth's — intended?`);
    if ((obj.favorTrickle ?? 0) > 0 && !obj.useDetection) err(file, `${obj.id} trickles favor but has no useDetection — idle works must feed nothing`);
    if (obj.sanctum && (obj.sanctum.relicSlots ?? 0) < 1) err(file, `${obj.id} sanctum.relicSlots must be >= 1`);
  }
  if (t === "god") {
    for (const inv of obj.invocations ?? []) {
      if (inv.vigorCost > 0 && inv.vigorCost < 0.15 && !obj.flags?.includes("missing"))
        warn(file, `${inv.id} vigorCost ${inv.vigorCost} is cheap — 'magic saves your life once per pickle', check tuning`);
    }
    for (const legendId of obj.affinityLegendIds ?? []) ref(file, obj.id, legendId, "affinityLegendIds");
    for (const lane of ["craves", "accepts", "offends"])
      for (const itemId of obj.offerings?.[lane] ?? []) ref(file, obj.id, itemId, `offerings.${lane}`);
  }
  if (t === "recipe") {
    ref(file, obj.id, obj.output?.itemId, "output");
    for (const c of obj.inputs ?? []) ref(file, obj.id, c.itemId, "inputs");
    if (obj.stationWorkId) ref(file, obj.id, obj.stationWorkId, "stationWorkId");
    if (obj.track === "legend" && !obj.unlock?.fragments) err(file, `${obj.id} legend recipe must unlock by PLACED fragments, never the tree`);
    if (obj.track === "legend" && !obj.ritual) warn(file, `${obj.id} legend final without ritual — the craft should be an event`);
  }
  if (t === "people") {
    ref(file, obj.id, obj.biomeId, "biomeId");
    for (const a of obj.brink?.exploitActions ?? []) {
      if (!a.attribution) err(file, `${obj.id}/${a.id} exploit action missing attribution (ledgers read causes)`);
      for (const y of a.yield ?? []) ref(file, obj.id, y.itemId, "exploit yield");
    }
    for (const cid of obj.wealth?.uniqueRecruitClassIds ?? []) ref(file, obj.id, cid, "uniqueRecruit");
    for (const iid of obj.wealth?.fairTrade ?? []) ref(file, obj.id, iid, "fairTrade");
  }
  if (t === "creature") {
    ref(file, obj.id, obj.biomeId, "biomeId");
    for (const d of obj.drops ?? []) ref(file, obj.id, d.itemId, "drops");
    if (obj.remnantItemId) ref(file, obj.id, obj.remnantItemId, "remnant");
    if (obj.archetype === "boss" && !obj.bossNotes) warn(file, `${obj.id} boss without bossNotes`);

    // ---- tame block (VILLAGER-AND-GODHEAD-SPEC Part III, Beasts at Heel) ----
    if (obj.tame) {
      const tm = obj.tame;
      ref(file, obj.id, tm.cravedFoodItemId, "tame.cravedFoodItemId");
      ref(file, obj.id, tm.keepsakeItemId, "tame.keepsakeItemId");
      if (!Array.isArray(tm.namePool) || tm.namePool.length < 1)
        err(file, `${obj.id} tame.namePool must be a non-empty array`);
      const instincts = tm.instincts ?? [];
      const tiers = instincts.map((i) => i.tier);
      if (JSON.stringify(tiers) !== JSON.stringify([3, 6, 9]))
        err(file, `${obj.id} tame.instincts must be exactly the 3/6/9 ignition trio (got [${tiers}])`);
      for (const ins of instincts) {
        for (const k of ["id", "name", "text"]) if (ins[k] === undefined) err(file, `${obj.id} tame instinct missing '${k}'`);
        if (!ins.effects?.length) err(file, `${obj.id}/${ins.id} instinct with no effects — sheet candy is not an instinct`);
        checkEffects(file, obj.id, ins.effects, ins.id ?? "?");
      }
      const b = tm.behavior ?? {};
      if (b.role === "porter") {
        if (b.carrySlots === undefined) err(file, `${obj.id} tame.behavior role=porter needs carrySlots`);
        if (b.engageRange !== undefined || b.breakHpPct !== undefined)
          err(file, `${obj.id} tame.behavior role=porter shouldn't carry fighter keys (engageRange/breakHpPct)`);
      } else if (b.role === "fighter") {
        if (b.engageRange === undefined || b.breakHpPct === undefined)
          err(file, `${obj.id} tame.behavior role=fighter needs engageRange + breakHpPct`);
        if (b.carrySlots !== undefined) err(file, `${obj.id} tame.behavior role=fighter shouldn't carry carrySlots`);
        if (typeof b.breakHpPct === "number" && (b.breakHpPct < 0 || b.breakHpPct > 1))
          err(file, `${obj.id} tame.behavior.breakHpPct must be a 0..1 fraction`);
      } else {
        err(file, `${obj.id} tame.behavior.role must be 'porter' or 'fighter' (got '${b.role}')`);
      }
      const bt = docs.find(({ file: f }) => f.endsWith("tuning/beasts.json"))?.data;
      if (bt && !Object.keys(bt.wildTierGate ?? {}).map(Number).includes(tm.tier))
        err(file, `${obj.id} tame.tier ${tm.tier} has no matching tuning/beasts.json wildTierGate entry`);
    }
  }
  if (t === "biome") {
    for (const k of ["resourceItemIds", "creatureIds", "peopleIds"]) for (const id of obj[k] ?? []) ref(file, obj.id, id, k);
    if (obj.bossCreatureId) ref(file, obj.id, obj.bossCreatureId, "boss");
    if (obj.signatureLegendItemId) ref(file, obj.id, obj.signatureLegendItemId, "signatureLegend");
  }
  if (t === "virtue") {
    ref(file, obj.id, obj.godId, "godId");
    const thresholds = (obj.talents ?? []).map((tal) => tal.threshold);
    if (JSON.stringify(thresholds) !== JSON.stringify([...thresholds].sort((a, b) => a - b)))
      err(file, `${obj.id} talents must ascend by threshold`);
    for (const tal of obj.talents ?? [])
      if (!tal.effects?.length) err(file, `${obj.id}/${tal.id} talent with no effects — sheet candy is not a talent`);
  }
  if (t === "class") {
    for (const w of obj.stationWorkIds ?? []) ref(file, obj.id, w, "stationWorkIds");
    if (obj.uniqueToPeopleId) ref(file, obj.id, obj.uniqueToPeopleId, "uniqueToPeopleId");
  }

  // ---- arms classes (VILLAGER-AND-GODHEAD-SPEC Part I) ----------------------
  if (t === "arms") {
    const talents = obj.talents ?? [];
    const tiers = talents.map((tal) => tal.tier);
    if (JSON.stringify(tiers) !== JSON.stringify([3, 6, 9]))
      err(file, `${obj.id} talents must be exactly the 3/6/9 ignition trio (got [${tiers}])`);
    for (const tal of talents) {
      for (const k of ["id", "name", "text"]) if (tal[k] === undefined) err(file, `${obj.id} talent missing '${k}'`);
      if (!tal.effects?.length) err(file, `${obj.id}/${tal.id} talent with no effects — sheet candy is not a talent`);
      checkEffects(file, obj.id, tal.effects, tal.id ?? "?");
    }
    if (!Array.isArray(obj.primaries) || obj.primaries.length < 1)
      err(file, `${obj.id} needs at least one primary stat`);
    const b = obj.behavior ?? {};
    for (const k of ["engageRange", "breakHpPct", "holdGround"])
      if (b[k] === undefined) err(file, `${obj.id} behavior missing '${k}'`);
    if (typeof b.breakHpPct === "number" && (b.breakHpPct < 0 || b.breakHpPct > 1))
      err(file, `${obj.id} behavior.breakHpPct must be a 0..1 fraction`);
    if (obj.requires !== undefined) {
      for (const k of Object.keys(obj.requires))
        if (!["minFaith", "needsPatron"].includes(k)) err(file, `${obj.id} requires has unknown key '${k}'`);
    }
  }

  // ---- calling design-law lints (the machine-checkable anti-shallow laws) ---
  if (t === "calling") {
    const c = obj;
    if (!c.giver?.name || !c.giver?.wound) err(file, `${c.id} LAW 1: a name and a wound — both required`);
    else if (!/withdraw|sea|drown|salt|tide|left/i.test(c.giver.wound)) warn(file, `${c.id} LAW 1: wound may not be rooted in the Withdrawal — curator judgment`);
    const hasTurn = (c.steps ?? []).some((s) => s.type === "turn" || (s.type === "choice" && (s.options?.length ?? 0) >= 2));
    if (!hasTurn) err(file, `${c.id} LAW 2: no turn/choice step — the quest must not be what it appeared`);
    if (!c.echo?.text) err(file, `${c.id} LAW 3: no echo — something observable must change`);
    for (const s of c.steps ?? []) {
      if (["kill", "collect"].includes(s.type) && (s.text ?? "").length < 60)
        err(file, `${c.id}/${s.id} LAW 4: bare verb — '${s.type}' needs its story clothing (${(s.text ?? "").length} chars)`);
    }
    if (c.status === "curated" || c.status === "live") warn(file, `${c.id} status='${c.status}' — LAW 5: only Jeff sets this. Verify.`);
    if (c.tier === "deep" && !c.deep) err(file, `${c.id} tier=deep requires deep.worldEffects`);
    if (c.source === "god-dream" && !c.sourceGodId) err(file, `${c.id} god-dream requires sourceGodId`);
    // step graph integrity
    const stepIds = new Set((c.steps ?? []).map((s) => s.id));
    for (const s of c.steps ?? []) {
      if (s.next && !stepIds.has(s.next)) err(file, `${c.id}/${s.id} next -> unknown step '${s.next}'`);
      for (const o of s.options ?? []) if (o.next && !stepIds.has(o.next)) err(file, `${c.id}/${s.id} option -> unknown step '${o.next}'`);
    }
    // ---- step params vocabulary (calling.schema.json params $comment) --------
    // The runtime (main.gd _step_met) enforces these at play; the validator
    // enforces them at authoring time so a typo'd key or anchor never ships.
    const ANCHORS = new Set(["shrine-halor", "shrine-maren", "shrine-neris",
      "wreck-west", "wreck-mid", "wreck-east", "boss-ring", "village", "brine-pool", "trench-edge"]);
    const PARAM_KEYS = {
      goto: ["near", "radius"], escort: ["near", "radius"], talk: ["at", "radius"],
      collect: ["itemId", "qty", "consume"], turn: ["itemId", "qty", "consume"],
      kill: ["creatureId", "count"], build: ["workId"], wait: ["until", "days"],
    };
    for (const s of c.steps ?? []) {
      const p = s.params;
      if (p === undefined) continue;
      const where = `${c.id}/${s.id}`;
      if (s.type === "choice") { err(file, `${where} choice steps take no params`); continue; }
      const allowed = PARAM_KEYS[s.type];
      if (!allowed) { err(file, `${where} type '${s.type}' takes no params`); continue; }
      for (const k of Object.keys(p))
        if (!allowed.includes(k)) err(file, `${where} params has unknown key '${k}' for type '${s.type}' (allowed: ${allowed.join(", ")})`);
      if (s.type === "goto" || s.type === "escort") {
        if (!p.near) err(file, `${where} ${s.type} params need 'near'`);
        else if (!ANCHORS.has(p.near)) err(file, `${where} unknown anchor '${p.near}' (documented list: ${[...ANCHORS].join(", ")})`);
      }
      if (s.type === "talk") {
        if (!p.at) err(file, `${where} talk params need 'at'`);
        else if (!ANCHORS.has(p.at)) err(file, `${where} unknown anchor '${p.at}'`);
      }
      if (typeof p.radius === "number" && (p.radius < 60 || p.radius > 400))
        warn(file, `${where} radius ${p.radius}px is outside the sane 60-400 band`);
      if (s.type === "collect" || s.type === "turn") {
        if (!p.itemId) err(file, `${where} ${s.type} params need 'itemId'`);
        else ref(file, c.id, p.itemId, `${s.id} params.itemId`);
        if (!(Number.isInteger(p.qty) && p.qty >= 1)) err(file, `${where} params.qty must be an integer >= 1`);
        if (s.type === "turn" && (s.options?.length ?? 0) > 0)
          err(file, `${where} a turn with options never evaluates params — drop one or the other`);
      }
      if (s.type === "kill") {
        if (!p.creatureId) err(file, `${where} kill params need 'creatureId'`);
        else ref(file, c.id, p.creatureId, `${s.id} params.creatureId`);
        if (!(Number.isInteger(p.count) && p.count >= 1)) err(file, `${where} params.count must be an integer >= 1`);
      }
      if (s.type === "build") {
        if (!p.workId) err(file, `${where} build params need 'workId'`);
        else ref(file, c.id, p.workId, `${s.id} params.workId`);
      }
      if (s.type === "wait") {
        if (!["storm", "storm-end", "days"].includes(p.until)) err(file, `${where} wait params.until must be 'storm', 'storm-end' or 'days'`);
        if (p.until === "days" && !(Number.isInteger(p.days) && p.days >= 1)) err(file, `${where} wait until:'days' needs integer params.days >= 1`);
        if (p.until !== "days" && p.days !== undefined) err(file, `${where} params.days only belongs with until:'days'`);
      }
    }
  }
}

// ---- cross-reference resolution ----------------------------------------------
for (const [file, owner, refId, ctx] of refFields) {
  if (!exists(refId)) err(file, `${owner} ${ctx} -> unresolved id '${refId}'`);
}

// ---- pantheon sanity -----------------------------------------------------------
const gods = idsWith("god-");
if (gods.length && gods.length !== 7) warn("pantheon", `expected 7 gods (6 + the empty seat), found ${gods.length}`);

// ---- villager Arms track (VILLAGER-AND-GODHEAD-SPEC Part I) ---------------------
{
  const armsIds = idsWith("arms-").filter((id) => !id.startsWith("arms-talent-"));
  if (armsIds.length < 3) err("arms-classes", `expected the EA trio (warrior/archer/acolyte), found ${armsIds.length}`);
  for (const id of ["arms-warrior", "arms-archer", "arms-acolyte"])
    if (!exists(id)) err("arms-classes", `missing EA class '${id}'`);
  // the drill-yard trains them; the memorial keeps them
  for (const id of ["work-drill-yard", "work-memorial"])
    if (!exists(id)) err("works", `missing Part-I work '${id}'`);

  const vt = docs.find(({ file }) => file.endsWith("tuning/villagers.json"))?.data;
  if (!vt) err("tuning/villagers.json", "missing — the Arms track is tuning-driven");
  else {
    for (const k of ["xp", "xpSources", "xpMults", "distressedExpressions", "hpPerLevelPct",
      "primaryPerLevelPct", "baseVillagerHp", "equipmentSlots", "partyCap",
      "downedSeconds", "griefDays", "memorialGriefMult"])
      if (vt[k] === undefined) err("tuning/villagers.json", `missing required key '${k}'`);
    if (vt.xp && (vt.xp.curveConstant === undefined || vt.xp.maxLevel === undefined))
      err("tuning/villagers.json", "xp needs curveConstant + maxLevel");
    for (const k of ["killAssistByTier", "expeditionReturn", "villageDefense", "drillDay", "riteLed"])
      if (vt.xpSources?.[k] === undefined) err("tuning/villagers.json", `xpSources missing '${k}'`);
    if (vt.xpSources?.killAssistByTier && !Array.isArray(vt.xpSources.killAssistByTier))
      err("tuning/villagers.json", "xpSources.killAssistByTier must be an array indexed by threat tier");
    for (const k of ["bloomed", "broken", "distressedExpression"])
      if (vt.xpMults?.[k] === undefined) err("tuning/villagers.json", `xpMults missing '${k}'`);
    // 'bloom beats Broken over any long run' — the multipliers must enforce the law
    if (vt.xpMults && !(vt.xpMults.bloomed > 1 && vt.xpMults.broken < 1))
      err("tuning/villagers.json", "xpMults must keep bloomed > 1 > broken (bloom beats Broken is a design LAW)");
  }
}

// ---- Godhead (VILLAGER-AND-GODHEAD-SPEC Part II) -------------------------------
{
  const gt = docs.find(({ file }) => file.endsWith("tuning/godhead.json"))?.data;
  if (!gt) err("tuning/godhead.json", "missing — Godhead is tuning-driven");
  else {
    if (gt.cap?.base === undefined || gt.cap?.perBiomeCap === undefined)
      err("tuning/godhead.json", "cap needs base + perBiomeCap");
    for (const k of ["riteLedByChurchTier", "dawnTithePerCravedItem", "devoutVillagerTricklePerDay", "enshrinedRemnant"])
      if (gt.sources?.[k] === undefined) err("tuning/godhead.json", `sources missing '${k}'`);
    for (const k of ["offenseLaidOnAltar", "urNothGrimRitePerRite", "neglect"])
      if (gt.sinks?.[k] === undefined) err("tuning/godhead.json", `sinks missing '${k}'`);
    const w = gt.waker ?? {};
    for (const k of ["feedPct", "repeatDecay", "decayWindowDays", "floorPct", "washIfAttuned", "whisperPoolThresholds", "noWakerFallback"])
      if (w[k] === undefined) err("tuning/godhead.json", `waker missing '${k}'`);
    if (w.noWakerFallback && (w.noWakerFallback.highestGodDrainPct === undefined || w.noWakerFallback.fallbackWakeHpPct === undefined))
      err("tuning/godhead.json", "waker.noWakerFallback needs highestGodDrainPct + fallbackWakeHpPct");
  }
}

// ---- Beasts at Heel (VILLAGER-AND-GODHEAD-SPEC Part III) -----------------------
{
  const bt = docs.find(({ file }) => file.endsWith("tuning/beasts.json"))?.data;
  if (!bt) err("tuning/beasts.json", "missing — beast taming is tuning-driven");
  else {
    for (const k of ["mealsByTier", "ghalRankMealDiscount", "minMeals", "wildTierGate",
      "unfedMoodDays", "porterDayXp", "trustDecayDays", "xp"])
      if (bt[k] === undefined) err("tuning/beasts.json", `missing required key '${k}'`);
    if (bt.mealsByTier && !Array.isArray(bt.mealsByTier)) err("tuning/beasts.json", "mealsByTier must be an array indexed by tier");
  }
  // one Ghal home, not two (CRAFT-AND-BUILD-SPEC Part 0 audit item 2 / Part 3)
  if (!exists("work-kennel")) err("works", "missing Part-III work 'work-kennel'");
  if (exists("work-beast-pen")) err("works", "work-beast-pen should not exist — it was renamed to work-kennel");
}

// ---- wakerWhispers shape (any god that carries them) ---------------------------
for (const { file, obj } of entities) {
  if (type(obj.id) !== "god" || !obj.wakerWhispers) continue;
  const ww = obj.wakerWhispers;
  for (const pool of ["early", "familiar", "proprietary"])
    if (!Array.isArray(ww[pool]) || ww[pool].length < 1) err(file, `${obj.id} wakerWhispers.${pool} must be a non-empty array`);
  if (ww.milestones)
    for (const k of Object.keys(ww.milestones))
      if (!/^[0-9]+$/.test(k)) err(file, `${obj.id} wakerWhispers.milestones key '${k}' must be a death-count integer`);
}

// ---- report -------------------------------------------------------------------
for (const w of warns) console.log(`  warn  ${w}`);
for (const e of errors) console.log(`  ERROR ${e}`);
console.log(`\n${entities.length} entities, ${refFields.length} refs checked — ${errors.length} error(s), ${warns.length} warning(s)`);
process.exit(errors.length ? 1 : 0);
