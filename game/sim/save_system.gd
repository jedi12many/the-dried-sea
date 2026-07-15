class_name SaveSystem
extends RefCounted
## Versioned saves with orderly migrations (docs/ARCHITECTURE.md §5).
## Systems serialize plain Dictionaries; content references are by immutable id.

const SAVE_VERSION := 1

## Migrations: index i migrates a save FROM version i+1 TO i+2.
## Pure funcs (Dictionary) -> Dictionary. NEVER edit a shipped migration.
static var MIGRATIONS: Array[Callable] = []

static func to_save(clock: SimClock, devotion: DevotionSystem, village: VillageSystem, works: WorksSystem, verdict: VerdictSystem) -> Dictionary:
	return {
		"saveVersion": SAVE_VERSION,
		"clock": {"day": clock.day, "minute_of_day": clock.minute_of_day},
		"devotion": devotion.state.duplicate(true),
		"village": {
			"tribesmen": village.tribesmen.duplicate(true),
			"next_id": village._next_id,
			"fear_days_remaining": village.fear_days_remaining,
		},
		"works": {"placed": works.placed.duplicate(true), "next_id": works._next_id},
		"verdict": {
			"ledgers": verdict.ledgers.duplicate(true),
			"history": verdict.history.duplicate(true),
			"god_world_strength": verdict.god_world_strength.duplicate(true),
		},
	}

static func migrate(save: Dictionary) -> Dictionary:
	var v := int(save.get("saveVersion", 1))
	while v < SAVE_VERSION:
		save = MIGRATIONS[v - 1].call(save)
		v += 1
		save["saveVersion"] = v
	return save

static func apply(save_in: Dictionary, clock: SimClock, devotion: DevotionSystem, village: VillageSystem, works: WorksSystem, verdict: VerdictSystem) -> void:
	var save := migrate(save_in)
	clock.day = int(save.clock.day)
	clock.minute_of_day = int(save.clock.minute_of_day)
	devotion.state = _int_keys(save.devotion)
	village.tribesmen = _int_keys(save.village.tribesmen)
	village._next_id = int(save.village.next_id)
	village.fear_days_remaining = int(save.village.fear_days_remaining)
	works.placed = _int_keys(save.works.placed)
	works._next_id = int(save.works.next_id)
	verdict.ledgers = _int_keys(save.verdict.ledgers)
	verdict.history = _int_keys(save.verdict.history)
	verdict.god_world_strength = save.verdict.god_world_strength

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
