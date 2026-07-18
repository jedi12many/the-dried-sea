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
	_test_trait_discovery()
	_test_villager_arms()
	_test_works()
	_test_verdict()
	_test_abilities()
	_test_save()
	_test_stats()
	_test_sanctum()
	_test_godhead()
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

## Trait discovery: traits are found BY ATTENTION (WORLD-SPEC), never a menu —
## hidden per-trait `notice` ticks toward tuned thresholds (tuning/villagers.json
## discovery block) and lands in `discovered`, or fires early via the Key
## (blooming is definitionally noticing).
func _test_trait_discovery() -> void:
	var reg := Registry.new()
	reg.load_all()
	var vil := VillageSystem.new(reg)
	var dtune: Dictionary = vil.vtune.get("discovery", {})

	# work axis: ticks only on "worked" days, discovers at the tuned threshold
	var work_threshold := int(dtune.get("work", 4))
	var worker := vil.add_tribesman("Worker", "class-salvager", "rescued", ["trait-industrious"])
	for i in work_threshold - 1:
		vil.discovery_day(worker, ["worked"])
	check(not vil.tribesmen[worker].discovered.has("trait-industrious"), "not yet — one worked dawn short of the tuned threshold")
	vil.discovery_day(worker, ["worked"])
	check(vil.tribesmen[worker].discovered.has("trait-industrious"), "work-axis trait discovers after %d worked dawns" % work_threshold)

	# an idle day (no task at all) teaches nothing about a work trait
	var idler := vil.add_tribesman("Idler", "class-salvager", "rescued", ["trait-industrious"])
	for i in work_threshold + 2:
		vil.discovery_day(idler, [])
	check(not vil.tribesmen[idler].discovered.has("trait-industrious"), "an idle villager's work trait never ticks")

	# faith axis: half rate absent a chapel, full rate once one stands — same
	# trait, roughly twice the dawns needed without it
	var faith_threshold: float = float(dtune.get("faith", 5))
	var slow_pilgrim := vil.add_tribesman("Slow", "class-salvager", "rescued", ["trait-devout"])
	for i in int(ceil(faith_threshold / 0.5)) - 1:
		vil.discovery_day(slow_pilgrim, [])
	check(not vil.tribesmen[slow_pilgrim].discovered.has("trait-devout"), "faith at half rate (no chapel) takes about twice as long")
	var fast_pilgrim := vil.add_tribesman("Fast", "class-salvager", "rescued", ["trait-devout"])
	for i in int(faith_threshold):
		vil.discovery_day(fast_pilgrim, ["faith"])
	check(vil.tribesmen[fast_pilgrim].discovered.has("trait-devout"), "faith at full rate (a chapel stands) discovers on schedule")

	# quirk axis: ticks every day, no context required — quirks show constantly
	var quirk_threshold := int(dtune.get("quirk", 8))
	var quirky := vil.add_tribesman("Quirky", "class-salvager", "rescued", ["trait-night-owl"])
	for i in quirk_threshold:
		vil.discovery_day(quirky, [])
	check(vil.tribesmen[quirky].discovered.has("trait-night-owl"), "quirks tick every day regardless of context")

	# "road" doubles every rate: walked with a player daily, half the dawns suffice
	var walker := vil.add_tribesman("Walker", "class-salvager", "rescued", ["trait-industrious"])
	for i in int(ceil(float(work_threshold) / 2.0)):
		vil.discovery_day(walker, ["worked", "road"])
	check(vil.tribesmen[walker].discovered.has("trait-industrious"), "road doubling discovers a work trait in half the dawns")

	# social axis: only from talk_discovery, capped at one increment per sim-day
	var social_threshold := int(dtune.get("social", 3))
	var talker := vil.add_tribesman("Talker", "class-salvager", "rescued", ["trait-storyteller"])
	for i in 20:   # 20 talks on the SAME day — the cap must still count it once
		vil.talk_discovery(talker, 0)
	check(not vil.tribesmen[talker].discovered.has("trait-storyteller"), "repeated talk on one day counts once (once-per-day cap)")
	for d in range(1, social_threshold):
		vil.talk_discovery(talker, d)
	check(vil.tribesmen[talker].discovered.has("trait-storyteller"), "social trait discovers after %d distinct talking days" % social_threshold)
	# discovery_day (the dawn tick) never ticks a social trait, however busy the day
	var quiet := vil.add_tribesman("Quiet", "class-salvager", "rescued", ["trait-storyteller"])
	for i in 50:
		vil.discovery_day(quiet, ["worked", "faith", "road"])
	check(not vil.tribesmen[quiet].discovered.has("trait-storyteller"), "social traits never tick from days, however attentive")

	# bloom reveals the key's trait: meeting a Key sourced from a trait's
	# keyHints auto-discovers THAT trait on the spot, and only that one
	var bloomer := vil.add_tribesman("Bloomer", "class-brinewife", "rescued", ["trait-devout", "trait-industrious"])
	check(vil.tribesmen[bloomer].key == "shrine-access", "Devout's keyHint wins the Key (first trait listed)")
	vil.meet_key(bloomer)
	check(vil.tribesmen[bloomer].discovered.has("trait-devout"), "blooming is definitionally noticing — the key's trait is discovered")
	check(not vil.tribesmen[bloomer].discovered.has("trait-industrious"), "...but only the trait the key came from, not the whole roster")

	# save/load round-trips notice (hidden, in-progress) + discovered (revealed)
	var partial := vil.add_tribesman("Partial", "class-salvager", "rescued", ["trait-industrious"])
	vil.discovery_day(partial, ["worked"])   # one tick, below the threshold — must survive as hidden progress
	var path := "user://test_save_discovery.json"
	check(SaveSystem.write_file(path, SaveSystem.to_save(SimClock.new(), DevotionSystem.new(reg), vil, WorksSystem.new(reg, DevotionSystem.new(reg)), VerdictSystem.new(reg))), "discovery save writes")
	var vil2 := VillageSystem.new(reg)
	SaveSystem.apply(SaveSystem.read_file(path), SimClock.new(), DevotionSystem.new(reg), vil2, WorksSystem.new(reg, DevotionSystem.new(reg)), VerdictSystem.new(reg))
	check(vil2.tribesmen[bloomer].discovered.has("trait-devout"), "save/load round-trips discovered traits")
	check(float(vil2.tribesmen[partial].notice.get("trait-industrious", -1.0)) == 1.0, "...and the hidden notice progress, untouched")

