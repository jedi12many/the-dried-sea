class_name VillageSystem
extends RefCounted
## Tribesmen: classes, traits, hidden disposition, Keys, bloom, the Taken.
## Design laws enforced here: origin is a door not a destiny; bloom beats
## Broken over any long run; fear accelerates drift (tyranny self-defeats);
## punish paranoia, never vigilance.
## Server-authoritative; ticks on sim_day.

var registry: Registry
var tune: Dictionary

var tribesmen: Dictionary = {}   # runtime id -> record
var _next_id := 1
var fear_days_remaining := 0     # village-wide, from evidence-free punishment

signal expression_changed(tribesman_id: int, expression: String)
signal bloomed(tribesman_id: int)
signal ledger_event(ledger: String, amount: float, note: String)

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("disposition", {})

## --- roster ------------------------------------------------------------------
func add_tribesman(display_name: String, class_id: String, origin: String, trait_ids: Array = [], patron_god_id: String = "") -> int:
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
	}
	for tid: String in trait_ids:
		var mods: Dictionary = registry.get_entity(tid).get("dispositionMods", {})
		rec.faith += float(mods.get("faithBase", 0))
	var id := _next_id
	_next_id += 1
	tribesmen[id] = rec
	return id

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
