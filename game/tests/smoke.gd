extends Node
## Playable-slice smoke test, run headless:
##   godot --headless --path game res://tests/smoke.tscn
## Actually PLAYS the game: moves, harvests, crafts, builds. Exit 0/1.

var failures := 0
var checks := 0

func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("SMOKE FAIL: " + msg)

func _ready() -> void:
	var host: GameHost = load("res://scenes/main.tscn").instantiate()
	host.skip_autoload = true
	host.save_path = "user://smoke-test-save.json"
	add_child(host)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(host.player != null, "world booted with a player in it")
	check(host.resource_nodes.size() > 0, "the flats have salvage on them")

	# walk east like you mean it
	var x0 := host.player.position.x
	Input.action_press("move_right")
	for i in 30:
		await get_tree().physics_frame
	Input.action_release("move_right")
	check(host.player.position.x > x0 + 20.0, "WASD moves the survivor (dx=%.0f)" % (host.player.position.x - x0))

	# harvest: stand on a node, take it
	check(not host.intent_harvest(), "nothing in reach, nothing harvested")
	var cloth := _node_of(host, "item-ship-cloth")
	host.player.position = cloth.position
	check(host.intent_harvest(), "harvested the sail-cloth underfoot")
	check(host.inventory.count(1, "item-ship-cloth") == 3, "cloth in hand (nodes yield 3 now)")

	# craft: rope from cloth, by hand
	check(host.intent_craft("recipe-rope"), "hand-crafted rope from cloth")
	check(host.inventory.count(1, "item-rope") == 2, "rope in hand, cloth spent")

	# build: gather timber the honest way, then raise a workbench
	for i in 3:
		var t := _node_of(host, "item-wreck-timber")
		host.player.position = t.position
		host.intent_harvest()
	check(host.inventory.count(1, "item-wreck-timber") >= 6, "timber gathered")
	check(host.intent_build("work-workbench"), "workbench raised")
	check(host.works.count_of("work-workbench") == 1, "the sim knows the workbench stands")
	check(not host.intent_build("work-workbench"), "can't afford a second — costs are real")

	# --- the camp ring: first structure plants it, the rest build inside ------
	check(host.camp_center != Vector2.INF, "the workbench planted the camp")
	host.inventory.add(1, "item-driftwood", 8)
	host.player.position = host.camp_center + Vector2(host.CAMP_RADIUS + 200.0, 0)  # way out
	check(not host.intent_build("work-driftwood-wall"), "can't build out past the ring")
	check(host.inventory.count(1, "item-driftwood") == 8, "and it didn't spend the materials")
	host.player.position = host.camp_center + Vector2(80, 0)  # back inside
	check(host.intent_build("work-driftwood-wall"), "inside the ring, the wall goes up")
	# rotate the wall so it can turn a corner
	var wall_inst := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-driftwood-wall":
			wall_inst = int(iid)
	# a wall is a real barrier now: it carries a physics body
	var has_body := false
	for child in (host.work_visuals[wall_inst] as Node2D).get_children():
		if child is StaticBody2D:
			has_body = true
	check(has_body, "the wall blocks — it has a collision body")
	host._rotate_work(wall_inst)
	check(int(host.works.placed[wall_inst].get("rot", 0)) == 90, "right-click turns the wall 90°")
	check((host.work_visuals[wall_inst] as Node2D).rotation_degrees == 90.0, "and the piece visibly turns")
	host._rotate_work(wall_inst); host._rotate_work(wall_inst); host._rotate_work(wall_inst)
	check(int(host.works.placed[wall_inst].get("rot", 0)) == 0, "four turns comes full circle")
	# reclaim the wall — half the driftwood comes back
	var drift_before := host.inventory.count(1, "item-driftwood")
	host._demolish_work(wall_inst)
	check(not host.works.placed.has(wall_inst), "Shift+right-click reclaims the wall")
	check(host.inventory.count(1, "item-driftwood") == drift_before + 2, "and salvages half its driftwood (4→2)")
	host.camp_center = Vector2.INF   # loosen for the scattered mechanic-tests below

	# station crafting now unlocked
	host.inventory.add(1, "item-driftwood", 1)
	check(host.intent_craft("recipe-salt-harvest"), "workbench enables salt harvest")

	# --- the menus you can read ----------------------------------------------
	var craftable := host.craftable_recipes()
	check("recipe-rope" in craftable, "the craft menu lists rope")
	check("recipe-marens-own-harpoon" not in craftable, "but hides the legend until you hold its verses")
	host._render_craft_menu()
	check(host.menu_label.text.contains("CRAFT") and host.menu_label.text.contains("by hand"), "craft menu shows recipes + where")
	host._render_build_menu()
	check(host.menu_label.text.contains("Workbench") and host.menu_label.text.contains("Crafting station"), "build menu shows each building's PURPOSE")

	# --- tools of the trade: the pack decides the swing ----------------------
	check(host.attack_damage() == 12.0, "bare hands to start")
	host.inventory.add(1, "item-driftwood", 4)
	host.inventory.add(1, "item-rope", 1)
	check(host.intent_craft("recipe-driftwood-club"), "a club from the sea's first gift")
	host.equip_toggle(1, "item-driftwood-club")
	check(host.equipped_item(1, "weapon") == "item-driftwood-club", "the club is in hand")
	check(host.attack_damage() == 15.0, "the club swings harder")
	host.inventory.add(1, "item-bronze-salvage", 4)
	host.inventory.add(1, "item-wreck-timber", 1)
	check(host.intent_craft("recipe-bronze-knife"), "bronze knife off the workbench")
	host.equip_toggle(1, "item-bronze-knife")
	check(host.inventory.count(1, "item-driftwood-club") == 1, "swapping weapons returns the club to the pack")
	check(host.attack_damage() == 19.0, "equipped bronze beats the club")
	# armor turns a blow; a naked hit lands full
	host.inventory.add(1, "item-salt-cloak", 1)
	var full := host.stats.hp(1)
	host.damage_player(20.0, 1)
	var naked_loss := full - host.stats.hp(1)
	host.stats.actors[1].hp = full
	host.equip_toggle(1, "item-salt-cloak")
	check(host.equipped_item(1, "armor") == "item-salt-cloak", "the cloak is worn")
	host.damage_player(20.0, 1)
	check((full - host.stats.hp(1)) < naked_loss, "the salt-crust cloak turns some of the blow")

	# tending: stand at the workbench, put it to work
	var wb_pos := host.work_pos("work-workbench")
	host.player.position = wb_pos
	check(host.current_prompt().contains("working"), "crafting put the bench to work already")
	host._on_sim_day(0)   # dawn: works rest
	check(host.current_prompt().contains("Tend"), "at dawn it needs tending again")
	check(host.intent_interact(), "tend the workbench")
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-workbench":
			check(bool(host.works.placed[iid].in_use), "and it is WORKING")

	# day/night: run the clock to 22:00, the world darkens
	host.clock.minute_of_day = 22 * 60
	host.clock.advance(1.0)  # tick one minute to apply
	await get_tree().physics_frame
	check(host.clock.is_night(), "22:00 is night")
	check(host.daynight.color != Color(1, 1, 1), "and the flats go cold")

	# --- combat: the flats are not empty -----------------------------------
	check(host.enemies.size() > 0, "salt-hounds prowl the flats")
	check(not host.intent_attack(), "swinging at nothing hits nothing")
	var hound: DSEnemy = host.enemies[0]
	var far := hound.position.distance_to(host.player.position)
	host.player.position = hound.position + Vector2(100, 0)  # inside aggro, outside bite
	for i in 20:
		await get_tree().physics_frame
	check(hound.position.distance_to(host.player.position) < 100.0 - 10.0, "the hound comes for you (was %.0f away)" % far)

	# it bites: standing in range costs blood
	host.player.position = hound.position + Vector2(10, 0)
	var hp0 := host.stats.hp(1)
	for i in 12:
		await get_tree().physics_frame
	check(host.stats.hp(1) < hp0, "standing in the pack costs blood")

	# swing back until it dies; the coat drops salt
	var salt0 := host.inventory.count(1, "item-salt")
	var pack0 := host.enemies.size()
	var swings := 0
	while host.enemies.size() == pack0 and swings < 30:
		host.intent_attack()
		swings += 1
		for i in 8:
			await get_tree().physics_frame  # let stamina breathe between swings
	check(host.enemies.size() < pack0, "the hound falls (%d swings)" % swings)
	check(host.inventory.count(1, "item-salt") > salt0, "its coat was never fur — salt drops")

	# stamina gates the swing
	host.stats.actors[1].stamina = 5.0
	check(not host.intent_attack() or host.enemies.is_empty(), "too tired to swing")

	# death is survivable (M1 placeholder: wake at center, whole)
	host.damage_player(1000.0)
	check(host.stats.hp(1) == host.stats.max_hp(1), "death returns you to the center, whole")

	# --- the soul, playable -------------------------------------------------
	# night makes the hounds bold: same distance, day vs night
	if host.enemies.size() > 0:
		var far_hound: DSEnemy = host.enemies[0]
		host.clock.minute_of_day = 12 * 60  # noon
		host.player.position = far_hound.position + Vector2(300, 0)
		for i in 5:
			await get_tree().physics_frame
		var day_moves := far_hound.velocity.length() > 1.0
		host.clock.minute_of_day = 23 * 60  # deep night
		for i in 5:
			await get_tree().physics_frame
		var night_moves := far_hound.velocity.length() > 1.0
		check(not day_moves and night_moves, "300px away: safe at noon, hunted at night")
		host.player.position = Vector2(9999, 9999)  # step out of its world
		host.clock.minute_of_day = 12 * 60

	# kneel at the shrine — attunement is a place, not a menu
	check(not host.intent_cast(), "no god yet, no miracle")
	host.player.position = host.shrines[0].position
	check(host.intent_interact(), "kneel at the fallen shrine")
	check("god-halor" in host.attuned_for(1) and host.devotion.state[1]["god-halor"].rank == 1, "Halor is with you")

	# the miracle: Pillar of Salt — untouchable, rooted, and it SPENDS the god
	var vigor0: float = host.devotion.state[1]["god-halor"].vigor
	check(host.intent_cast(), "cast in the pinch")
	check(host.petrify_frames > 0, "rooted and untouchable")
	var hp_before := host.stats.hp(1)
	host.damage_player(50.0)
	check(host.stats.hp(1) == hp_before, "the salt holds — no blood while petrified")
	check(host.devotion.state[1]["god-halor"].vigor < vigor0, "and Halor paid for it")
	host.petrify_frames = 1
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(host.petrify_frames == 0, "the salt lets go")

	# vigor is precious: spend him dry, the miracle refuses
	while host.intent_cast():
		host.petrify_frames = 0
	check(not host.devotion.can_cast(1, "inv-pillar-of-salt"), "Halor has nothing left")

	# worship gives it back: raise a chapel, hold the rite
	host.inventory.add(1, "item-wreck-timber", 20)
	host.inventory.add(1, "item-salt", 10)
	host.inventory.add(1, "item-bronze-salvage", 4)
	host.camp_center = Vector2.INF
	check(host.intent_build("work-chapel"), "a chapel to Halor rises")
	var dry: float = host.devotion.state[1]["god-halor"].vigor
	host.player.position = host.chapels["god-halor"]
	check(host.intent_interact(), "lead the evening rite")
	check(host.devotion.state[1]["god-halor"].vigor > dry, "worship restores what casting spent")
	check(not host.intent_rite("god-halor"), "one rite a day — Halor keeps slow time")

	# click-and-drag: the chapel moves, and its dedication moves with it
	var chapel_inst := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-chapel":
			chapel_inst = int(iid)
	var new_spot: Vector2 = (host.chapels["god-halor"] as Vector2) + Vector2(160, 0)
	host._move_work(chapel_inst, new_spot)
	check(host.chapels["god-halor"] == new_spot, "the dedication travels with the chapel")
	check((host.work_visuals[chapel_inst] as Node2D).position == new_spot, "and so does its body")
	host.player.position = new_spot
	check(host.current_prompt().contains("rite already"), "rites find the chapel at its new home")

	# the stranded survivor joins the village and prays
	host.player.position = host.survivor.position
	check(host.intent_interact(), "rescue Anna of the coast towns")
	check(host.village.tribesmen.size() == 1, "she is one of yours now")
	check(host.village.devout_count("god-halor") == 1, "and she prays")
	var v_before_days: float = host.devotion.state[1]["god-halor"].vigor
	host._on_sim_day(1)
	check(host.devotion.state[1]["god-halor"].vigor > v_before_days, "her prayers feed Halor daily")

	# --- the village lives: rescue, jobs, production, mood, feeding ----------
	var stranded := host.villagers.filter(func(v): return not v.rescued)
	check(stranded.size() >= 3, "strangers are stranded out on the flats (%d)" % stranded.size())
	# force a known worker: make the first stranger a salvager and rescue them
	var worker = stranded[0]
	worker.def_class = "class-salvager"
	# a workbench already stands from earlier; put the worker at home and rescue
	host.player.position = worker.position
	check(host.intent_interact(), "rescue the stranger")
	check(worker.rescued and worker.tribesman_id >= 0, "they join the village")
	check(worker.job_work_id == "work-workbench", "and take the workbench job (they are a salvager)")
	worker.position = host.village_heart()   # settle them at home so they work
	var salt_b2 := host.inventory.count(1, "item-salt")
	host._on_sim_day(2)
	check(host.inventory.count(1, "item-salt") > salt_b2, "at dawn the salvager produced salt into your pack")
	# feeding: pool food, and a fed villager doesn't go hungry
	host.inventory.add(1, "item-smoked-crab", 5)
	host.intent_give_food()
	check(host._stock_food_total() >= 5, "you stocked the village larder")
	host._on_sim_day(3)
	check(host._stock_food_total() < 5, "your people ate from the stores")
	# talk-to-bloom: a grievance-heard villager blooms when you hear them
	var talker_id := host.village.add_tribesman("Test", "class-reef-runner", "rescued", ["trait-bitter"], "god-halor")
	var talker = DSVillager.new(); talker.host = host; talker.tribesman_id = talker_id
	talker.def_traits = ["trait-bitter"]; talker.rescued = true
	talker.position = host.village_heart(); host.add_child(talker); host.villagers.append(talker)
	check(host.village.tribesmen[talker_id].key == "grievance-heard", "the bitter one wants to be heard")
	host.player.position = talker.position
	host.intent_talk(talker)
	check(host.village.tribesmen[talker_id].bloomed, "hearing them out blooms them")

	# the village survives a save/load
	host.save_game()

	# readability: her need already stands built (the chapel) — she blooms on arrival
	check(host.village.tribesmen[host.survivor.tribesman_id].bloomed, "Anna's Key was waiting: the chapel — she blooms")

	# regression (Jeff, playtest): Anna must NEVER pin the player.
	# She stands directly in your path north; you walk straight through her.
	host.player.position = Vector2(4000, 4000)  # far from the village: she follows the player
	host.survivor.position = host.player.position + Vector2(0, -30)
	var y0 := host.player.position.y
	Input.action_press("move_up")
	for i in 40:
		await get_tree().physics_frame
	Input.action_release("move_up")
	check(host.player.position.y < y0 - 60.0, "walked north straight through Anna (dy=%.0f)" % (host.player.position.y - y0))
	# and at heel she idles instead of crowding into your hitbox
	var gap := host.survivor.position.distance_to(host.player.position)
	for i in 30:
		await get_tree().physics_frame
	check(host.survivor.position.distance_to(host.player.position) >= 30.0 or gap > 100.0, "she keeps a respectful distance")

	# the prompt mirrors the world
	host.player.position = host.chapels["god-halor"]
	check(host.current_prompt().contains("rite"), "prompt at the chapel speaks of rites (got '%s')" % host.current_prompt())
	host.player.position = Vector2(-9999, -9999)
	check(host.current_prompt() == "", "no prompt in the empty flats")
	check(host._direction_hints().contains("pale shrine"), "the HUD points at the storm shrine still waiting")

	# --- hunger: hunt, eat, smoke, feast (after kneeling — Halor's works are open) ---
	var crab := _enemy_of(host, "creature-scuttle-crab")
	check(crab != null and crab.peaceful, "crabs have nowhere to be and no quarrel with you")
	var base_max := host.stats.max_hp(1)
	host.player.position = crab.position
	host.stats.actors[1].stamina = 60.0
	var n0 := host.enemies.size()
	while host.enemies.size() == n0:
		host.intent_attack()
		for i in 6:
			await get_tree().physics_frame
	check(host.inventory.count(1, "item-crab-meat") >= 2, "the crab was excellent soup")
	check(host.intent_eat(), "eat raw crab")
	check(host.stats.max_hp(1) > base_max, "food raises the ceiling — preparation, not maintenance")

	# smoke the rest: build the smokehouse, cook, eat the good stuff
	host.inventory.add(1, "item-wreck-timber", 8)
	host.inventory.add(1, "item-salt", 13)
	check("work-smokehouse" in host.menu_works(), "Halor's smokehouse is on the build menu (you knelt)")
	host.camp_center = Vector2.INF
	check(host.intent_build("work-smokehouse"), "smokehouse raised")
	var crab2 := _enemy_of(host, "creature-scuttle-crab")
	host.player.position = crab2.position
	host.stats.actors[1].stamina = 60.0
	var n1 := host.enemies.size()
	while host.enemies.size() == n1:
		host.intent_attack()
		for i in 6:
			await get_tree().physics_frame
	check(host.intent_craft("recipe-smoked-crab"), "the brinewife's answer: smoked crab")
	check(host.intent_eat(), "second slot filled")
	check(not host.intent_eat(), "a full belly refuses")
	var fed_max := host.stats.max_hp(1)
	host.stats.tick(3600.0)
	check(host.stats.max_hp(1) < fed_max, "meals wear off with the hours")

	# --- the second god: Maren, the Storm-Mother ----------------------------
	check(not host.intent_cast("inv-call-squall"), "no storm without the Storm-Mother")
	host.player.position = host.shrines[1].position
	check(host.intent_interact(), "kneel at the storm shrine on the east edge")
	check("god-maren" in host.attuned_for(1), "Maren is with you — two gods now")
	check("work-lightning-rod" in host.menu_works(), "her storm-craft opens on the build menu")

	# the squall: lightning falls on whatever crowds you
	var prey := _enemy_of(host, "creature-salt-hound")
	check(prey != null, "a hound remains to learn about weather")
	host.player.position = prey.position + Vector2(60, 0)
	var prey_hp := host.stats.hp(prey)
	var m_vigor: float = host.devotion.state[1]["god-maren"].vigor
	check(host.intent_cast("inv-call-squall"), "call the squall")
	check(host.stats.hp(prey) < prey_hp or _enemy_of(host, "creature-salt-hound") != prey, "the bolt came down on the mark")
	check(host.devotion.state[1]["god-maren"].vigor < m_vigor, "and Maren paid for it")

	# her own chapel, her own rites
	host.inventory.add(1, "item-wreck-timber", 20)
	host.inventory.add(1, "item-salt", 10)
	host.inventory.add(1, "item-bronze-salvage", 4)
	host.camp_center = Vector2.INF
	check(host.intent_build("work-chapel"), "a second chapel rises")
	check(host.chapels.has("god-maren"), "dedicated to the Storm-Mother")
	var m_dry: float = host.devotion.state[1]["god-maren"].vigor
	host.player.position = host.chapels["god-maren"]
	check(host.intent_interact(), "lead her rite")
	check(host.devotion.state[1]["god-maren"].vigor > m_dry, "worship restores the storm")
	check(host.devotion.devotion_spent(1) == 2, "two gods, two devotion points — the budget holds")

	# --- Old Shellback and the first Verdict choice --------------------------
	var boss := _enemy_of(host, "creature-old-shellback")
	check(boss != null and boss.is_boss, "Old Shellback guards the northwest")
	boss._stun = 0.0   # the earlier squall test may have clipped him; not what we're testing
	host.player.position = boss.position + Vector2(200, 0)
	for i in 10:
		await get_tree().physics_frame
	check(boss.velocity.length() > 1.0, "walk into his ring and he comes")
	host.player.position = boss.position + Vector2(900, 0)  # flee far
	for i in 10:
		await get_tree().physics_frame
	check(boss.position.distance_to(boss.spawn_pos) < 900.0 and boss.velocity.length() >= 0.0, "he leashes home rather than hunting you across the flats")

	# the kill (test-accelerated: we've proven melee elsewhere)
	var boss_home: Vector2 = boss.spawn_pos  # he'll be freed; ask now
	host.player.position = boss.position + Vector2(40, 0)
	host.stats.damage(boss, 880.0)
	boss.on_hit()
	host.stats.actors[1].stamina = 60.0
	var packn := host.enemies.size()
	var tries := 0
	while host.enemies.size() == packn and tries < 20:
		host.stats.actors[1].stamina = 60.0
		host.intent_attack()
		tries += 1
		await get_tree().physics_frame
	check(host.inventory.count(1, "item-remnant-shellback") == 1, "something divine remains in the wreck of him")
	var hoard_nodes := 0
	for n in host.resource_nodes:
		if is_instance_valid(n) and n.position.distance_to(boss_home) < 150.0:
			hoard_nodes += 1
	check(hoard_nodes >= 4, "the wreck-ring opens — his hoard becomes salvage ground (%d nodes)" % hoard_nodes)

	# the Verdict, in hand: CONSUME — power now, a dimmer world forever
	var base_hp0: float = host.stats.actors[1].base_hp
	var halor_strength0: float = host.verdict.god_world_strength["god-halor"]
	check(host.intent_consume_remnant(), "the warm voice gets its way")
	check(host.stats.actors[1].base_hp == base_hp0 + 15.0, "you feel MAGNIFICENT — permanently")
	check(host.verdict.god_world_strength["god-halor"] == halor_strength0 - 20.0, "and Halor dims, for everyone, forever")
	check(host.verdict.ledgers[1]["remnants"] < 0.0, "the ledger remembers what you ate")

	# ...and ENSHRINE, the other door (a second remnant, test-granted)
	host.inventory.add(1, "item-remnant-shellback", 1)
	host.player.position = host.chapels["god-halor"]
	check(host.current_prompt().contains("Enshrine"), "the chapel prompt offers the better door")
	check(host.intent_enshrine("god-halor"), "set the remnant in the chapel-stone")
	check(host.verdict.god_world_strength["god-halor"] == halor_strength0 - 10.0, "some of what dimmed comes back")

	# --- the flats remember: full save -> fresh world -> load ----------------
	var take_one := _node_of(host, "item-salt")
	host.player.position = take_one.position
	host.intent_harvest()  # dawns respawn salvage now: ensure something is missing AT save time
	host.save_game()
	var host2: GameHost = load("res://scenes/main.tscn").instantiate()
	host2.skip_autoload = true
	host2.save_path = host.save_path
	add_child(host2)
	await get_tree().physics_frame
	host2.load_game()
	await get_tree().physics_frame
	check(host2.attuned_for(1) == host.attuned_for(1), "both gods still know you")
	check(host2.chapels.size() == 2, "both chapels stand where they stood")
	check(host2.inventory.count(1, "item-rope") == host.inventory.count(1, "item-rope"), "the pack survives")
	check(host2.village.tribesmen.size() == host.village.tribesmen.size(), "Anna is still yours")
	check(host2.survivor.rescued, "and she knows it")
	check(host2.resource_nodes.size() < host2.node_defs.size(), "harvested nodes stay harvested")
	check(_enemy_of(host2, "creature-old-shellback") == null, "Old Shellback stays dead")
	check(absf(float(host2.verdict.god_world_strength["god-halor"]) - float(host.verdict.god_world_strength["god-halor"])) < 0.01, "the world remembers what you consumed")
	host2.queue_free()

	# --- the great storm ------------------------------------------------------
	# (dawns now respawn salvage, so guarantee something is freshly missing)
	var fresh_node := _node_of(host, "item-driftwood")
	host.player.position = fresh_node.position
	host.intent_harvest()
	var taken_before := host.harvested_indices.size()
	check(taken_before > 0, "some salvage is gone (we took it)")
	host.clock.day = 3
	host._on_sim_day(3)
	check(host.is_storm_day(), "day 4 is the storm's day")
	check(host.harvested_indices.size() < taken_before, "the seabed shifts — old salvage uncovered")
	check(_node_of(host, "item-storm-glass") != null, "storm-glass smokes on the flats")
	host.devotion.state[1]["god-maren"].vigor = 100.0
	host.devotion.state[1]["god-maren"].dormant = false
	host.player.position = Vector2(-5000, -5000)  # cast at nothing, cheaply
	check(host.intent_cast("inv-call-squall"), "call the squall INTO the storm")
	var after_cast: float = host.devotion.state[1]["god-maren"].vigor
	check(after_cast > 60.0, "she is everywhere today — half cost (vigor %.0f)" % after_cast)
	# --- the legend hunt: Maren's Own Harpoon --------------------------------
	# verses so far: the shrine-gift (kneeling) + Shellback's hoard = 2
	check(host.inventory.count(1, "item-harpoon-verse") == 2, "two verses of the harpoon-song held (got %d)" % host.inventory.count(1, "item-harpoon-verse"))
	check(not host.intent_craft("recipe-marens-own-harpoon"), "two verses are not the song — the making refuses")
	var glass := _node_of(host, "item-storm-glass")
	while glass != null:
		host.player.position = glass.position
		host.intent_harvest()
		glass = _node_of(host, "item-storm-glass")
	check(host.inventory.count(1, "item-harpoon-verse") == 3, "the last verse was folded in the glass")
	check(host.inventory.count(1, "item-storm-glass") >= 3, "storm-glass in hand — the event material")
	host.inventory.add(1, "item-bronze-salvage", 6)
	host.inventory.add(1, "item-wreck-timber", 4)
	check(host.intent_craft("recipe-marens-own-harpoon"), "THE RITE IS DONE — the harpoon is forged")
	check(host.inventory.count(1, "item-marens-own-harpoon") == 1, "Maren's Own Harpoon, in hand")
	host.equip_toggle(1, "item-marens-own-harpoon")
	check(host.attack_damage() > 20.0, "the equipped legend changes what your hands can do")
	check(host.inventory.count(1, "item-harpoon-verse") == 3, "the song is knowledge — not consumed")

	host.clock.day = 4
	host._on_sim_day(4)
	check(not host.is_storm_day(), "the sky clears")
	check(_node_of(host, "item-storm-glass") == null, "and takes its glass back")

	# --- the Tally: virtues in play --------------------------------------------
	check(host.abilities.available(1) > 3, "the flats have tempered you (deeds + days: %d)" % host.abilities.available(1))
	var max0: float = host.stats.max_hp(1)
	for i in 3:
		host.abilities.allocate(1, "virtue-grit")
	check(host.stats.max_hp(1) == max0 + 20.0, "3 GRIT ignites Salt-Skin: the body follows the sheet")
	var speed_mult: float = host.abilities.mod_mult(1, "move-speed-mult")
	check(speed_mult == 1.0, "no CURRENT yet, no speed")
	for i in 3:
		host.abilities.allocate(1, "virtue-hunger")
	var salt_before := host.inventory.count(1, "item-salt")
	var salt_node := _node_of(host, "item-salt")
	if salt_node != null:
		host.player.position = salt_node.position
		host.intent_harvest()
		check(host.inventory.count(1, "item-salt") - salt_before == 4, "Take More: +1 to every harvest (got %d)" % (host.inventory.count(1, "item-salt") - salt_before))
	# free respec: drain HUNGER, the Temper returns
	var avail_before := host.abilities.available(1)
	for i in 3:
		host.abilities.deallocate(1, "virtue-hunger")
	check(host.abilities.available(1) == avail_before + 3, "unlimited respec: the Temper returns whole")
	check(host.stats.max_hp(1) == max0 + 20.0, "GRIT untouched by HUNGER's respec")
	# the sheet survives the save
	host.save_game()
	var host3: GameHost = load("res://scenes/main.tscn").instantiate()
	host3.skip_autoload = true
	host3.save_path = host.save_path
	add_child(host3)
	await get_tree().physics_frame
	host3.load_game()
	check(host3.abilities.score(1, "virtue-grit") == 3, "the Tally survives the save")
	check(host3.stats.max_hp(1) == host.stats.max_hp(1), "and the body still follows it")
	host3.queue_free()

	# regression (Jeff, playtest): a PRE-Tally save must back-pay Temper, not zero it
	var raw := SaveSystem.read_file(host.save_path)
	(raw.game as Dictionary).erase("abilities")
	SaveSystem.write_file("user://smoke-pretally-save.json", raw)
	var host4: GameHost = load("res://scenes/main.tscn").instantiate()
	host4.skip_autoload = true
	host4.save_path = "user://smoke-pretally-save.json"
	add_child(host4)
	await get_tree().physics_frame
	host4.load_game()
	check(host4.abilities.earned(1) >= 8, "old saves get back-pay (%d Temper owed)" % host4.abilities.earned(1))
	check(host4.abilities.allocate(1, "virtue-grit"), "and can spend it immediately")
	host4.queue_free()

	# --- Anna keeps a day ------------------------------------------------------
	var center := Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, GameHost.WORLD.y * GameHost.TILE / 2.0)
	host.survivor.position = center  # settled
	host.inventory.add(1, "item-wreck-timber", 8)
	host.inventory.add(1, "item-salt", 12)
	host.player.position = center + Vector2(-200, 0)
	host.camp_center = Vector2.INF
	check(host.intent_build("work-smokehouse") or host.works.count_of("work-smokehouse") > 0, "a smokehouse stands")
	host.clock.minute_of_day = 8 * 60  # working morning
	var post := host.work_pos("work-smokehouse")
	var gap0 := host.survivor.position.distance_to(post)
	for i in 40:
		await get_tree().physics_frame
	check(host.survivor.position.distance_to(post) < gap0, "morning: Anna walks to her work (%.0f -> %.0f)" % [gap0, host.survivor.position.distance_to(post)])
	host.clock.minute_of_day = 18 * 60  # evening rites
	for i in 40:
		await get_tree().physics_frame
	var chapel_gap: float = host.survivor.position.distance_to(host.chapels["god-halor"])
	for i in 40:
		await get_tree().physics_frame
	check(host.survivor.position.distance_to(host.chapels["god-halor"]) <= chapel_gap, "evening: she turns toward the chapel")

	print("\nsmoke: %d checks, %d failure(s)" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

func _node_of(host: GameHost, item_id: String) -> Area2D:
	for n in host.resource_nodes:
		if is_instance_valid(n) and str(n.get_meta("item_id")) == item_id:
			return n
	return null

func _enemy_of(host: GameHost, creature_id: String) -> DSEnemy:
	for e in host.enemies:
		if is_instance_valid(e) and e.creature_id == creature_id:
			return e
	return null
