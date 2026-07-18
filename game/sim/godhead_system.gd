class_name GodheadSystem
extends RefCounted
## Godhead: world-level per-god health, 0-100%, SHARED by every player — the
## campaign-scale companion to devotion_system's per-player Vigor
## (VILLAGER-AND-GODHEAD-SPEC Part II). Vigor decides whether you can cast;
## Godhead decides how much god shows up when you do:
##
##   effective = base_magnitude x blessing_dim(vigor) x godhead
##
## `blessing_dim` (Vigor) lives in devotion_system; `godhead` (this file) is
## the new term and multiplies EVERYTHING a god grants — invocation
## magnitudes, durations, radii, passive blessings, Acolyte channels. Callers
## (devotion_system.cast/blessing_strength, villager Acolyte channels) read
## effective_mult(god_id) and multiply their own magnitude by it.
##
## The cap is the world's gift; the filling is the players'. Cap = base% +
## perBiomeCap% x biomes cleared, clamped 0-100 (§1). Within the cap, feed()
## and drain() move a god's value per the source/sink tables in
## tuning/godhead.json (§3). At 0 a god GUTTERS (§4): grants no magic
## (effective_mult 0) for EVERYONE, until fed back above 0 — UNLESS
## consumed(), the one irreversible act (§4's Verdict promise), which locks
## the value at 0 forever; no feed can revive a consumed god.
##
## §5 the Waker: every player death feeds Ur-Noth (he alone restores the
## dead), decaying per repeat-within-window, per PLAYER (co-op: one dying
## player can't carry the whole farm). Design law: dying is ledger-neutral —
## the feed/decay math never reads as a moral score, just an economy guard.
## The UI law holds throughout: the numbers are always on screen — nothing
## here is hidden math.
##
## Server-authoritative: only the host mutates. Pure sim, no Node deps.
## Verified by game/tests/run_tests.gd; economy bands (once extended) by
## tools/economy-model.mjs.

var registry: Registry
var tune: Dictionary

# god_id -> {value: float, consumed: bool}. Only non-"missing" gods are tracked.
var state: Dictionary = {}

var biomes_cleared_count: int = 0

# player_id -> int (deaths across the whole save, never decrements)
var lifetime_deaths: Dictionary = {}
# player_id -> {last_death_day: int, streak: int} — the Waker's decay window
var death_window: Dictionary = {}

signal godhead_changed(god_id: String, old: float, new: float)
signal god_guttered(god_id: String)
signal god_rekindled(god_id: String)

func _init(reg: Registry) -> void:
	registry = reg
	tune = reg.tuning.get("godhead", {})
	var start: float = float(tune.get("cap", {}).get("base", 10.0))
	for god: Dictionary in registry.all_of("god"):
		if "missing" in god.get("flags", []):
			continue
		state[god.id] = {"value": start, "consumed": false}

## --- the cap: biomes are the ceiling (§1) ---------------------------------------
## Global — one world-progress clock, every god shares it. Raising it never
## moves any god's current value (cap and value are independent variables).
func cap() -> float:
	var c: Dictionary = tune.get("cap", {})
	var raw: float = float(c.get("base", 10.0)) + float(c.get("perBiomeCap", 30.0)) * float(biomes_cleared_count)
	return clampf(raw, 0.0, float(c.get("maxOverall", 100.0)))

## Presentation owns what "cleared" means; this just stores the count.
## Biome keystones don't get un-defeated, so this should only ever rise —
## but the sim doesn't enforce that, it just trusts the caller.
func set_biomes_cleared(n: int) -> void:
	biomes_cleared_count = n

func biomes_cleared() -> int:
	return biomes_cleared_count

## --- reading a god's health -------------------------------------------------------
func godhead(god_id: String) -> float:
	return float(state.get(god_id, {}).get("value", 0.0))

func is_consumed(god_id: String) -> bool:
	return bool(state.get(god_id, {}).get("consumed", false))

## A guttered god grants NO magic, for everyone, until fed back above 0.
func is_guttered(god_id: String) -> bool:
	return godhead(god_id) <= 0.0

## The one number every spell/blessing/acolyte magnitude gets multiplied by.
func effective_mult(god_id: String) -> float:
	if not state.has(god_id) or is_guttered(god_id):
		return 0.0
	return godhead(god_id) / 100.0

