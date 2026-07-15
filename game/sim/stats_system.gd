class_name StatsSystem
extends RefCounted
## Actor vitals: HP and stamina. Everything that bleeds or tires registers here
## — the player and every creature. Stamina is the shared currency of moving,
## fighting, and fleeing (GAME-SPEC pillar). Server-authoritative.

const STAMINA_REGEN_PER_SEC := 12.0
const FOOD_SLOTS := 2

## Valheim's food model (spec): eating is not survival maintenance, it's
## PREPARATION — food raises your maximums for a while. An unfed survivor is
## weak, not dying. base_* are the unfed floor; foods stack on top.
var actors: Dictionary = {}   # actor_id -> {hp, stamina, base_hp, base_stamina, foods: [{hp, stamina, seconds}]}

signal died(actor_id: Variant)
signal changed(actor_id: Variant)

func register(actor_id: Variant, base_hp: float, base_stamina: float = 0.0) -> void:
	actors[actor_id] = {"hp": base_hp, "base_hp": base_hp, "stamina": base_stamina, "base_stamina": base_stamina, "foods": []}

func max_hp(actor_id: Variant) -> float:
	var a: Dictionary = actors.get(actor_id, {})
	var m := float(a.get("base_hp", 0.0))
	for f: Dictionary in a.get("foods", []):
		m += float(f.hp)
	return m

func max_stamina(actor_id: Variant) -> float:
	var a: Dictionary = actors.get(actor_id, {})
	var m := float(a.get("base_stamina", 0.0))
	for f: Dictionary in a.get("foods", []):
		m += float(f.stamina)
	return m

## Eat: raises maximums for `seconds`, and the meal itself restores that much.
## Two slots — a full belly refuses (come back when one wears off).
func eat(actor_id: Variant, food_hp: float, food_stamina: float, seconds: float) -> bool:
	if not actors.has(actor_id):
		return false
	var a: Dictionary = actors[actor_id]
	if (a.foods as Array).size() >= FOOD_SLOTS:
		return false
	a.foods.append({"hp": food_hp, "stamina": food_stamina, "seconds": seconds})
	a.hp = minf(float(a.hp) + food_hp, max_hp(actor_id))
	a.stamina = minf(float(a.stamina) + food_stamina, max_stamina(actor_id))
	changed.emit(actor_id)
	return true

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
	a.hp = max_hp(actor_id)
	a.stamina = max_stamina(actor_id)
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

## Frame tick: stamina recovers toward the fed maximum; food wears off.
func tick(delta: float) -> void:
	for id: Variant in actors:
		var a: Dictionary = actors[id]
		var foods: Array = a.foods
		if foods.size() > 0:
			for f: Dictionary in foods:
				f.seconds = float(f.seconds) - delta
			var before := foods.size()
			a.foods = foods.filter(func(f: Dictionary) -> bool: return float(f.seconds) > 0.0)
			if (a.foods as Array).size() != before:
				a.hp = minf(float(a.hp), max_hp(id))
				a.stamina = minf(float(a.stamina), max_stamina(id))
				changed.emit(id)
		var ms := max_stamina(id)
		if ms > 0.0 and float(a.stamina) < ms:
			a.stamina = minf(float(a.stamina) + STAMINA_REGEN_PER_SEC * delta, ms)
