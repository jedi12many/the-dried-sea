class_name VillageSystem
extends RefCounted
## Tribesmen: classes, traits, hidden disposition, Keys, bloom, the Taken.
## Design laws enforced here: origin is a door not a destiny; bloom beats
## Broken over any long run; fear accelerates drift (tyranny self-defeats);
## punish paranoia, never vigilance.
## Server-authoritative; ticks on sim_day.

var registry: Registry
var tune: Dictionary
var vtune: Dictionary            # tuning/villagers.json — the Arms track

var tribesmen: Dictionary = {}   # runtime id -> record
var _next_id := 1
var fear_days_remaining := 0     # village-wide, from evidence-free punishment
var grief_days_remaining := 0    # village-wide, from a death on the road
var has_memorial := false        # set by presentation when work-memorial stands; sim never reads works directly

signal expression_changed(tribesman_id: int, expression: String)
signal bloomed(tribesman_id: int)
signal ledger_event(ledger: String, amount: float, note: String)
signal arms_leveled(tribesman_id: int, new_level: int)
signal arms_talent_ignited(tribesman_id: int, talent_id: String)

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("disposition", {})
	vtune = reg.tuning.get("villagers", {})

## --- roster ------------------------------------------------------------------
func add_tribesman(display_name: String, class_id: String, origin: String, trait_ids: Array = [], patron_god_id: String = "", starting_arms: String = "") -> int:
	var profile: Dictionary = tune.get("startProfiles", {}).get(origin, tune.get("axes", {}))
	var rec := {
		"name": display_name, "class_id": class_id, "origin": origin,
		"faith": float(profile.get("faith", 50)),
		"grievance": float(profile.get("grievance", 10)),
		"susceptibility": float(profile.get("susceptibility", 30)),
		"traits": trait_ids.duplicate(), "discovered": [],
		"patron_god_id": patron_god_id,
		"key": _pick_key(trait_ids), "key_met": false, "bloomed": false,
		"expression": "steady", "warden_covered": true,
		"arms": {"class_id": "", "xp": 0.0, "levels_by_class": {}},
		"equipment": _blank_equipment(),
		"on_road": false, "downed_until": 0.0,
	}
	for tid: String in trait_ids:
		var mods: Dictionary = registry.get_entity(tid).get("dispositionMods", {})
		rec.faith += float(mods.get("faithBase", 0))
	var id := _next_id
	_next_id += 1
	tribesmen[id] = rec
	if starting_arms != "":   # wardens arrive Warrior 1, priests Acolyte 1 — presentation's call
		train_arms(id, starting_arms)
	return id

## Slots are data-driven (tuning/villagers.json equipmentSlots) — the game's
## existing 3-slot doll today, easy to grow when the doll grows.
func _blank_equipment() -> Dictionary:
	var out: Dictionary = {}
	for slot: String in vtune.get("equipmentSlots", ["weapon", "armor", "trinket"]):
		out[slot] = ""
	return out

func _pick_key(trait_ids: Array) -> String:
	for tid: String in trait_ids:
		var hints: Array = registry.get_entity(tid).get("keyHints", [])
		if hints.size() > 0:
			return str(hints[0].get("key", ""))
	return "grievance-heard"  # everyone has at least this door

## --- the Key & bloom ------------------------------------------------------------
func meet_key(id: int) -> void:
	var rec: Dictionary = tribesmen[id]
	if rec.key_met:
		return
	rec.key_met = true
	if rec.origin != "broken":  # the Broken cannot bloom — that's what the Wheel costs THEM
		rec.bloomed = true
		bloomed.emit(id)
		ledger_event.emit("shepherd", 4.0, "key met: %s" % rec.name)

