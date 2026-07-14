class_name WorksSystem
extends RefCounted
## Placed buildables. Spells drain; works FEED: building pulses favor, a work
## IN USE trickles favor to its god, idle works feed nothing (law). Grim works
## testify by their presence.
## Inventory/cost-checking arrives with the inventory system (M1); place()
## currently trusts the caller — intents validate costs before calling.

var registry: Registry
var devotion: DevotionSystem
var econ: Dictionary

var placed: Dictionary = {}   # instance id -> {work_id, owner, in_use}
var _next_id := 1

signal grim_raised(work_id: String)

func _init(reg: Registry, dev: DevotionSystem) -> void:
	registry = reg
	devotion = dev
	econ = reg.tuning.get("economy", {})

func place(work_id: String, owner_player: int) -> int:
	var work := registry.get_entity(work_id)
	if work.is_empty():
		return -1
	var id := _next_id
	_next_id += 1
	placed[id] = {"work_id": work_id, "owner": owner_player, "in_use": false}
	var god_id: String = work.get("godId", "neutral")
	if god_id != "neutral":
		devotion.work_favor_hour(owner_player, god_id, float(econ.get("favor", {}).get("buildPulse", 5)))
	if work.get("grim", false):
		grim_raised.emit(work_id)
	return id

func set_in_use(instance_id: int, in_use: bool) -> void:
	if placed.has(instance_id):
		placed[instance_id].in_use = in_use

## Called once per sim_hour by the host loop.
func favor_hour() -> void:
	for id: int in placed:
		var inst: Dictionary = placed[id]
		if not inst.in_use:
			continue  # idle works feed nothing — the law
		var work := registry.get_entity(inst.work_id)
		var god_id: String = work.get("godId", "neutral")
		var trickle: float = float(work.get("favorTrickle", 0))
		if god_id != "neutral" and trickle > 0.0:
			devotion.work_favor_hour(int(inst.owner), god_id, trickle)

## Presence checks for testimony (priests, pilgrims, Peoples trade refusal).
func grim_in_village() -> bool:
	for id: int in placed:
		if registry.get_entity(placed[id].work_id).get("grim", false):
			return true
	return false

func count_of(work_id: String) -> int:
	var n := 0
	for id: int in placed:
		if placed[id].work_id == work_id:
			n += 1
	return n
