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
	_test_verdict()
	_test_save()
	_test_stats()
	_test_golden_run()
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

func _test_verdict() -> void:
	var reg := Registry.new()
	reg.load_all()
	var ver := VerdictSystem.new(reg)
	var P := 1

	check(ver.lean(P) == "steady", "a blank slate reads steady")
	ver.record(P, "shepherd", 25.0, "many keys met")
	check(ver.lean(P) == "shepherd", "kept people -> shepherd lean")

	# remnants: consume dims the god WORLD-WIDE, permanently
	var dimmed: Array[bool] = [false]
	ver.god_dimmed_worldwide.connect(func(_g: String, _s: float) -> void: dimmed[0] = true)
	ver.remnant_consume(P, "god-neris")
	check(dimmed[0] and ver.god_world_strength["god-neris"] == 80.0, "consuming Neris breaks a piece of everyone's tides")
	ver.remnant_enshrine(P, "god-neris")
	check(ver.god_world_strength["god-neris"] == 90.0, "enshrining gives some of it back")

	# a purge spree reads dark
	ver.record(P, "shepherd", -15.0, "execution without evidence")
	ver.record(P, "shepherd", -15.0, "execution without evidence")
	ver.record(P, "peoples", -22.0, "pool-draining")
	check(ver.lean(P) in ["taker", "dark"], "the ledgers notice a tyrant (lean=%s)" % ver.lean(P))

func _test_save() -> void:
	var reg := Registry.new()
	reg.load_all()
	var clock := SimClock.new()
	var dev := DevotionSystem.new(reg)
	var vil := VillageSystem.new(reg)
	var works := WorksSystem.new(reg, dev)
	var ver := VerdictSystem.new(reg)

	clock.day = 12
	dev.attune(1, "god-halor")
	dev.cast(1, "inv-pillar-of-salt")
	var anna := vil.add_tribesman("Anna", "class-brinewife", "rescued", ["trait-devout"], "god-halor")
	vil.meet_key(anna)
	var smoke := works.place("work-smokehouse", 1)
	works.set_in_use(smoke, true)
	ver.record(1, "shepherd", 25.0, "test deeds")

	# round-trip through JSON on disk (the real path, string keys and all)
	var path := "user://test_save.json"
	check(SaveSystem.write_file(path, SaveSystem.to_save(clock, dev, vil, works, ver)), "save writes")
	var clock2 := SimClock.new()
	var dev2 := DevotionSystem.new(reg)
	var vil2 := VillageSystem.new(reg)
	var works2 := WorksSystem.new(reg, dev2)
	var ver2 := VerdictSystem.new(reg)
	SaveSystem.apply(SaveSystem.read_file(path), clock2, dev2, vil2, works2, ver2)

	check(clock2.day == 12, "clock survives the round trip")
	check(dev2.state[1]["god-halor"].rank == 1, "attunement survives")
	check(absf(float(dev2.state[1]["god-halor"].vigor) - float(dev.state[1]["god-halor"].vigor)) < 0.001, "vigor survives")
	check(vil2.tribesmen[anna].bloomed, "Anna's bloom survives")
	check(works2.placed[smoke].in_use, "the smokehouse is still curing")
	check(ver2.lean(1) == "shepherd", "the ledgers survive")
	check(vil2.add_tribesman("New", "class-warden", "rescued") != anna, "id counters restored — no collisions")

func _test_stats() -> void:
	var stats := StatsSystem.new()
	stats.register("hero", 100.0, 100.0)
	stats.register("hound", 40.0)

	check(not stats.damage("hound", 39.0), "a wounded hound is not a dead hound")
	var deaths: Array = []
	stats.died.connect(func(id: Variant) -> void: deaths.append(id))
	check(stats.damage("hound", 2.0), "the last point counts")
	check(deaths == ["hound"], "death signal names the fallen")

	check(stats.spend_stamina("hero", 60.0), "spend within means")
	check(not stats.spend_stamina("hero", 60.0), "tired arms refuse — no negative stamina")
	stats.tick(2.0)
	check(stats.stamina("hero") > 40.0, "breath comes back with time")
	stats.tick(100.0)
	check(stats.stamina("hero") == 100.0, "stamina caps at max")

	# food is preparation: it raises the ceiling, then wears off
	check(stats.max_hp("hero") == 100.0, "unfed floor")
	check(stats.eat("hero", 20.0, 15.0, 30.0), "first meal")
	check(stats.eat("hero", 10.0, 10.0, 60.0), "second meal")
	check(not stats.eat("hero", 10.0, 10.0, 60.0), "a full belly refuses the third")
	check(stats.max_hp("hero") == 130.0 and stats.max_stamina("hero") == 125.0, "fed ceiling")
	stats.tick(31.0)
	check(stats.max_hp("hero") == 110.0, "the first meal wears off")
	check(stats.hp("hero") <= stats.max_hp("hero"), "hp clamps down with the ceiling")
	stats.tick(60.0)
	check(stats.max_hp("hero") == 100.0, "unfed again")

func _test_golden_run() -> void:
	## 30 sim-days, all systems ticking together, mid-game setup.
	## The WORLD-SPEC tuning laws asserted as an integration outcome.
	var reg := Registry.new()
	reg.load_all()
	var dev := DevotionSystem.new(reg)
	var vil := VillageSystem.new(reg)
	var works := WorksSystem.new(reg, dev)
	var ver := VerdictSystem.new(reg)
	dev.ledger_event.connect(func(p: int, l: String, a: float, n: String) -> void: ver.record(p, l, a, n))
	vil.ledger_event.connect(func(l: String, a: float, n: String) -> void: ver.record(1, l, a, n))

	var P := 1
	dev.attune(P, "god-halor")
	dev.attune(P, "god-halor")  # rank 2: unlocks brine-ward; pillar from r1
	var tended: Array[int] = []
	for i in 3:
		tended.append(vil.add_tribesman("Tended%d" % i, "class-brinewife", "rescued", ["trait-devout"], "god-halor"))
	var neglected := vil.add_tribesman("Forgotten", "class-salvager", "rescued", ["trait-bitter"])
	var smoke := works.place("work-smokehouse", P)
	works.set_in_use(smoke, true)

	var casts := 0
	for day in 30:
		for hour in 24:
			works.favor_hour()
		# greedy clutch-casting: cast the moment the god can afford it
		if dev.can_cast(P, "inv-pillar-of-salt"):
			dev.cast(P, "inv-pillar-of-salt")
			casts += 1
		for id: int in tended:
			vil.drift_day(id, ["rested", "riteAttended"])
		vil.drift_day(neglected, ["overworked", "noShrineAccess"])
		dev.rite_day(P, "god-halor", "chapel", 1)
		dev.villager_trickle_day(P, "god-halor", vil.devout_count("god-halor"))
		vil.end_of_day()

	# the tuning law: 'once per pickle' — mid-game sustainable casts land in band
	check(casts >= 5 and casts <= 14, "30-day mid-game casts in spec band [5,14] (got %d)" % casts)
	# tended villagers hold; the forgotten one soured
	for id: int in tended:
		check(vil.tribesmen[id].expression == "steady", "tended villager stays steady")
	check(vil.tribesmen[neglected].expression != "steady", "the Forgotten soured (%s)" % vil.tribesmen[neglected].expression)
	# a month of honest use courts the god materially
	check(dev.favor_tier(P, "god-halor") >= 1, "a month of smokehouse courts Halor to tier %d" % dev.favor_tier(P, "god-halor"))
	# and the whole month reads as decent shepherding
	check(ver.lean(P) != "dark", "an honest month doesn't read dark (lean=%s)" % ver.lean(P))