## --- daily drift -------------------------------------------------------------------
## conditions: keys into driftPerDay tables that applied to this villager today.
func drift_day(id: int, conditions: Array = []) -> void:
	var rec: Dictionary = tribesmen[id]
	var tables: Dictionary = tune.get("driftPerDay", {})
	var delta := 0.0
	for c: String in conditions:
		for table_name: String in tables:
			var v: Variant = tables[table_name].get(c)
			if v != null:
				delta += float(v)
	if rec.key_met:
		delta += float(tables.get("attention", {}).get("keyMet", -4))
	if fear_days_remaining > 0:
		delta += float(tables.get("environment", {}).get("villagerExecutedWithoutEvidence", 12)) * 0.5
	if grief_days_remaining > 0:   # a death on the road weighs on everyone, at half the witnessed rate
		delta += float(tables.get("neglect", {}).get("expeditionDeathWitnessed", 8)) * 0.5
	# trait + state multipliers apply to WORSENING only — kindness is never discounted
	if delta > 0.0:
		for tid: String in rec.traits:
			delta *= float(registry.get_entity(tid).get("dispositionMods", {}).get("grievanceGainMult", 1.0))
		if rec.bloomed:
			delta *= float(tune.get("bloom", {}).get("driftResistMult", 0.5))
		if rec.origin == "taken" and not rec.warden_covered:
			delta *= float(tune.get("wardenCoverage", {}).get("uncoveredTakenDriftMult", 2.0))
	rec.grievance = clampf(rec.grievance + delta, 0.0, 100.0)
	_update_expression(id)

func end_of_day() -> void:
	if fear_days_remaining > 0:
		fear_days_remaining -= 1
	if grief_days_remaining > 0:
		grief_days_remaining -= 1

## --- expression ----------------------------------------------------------------------
func composite(id: int) -> float:
	var rec: Dictionary = tribesmen[id]
	return float(rec.grievance) * 0.6 + float(rec.susceptibility) * 0.2

func _update_expression(id: int) -> void:
	var rec: Dictionary = tribesmen[id]
	var thresholds: Dictionary = tune.get("expressionThresholds", {})
	var score := composite(id)
	var current := "steady"
	var best := -1.0
	for expr: String in thresholds:
		if expr.begins_with("$"):  # tuning-file metadata ($comment), not an expression
			continue
		var t := float(thresholds[expr])
		if score >= t and t > best:
			best = t
			current = expr
	if current != rec.expression:
		rec.expression = current
		expression_changed.emit(id, current)

## --- output ---------------------------------------------------------------------------
func output_per_hour(id: int) -> float:
	var rec: Dictionary = tribesmen[id]
	var base: float = float(registry.get_entity(rec.class_id).get("baseOutputPerHour", 1.0))
	for tid: String in rec.traits:
		for eff: Dictionary in registry.get_entity(tid).get("effects", []):
			if eff.get("type", "") == "output-mult":
				base *= float(eff.get("magnitude", 1.0))
	if rec.bloomed:
		base *= float(tune.get("bloom", {}).get("outputMult", 1.6))
	elif rec.origin == "broken":
		base *= float(tune.get("brokenOutputMult", 1.15))
	if rec.expression == "slacking":
		base *= 0.6
	return base

## --- worship contribution ---------------------------------------------------------------
func devout_count(god_id: String) -> int:
	var n := 0
	for id: int in tribesmen:
		var rec: Dictionary = tribesmen[id]
		if rec.patron_god_id == god_id and rec.faith >= 50.0:
			var trickle := 0.0
			for tid: String in rec.traits:
				trickle += float(registry.get_entity(tid).get("dispositionMods", {}).get("vigorTrickle", 0))
			if trickle > 0.0:
				n += 1
	return n

## --- the Arms track (VILLAGER-AND-GODHEAD-SPEC Part I) ---------------------------------------
## Every villager holds up to two classes: the Trade (class_id, above) and the
## Arms (combat kit, trained at the Drill-Yard). Arms classes level 1-10 on the
## tuning curve; talents ignite at 3/6/9 — the player's Six Virtues rhythm read
## into an NPC. Levels bank per class: switching Arms is never erasure.
## Server-authoritative; XP grants flow through here.

## Migration-tolerant accessor: records from older saves grow the block lazily.
func _arms(rec: Dictionary) -> Dictionary:
	if not rec.has("arms"):
		rec["arms"] = {"class_id": "", "xp": 0.0, "levels_by_class": {}}
		rec["equipment"] = _blank_equipment()
		rec["on_road"] = false
		rec["downed_until"] = 0.0
	return rec.arms