## The Arms track (VILLAGER-AND-GODHEAD-SPEC Part I): the Trade feeds the
## village, the Arms walks the road. Levels bank per class, talents ignite at
## 3/6/9, bloom out-levels Broken, and the village grieves its road-dead.
func _test_villager_arms() -> void:
	var reg := Registry.new()
	reg.load_all()
	var vil := VillageSystem.new(reg)

	# training: origin is a door, not a destiny
	var rook := vil.add_tribesman("Rook", "class-salvager", "rescued")
	check(vil.arms_level(rook) == 0, "no arms class -> level 0")
	check(not vil.train_arms(rook, "arms-nonsense"), "unknown arms class refused")
	check(vil.train_arms(rook, "arms-warrior"), "any villager can take up arms")
	check(vil.arms_level(rook) == 1, "a fresh class starts at level 1")
	check(vil.villager_max_hp(rook) == 50.0, "level 1 stands at base hp")
	check(vil.arms_primary_mult(rook) == 1.0, "level 1 primaries x1.0")

	# the curve: level n at 25*n^2 total XP (L2 at 100, L10 at 2500)
	var arms: Dictionary = vil.tribesmen[rook].arms
	arms.xp = 99.0
	check(vil.arms_level(rook) == 1, "99 xp is still level 1")
	arms.xp = 100.0
	check(vil.arms_level(rook) == 2, "1->2 at exactly 100")
	arms.xp = 2025.0
	check(vil.arms_level(rook) == 9, "8->9 at 2025 (25*81)")
	arms.xp = 2499.0
	check(vil.arms_level(rook) == 9, "one xp short of the summit")
	arms.xp = 2500.0
	check(vil.arms_level(rook) == 10, "9->10 at 2500 (25*100)")
	arms.xp = 999999.0
	check(vil.arms_level(rook) == 10, "the curve clamps at 10")

	# per-level baseline at the summit: +8% hp, +2% primary per level past 1
	check(absf(vil.villager_max_hp(rook) - 50.0 * 1.72) < 0.001, "L10 hp = base x1.72 (+8 pct/level)")
	check(absf(vil.arms_primary_mult(rook) - 1.18) < 0.001, "L10 primaries x1.18 (+2 pct/level)")

	# talents ignite at exactly 3/6/9, with signals
	arms.xp = 224.0   # one short of level 3 (225)
	var leveled: Array = []
	var ignitions: Array = []
	vil.arms_leveled.connect(func(_i: int, l: int) -> void: leveled.append(l))
	vil.arms_talent_ignited.connect(func(_i: int, t: String) -> void: ignitions.append(t))
	check(vil.ignited_talents(rook).size() == 0, "level 2: nothing ignited yet")
	vil.grant_xp(rook, "drillDay")   # +8 -> 232, crosses 225
	check(vil.arms_level(rook) == 3, "a drill day tips level 3")
	check(leveled == [3], "arms_leveled fired with the new level")
	check("arms-talent-hold-fast" in ignitions, "Hold-fast ignites at 3")
	check(vil.ignited_talents(rook).size() == 1, "one talent lit")
	arms.xp = 875.0   # level 5; expeditionReturn +40 -> 915 crosses 900
	vil.grant_xp(rook, "expeditionReturn")
	check("arms-talent-shield-wall" in ignitions, "Shield-wall ignites at 6")
	arms.xp = 2024.0   # one short of level 9
	vil.grant_xp(rook, "drillDay")
	check("arms-talent-breakwater" in ignitions and vil.ignited_talents(rook).size() == 3, "Breakwater ignites at 9")

	# xp sources + multipliers: bloom beats Broken here too
	var bloomy := vil.add_tribesman("Bloomy", "class-brinewife", "rescued", ["trait-devout"])
	vil.train_arms(bloomy, "arms-archer")
	vil.meet_key(bloomy)
	vil.grant_xp(bloomy, "drillDay")
	check(float(vil.tribesmen[bloomy].arms.xp) == 12.0, "bloomed x1.5: a drill day pays 12")
	var hollow := vil.add_tribesman("Hollow", "class-salvager", "broken")
	vil.train_arms(hollow, "arms-warrior")
	vil.grant_xp(hollow, "drillDay")
	check(float(vil.tribesmen[hollow].arms.xp) == 6.0, "Broken x0.75: obedient, diminished")
	var glum := vil.add_tribesman("Glum", "class-salvager", "rescued")
	vil.train_arms(glum, "arms-warrior")
	vil.tribesmen[glum].expression = "slacking"
	vil.grant_xp(glum, "killAssist", 2)
	check(float(vil.tribesmen[glum].arms.xp) == 12.5, "slacking x0.5 on a tier-2 kill assist (25)")
	vil.grant_xp(glum, "killAssist", 99)
	check(float(vil.tribesmen[glum].arms.xp) == 12.5, "an unknown threat tier pays nothing")
	var idle := vil.add_tribesman("Idle", "class-salvager", "rescued")
	vil.grant_xp(idle, "drillDay")
	check(vil.arms_level(idle) == 0, "xp without an arms class goes nowhere")

	# the Acolyte gate: faith >= 50 and a patron — they channel, not cast
	check(not vil.train_arms(hollow, "arms-acolyte"), "the faithless cannot channel (broken faith 0)")
	check(not vil.train_arms(rook, "arms-acolyte"), "no patron, no lens")
	var devout := vil.add_tribesman("Devout", "class-priest", "pilgrim", [], "god-maren")
	check(vil.train_arms(devout, "arms-acolyte"), "faith and a patron open the Acolyte door")

	# switching banks levels; switching back restores them (never erasure)
	var warrior_xp: float = float(vil.tribesmen[rook].arms.xp)
	check(vil.train_arms(rook, "arms-archer"), "retraining is allowed")
	check(vil.arms_level(rook) == 1, "the new class starts fresh")
	check(vil.arms_level_for(rook, "arms-warrior") == 9, "the old levels are banked, not burned")
	vil.tribesmen[rook].arms.xp = 400.0   # archer level 4
	vil.train_arms(rook, "arms-warrior")
	check(float(vil.tribesmen[rook].arms.xp) == warrior_xp, "switching back restores the banked xp")
	check(vil.arms_level_for(rook, "arms-archer") == 4, "and the archer levels wait their turn")

	# downed bookkeeping: sim owns the state, presentation owns the clock
	vil.mark_downed(rook, 123.4)
	check(vil.is_downed(rook), "downed at 0 hp")
	vil.revive(rook)
	check(not vil.is_downed(rook), "revived by a friend standing over them")

	# the road's far side: permadeath, gear where they fell, the village grieves
	var deltas: Array = []
	var notes: Array = []
	vil.ledger_event.connect(func(_l: String, a: float, n: String) -> void:
		deltas.append(a)
		notes.append(n))
	vil.tribesmen[glum].equipment.weapon = "item-bronze-knife"
	var dropped: Dictionary = vil.road_death(glum, false)
	check(str(dropped.weapon) == "item-bronze-knife", "their sword drops where they fell")
	check(not vil.tribesmen.has(glum), "dead is dead — no softer tier")
	check(deltas[-1] == 0.0 and "mourned" in str(notes[-1]), "an honest death writes 0, mourned")
	check(vil.grief_days_remaining == 3, "the village grieves 3 days")
	var mourner := vil.add_tribesman("Mourner", "class-salvager", "rescued")
	var g0: float = float(vil.tribesmen[mourner].grievance)
	vil.drift_day(mourner, [])
	check(float(vil.tribesmen[mourner].grievance) > g0, "grief weighs on the survivors' drift")
	vil.end_of_day()
	check(vil.grief_days_remaining == 2, "grief lifts a day at a time")
	vil.road_death(hollow, true)
	check(deltas[-1] == -4.0, "a reckless death writes shepherd -4")

	# the memorial halves grief: the homestead god keeps the dead
	var vil2 := VillageSystem.new(reg)
	vil2.has_memorial = true
	var kept := vil2.add_tribesman("Kept", "class-salvager", "rescued")
	vil2.road_death(kept, false)
	check(vil2.grief_days_remaining < 3, "a memorial halves the grief days (3 -> %d)" % vil2.grief_days_remaining)

	# arrivals can come pre-trained (wardens as Warrior 1, priests as Acolyte 1)
	var ward := vil.add_tribesman("Ward", "class-warden", "rescued", [], "", "arms-warrior")
	check(vil.arms_level(ward) == 1 and str(vil.tribesmen[ward].arms.class_id) == "arms-warrior", "wardens can arrive Warrior 1")
	var pilgrim := vil.add_tribesman("Pil", "class-priest", "pilgrim", [], "god-halor", "arms-acolyte")
	check(vil.arms_level(pilgrim) == 1 and str(vil.tribesmen[pilgrim].arms.class_id) == "arms-acolyte", "priests can arrive Acolyte 1 of their god")

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

	# remnants: the deed is recorded here; WORLD-WIDE strength moved to
	# godhead_system (VILLAGER-AND-GODHEAD-SPEC Part II §4 — see _test_godhead's
	# consumed()/enshrine_remnant() coverage, and smoke.gd's end-to-end version
	# of this exact scenario). This system only keeps the player ledger now.
	ver.remnant_consume(P, "god-neris")
	check(ver.ledgers[P]["remnants"] == -12.0, "consuming a remnant records the deed")
	ver.remnant_enshrine(P, "god-neris")
	check(ver.ledgers[P]["remnants"] == -2.0, "enshrining records its own, gentler deed (-12 + 10)")

	# a purge spree reads dark
	ver.record(P, "shepherd", -15.0, "execution without evidence")
	ver.record(P, "shepherd", -15.0, "execution without evidence")
	ver.record(P, "peoples", -22.0, "pool-draining")
	check(ver.lean(P) in ["taker", "dark"], "the ledgers notice a tyrant (lean=%s)" % ver.lean(P))

