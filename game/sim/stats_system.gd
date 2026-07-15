class_name StatsSystem
extends RefCounted
## Actor vitals: HP and stamina. Everything that bleeds or tires registers here
## — the player and every creature. Stamina is the shared currency of moving,
## fighting, and fleeing (GAME-SPEC pillar). Server-authoritative.

const STAMINA_REGEN_PER_SEC := 12.0

var actors: Dictionary = {}   # actor_id -> {hp, max_hp, stamina, max_stamina}

signal died(actor_id: Variant)
signal changed(actor_id: Variant)

func register(actor_id: Variant, max_hp: float, max_stamina: float = 0.0) -> void:
	actors[actor_id] = {"hp": max_hp, "max_hp": max_hp, "stamina": max_stamina, "max_stamina": max_stamina}

func unregister(actor_id: Variant) -> void:
	actors.erase(actor_id)

func hp(actor_id: Variant) -> float:
	return float(actors.get(actor_id, {}).get("hp", 0.0))

func stamina(actor_id: Variant) -> float:
	return float(actors.get(actor_id, {}).get("stamina", 0.0))

## Returns true if this damage killed the actor.
func damage(actor_id: Variant, amount: float) -> bool:
	if not actors.has(actor_id):
		return false
	var a: Dictionary = actors[actor_id]
	a.hp = maxf(float(a.hp) - amount, 0.0)
	changed.emit(actor_id)
	if float(a.hp) <= 0.0:
		died.emit(actor_id)
		return true
	return false

func heal_full(actor_id: Variant) -> void:
	if not actors.has(actor_id):
		return
	var a: Dictionary = actors[actor_id]
	a.hp = a.max_hp
	a.stamina = a.max_stamina
	changed.emit(actor_id)

## Returns false (and spends nothing) if the actor is too tired.
func spend_stamina(actor_id: Variant, amount: float) -> bool:
	if not actors.has(actor_id):
		return false
	var a: Dictionary = actors[actor_id]
	if float(a.stamina) < amount:
		return false
	a.stamina = float(a.stamina) - amount
	changed.emit(actor_id)
	return true

## Frame tick: stamina recovers; HP does not (food's job, later).
func tick(delta: float) -> void:
	for id: Variant in actors:
		var a: Dictionary = actors[id]
		if float(a.max_stamina) > 0.0 and float(a.stamina) < float(a.max_stamina):
			a.stamina = minf(float(a.stamina) + STAMINA_REGEN_PER_SEC * delta, float(a.max_stamina))
