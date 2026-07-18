class_name SanctumSystem
extends RefCounted
## The altar is the god's character sheet. Each altar work (works.json `sanctum`)
## carries RELIC SLOTS (the god's worn equipment — quest-won singulars, displayed,
## never consumed) and an OFFERTORY bag (the god's pack — ordinary goods, taken by
## the dawn tithe). What sits there sets the altar's SPLENDOR, and Splendor
## multiplies the Vigor a rite returns (WORLD-SPEC "The Sanctum").
##
## Appetites: each god's data carries offerings {craves ×2 / accepts ×1 /
## offends ×-2}; anything unlisted is ignored ×0. Bronze means something to
## Neris and nothing to Halor — the pantheon legible through its stomach.
##
## Pure sim: no Node dependencies; server-authoritative; verified in run_tests.

var registry: Registry
var tune: Dictionary

# altar instance id -> {god_id, relics: Array[item_id], bag: {item_id: qty}}
var state: Dictionary = {}

signal offense_laid(player_id: int, god_id: String, item_id: String)

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("sanctum", {})

## --- altar lifecycle (works place/demolish call these) -------------------------
func register(inst_id: int, work_id: String) -> void:
	var work := registry.get_entity(work_id)
	if work.get("sanctum", {}).is_empty():
		return
	if not state.has(inst_id):
		state[inst_id] = {"god_id": str(work.get("godId", "neutral")), "work_id": work_id, "relics": [], "bag": {}}

func unregister(inst_id: int) -> Dictionary:
	## Returns what was on the altar so the caller can refund it to a pack.
	var contents: Dictionary = state.get(inst_id, {})
	state.erase(inst_id)
	return contents

func is_altar(inst_id: int) -> bool:
	return state.has(inst_id)

## The first altar consecrated to a god — rites read this one's Splendor.
func altar_for(god_id: String) -> int:
	for inst_id: int in state:
		if str(state[inst_id].god_id) == god_id:
			return inst_id
	return -1

## --- appetites ------------------------------------------------------------------
func lane(god_id: String, item_id: String) -> String:
	var offerings: Dictionary = registry.get_entity(god_id).get("offerings", {})
	if item_id in offerings.get("craves", []):
		return "craves"
	if item_id in offerings.get("accepts", []):
		return "accepts"
	if item_id in offerings.get("offends", []):
		return "offends"
	return "ignores"

func lane_mult(god_id: String, item_id: String) -> float:
	return float(tune.get("lanes", {}).get(lane(god_id, item_id), 0.0))

## A relic is any item with relic.points. Its god: legend affinity or remnant origin.
func relic_points(item_id: String) -> float:
	return float(registry.get_entity(item_id).get("relic", {}).get("points", 0.0))

func relic_god(item_id: String) -> String:
	var item := registry.get_entity(item_id)
	return str(item.get("legend", {}).get("godAffinity", item.get("remnantOf", "")))

## --- the god's worn equipment (relic slots) --------------------------------------
func relic_slots(inst_id: int, favor_tier: int) -> int:
	if not state.has(inst_id):
		return 0
	var work_sanctum := _work_sanctum(inst_id)
	var base := int(work_sanctum.get("relicSlots", 4))
	var per := int(work_sanctum.get("slotsPerTier", 2))
	return base + per * maxi(favor_tier - 1, 0)

func place_relic(inst_id: int, item_id: String, favor_tier: int) -> bool:
	if not state.has(inst_id) or relic_points(item_id) <= 0.0:
		return false
	var relics: Array = state[inst_id].relics
	if item_id in relics or relics.size() >= relic_slots(inst_id, favor_tier):
		return false
	relics.append(item_id)
	return true

func take_relic(inst_id: int, item_id: String) -> bool:
	if not state.has(inst_id) or item_id not in state[inst_id].relics:
		return false
	state[inst_id].relics.erase(item_id)
	return true

