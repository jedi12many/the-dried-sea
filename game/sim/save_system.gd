class_name SaveSystem
extends RefCounted
## Versioned saves with orderly migrations (docs/ARCHITECTURE.md §5).
## Systems serialize plain Dictionaries; content references are by immutable id.

const SAVE_VERSION := 1

## Migrations: index i migrates a save FROM version i+1 TO i+2.
## Pure funcs (Dictionary) -> Dictionary. NEVER edit a shipped migration.
static var MIGRATIONS: Array[Callable] = []

## `godhead` is optional (default null) so existing call sites keep compiling
## unchanged — additive, the way sanctum's state is bolted on by the caller.
static func to_save(clock: SimClock, devotion: DevotionSystem, village: VillageSystem, works: WorksSystem, verdict: VerdictSystem, godhead: GodheadSystem = null) -> Dictionary:
	var out := {
		"saveVersion": SAVE_VERSION,
		"clock": {"day": clock.day, "minute_of_day": clock.minute_of_day},
		"devotion": devotion.state.duplicate(true),
		"village": {
			"tribesmen": village.tribesmen.duplicate(true),
			"next_id": village._next_id,
			"fear_days_remaining": village.fear_days_remaining,
			"grief_days_remaining": village.grief_days_remaining,
			"has_memorial": village.has_memorial,
		},
		"works": {"placed": works.placed.duplicate(true), "next_id": works._next_id},
		"verdict": {
			"ledgers": verdict.ledgers.duplicate(true),
			"history": verdict.history.duplicate(true),
		},
	}
	if godhead != null:
		out["godhead"] = godhead.to_save()
	return out

static func migrate(save: Dictionary) -> Dictionary:
	var v := int(save.get("saveVersion", 1))
	while v < SAVE_VERSION:
		save = MIGRATIONS[v - 1].call(save)
		v += 1
		save["saveVersion"] = v
	return save

static func apply(save_in: Dictionary, clock: SimClock, devotion: DevotionSystem, village: VillageSystem, works: WorksSystem, verdict: VerdictSystem, godhead: GodheadSystem = null) -> void:
	var save := migrate(save_in)
	clock.day = int(save.clock.day)
	clock.minute_of_day = int(save.clock.minute_of_day)
	devotion.state = _int_keys(save.devotion)
	village.tribesmen = _int_keys(save.village.tribesmen)
	village._next_id = int(save.village.next_id)
	village.fear_days_remaining = int(save.village.fear_days_remaining)
	village.grief_days_remaining = int(save.village.get("grief_days_remaining", 0))   # additive since Arms track; old saves default
	village.has_memorial = bool(save.village.get("has_memorial", false))
	works.placed = _int_keys(save.works.placed)
	works._next_id = int(save.works.next_id)
	verdict.ledgers = _int_keys(save.verdict.ledgers)
	verdict.history = _int_keys(save.verdict.history)
	# NOTE: pre-Godhead saves may still carry a verdict.god_world_strength key
	# (the ad-hoc worldwide-dim hack this system used before Part II) — it is
	# simply ignored now; godhead_system.apply() below is the one true source.
	if godhead != null and save.has("godhead"):   # additive since Godhead (Part II); old saves have no key, godhead keeps its _init defaults
		godhead.apply(save.godhead)

static func write_file(path: String, save: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(save, "\t"))
	return true

static func read_file(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	return data if data is Dictionary else {}

## JSON round-trips Dictionary int keys as Strings; restore them.
static func _int_keys(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in d:
		var key: Variant = int(k) if (k is String and k.is_valid_int()) or k is float else k
		out[key] = d[k]
	return out