## The one truly irreversible act (§4): locks the god at 0 forever. No feed
## call can revive a consumed god — enshrine (the Verdict's kinder verb)
## feeds instead, per the source table, as long as the remnant isn't consumed.
func consumed(god_id: String) -> void:
	if not state.has(god_id):
		return
	var s: Dictionary = state[god_id]
	var old: float = float(s.value)
	s.consumed = true
	s.value = 0.0
	if old > 0.0:
		godhead_changed.emit(god_id, old, 0.0)
		god_guttered.emit(god_id)

## --- sources: feeding a god (§3) ---------------------------------------------------
## Generic entry point: source names a tuning rate table; amount_override,
## when given (>= 0), is used directly instead (the caller already computed
## it — e.g. a rite's base-by-tier x that altar's Splendor). Clamps to
## [0, cap()]. Returns the actual delta applied (0 if the god is consumed or
## already at cap).
func feed(god_id: String, _source: String, amount_override: float = -1.0) -> float:
	var amount: float = amount_override if amount_override >= 0.0 else 0.0
	return _apply_delta(god_id, amount)

## Daily rite at that god's church (church_tier -> tuning rate) x Splendor
## (the Sanctum multiplies god-healing — that was always its job).
func rite_day(god_id: String, church_tier: String, splendor: float = 1.0) -> float:
	var base: float = float(tune.get("sources", {}).get("riteLedByChurchTier", {}).get(church_tier, 0.0))
	return feed(god_id, "rite", base * splendor)

## The Sanctum's dawn tithe: craved items the god took overnight.
func tithe_day(god_id: String, craved_items_taken: int) -> float:
	var per: float = float(tune.get("sources", {}).get("dawnTithePerCravedItem", 0.05))
	return feed(god_id, "tithe", per * float(craved_items_taken))

## Devout villagers (village_system.devout_count) — the congregation matters,
## barely but truly.
func villager_trickle_day(god_id: String, devout_count: int) -> float:
	var per: float = float(tune.get("sources", {}).get("devoutVillagerTricklePerDay", 0.01))
	return feed(god_id, "villager_trickle", per * float(devout_count))

## Enshrining a remnant (the Verdict's kinder verb) feeds the god a one-time
## chunk — the mirror of consumed(), which locks them at 0 forever instead.
func enshrine_remnant(god_id: String) -> float:
	return feed(god_id, "enshrine", float(tune.get("sources", {}).get("enshrinedRemnant", 2.0)))

## --- sinks: bleeding a god (§3) ----------------------------------------------------
## Generic entry point: amount is a UNIT COUNT (e.g. one offense, one grim
## rite); the per-unit rate comes from tuning. Casting is never a sink here —
## players must never feel that using magic hurts their god (§3 design law).
func drain(god_id: String, source: String, amount: float) -> float:
	var rate := 0.0
	match source:
		"offense":
			rate = float(tune.get("sinks", {}).get("offenseLaidOnAltar", 0.1))
		"grim_rite":
			rate = float(tune.get("sinks", {}).get("urNothGrimRitePerRite", 0.5))
	return _apply_delta(god_id, -rate * amount)

## The Offertory's `offends` lane gets teeth (sanctum_system.offense_laid).
func offense_laid(god_id: String, count: int = 1) -> float:
	return drain(god_id, "offense", float(count))

## Ur-Noth's grim rites: "-0.5% per rite from a god of your choice" — the
## grim mirror made literal, his Splendor multiplies the theft (caller picks
## which god's Godhead to drain; every use is a Verdict ledger entry too).
func grim_rite_drain(god_id: String, count: int = 1) -> float:
	return drain(god_id, "grim_rite", float(count))

## Neglect: the only sink with its own floor (5%) — absence cools, it never
## kills. Only applies below cap/2 and only on a day with zero worship of
## that god; guttering is reachable only by the deliberate sinks above.
func neglect_day(god_id: String, had_worship_today: bool) -> float:
	if had_worship_today or not state.has(god_id) or is_consumed(god_id):
		return 0.0
	if godhead(god_id) >= cap() * 0.5:
		return 0.0
	var n: Dictionary = tune.get("sinks", {}).get("neglect", {})
	var floor_pct: float = float(n.get("floorPct", 5.0))
	var per_day: float = float(n.get("perDay", 0.05))
	var s: Dictionary = state[god_id]
	var old: float = float(s.value)
	var new_val: float = maxf(old - per_day, floor_pct)
	return _set_value(god_id, new_val)

