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
  inv: null, // sub-entities, skipped
};

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
  }
}

// ---- cross-reference resolution ----------------------------------------------
for (const [file, owner, refId, ctx] of refFields) {
  if (!exists(refId)) err(file, `${owner} ${ctx} -> unresolved id '${refId}'`);
}

// ---- pantheon sanity -----------------------------------------------------------
const gods = idsWith("god-");
if (gods.length && gods.length !== 7) warn("pantheon", `expected 7 gods (6 + the empty seat), found ${gods.length}`);

// ---- report -------------------------------------------------------------------
for (const w of warns) console.log(`  warn  ${w}`);
for (const e of errors) console.log(`  ERROR ${e}`);
console.log(`\n${entities.length} entities, ${refFields.length} refs checked — ${errors.length} error(s), ${warns.length} warning(s)`);
process.exit(errors.length ? 1 : 0);