func _test_abilities() -> void:
	var reg := Registry.new()
	reg.load_all()
	var ab := AbilitiesSystem.new(reg)
	var P := 1

	check(reg.all_of("virtue").size() == 6, "six virtues — the pantheon read into a person")
	check(not ab.allocate(P, "virtue-grit"), "no Temper, no tempering")
	ab.earn(P, 10)
	var ignited: Array[String] = []
	ab.talent_ignited.connect(func(_p: int, t: String) -> void: ignited.append(t))
	for i in 3:
		check(ab.allocate(P, "virtue-grit"), "spend Temper into GRIT")
	check(ab.talent_active(P, "talent-salt-skin"), "Salt-Skin ignites at 3")
	check("talent-salt-skin" in ignited, "and the signal fired")
	check(ab.mod_add(P, "base-hp") == 20.0, "+20 health from the talent")
	check(ab.available(P) == 7, "seven Temper left")

	# free, unlimited respec — the Temper returns whole
	check(ab.deallocate(P, "virtue-grit"), "take one back")
	check(not ab.talent_active(P, "talent-salt-skin"), "the talent goes dark below threshold")
	check(ab.available(P) == 8, "the Temper returns whole")

	# multiplicative mods
	for i in 3:
		ab.allocate(P, "virtue-tide")
	check(ab.mod_mult(P, "stamina-regen-mult") == 1.5, "Second Wind: breath owed to you")
	check(ab.mod_mult(P, "nonexistent-mod") == 1.0 and ab.mod_add(P, "nonexistent-mod") == 0.0, "unknown mods are inert")

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

