class_name VerdictSystem
extends RefCounted
## The four ledgers: gods, remnants, shepherd, peoples. Deeds are recorded per
## player; lean is derived, never displayed as a number.
## Wire other systems' ledger_event signals into record().
##
## World-wide god strength moved OUT of this system (VILLAGER-AND-GODHEAD-SPEC
## Part II): what used to be an ad-hoc `god_world_strength` dict here (-20 on
## consume, +10 on enshrine, no real gameplay consumer) is now the single
## source of truth in `godhead_system.gd` — `consumed()` is the one
## irreversible act (locks a god's Godhead at 0 forever), `enshrine_remnant()`
## feeds a god back within their cap. The host wires those calls alongside
## `remnant_consume`/`remnant_enshrine` below (systems don't call each other's
## internals — see docs/ARCHITECTURE.md §2); this system keeps ONLY the
## player-ledger bookkeeping (the "remnants" deed, per-player).

var registry: Registry
var tune: Dictionary

# player_id -> ledger -> float
var ledgers: Dictionary = {}
# player_id -> Array[{ledger, amount, note, day}] (capped)
var history: Dictionary = {}
const HISTORY_CAP := 500

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("verdict", {})

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
## World-wide strength is godhead_system's job now (enshrine_remnant() / consumed());
## the host calls those alongside these — this system only records the deed.
func remnant_enshrine(player_id: int, god_id: String) -> void:
	record(player_id, "remnants", 10.0, "enshrined a remnant of %s" % god_id)

func remnant_trade(player_id: int, god_id: String) -> void:
	record(player_id, "remnants", 0.0, "traded a remnant of %s" % god_id)

func remnant_consume(player_id: int, god_id: String) -> void:
	record(player_id, "remnants", -12.0, "CONSUMED a remnant of %s" % god_id)

## --- the keystone moment (REEF-FOREST-SPEC §6) ---------------------------------
## Dedicating a boss's keystone to one god is a public act of favor — worship
## given, not taken — so it lands on the "gods" ledger (Vigor taken vs worship
## returned), not "remnants" (which already tracks the boss's OWN remnant
## separately via enshrine/consume above). +5.0 is not spec'd by name (§3's
## ledger table lists inputs, not per-deed weights) — a first-guess positive
## note, modest next to remnant_enshrine's +10, since the god-fed part of the
## deed is godhead_system's job; this is only the ledger's memory of the choice.
func keystone_dedicated(player_id: int, god_id: String) -> void:
	record(player_id, "gods", 5.0, "dedicated a keystone to %s" % god_id)
