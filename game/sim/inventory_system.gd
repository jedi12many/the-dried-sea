class_name InventorySystem
extends RefCounted
## Per-player inventory. Slot/weight model decided at M1-end by feel (spec open
## question); until then a simple counted-stacks model. Server-authoritative.

var registry: Registry
var inventories: Dictionary = {}   # player_id -> {item_id: int}

signal changed(player_id: int)

func _init(reg: Registry) -> void:
	registry = reg

func _inv(player_id: int) -> Dictionary:
	if not inventories.has(player_id):
		inventories[player_id] = {}
	return inventories[player_id]

func count(player_id: int, item_id: String) -> int:
	return int(_inv(player_id).get(item_id, 0))

func add(player_id: int, item_id: String, qty: int) -> void:
	if registry.get_entity(item_id).is_empty():
		push_warning("unknown item %s" % item_id)
		return
	var inv := _inv(player_id)
	inv[item_id] = int(inv.get(item_id, 0)) + qty
	changed.emit(player_id)

func can_afford(player_id: int, cost: Array) -> bool:
	for c: Dictionary in cost:
		if count(player_id, str(c.itemId)) < int(c.qty):
			return false
	return true

func pay(player_id: int, cost: Array) -> bool:
	if not can_afford(player_id, cost):
		return false
	var inv := _inv(player_id)
	for c: Dictionary in cost:
		inv[str(c.itemId)] = int(inv[str(c.itemId)]) - int(c.qty)
		if int(inv[str(c.itemId)]) <= 0:
			inv.erase(str(c.itemId))
	changed.emit(player_id)
	return true

## Craft a recipe. Station proximity enforced by the caller (intent layer).
func craft(player_id: int, recipe_id: String, works: WorksSystem) -> bool:
	var recipe := registry.get_entity(recipe_id)
	if recipe.is_empty():
		return false
	var station: String = recipe.get("stationWorkId", "")
	if station != "" and works.count_of(station) == 0:
		return false
	if not pay(player_id, recipe.get("inputs", [])):
		return false
	add(player_id, str(recipe.output.itemId), int(recipe.output.qty))
	return true
