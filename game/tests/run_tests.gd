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
	_test_village()
	_test_works()
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

	# drain to dormant (array capture: GDScript lambdas copy locals by value)
	var went_dormant: Array[bool] = [false]
	dev.god_dormant.connect(func(_p: int, _g: String) -> void: went_dormant[0] = true)
	while dev.can_cast(P, "inv-call-squall"):
		dev.cast(P, "inv-call-squall")
	check(went_dormant[0] or dev.state[P]["god-maren"].vigor < 0.45 * dev.max_vigor("god-maren"),
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

func _test_village() -> void:
	var reg := Registry.new()
	reg.load_all()
	var vil := VillageSystem.new(reg)

	# origin is a door: rescued start warm, taken start hot
	var anna := vil.add_tribesman("Anna", "class-brinewife", "rescued", ["trait-devout", "trait-industrious"], "god-halor")
	var korr := vil.add_tribesman("Korr", "class-salvager", "taken", ["trait-bitter"])
	check(vil.tribesmen[anna].grievance < vil.tribesmen[korr].grievance, "the Taken arrive resentful")
	check(vil.composite(korr) > vil.composite(anna), "captive composite runs hot")

	# neglect worsens; bitter trait multiplies worsening only
	var g0: float = vil.tribesmen[korr].grievance
	vil.drift_day(korr, ["overworked", "noShrineAccess"])
	var worsened: float = vil.tribesmen[korr].grievance - g0
	check(worsened > 5.0, "neglect + bitter multiplies drift (got %.1f)" % worsened)

	# attention heals, and kindness is never discounted
	vil.drift_day(korr, ["grievanceHeard"])
	check(vil.tribesmen[korr].grievance < g0 + worsened, "a grievance heard undoes real damage")

	# warden coverage: uncovered captives drift double
	var brek := vil.add_tribesman("Brek", "class-salvager", "taken", [])
	vil.tribesmen[brek].warden_covered = false
	var covered := vil.add_tribesman("Covered", "class-salvager", "taken", [])
	vil.drift_day(brek, ["overworked"])
	vil.drift_day(covered, ["overworked"])
	check(vil.tribesmen[brek].grievance > vil.tribesmen[covered].grievance, "uncovered Taken drift faster")

	# the Key -> bloom -> output beats Broken labor
	vil.meet_key(anna)
	check(vil.tribesmen[anna].bloomed, "key met -> bloom")
	var broke := vil.add_tribesman("Hollow", "class-brinewife", "broken", [])
	check(vil.output_per_hour(anna) > vil.output_per_hour(broke), "bloom beats Broken over any long run")

	# devout villagers power the gods
	check(vil.devout_count("god-halor") == 1, "Anna worships Halor for you")

	# justice: evidence free, paranoia priced
	var deltas: Array[float] = []
	vil.ledger_event.connect(func(_l: String, amount: float, _n: String) -> void: deltas.append(amount))
	vil.punish(brek, "execute", true)
	check(deltas[-1] == 0.0, "justice with evidence costs nothing")
	vil.punish(covered, "execute", false)
	check(deltas[-1] < 0.0 and vil.fear_days_remaining > 0, "evidence-free execution: ledger hit + village fear")
	var g_before_fear: float = vil.tribesmen[korr].grievance
	vil.drift_day(korr, [])
	check(vil.tribesmen[korr].grievance > g_before_fear, "fear accelerates drift in the survivors")

	# the Unbinding converts the Taken
	vil.unbind(korr)
	check(vil.tribesmen[korr].origin == "rescued" and vil.tribesmen[korr].grievance < g_before_fear + 10.0,
		"the Unbinding opens the kind door")

func _test_works() -> void:
	var reg := Registry.new()
	reg.load_all()
	var dev := DevotionSystem.new(reg)
	var works := WorksSystem.new(reg, dev)
	var P := 1

	# building pulses favor to the owning god
	works.place("work-hearth", P)
	check(dev.state[P]["god-halor"].favor > 0.0, "raising Halor's hearth pulses favor")

	# in-use works trickle; idle works feed nothing (the law)
	var smoke := works.place("work-smokehouse", P)
	var f0: float = dev.state[P]["god-halor"].favor
	works.favor_hour()
	check(dev.state[P]["god-halor"].favor == f0, "idle works feed NOTHING")
	works.set_in_use(smoke, true)
	works.favor_hour()
	check(dev.state[P]["god-halor"].favor > f0, "curing meat is a small prayer")

	# grim works testify by presence
	check(not works.grim_in_village(), "an honest village so far")
	var grim_seen: Array[bool] = [false]
	works.grim_raised.connect(func(_w: String) -> void: grim_seen[0] = true)
	works.place("work-salt-wheel", P)
	check(grim_seen[0] and works.grim_in_village(), "the Salt-Wheel testifies")
	check(dev.state[P]["god-ur-noth"].favor > 0.0, "and Ur-Noth felt it go up")