## Assign an Arms class (the Drill-Yard's verb). Banks the current class's XP;
## restores the new class at its banked XP (level 1 / 0 XP if never held).
## Enforces the class's requires gate (the Acolyte: faith >= 50 and a patron —
## trait-agnostic villagers never qualify; trait-bitter ones do, frighteningly).
func train_arms(id: int, arms_class_id: String) -> bool:
	var cls: Dictionary = registry.get_entity(arms_class_id)
	if cls.is_empty() or not arms_class_id.begins_with("arms-"):
		return false
	var rec: Dictionary = tribesmen[id]
	var req: Dictionary = cls.get("requires", {})
	if req.has("minFaith") and float(rec.faith) < float(req.minFaith):
		return false
	if req.get("needsPatron", false) and str(rec.patron_god_id) == "":
		return false
	var arms := _arms(rec)
	if str(arms.class_id) == arms_class_id:
		return true
	if str(arms.class_id) != "":
		arms.levels_by_class[str(arms.class_id)] = float(arms.xp)
	arms.class_id = arms_class_id
	arms.xp = float(arms.levels_by_class.get(arms_class_id, 0.0))
	return true

## Level from XP: level n is reached at curveConstant * n^2 total XP
## (25n^2 first guess: L2 at 100, L10 at 2500), clamped 1..maxLevel.
func _level_for_xp(xp: float) -> int:
	var xp_tune: Dictionary = vtune.get("xp", {})
	var c: float = float(xp_tune.get("curveConstant", 25))
	var cap: int = int(xp_tune.get("maxLevel", 10))
	return clampi(int(floorf(sqrt(maxf(xp, 0.0) / c))), 1, cap)

func arms_level(id: int) -> int:
	var arms := _arms(tribesmen[id])
	if str(arms.class_id) == "":
		return 0
	return _level_for_xp(float(arms.xp))

## Banked level for any class this villager has held (current class included).
func arms_level_for(id: int, arms_class_id: String) -> int:
	var arms := _arms(tribesmen[id])
	if str(arms.class_id) == arms_class_id:
		return _level_for_xp(float(arms.xp))
	if arms.levels_by_class.has(arms_class_id):
		return _level_for_xp(float(arms.levels_by_class[arms_class_id]))
	return 0

## Grant XP from a named source (tuning xpSources; killAssist indexes
## killAssistByTier by threat tier). Multipliers: bloomed x1.5 (bloom beats
## Broken, enforced), Broken origin x0.75, distressed expression x0.5 —
## a grieving villager trains badly; disposition leaks into growth.
func grant_xp(id: int, source: String, tier: int = 0) -> void:
	var rec: Dictionary = tribesmen[id]
	var arms := _arms(rec)
	if str(arms.class_id) == "":
		return
	var sources: Dictionary = vtune.get("xpSources", {})
	var amount := 0.0
	if source == "killAssist":
		var tiers: Array = sources.get("killAssistByTier", [])
		if tier >= 0 and tier < tiers.size():
			amount = float(tiers[tier])
	else:
		amount = float(sources.get(source, 0.0))
	if amount <= 0.0:
		return
	var mults: Dictionary = vtune.get("xpMults", {})
	if rec.bloomed:
		amount *= float(mults.get("bloomed", 1.5))
	if rec.origin == "broken":
		amount *= float(mults.get("broken", 0.75))
	var distressed: Array = vtune.get("distressedExpressions", [])
	for e: Variant in distressed:
		if str(e) == str(rec.expression):
			amount *= float(mults.get("distressedExpression", 0.5))
			break
	var level_before := arms_level(id)
	arms.xp = float(arms.xp) + amount
	var level_after := arms_level(id)
	if level_after > level_before:
		arms_leveled.emit(id, level_after)
		for talent: Dictionary in registry.get_entity(str(arms.class_id)).get("talents", []):
			var t := int(talent.tier)
			if t > level_before and t <= level_after:
				arms_talent_ignited.emit(id, str(talent.id))

## Talents whose ignition tier this villager's current level has reached.
func ignited_talents(id: int) -> Array:
	var out: Array = []
	var arms := _arms(tribesmen[id])
	if str(arms.class_id) == "":
		return out
	var level := arms_level(id)
	for talent: Dictionary in registry.get_entity(str(arms.class_id)).get("talents", []):
		if int(talent.tier) <= level:
			out.append(talent)
	return out

## Per-level baseline: +hpPerLevelPct% max HP per level past 1 (class value,
## tuning fallback). An unarmed villager stands at baseVillagerHp.
func villager_max_hp(id: int) -> float:
	var base: float = float(vtune.get("baseVillagerHp", 50))
	var level := arms_level(id)
	if level <= 1:
		return base
	var cls: Dictionary = registry.get_entity(str(_arms(tribesmen[id]).class_id))
	var pct: float = float(cls.get("hpPerLevelPct", vtune.get("hpPerLevelPct", 8)))
	return base * (1.0 + pct / 100.0 * float(level - 1))

