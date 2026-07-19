class_name BeastSystem
extends RefCounted
## Beasts at Heel (VILLAGER-AND-GODHEAD-SPEC Part III). The heel slot's
## companion animal: taming (WILD-gated, Ghal-sweetened), the tamed roster,
## leveling on the SAME shared curve as villager Arms (tuning/villagers.json
## xp — "one growth system, three wearers": player virtues / villager Arms /
## beast levels), mood, and death.
##
## Decoupled by design: `can_tame` takes the player's WILD virtue score as a
## plain int — this system never reads AbilitiesSystem or any other sim
## system directly (CLAUDE.md: systems talk through the world state, never by
## calling each other's internals).
##
## Two roster shapes:
##  - wild_trust: nid (world-instance id of an untamed beast) -> trust ledger,
##    kept only until the beast is tamed, then discarded.
##  - beasts: beast id (this system's own counter) -> the tamed roster record.
## HP itself lives in stats_system (presentation registers it there on tame);
## this system only computes what that HP ceiling SHOULD be (beast_max_hp).
##
## Server-authoritative; pure sim, no Node deps; headless-testable.

var registry: Registry
var tune: Dictionary       # tuning/beasts.json
var vtune: Dictionary      # tuning/villagers.json — the shared XP curve + hpPerLevelPct

# beast id (own counter) -> {name, creature_id, xp: float, owner_pid: int,
# at_heel: bool, kenneled: bool, fed_today: bool, mood: "keen"|"sulking"}
var beasts: Dictionary = {}
var _next_id := 1

# world nid (untamed beast instance, owned by world_system/presentation) ->
# {creature_id, trust: int, last_meal_day: int}. Erased once tamed.
var wild_trust: Dictionary = {}

signal beast_tamed(beast_id: int, creature_id: String, name: String)
signal beast_leveled(beast_id: int, new_level: int)
signal instinct_ignited(beast_id: int, instinct_id: String)

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("beasts", {})
	vtune = reg.tuning.get("villagers", {})

## --- taming: the WILD ladder ----------------------------------------------------
## Presentation passes the player's WILD virtue score (talent-soft-step/
## crab-friend/herd-sense thresholds, 3/6/9) — the sim never reads virtues
## directly. A creature with no `tame` block can never be tamed.
func can_tame(wild_points: int, creature_id: String) -> bool:
	var tm: Dictionary = registry.get_entity(creature_id).get("tame", {})
	if tm.is_empty():
		return false
	var tier: int = int(tm.get("tier", 1))
	var needed: int = int(tune.get("wildTierGate", {}).get(str(tier), 999))
	return wild_points >= needed

## The Shepherd's Way: drop the craved food, the beast eats, trust rises.
## `ghal_rank` is the player's Ghal attunement rank (the god's sweetener —
## discounts meals, min floor `minMeals`; he never gates, only sweetens).
## DECISION (one meal per day per beast): the spec's table says "meals" but
## doesn't settle whether repeat feeds in one day should stack. Stacking would
## let a player farm trust in a single sitting with a full stack of smoked
## crab, which cuts against "the journey is long, never lottery." Implemented:
## only the FIRST feed on a given sim-day advances trust; a same-day repeat
## feed is a no-op that still reports the current trust/needed (so the UI
## reads consistently either way) — tested below.
## Trust decays to 0 if `trustDecayDays` pass with no meal (day-stamped); the
## decaying meal itself still counts (a half-fed beast can always be re-won).
## Returns {trust, needed, tamed, id} — id is the new roster id when tamed>0,
## else -1.
func feed_wild(nid: int, creature_id: String, pid: int, today: int, ghal_rank: int = 0) -> Dictionary:
	var tm: Dictionary = registry.get_entity(creature_id).get("tame", {})
	if tm.is_empty():
		return {"trust": 0, "needed": 0, "tamed": false, "id": -1}

	var tier: int = int(tm.get("tier", 1))
	var meals_by_tier: Array = tune.get("mealsByTier", [0, 2, 3, 4])
	var base_meals: int = int(meals_by_tier[tier]) if tier >= 0 and tier < meals_by_tier.size() else int(tune.get("minMeals", 1))
	var discount: int = int(tune.get("ghalRankMealDiscount", 1)) * maxi(ghal_rank, 0)
	var needed: int = maxi(base_meals - discount, int(tune.get("minMeals", 1)))

	var rec: Dictionary = wild_trust.get(nid, {"creature_id": creature_id, "trust": 0, "last_meal_day": -999999999})
	var decay_days: int = int(tune.get("trustDecayDays", 3))
	if int(rec.trust) > 0 and today - int(rec.last_meal_day) > decay_days:
		rec.trust = 0

	if int(rec.last_meal_day) != today:
		rec.trust = int(rec.trust) + 1
		rec.last_meal_day = today
	wild_trust[nid] = rec

	var tamed := false
	var new_id := -1
	if int(rec.trust) >= needed:
		new_id = _tame(creature_id, pid, nid)
		tamed = true
		wild_trust.erase(nid)

	return {"trust": int(rec.trust), "needed": needed, "tamed": tamed, "id": new_id}

