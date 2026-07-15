class_name AbilitiesSystem
extends RefCounted
## The Six Virtues — ability scores that ARE the pantheon read into a person.
## One currency (Temper: the flats temper you) spent directly into virtues;
## talents IGNITE at point thresholds in that virtue. Respec is free and
## unlimited: drain a virtue, the Temper comes back. Server-authoritative.

const VIRTUE_CAP := 12

var registry: Registry
# player_id -> {"earned": int, "alloc": {virtue_id: int}}
var state: Dictionary = {}

signal changed(player_id: int)
signal talent_ignited(player_id: int, talent_id: String)

func _init(reg: Registry) -> void:
	registry = reg

func _p(player_id: int) -> Dictionary:
	if not state.has(player_id):
		state[player_id] = {"earned": 0, "alloc": {}}
	return state[player_id]

func earn(player_id: int, amount: int) -> void:
	_p(player_id).earned += amount
	changed.emit(player_id)

func earned(player_id: int) -> int:
	return int(_p(player_id).earned)

func spent(player_id: int) -> int:
	var total := 0
	for v: String in _p(player_id).alloc:
		total += int(_p(player_id).alloc[v])
	return total

func available(player_id: int) -> int:
	return earned(player_id) - spent(player_id)

func score(player_id: int, virtue_id: String) -> int:
	return int(_p(player_id).alloc.get(virtue_id, 0))

func allocate(player_id: int, virtue_id: String) -> bool:
	if available(player_id) <= 0 or registry.get_entity(virtue_id).is_empty():
		return false
	if score(player_id, virtue_id) >= VIRTUE_CAP:
		return false
	var before := active_talents(player_id)
	_p(player_id).alloc[virtue_id] = score(player_id, virtue_id) + 1
	for t: String in active_talents(player_id):
		if t not in before:
			talent_ignited.emit(player_id, t)
	changed.emit(player_id)
	return true

## Free, unlimited respec: the Temper returns whole.
func deallocate(player_id: int, virtue_id: String) -> bool:
	if score(player_id, virtue_id) <= 0:
		return false
	_p(player_id).alloc[virtue_id] = score(player_id, virtue_id) - 1
	changed.emit(player_id)
	return true

func active_talents(player_id: int) -> Array[String]:
	var out: Array[String] = []
	for virtue: Dictionary in registry.all_of("virtue"):
		var s := score(player_id, str(virtue.id))
		for talent: Dictionary in virtue.talents:
			if s >= int(talent.threshold):
				out.append(str(talent.id))
	return out

func talent_active(player_id: int, talent_id: String) -> bool:
	return talent_id in active_talents(player_id)

## Aggregate a modifier across all ignited talents.
## Additive kinds sum from `base`; multiplicative kinds multiply from `base`.
func mod_add(player_id: int, effect_type: String, base: float = 0.0) -> float:
	var total := base
	for eff: Dictionary in _active_effects(player_id):
		if str(eff.get("type", "")) == effect_type:
			total += float(eff.get("magnitude", 0))
	return total

func mod_mult(player_id: int, effect_type: String, base: float = 1.0) -> float:
	var total := base
	for eff: Dictionary in _active_effects(player_id):
		if str(eff.get("type", "")) == effect_type:
			total *= float(eff.get("magnitude", 1))
	return total

func _active_effects(player_id: int) -> Array:
	var out: Array = []
	for virtue: Dictionary in registry.all_of("virtue"):
		var s := score(player_id, str(virtue.id))
		for talent: Dictionary in virtue.talents:
			if s >= int(talent.threshold):
				out.append_array(talent.effects)
	return out
