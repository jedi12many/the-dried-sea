class_name SimClock
extends RefCounted
## Sim time. The soul of this game is slow variables (drift, favor, Vigor,
## Brink) — they tick on sim_minute or sim_day, NEVER per frame.
## Default scale: 1 real second = 1 sim minute; 1 sim day = 24 sim hours.

signal sim_minute(minute_of_day: int)
signal sim_day(day: int)

const MINUTES_PER_DAY := 24 * 60

var real_seconds_per_sim_minute := 1.0
var day := 0
var minute_of_day := 6 * 60   # campaigns start at dawn
var _accum := 0.0

func advance(real_delta: float) -> void:
	_accum += real_delta
	while _accum >= real_seconds_per_sim_minute:
		_accum -= real_seconds_per_sim_minute
		minute_of_day += 1
		if minute_of_day >= MINUTES_PER_DAY:
			minute_of_day = 0
			day += 1
			sim_day.emit(day)
		sim_minute.emit(minute_of_day)

func is_night() -> bool:
	return is_night_at(minute_of_day)

## Static, pure form (REEF-FOREST-SPEC §2/§6): _tint_for_minute and the reef's
## night-only creature spawns both need "is it night at minute X" without an
## instance — this is the one source of truth both read, so the threshold
## never drifts between the two call sites.
static func is_night_at(minute_of_day: int) -> bool:
	return minute_of_day < 5 * 60 or minute_of_day >= 21 * 60

func day_fraction(minutes: int) -> float:
	return float(minutes) / float(MINUTES_PER_DAY)