func _tame(creature_id: String, pid: int, name_seed: int) -> int:
	var tm: Dictionary = registry.get_entity(creature_id).get("tame", {})
	var pool: Array = tm.get("namePool", [])
	var id := _next_id
	_next_id += 1
	var name := _draw_name(pool, name_seed)
	beasts[id] = {
		"name": name, "creature_id": creature_id, "xp": 0.0, "owner_pid": pid,
		"at_heel": true, "kenneled": false, "fed_today": true, "mood": "keen",
	}
	beast_tamed.emit(id, creature_id, name)
	return id

## Deterministic draw from the species' namePool, seeded on the wild beast's
## world nid — two players taming the same wild instance (or a replay) get
## the same name.
func _draw_name(pool: Array, seed_val: int) -> String:
	if pool.is_empty():
		return "Unnamed"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	return str(pool[rng.randi() % pool.size()])

## --- leveling: the shared curve (villagers.json xp) --------------------------------
func _level_for_xp(xp: float) -> int:
	var xp_tune: Dictionary = vtune.get("xp", {})
	var c: float = float(xp_tune.get("curveConstant", 25))
	var cap: int = int(xp_tune.get("maxLevel", 10))
	return clampi(int(floorf(sqrt(maxf(xp, 0.0) / c))), 1, cap)

func beast_level(id: int) -> int:
	if not beasts.has(id):
		return 0
	return _level_for_xp(float(beasts[id].xp))

## Sources: "killAssist" (tier indexes vtune.xpSources.killAssistByTier, same
## table villager Arms reads), "expeditionReturn" (flat, vtune.xpSources),
## "porterDay" (flat, THIS system's own tune.porterDayXp — crabs don't drill,
## they carry). Unknown/zero sources are a no-op.
func grant_xp(id: int, source: String, tier: int = 0) -> void:
	if not beasts.has(id):
		return
	var rec: Dictionary = beasts[id]
	var amount := 0.0
	match source:
		"killAssist":
			var tiers: Array = vtune.get("xpSources", {}).get("killAssistByTier", [])
			if tier >= 0 and tier < tiers.size():
				amount = float(tiers[tier])
		"expeditionReturn":
			amount = float(vtune.get("xpSources", {}).get("expeditionReturn", 0.0))
		"porterDay":
			amount = float(tune.get("porterDayXp", 0.0))
		_:
			amount = 0.0
	if amount <= 0.0:
		return
	var level_before := beast_level(id)
	rec.xp = float(rec.xp) + amount
	var level_after := beast_level(id)
	if level_after > level_before:
		beast_leveled.emit(id, level_after)
		var tm: Dictionary = registry.get_entity(str(rec.creature_id)).get("tame", {})
		for ins: Dictionary in tm.get("instincts", []):
			var t := int(ins.tier)
			if t > level_before and t <= level_after:
				instinct_ignited.emit(id, str(ins.id))