## +primaryPerLevelPct% to the class's primaries per level past 1.
func arms_primary_mult(id: int) -> float:
	var level := arms_level(id)
	if level <= 1:
		return 1.0
	var cls: Dictionary = registry.get_entity(str(_arms(tribesmen[id]).class_id))
	var pct: float = float(cls.get("primaryPerLevelPct", vtune.get("primaryPerLevelPct", 2)))
	return 1.0 + pct / 100.0 * float(level - 1)

## --- the road: downed, and the far side of it ---------------------------------------------
## Sim owns the state; presentation owns the timer tick (downedSeconds in tuning).
func mark_downed(id: int, until: float) -> void:
	_arms(tribesmen[id])   # ensure fields on old records
	tribesmen[id].downed_until = until

func revive(id: int) -> void:
	_arms(tribesmen[id])
	tribesmen[id].downed_until = 0.0

func is_downed(id: int) -> bool:
	_arms(tribesmen[id])
	return float(tribesmen[id].downed_until) > 0.0

## Permadeath on the road. Removes the villager, writes the ledger (shepherd -4
## if sent reckless — under-leveled below the biome's band — else 0, mourned),
## starts village-wide grief (halved if the memorial stands: the homestead god
## keeps the dead), and returns their equipment so the caller can drop it where
## they fell. Retrieving a dead companion's sword is a corpse-run with feelings.
func road_death(id: int, reckless: bool = false) -> Dictionary:
	var rec: Dictionary = tribesmen[id]
	_arms(rec)
	var dropped: Dictionary = rec.equipment.duplicate()
	tribesmen.erase(id)
	if reckless:
		ledger_event.emit("shepherd", -4.0, "died on the road, sent reckless: %s" % rec.name)
	else:
		ledger_event.emit("shepherd", 0.0, "mourned: %s" % rec.name)
	var days: int = int(vtune.get("griefDays", 3))
	if has_memorial:
		days = int(ceilf(float(days) * float(vtune.get("memorialGriefMult", 0.5))))
	grief_days_remaining = maxi(grief_days_remaining, days)
	return dropped

## --- justice: punish paranoia, never vigilance ---------------------------------------------
func punish(id: int, kind: String, has_evidence: bool) -> void:
	var rec: Dictionary = tribesmen[id]
	if has_evidence:
		ledger_event.emit("shepherd", 0.0, "justice with evidence: %s (%s)" % [rec.name, kind])
	else:
		var j: Dictionary = tune.get("justice", {}).get("withoutEvidence", {})
		ledger_event.emit("shepherd", float(j.get("ledgerDelta", -15)), "punishment WITHOUT evidence: %s (%s)" % [rec.name, kind])
		fear_days_remaining = maxi(fear_days_remaining, int(j.get("fearDriftDays", 10)))
	if kind == "execute" or kind == "banish":
		tribesmen.erase(id)

## --- the Unbinding (the kind door for the Taken) ----------------------------------------------
## The Salt-Wheel: break a captive fast into the Broken — obedient, productive,
## faithless, forever susceptible. The grim shortcut. Weighs on the ledger.
func break_captive(id: int) -> void:
	var rec: Dictionary = tribesmen[id]
	if rec.origin != "taken":
		return
	var prof: Dictionary = tune.get("startProfiles", {}).get("broken", {})
	rec.origin = "broken"
	rec.faith = float(prof.get("faith", 0))
	rec.grievance = float(prof.get("grievance", 40))
	rec.susceptibility = float(prof.get("susceptibility", 100))
	rec.bloomed = false
	rec.key_met = false
	ledger_event.emit("shepherd", -12.0, "the Salt-Wheel broke %s" % rec.name)
	_update_expression(id)

func unbind(id: int) -> void:
	var rec: Dictionary = tribesmen[id]
	if rec.origin != "taken":
		return
	rec.origin = "rescued"
	rec.grievance = maxf(rec.grievance - 30.0, 0.0)
	rec.susceptibility = float(tune.get("startProfiles", {}).get("rescued", {}).get("susceptibility", 25))
	ledger_event.emit("shepherd", 10.0, "the Unbinding: %s" % rec.name)
	if rec.key == "unbinding-kept" and not rec.key_met:
		meet_key(id)
	_update_expression(id)