## --- §5 the Waker of the Drowned ----------------------------------------------------
## Every player death ends with Ur-Noth handing you back. `today` is the sim
## day (this system owns no clock — caller passes it). Feed decays x
## repeatDecay per repeat within decayWindowDays, floored, resetting after
## that many deathless days. If the dying player is Ur-Noth's own and
## washIfAttuned holds, the revival costs him exactly what it feeds him — a
## wash, net +-0 — but the death still counts (design law: dying is
## ledger-neutral; being bad at the game is never a moral entry). Ur-Noth
## guttered doesn't block the feed ("you cannot keep the dark down while
## anyone drowns") — only consumed() does.
func player_death(pid: int, today: int, attuned_to_urnoth: bool) -> Dictionary:
	var w: Dictionary = tune.get("waker", {})
	var feed_pct: float = float(w.get("feedPct", 0.4))
	var decay: float = float(w.get("repeatDecay", 0.6))
	var window_days: int = int(w.get("decayWindowDays", 3))
	var floor_pct: float = float(w.get("floorPct", 0.05))
	var wash_if_attuned: bool = bool(w.get("washIfAttuned", true))

	var dw: Dictionary = death_window.get(pid, {"last_death_day": -999999999, "streak": 0})
	var days_since: int = today - int(dw.get("last_death_day", -999999999))
	var streak: int = int(dw.get("streak", 0))
	if days_since > window_days:
		streak = 0  # a deathless gap longer than the window resets the decay
	var amount: float = maxf(feed_pct * pow(decay, streak), floor_pct)
	death_window[pid] = {"last_death_day": today, "streak": streak + 1}

	lifetime_deaths[pid] = int(lifetime_deaths.get(pid, 0)) + 1
	var lifetime: int = int(lifetime_deaths[pid])

	var washed := wash_if_attuned and attuned_to_urnoth
	var fed := 0.0
	if not washed:
		fed = feed("god-ur-noth", "waker_death", amount)

	return {
		"fed": fed,
		"washed": washed,
		"lifetime": lifetime,
		"whisper_pool": _whisper_pool(lifetime),
	}

func _whisper_pool(lifetime: int) -> String:
	var t: Dictionary = tune.get("waker", {}).get("whisperPoolThresholds", {})
	var familiar_at: int = int(t.get("familiar", 5))
	var proprietary_at: int = int(t.get("proprietary", 15))
	if lifetime >= proprietary_at:
		return "proprietary"
	if lifetime >= familiar_at:
		return "familiar"
	return "early"

## --- internals -------------------------------------------------------------------
func _apply_delta(god_id: String, delta: float) -> float:
	if not state.has(god_id) or is_consumed(god_id):
		return 0.0
	var s: Dictionary = state[god_id]
	var new_val: float = clampf(float(s.value) + delta, 0.0, cap())
	return _set_value(god_id, new_val)

func _set_value(god_id: String, new_val: float) -> float:
	var s: Dictionary = state[god_id]
	var old: float = float(s.value)
	if is_equal_approx(old, new_val):
		return 0.0
	s.value = new_val
	godhead_changed.emit(god_id, old, new_val)
	if new_val <= 0.0 and old > 0.0:
		god_guttered.emit(god_id)
	elif old <= 0.0 and new_val > 0.0:
		god_rekindled.emit(god_id)
	return new_val - old

## --- persistence (sanctum_system's to_save()/from_save() pattern) ------------------
func to_save() -> Dictionary:
	return {
		"biomes_cleared": biomes_cleared_count,
		"state": state.duplicate(true),
		"lifetime_deaths": lifetime_deaths.duplicate(true),
		"death_window": death_window.duplicate(true),
	}

## Additive; .get() defaults throughout so an old save (no "godhead" key at
## all, handled by the caller) or a save from before a given god existed
## loads clean.
func apply(data: Dictionary) -> void:
	biomes_cleared_count = int(data.get("biomes_cleared", 0))
	var st: Dictionary = data.get("state", {})
	for god_id: String in st:
		if state.has(god_id):
			var entry: Dictionary = st[god_id]
			state[god_id].value = float(entry.get("value", state[god_id].value))
			state[god_id].consumed = bool(entry.get("consumed", false))
	lifetime_deaths = SaveSystem._int_keys(data.get("lifetime_deaths", {}))
	var dw: Dictionary = SaveSystem._int_keys(data.get("death_window", {}))
	var fixed: Dictionary = {}
	for pid: Variant in dw:
		var rec: Dictionary = dw[pid]
		fixed[pid] = {"last_death_day": int(rec.get("last_death_day", -999999999)), "streak": int(rec.get("streak", 0))}
	death_window = fixed