## Instincts whose ignition tier this beast's current level has reached.
func instincts_ignited(id: int) -> Array:
	var out: Array = []
	if not beasts.has(id):
		return out
	var level := beast_level(id)
	var tm: Dictionary = registry.get_entity(str(beasts[id].creature_id)).get("tame", {})
	for ins: Dictionary in tm.get("instincts", []):
		if int(ins.tier) <= level:
			out.append(ins)
	return out

## creature stats.hp x (1 + hpPerLevelPct/100 x (level-1)) — the same
## per-level baseline shape as village_system.villager_max_hp, reading the
## SAME villagers.json hpPerLevelPct (one curve, three wearers).
func beast_max_hp(id: int) -> float:
	if not beasts.has(id):
		return 0.0
	var rec: Dictionary = beasts[id]
	var base: float = float(registry.get_entity(str(rec.creature_id)).get("stats", {}).get("hp", 0.0))
	var level := beast_level(id)
	if level <= 1:
		return base
	var pct: float = float(vtune.get("hpPerLevelPct", 8))
	return base * (1.0 + pct / 100.0 * float(level - 1))

## --- the kennel day ---------------------------------------------------------------
## Called once per beast per dawn by the host. An unfed beast's mood drops to
## "sulking" and it won't walk that day (presentation reads mood — it never
## deserts; it's a dog, not a tribesman). `kennel_stands` just records whether
## a Kennel work exists to house it (informational for presentation/UI).
func dawn(id: int, kennel_stands: bool, fed_from_stores: bool) -> void:
	if not beasts.has(id):
		return
	var rec: Dictionary = beasts[id]
	rec.kenneled = kennel_stands
	rec.fed_today = fed_from_stores
	rec.mood = "keen" if fed_from_stores else "sulking"

## Porters at heel earn the quiet porterDay trickle (a day carried is a day
## trained) — the host calls this once per porter-role beast per day it
## walked at heel. A no-op for fighter-role beasts (they earn via killAssist/
## expeditionReturn instead).
func porter_day(id: int) -> void:
	if not beasts.has(id):
		return
	var tm: Dictionary = registry.get_entity(str(beasts[id].creature_id)).get("tame", {})
	if str(tm.get("behavior", {}).get("role", "")) != "porter":
		return
	grant_xp(id, "porterDay")

## --- death ---------------------------------------------------------------------
## Downed 30s -> [E] revive, same shape as villagers; the timer running out is
## permadeath (the caller/presentation owns the downed timer, same law as
## village_system.mark_downed/revive). No gear, no village grief — the beast
## leaves a keepsake: an item Ghal's altar craves. (Crabs never die at heel —
## that's presentation's shell rule; this method must still exist for hounds/
## apexes, and for a crab it simply won't be called in practice.)
func beast_death(id: int) -> String:
	if not beasts.has(id):
		return ""
	var rec: Dictionary = beasts[id]
	var keepsake := str(registry.get_entity(str(rec.creature_id)).get("tame", {}).get("keepsakeItemId", ""))
	beasts.erase(id)
	return keepsake

## --- persistence (godhead_system's to_save()/apply() optional-trailing-arg pattern) --
func to_save() -> Dictionary:
	return {
		"beasts": beasts.duplicate(true),
		"next_id": _next_id,
		"wild_trust": wild_trust.duplicate(true),
	}

## Additive; an old save (no "beast" key at all) loads clean and leaves this
## system at its fresh _init state (empty roster, empty trust ledger).
func apply(data: Dictionary) -> void:
	beasts = SaveSystem._int_keys(data.get("beasts", {}))
	_next_id = int(data.get("next_id", 1))
	wild_trust = SaveSystem._int_keys(data.get("wild_trust", {}))
