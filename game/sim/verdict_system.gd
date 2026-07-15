class_name VerdictSystem
extends RefCounted
## The four ledgers: gods, remnants, shepherd, peoples. Deeds are recorded per
## player; lean is derived, never displayed as a number. Also owns shared god
## WORLD-strength: a consumed remnant dims its god's domain for everyone, forever.
## Wire other systems' ledger_event signals into record().

var registry: Registry
var tune: Dictionary

# player_id -> ledger -> float
var ledgers: Dictionary = {}
# player_id -> Array[{ledger, amount, note, day}] (capped)
var history: Dictionary = {}
const HISTORY_CAP := 500

# god_id -> 0..100 shared world strength (100 = as strong as a dying god gets)
var god_world_strength: Dictionary = {}

signal god_dimmed_worldwide(god_id: String, strength: float)

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("verdict", {})
	for god: Dictionary in reg.all_of("god"):
		god_world_strength[god.id] = 100.0

func record(player_id: int, ledger: String, amount: float, note: String, day: int = -1) -> void:
	if not tune.get("ledgers", {}).has(ledger):
		push_warning("unknown ledger '%s'" % ledger)
		return
	if not ledgers.has(player_id):
		ledgers[player_id] = {}
		history[player_id] = []
	ledgers[player_id][ledger] = float(ledgers[player_id].get(ledger, 0.0)) + amount
	var h: Array = history[player_id]
	h.append({"ledger": ledger, "amount": amount, "note": note, "day": day})
	if h.size() > HISTORY_CAP:
		h.pop_front()

func total(player_id: int) -> float:
	var sum := 0.0
	for ledger: String in ledgers.get(player_id, {}):
		sum += float(ledgers[player_id][ledger])
	return sum

## Band = first threshold met, top-down. Priests read this; the player never sees a number.
func lean(player_id: int) -> String:
	var t: Dictionary = tune.get("lean", {}).get("thresholds", {})
	var score := total(player_id)
	if score >= float(t.get("shepherd", 20)):
		return "shepherd"
	if score >= float(t.get("steady", -10)):
		return "steady"
	if score >= float(t.get("taker", -40)):
		return "taker"
	return "dark"

## --- remnants: enshrine / trade / consume -------------------------------------
func remnant_enshrine(player_id: int, god_id: String) -> void:
	god_world_strength[god_id] = minf(float(god_world_strength.get(god_id, 100.0)) + 10.0, 100.0)
	record(player_id, "remnants", 10.0, "enshrined a remnant of %s" % god_id)

func remnant_trade(player_id: int, god_id: String) -> void:
	record(player_id, "remnants", 0.0, "traded a remnant of %s" % god_id)

func remnant_consume(player_id: int, god_id: String) -> void:
	var dim := float(tune.get("worldStrength", {}).get("consumedRemnantDim", 20))
	god_world_strength[god_id] = maxf(float(god_world_strength.get(god_id, 100.0)) - dim, 0.0)
	record(player_id, "remnants", -12.0, "CONSUMED a remnant of %s" % god_id)
	god_dimmed_worldwide.emit(god_id, float(god_world_strength[god_id]))