## --- the god's pack (the offertory bag) ------------------------------------------
func deposit(player_id: int, inst_id: int, item_id: String, qty: int) -> bool:
	if not state.has(inst_id) or qty <= 0:
		return false
	var bag: Dictionary = state[inst_id].bag
	bag[item_id] = int(bag.get(item_id, 0)) + qty
	if lane(str(state[inst_id].god_id), item_id) == "offends":
		offense_laid.emit(player_id, str(state[inst_id].god_id), item_id)
	return true

func withdraw(inst_id: int, item_id: String) -> int:
	if not state.has(inst_id):
		return 0
	var bag: Dictionary = state[inst_id].bag
	var qty := int(bag.get(item_id, 0))
	bag.erase(item_id)
	return qty

## --- Splendor ---------------------------------------------------------------------
## 1.0 + relics + offerings, bounded. Variety of craved types beats one giant
## stack (sqrt curve); an offense on the altar drags the whole temple down.
func splendor(inst_id: int) -> float:
	if not state.has(inst_id):
		return 1.0
	var s: Dictionary = state[inst_id]
	var god_id := str(s.god_id)
	var total := 0.0
	for item_id: String in s.relics:
		var mult := 1.0 if relic_god(item_id) == god_id else float(tune.get("relicOffGodMult", 0.5))
		total += relic_points(item_id) * mult
	var k := float(tune.get("offeringScoreK", 0.06))
	for item_id: String in s.bag:
		total += lane_mult(god_id, item_id) * sqrt(float(s.bag[item_id])) * k
	var ceiling := float(tune.get("multiplierCeiling", 2.5))
	return clampf(1.0 + total, 0.5, ceiling)

## --- the dawn tithe ------------------------------------------------------------------
## Each dawn the god takes a little of what was laid out — craved first — and
## that consumption IS worship: a stocked altar is a small standing prayer.
## Returns {"vigor": {god_id: vigor}, "craved": {god_id: count}} — the host
## feeds "vigor" into devotion (per-player Vigor) and "craved" into
## godhead_system.tithe_day (VILLAGER-AND-GODHEAD-SPEC Part II §3: "+0.05% per
## craved item taken" — world-level, so only craved-lane items count, not the
## lesser "accepts" lane that also restores Vigor above).
func dawn_tithe() -> Dictionary:
	var fed := {}
	var craved := {}
	var types_per := int(tune.get("titheTypesPerDawn", 2))
	var qty_per := int(tune.get("titheQtyPerType", 1))
	var vigor_per := float(tune.get("titheVigorPerUnit", 1.0))
	for inst_id: int in state:
		var s: Dictionary = state[inst_id]
		var god_id := str(s.god_id)
		var bag: Dictionary = s.bag
		# craved first, then accepted; the god does not stoop to what it ignores
		var order: Array = []
		for lane_name in ["craves", "accepts"]:
			for item_id: String in bag:
				if lane(god_id, item_id) == lane_name and item_id not in order:
					order.append(item_id)
		var taken := 0
		for item_id: String in order:
			if taken >= types_per:
				break
			var take := mini(qty_per, int(bag[item_id]))
			bag[item_id] = int(bag[item_id]) - take
			if int(bag[item_id]) <= 0:
				bag.erase(item_id)
			fed[god_id] = float(fed.get(god_id, 0.0)) + vigor_per * lane_mult(god_id, item_id) * take
			if lane(god_id, item_id) == "craves":
				craved[god_id] = int(craved.get(god_id, 0)) + take
			taken += 1
	return {"vigor": fed, "craved": craved}

## --- persistence ----------------------------------------------------------------------
func to_save() -> Dictionary:
	return state.duplicate(true)

func from_save(data: Dictionary) -> void:
	state.clear()
	for inst_id: Variant in data:
		var s: Dictionary = data[inst_id]
		state[int(inst_id)] = {"god_id": str(s.get("god_id", "neutral")),
			"work_id": str(s.get("work_id", "")),
			"relics": (s.get("relics", []) as Array).map(func(r: Variant) -> String: return str(r)),
			"bag": s.get("bag", {}).duplicate()}

func _work_sanctum(inst_id: int) -> Dictionary:
	return registry.get_entity(str(state[inst_id].get("work_id", ""))).get("sanctum", {})