## The Sanctum: the altar is the god's character sheet — relic slots are its
## worn gear, the offertory bag its pack, appetites make bronze mean something
## to one god and nothing to another, and Splendor multiplies the rite.
func _test_sanctum() -> void:
	var reg := Registry.new()
	reg.load_all()
	var sanc := SanctumSystem.new(reg)
	var P := 1
	# appetites straight from the god data — the tables are the tutorial
	check(sanc.lane("god-halor", "item-salt") == "craves", "Halor craves salt")
	check(sanc.lane("god-halor", "item-storm-glass") == "ignores", "Halor ignores storm-glass")
	check(sanc.lane("god-maren", "item-storm-glass") == "craves", "Maren craves storm-glass")
	check(sanc.lane("god-halor", "item-crab-meat") == "offends", "raw blood on the hearth god's altar offends")
	check(sanc.lane("god-neris", "item-bronze-salvage") == "craves", "bronze means something to Neris")
	check(sanc.lane("god-halor", "item-bronze-salvage") == "ignores", "…and nothing to Halor")
	# an altar wakes on register, and only sanctum works count
	sanc.register(1, "work-altar-halor")
	sanc.register(2, "work-hearth")
	check(sanc.is_altar(1) and not sanc.is_altar(2), "only sanctum works become altars")
	check(sanc.altar_for("god-halor") == 1, "rites can find the god's altar")
	check(absf(sanc.splendor(1) - 1.0) < 0.001, "a bare altar is exactly x1.0")
	# offerings: craved beats accepted, variety beats one giant stack
	sanc.deposit(P, 1, "item-salt", 16)
	var salt_only := sanc.splendor(1)
	check(salt_only > 1.0, "craved offerings raise Splendor (%.2f)" % salt_only)
	sanc.deposit(P, 1, "item-smoked-crab", 16)
	var two_craved := sanc.splendor(1)
	sanc.withdraw(1, "item-smoked-crab")
	sanc.deposit(P, 1, "item-salt", 16)   # same units, one stack of 32
	check(two_craved > sanc.splendor(1), "variety of craved types beats one giant stack")
	# relics: the god's worn gear — capped slots, off-god worth less
	var pre_relic := sanc.splendor(1)
	check(sanc.place_relic(1, "item-remnant-shellback", 0), "a remnant can be DISPLAYED (the third road)")
	check(absf(sanc.splendor(1) - pre_relic - 0.4) < 0.01, "the on-god relic adds exactly its 0.4 chunk")
	var pre_offgod := sanc.splendor(1)
	sanc.place_relic(1, "item-neriss-hourglass", 0)   # Neris's story on Halor's altar
	check(absf(sanc.splendor(1) - pre_offgod - 0.25) < 0.01, "an off-god relic burns at half (0.5 pts x 0.5)")
	sanc.take_relic(1, "item-neriss-hourglass")
	check(not sanc.place_relic(1, "item-remnant-shellback", 0), "the same story can't be told twice")
	check(not sanc.place_relic(1, "item-salt", 0), "ordinary goods are not relics")
	check(sanc.relic_slots(1, 0) == 4 and sanc.relic_slots(1, 2) == 6 and sanc.relic_slots(1, 3) == 8, "slots grow 4/6/8 with favor tier")
	check(sanc.take_relic(1, "item-remnant-shellback"), "relics come back — displayed, never consumed")
	# the offends lane drags the whole temple down, below 1.0
	sanc.register(3, "work-altar-maren")
	# (halor altar) — lay an offense
	var before_offense := sanc.splendor(1)
	var offended := [false]
	sanc.offense_laid.connect(func(_p: int, _g: String, _i: String) -> void: offended[0] = true)
	sanc.deposit(P, 1, "item-crab-meat", 9)
	check(offended[0], "the offense is witnessed (signal for the Verdict ledger)")
	check(sanc.splendor(1) < before_offense, "an offense sours Splendor")
	sanc.withdraw(1, "item-crab-meat")
	# the dawn tithe: craved taken first, consumption IS worship
	sanc.deposit(P, 3, "item-storm-glass", 2)
	sanc.deposit(P, 3, "item-rope", 4)
	var fed := sanc.dawn_tithe()
	check(float(fed.vigor.get("god-maren", 0.0)) > 0.0, "the tithe feeds Maren (%.1f vigor)" % float(fed.vigor.get("god-maren", 0.0)))
	check(int(sanc.state[3].bag.get("item-storm-glass", 0)) == 1, "the god took one craved storm-glass")
	# Godhead (Part II §3): "craved" is reported SEPARATELY from vigor — only the
	# craved lane feeds a god's world-level body ("+0.05% per craved item taken");
	# the rope taken alongside it is merely "accepts" (Vigor-only, no Godhead cut).
	check(int(fed.craved.get("god-maren", 0)) == 1, "exactly the one craved storm-glass counts toward Godhead's tithe")
	# splendor bounded by the ceiling
	for i in 30:
		sanc.deposit(P, 3, "item-storm-glass", 100)
	check(sanc.splendor(3) <= float(reg.tuning.sanctum.multiplierCeiling) + 0.001, "Splendor never exceeds the ceiling")
	# save round-trip
	var dump := sanc.to_save()
	var sanc2 := SanctumSystem.new(reg)
	sanc2.from_save(dump)
	check(sanc2.is_altar(1) and absf(sanc2.splendor(3) - sanc.splendor(3)) < 0.001, "the altars survive a save round-trip")
	check(sanc2.relic_slots(3, 0) == 4, "work_id survives the round-trip (slots still resolve)")
	# rites: splendor multiplies recovery, and the sour floor is real
	var dev := DevotionSystem.new(reg)
	dev.attune(P, "god-halor")
	dev.state[P]["god-halor"].vigor = 10.0
	dev.rite_day(P, "god-halor", "chapel", 1, 1.0)
	var plain: float = dev.state[P]["god-halor"].vigor
	dev.state[P]["god-halor"].vigor = 10.0
	dev.rite_day(P, "god-halor", "chapel", 1, 2.0)
	check(dev.state[P]["god-halor"].vigor > plain, "a splendid altar bears the rite up")
	dev.state[P]["god-halor"].vigor = 10.0
	dev.rite_day(P, "god-halor", "chapel", 1, 0.5)
	check(dev.state[P]["god-halor"].vigor < plain, "an offended altar sours the rite (floor 0.5)")

