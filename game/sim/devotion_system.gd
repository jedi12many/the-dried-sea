class_name DevotionSystem
extends RefCounted
## Per-player devotion state: attunement ranks, per-god Vigor & favor.
## Implements the core laws: spells drain / worship (and works-in-use) feed;
## blessings dim as Vigor falls; Dormant at threshold; recovery is time-gated
## rites at that god's church. Server-authoritative: only the host mutates.
##
## Verified by game/tests/test_devotion.gd; economy bands by tools/economy-model.mjs.

var registry: Registry
var econ: Dictionary

# player_id -> god_id -> {rank:int, vigor:float, favor:float, dormant:bool}
var state: Dictionary = {}

signal god_dormant(player_id: int, god_id: String)
signal god_restored(player_id: int, god_id: String)
signal ledger_event(player_id: int, ledger: String, amount: float, note: String)

func _init(reg: Registry) -> void:
	registry = reg
	econ = reg.tuning.get("economy", {})

func _god_state(player_id: int, god_id: String) -> Dictionary:
	if not state.has(player_id):
		state[player_id] = {}
	if not state[player_id].has(god_id):
		state[player_id][god_id] = {"rank": 0, "vigor": max_vigor(god_id), "favor": 0.0, "dormant": false}
	return state[player_id][god_id]

func max_vigor(god_id: String) -> float:
	var god := registry.get_entity(god_id)
	return god.get("vigor", {}).get("maxVigor", econ.get("vigor", {}).get("defaultMax", 100.0))

## --- attunement -------------------------------------------------------------
func attune(player_id: int, god_id: String) -> bool:
	var god := registry.get_entity(god_id)
	if god.is_empty() or "missing" in god.get("flags", []):
		return false
	var s := _god_state(player_id, god_id)
	if s.rank >= 3:
		return false
	var costs: Array = econ.get("devotion", {}).get("rankCosts", [1, 1, 2])
	var cost: int = costs[s.rank]
	if devotion_spent(player_id) + cost > devotion_budget():
		return false
	s.rank += 1
	return true

func devotion_budget() -> int:
	return int(econ.get("devotion", {}).get("ranksBudgetAtEA", 5))

func devotion_spent(player_id: int) -> int:
	var costs: Array = econ.get("devotion", {}).get("rankCosts", [1, 1, 2])
	var total := 0
	for god_id: String in state.get(player_id, {}):
		var rank: int = state[player_id][god_id].rank
		for r in rank:
			total += int(costs[r])
	return total

## --- casting: spells drain ---------------------------------------------------
func can_cast(player_id: int, invocation_id: String) -> bool:
	var found := _find_invocation(invocation_id)
	if found.is_empty():
		return false
	var s := _god_state(player_id, found.god_id)
	return s.rank >= int(found.inv.rankRequired) and not s.dormant \
		and s.vigor >= float(found.inv.vigorCost) * max_vigor(found.god_id)

func cast(player_id: int, invocation_id: String) -> Dictionary:
	if not can_cast(player_id, invocation_id):
		return {}
	var found := _find_invocation(invocation_id)
	var s := _god_state(player_id, found.god_id)
	s.vigor -= float(found.inv.vigorCost) * max_vigor(found.god_id)
	ledger_event.emit(player_id, "gods", -float(found.inv.vigorCost), "cast %s" % invocation_id)
	if s.vigor <= float(econ.get("vigor", {}).get("dormantThreshold", 5)):
		s.dormant = true
		god_dormant.emit(player_id, found.god_id)
	return found.inv  # caller (combat/effects) applies effects + selfCost

## --- worship: rites, trickle, works feed --------------------------------------
## Called once per sim_day per god the player worshipped at (church tier of
## THAT god's building; priest rank; offering mult from offerings spent today).
func rite_day(player_id: int, god_id: String, church_tier: String, priest_rank: int, offering_mult: float = 1.0) -> void:
	var w: Dictionary = econ.get("worship", {})
	var base: float = w.get("riteRecoveryPerDayByChurchTier", {}).get(church_tier, 0.0)
	var mult: float = w.get("priestRankMult", [1.0])[clampi(priest_rank - 1, 0, 2)]
	# floor 0.5, not 1.0 — an offense laid on the altar (Sanctum) genuinely sours the rite
	_restore(player_id, god_id, base * mult * clampf(offering_mult, 0.5, float(w.get("offeringBuydownMaxMult", 2.0))))
	ledger_event.emit(player_id, "gods", base * mult * 0.01, "rite for %s" % god_id)

## The Sanctum's dawn tithe: offerings the god took from an altar overnight
## (sanctum_system computes the amount; sized well below rites — worship stays
## the main verb).
func tithe_day(player_id: int, god_id: String, amount: float) -> void:
	_restore(player_id, god_id, amount)

## Devout-villager passive worship (village_system reports the count per god per day).
func villager_trickle_day(player_id: int, god_id: String, devout_count: int) -> void:
	var per: float = econ.get("worship", {}).get("devoutVillagerTricklePerDay", 0.5)
	_restore(player_id, god_id, per * devout_count)

## Works-in-use favor (works_system reports per sim_hour). Use is worship —
## favor, not Vigor: works court a god; only worship refills their strength.
func work_favor_hour(player_id: int, god_id: String, trickle: float) -> void:
	_god_state(player_id, god_id).favor += trickle

func favor_tier(player_id: int, god_id: String) -> int:
	var thresholds: Array = econ.get("favor", {}).get("tierThresholds", [0, 25, 75, 150])
	var favor: float = _god_state(player_id, god_id).favor
	var tier := 0
	for i in thresholds.size():
		if favor >= float(thresholds[i]):
			tier = i
	return tier

## --- blessing dim curve --------------------------------------------------------
func blessing_strength(player_id: int, god_id: String) -> float:
	var s := _god_state(player_id, god_id)
	if s.rank == 0 or s.dormant:
		return 0.0
	var curve: Array = econ.get("vigor", {}).get("blessingDimCurve", [])
	var pct: float = float(s.vigor) / max_vigor(god_id) * 100.0
	var strength := 0.0
	for point: Array in curve:  # sorted desc by vigor pct
		if pct <= float(point[0]):
			strength = float(point[1])
	return strength

## --- internals -------------------------------------------------------------------
func _restore(player_id: int, god_id: String, amount: float) -> void:
	var s := _god_state(player_id, god_id)
	var was_dormant: bool = s.dormant
	s.vigor = minf(s.vigor + amount, max_vigor(god_id))
	if was_dormant and s.vigor > float(econ.get("vigor", {}).get("dormantThreshold", 5)) * 2.0:
		s.dormant = false
		god_restored.emit(player_id, god_id)

func _find_invocation(invocation_id: String) -> Dictionary:
	for god: Dictionary in registry.all_of("god"):
		for inv: Dictionary in god.get("invocations", []):
			if inv.get("id", "") == invocation_id:
				return {"god_id": god.id, "inv": inv}
	return {}
