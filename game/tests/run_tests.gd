extends SceneTree
## Headless test runner: godot --headless --path game --script res://tests/run_tests.gd
## Plain asserts, no framework until one earns its place. Exit code 0/1.

var failures: PackedStringArray = []
var checks := 0

func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures.append(msg)
		push_error("FAIL: " + msg)

func _init() -> void:
	_test_registry()
	_test_clock()
	_test_devotion()
	print("\n%d checks, %d failure(s)" % [checks, failures.size()])
	quit(1 if failures.size() > 0 else 0)

func _test_registry() -> void:
	var reg := Registry.new()
	check(reg.load_all(), "registry loads clean: %s" % ", ".join(reg.load_errors))
	check(reg.all_of("god").size() == 7, "7 gods incl. the empty seat")
	check(reg.get_entity("work-salt-wheel").get("grim", false), "the Salt-Wheel knows what it is")
	check(reg.tuning.has("economy"), "economy tuning loaded")

func _test_clock() -> void:
	var clock := SimClock.new()
	var days: Array[int] = []
	clock.sim_day.connect(func(d: int) -> void: days.append(d))
	clock.real_seconds_per_sim_minute = 1.0
	clock.advance(SimClock.MINUTES_PER_DAY * 1.0)  # exactly one day of real-seconds
	check(days.size() == 1, "one sim_day fired after a day of minutes (got %d)" % days.size())
	check(clock.minute_of_day == 6 * 60, "clock wraps back to dawn start offset")

func _test_devotion() -> void:
	var reg := Registry.new()
	reg.load_all()
	var dev := DevotionSystem.new(reg)
	var P := 1

	# attunement budget
	check(dev.attune(P, "god-maren"), "attune maren r1")
	check(dev.attune(P, "god-maren"), "attune maren r2")
	check(not dev.attune(P, "god-all-tide"), "the empty seat is unattunable")

	# spells drain
	check(dev.can_cast(P, "inv-call-squall"), "can cast at full vigor")
	var before: float = dev.state[P]["god-maren"].vigor
	dev.cast(P, "inv-call-squall")
	check(dev.state[P]["god-maren"].vigor < before, "casting drains Maren")

	# drain to dormant
	var went_dormant := false
	dev.god_dormant.connect(func(_p: int, _g: String) -> void: went_dormant = true)
	while dev.can_cast(P, "inv-call-squall"):
		dev.cast(P, "inv-call-squall")
	check(went_dormant or dev.state[P]["god-maren"].vigor < 0.45 * dev.max_vigor("god-maren"),
		"repeated casting exhausts the god")
	check(dev.blessing_strength(P, "god-maren") < 1.0, "blessing dims as vigor falls")

	# worship feeds
	var low: float = dev.state[P]["god-maren"].vigor
	dev.rite_day(P, "god-maren", "chapel", 1)
	dev.villager_trickle_day(P, "god-maren", 3)
	check(dev.state[P]["god-maren"].vigor > low, "worship restores")

	# works feed favor, not vigor
	var v: float = dev.state[P]["god-maren"].vigor
	dev.work_favor_hour(P, "god-maren", 3.0)
	check(dev.state[P]["god-maren"].favor > 0.0 and dev.state[P]["god-maren"].vigor == v,
		"use is worship: favor rises, vigor untouched")