## Godhead (VILLAGER-AND-GODHEAD-SPEC Part II): the world-level god body,
## separate from devotion_system's per-player Vigor. The cap is the world's
## gift (biome keystones); feeding/draining moves a god within it; 0 gutters
## (no magic, for everyone) until fed back — unless consumed(), the one
## irreversible act. §5 the Waker: every player death feeds Ur-Noth, decaying
## per repeat within a window, per-player, washed to zero if he's your own.
func _test_godhead() -> void:
	var reg := Registry.new()
	reg.load_all()
	check(reg.tuning.has("godhead"), "godhead tuning loaded")
	var gh := GodheadSystem.new(reg)

	# every non-missing god starts AT the cap (10%); the empty seat is untracked
	check(gh.state.size() == 6, "six non-missing gods tracked (the empty seat excluded)")
	check(not gh.state.has("god-all-tide"), "the All-Tide is untracked — missing, not a body to feed")
	check(gh.godhead("god-halor") == 10.0, "campaign start: every god flickers at the base 10%")

	# the cap: biomes are the ceiling (§1 exact table)
	check(gh.cap() == 10.0, "0 biomes cleared -> cap 10%")
	gh.set_biomes_cleared(1)
	check(gh.cap() == 40.0, "1 biome (Salt Shallows) -> cap 40% — the current test world's ceiling")
	gh.set_biomes_cleared(2)
	check(gh.cap() == 70.0, "2 biomes (Reef Forest) -> cap 70%")
	gh.set_biomes_cleared(3)
	check(gh.cap() == 100.0, "3 biomes (the Drop) -> cap 100%, full godhead is endgame material")
	check(gh.godhead("god-maren") == 10.0, "raising the cap never moves a god's current value")
	gh.set_biomes_cleared(1)   # back to the test world's ceiling (40%) for everything below

	# enshrine_remnant: the mirror of consumed() — the spec's §3 "restore a
	# fallen shrine" analog used for a remnant's one-time feed (+2%, per
	# godhead.json's own $comment), clamped like any other feed.
	var enshrine_delta := gh.enshrine_remnant("god-halor")
	check(absf(enshrine_delta - 2.0) < 0.001 and gh.godhead("god-halor") == 12.0,
		"enshrine_remnant feeds +2%% one-time (now %.1f%%)" % gh.godhead("god-halor"))

	# feed clamps at cap
	gh.feed("god-maren", "rite", 50.0)
	check(gh.godhead("god-maren") == 40.0, "feed clamps at the cap, however large the source")

	# drain floors at 0, with the gutter signal
	var guttered: Array[bool] = [false]
	gh.god_guttered.connect(func(_g: String) -> void: guttered[0] = true)
	gh.drain("god-maren", "grim_rite", 1000.0)
	check(gh.godhead("god-maren") == 0.0 and guttered[0], "drain floors at 0 and fires god_guttered")
	check(gh.is_guttered("god-maren") and gh.effective_mult("god-maren") == 0.0, "a guttered god grants NO magic")

	# rekindle signal on recovery
	var rekindled: Array[bool] = [false]
	gh.god_rekindled.connect(func(_g: String) -> void: rekindled[0] = true)
	gh.feed("god-maren", "rite", 5.0)
	check(rekindled[0] and gh.godhead("god-maren") == 5.0, "feeding a guttered god fires god_rekindled")

	# consumed: the one irreversible act — locks at 0, no feed can revive
	gh.feed("god-maren", "rite", 20.0)
	check(gh.godhead("god-maren") > 0.0, "fed back up before consuming (proves consume isn't a no-op)")
	gh.consumed("god-maren")
	check(gh.is_consumed("god-maren") and gh.godhead("god-maren") == 0.0, "consumed locks the god at 0")
	gh.feed("god-maren", "rite", 20.0)
	check(gh.godhead("god-maren") == 0.0, "consumed locks FOREVER — feed does nothing after")
	check(gh.effective_mult("god-maren") == 0.0, "a consumed god still grants no magic")

	# §5 the Waker: first death, decay per repeat, floor, window reset
	var P := 1
	var r1: Dictionary = gh.player_death(P, 1, false)
	check(absf(float(r1.fed) - 0.4) < 0.001 and not r1.washed and r1.lifetime == 1 and r1.whisper_pool == "early",
		"first death feeds 0.4%, unwashed, lifetime 1, early pool")
	check(absf(gh.godhead("god-ur-noth") - 10.4) < 0.001, "Ur-Noth actually gained the feed")
	var r2: Dictionary = gh.player_death(P, 2, false)
	check(absf(float(r2.fed) - 0.24) < 0.001, "second death in-window feeds x0.6 -> 0.24%")
	var r3: Dictionary = gh.player_death(P, 3, false)
	check(absf(float(r3.fed) - 0.144) < 0.001, "third death in-window feeds x0.6 again -> 0.144%")
	var last_fed := 1.0
	for i in 8:
		last_fed = float(gh.player_death(P, 3, false).fed)
	check(absf(last_fed - 0.05) < 0.0001, "repeated same-day deaths floor at 0.05%")
	var r_reset: Dictionary = gh.player_death(P, 3 + 4, false)   # 4 days later: 3 deathless days passed -> reset
	check(absf(float(r_reset.fed) - 0.4) < 0.001, "3 deathless days resets the window — full feed again")

	# the wash: attuned to Ur-Noth costs him exactly what it feeds him
	var P2 := 2
	var before_urnoth := gh.godhead("god-ur-noth")
	var rw: Dictionary = gh.player_death(P2, 10, true)
	check(bool(rw.washed) and absf(float(rw.fed)) < 0.0001, "an Ur-Noth-attuned death washes — fed reads 0")
	check(absf(gh.godhead("god-ur-noth") - before_urnoth) < 0.0001, "the wash truly nets +-0% to his Godhead")
	check(int(rw.lifetime) == 1, "dying is ledger-neutral, but the death still counts")

	# whisper pool transitions: <5 early, 5-14 familiar, >=15 proprietary (tuning first guess)
	var P3 := 3
	var pools: Array[String] = []
	for i in 20:
		pools.append(str(gh.player_death(P3, i * 10, false).whisper_pool))   # far apart: no decay noise
	check(pools[0] == "early" and pools[3] == "early", "deaths 1 and 4: early pool")
	check(pools[4] == "familiar" and pools[13] == "familiar", "deaths 5 and 14: familiar pool")
	check(pools[14] == "proprietary", "death 15: proprietary pool")

	# Ur-Noth guttered still gets fed — "you cannot keep him down while anyone drowns"
	gh.drain("god-ur-noth", "grim_rite", 1000.0)
	check(gh.is_guttered("god-ur-noth"), "Ur-Noth guttered by a grim-rite drain")
	gh.player_death(4, 100, false)
	check(gh.godhead("god-ur-noth") > 0.0, "a death feeds him even guttered — the dark always takes someone")

	# consumed Ur-Noth: the death still counts, but nothing reaches him anymore
	gh.consumed("god-ur-noth")
	var r_after_consume: Dictionary = gh.player_death(5, 200, false)
	check(gh.godhead("god-ur-noth") == 0.0, "consumed Ur-Noth cannot be fed even by deaths")
	check(int(r_after_consume.lifetime) == 1, "the death still counts for the ledger even though it fed no one")

	# save round-trip: godhead, consumed, and both death ledgers survive
	var dump := gh.to_save()
	var gh2 := GodheadSystem.new(reg)
	gh2.apply(dump)
	check(gh2.godhead("god-maren") == gh.godhead("god-maren") and gh2.is_consumed("god-maren"),
		"godhead value + consumed flag survive the round trip")
	check(gh2.lifetime_deaths.get(P, 0) == gh.lifetime_deaths.get(P, 0), "lifetime death ledger survives")
	check(int(gh2.death_window.get(P, {}).get("streak", -1)) == int(gh.death_window.get(P, {}).get("streak", -1)),
		"the Waker's per-player decay window survives")
	check(gh2.biomes_cleared() == gh.biomes_cleared(), "biomes_cleared survives")

	# save_system wiring: additive, old-save-compatible
	var clock := SimClock.new()
	var dev := DevotionSystem.new(reg)
	var vil := VillageSystem.new(reg)
	var works := WorksSystem.new(reg, dev)
	var ver := VerdictSystem.new(reg)
	var gsave := SaveSystem.to_save(clock, dev, vil, works, ver, gh)
	check(gsave.has("godhead"), "SaveSystem.to_save includes godhead when given a GodheadSystem")
	var gh3 := GodheadSystem.new(reg)
	SaveSystem.apply(gsave, SimClock.new(), DevotionSystem.new(reg), VillageSystem.new(reg), WorksSystem.new(reg, DevotionSystem.new(reg)), VerdictSystem.new(reg), gh3)
	check(gh3.godhead("god-maren") == gh.godhead("god-maren"), "SaveSystem.apply restores godhead through the wiring")
	var old_save: Dictionary = gsave.duplicate(true)
	old_save.erase("godhead")
	var gh4 := GodheadSystem.new(reg)
	SaveSystem.apply(old_save, SimClock.new(), DevotionSystem.new(reg), VillageSystem.new(reg), WorksSystem.new(reg, DevotionSystem.new(reg)), VerdictSystem.new(reg), gh4)
	check(gh4.godhead("god-halor") == 10.0, "a save with no godhead key at all (pre-Part-II) loads clean — defaults hold")

	# economy sanity: the floor+decay curve suppresses same-day farming, though
	# NOTE for Jeff — the spec's own comparison ("a day of suicide-diving feeds
	# less than one grim rite") does not hold at N=10 with these exact numbers:
	# floorPct (0.05%) sits close enough under feedPct (0.4%) that repeats past
	# ~5 add nearly linearly. 10 same-day deaths total ~1.17%, over BOTH one
	# grim rite (0.5%) and the spec's own 1.0% fallback bound. Flagging as a
	# tuning tension rather than asserting a false bound; the true, weaker
	# guarantee (the floor keeps it well under naive undecayed 10x0.4=4.0%)
	# is what's asserted below.
	var gh5 := GodheadSystem.new(reg)
	gh5.set_biomes_cleared(1)
	var total_fed := 0.0
	for i in 10:
		total_fed += float(gh5.player_death(99, 1, false).fed)
	var undecayed := 10.0 * float(reg.tuning.godhead.get("waker", {}).get("feedPct", 0.4))
	check(total_fed < undecayed * 0.35, "decay+floor meaningfully suppresses same-day farming (%.3f%% vs %.3f%% undecayed)" % [total_fed, undecayed])

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
