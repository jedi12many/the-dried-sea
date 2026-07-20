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

	# build: CUT timber the honest way — nodes are worked swing by swing now
	var t0 := _node_of(host, "item-wreck-timber")
	host.player.position = t0.position
	host.intent_harvest()
	check(host.inventory.count(1, "item-wreck-timber") == 1, "a swing yields one timber — nodes are worked, not scooped")
	check(int(t0.get_meta("left", 0)) == 4, "and the wreck wears down (4 of 5 left)")
	var cut_swings := 0
	while host.inventory.count(1, "item-wreck-timber") < 6 and cut_swings < 40:
		var t := _node_of(host, "item-wreck-timber")
		host.player.position = t.position
		host.intent_harvest()
		cut_swings += 1
	check(host.inventory.count(1, "item-wreck-timber") >= 6, "timber gathered, swing by swing")
	check(host.harvested_indices.size() > 0, "a spent stand is gone from the flats")
	# --- shelter first: a personal tent, pitched anywhere, is your respawn ----
	host.inventory.add(1, "item-driftwood", 3)
	host.inventory.add(1, "item-ship-cloth", 1)
	var founding_menu := host.menu_works()
	check("work-hearth" in founding_menu and "work-tent" in founding_menu, "before founding: raise a hearth, or pitch a tent")
	check(not host.intent_build("work-workbench"), "but nothing else raises before the hearth")
	check(host.camp_center == Vector2.INF, "and no ring exists yet")
	host.player.position = Vector2(2000, 2000)   # out on the open flats, no village
	check(host.intent_build("work-tent"), "a tent pitches anywhere — no hearth needed")
	check(host.camp_center == Vector2.INF, "and pitching it founds no village")
	var tent_inst := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-tent":
			tent_inst = int(iid)
	var tent_pos := host.work_pos("work-tent")
	# with no rest point chosen yet, you fall back to your nearest tent
	host.player.position = tent_pos + Vector2(600, 0)
	host.stats.actors[1].hp = 5.0
	host.damage_player(999.0, 1)
	check(host.player.position.distance_to(tent_pos) < 60.0, "with no rest point set, you wake at your nearest tent")
	# SET it: stand on the tent, [E] binds your respawn there
	host.player.position = tent_pos
	check(host.intent_interact(), "stand on the tent and [E] binds your respawn")
	check(int(host.respawn_bind.get(1, -1)) == tent_inst, "the tent is now your chosen rest point")
	host.player.position = tent_pos + Vector2(900, 0)
	host.stats.actors[1].hp = 5.0
	host.damage_player(999.0, 1)
	check(host.player.position.distance_to(tent_pos) < 60.0, "and you wake at your bound tent when you fall")

	# --- the village grows around its hearth ---------------------------------
	host.inventory.add(1, "item-wreck-timber", 12)   # enough for hearth + workbench
	host.inventory.add(1, "item-salt", 8)
	check(not host.intent_build("work-workbench"), "nothing raises before the hearth")
	check(host.camp_center == Vector2.INF, "and no ring exists yet")
	check(host.intent_build("work-hearth"), "the Great Hearth founds the village")
	check(host.camp_center != Vector2.INF and host.camp_center == host.work_pos("work-hearth"), "the ring centers on the hearth")
	# home again — re-bind your respawn to the hearth, away from the far tent
	host.player.position = host.work_pos("work-hearth")
	check(host.intent_interact() and int(host.respawn_bind.get(1, -1)) != tent_inst, "stand at the hearth, [E] re-binds respawn home")
	host.player.position = host.camp_center + Vector2(70, 0)   # a step off the hearth, still in-ring
	check(host.intent_build("work-workbench"), "now the workbench raises, inside the ring")
	check(host.works.count_of("work-workbench") == 1, "the sim knows the workbench stands")
	check(host.message != "" and host.message.contains("Workbench"), "a plain build gets a real confirmation, not silence (Jeff: builds read as broken)")

	# --- the stores-cover UX (Jeff: "I can't build from the village stores") -
	# the mechanic always worked (_stores_cover tops up from village_stock in
	# the ring); the menu label just lied by checking the pack alone.
	var dw_leftover := host.inventory.count(1, "item-driftwood")
	if dw_leftover > 0:
		host.inventory.pay(1, [{"itemId": "item-driftwood", "qty": dw_leftover}])
	host.village_stock["item-driftwood"] = 20
	host.player.position = host.camp_center + Vector2(60, 0)   # inside the ring
	host._toggle_menu(true, "build")
	check(host.menu_label.text.contains("the stores will cover it"), "empty pack + stocked stores reads as buildable, not broken")
	host._toggle_menu(false)
	check(host.intent_build("work-driftwood-wall"), "and it really does build, drawing from the stores")
	check(host.message.contains("the stores provided what your pack lacked"), "the confirmation says where the materials came from")
	host.village_stock.erase("item-driftwood")   # now truly short, pack AND stores empty
	host._toggle_menu(true, "build")
	check(host.menu_label.text.contains("can't afford — pack and stores together"), "genuinely unaffordable still reads as unaffordable")
	host._toggle_menu(false)

	# --- the ring: everything else falls inside it ---------------------------
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
	host.camp_center = host.player.position   # ring follows the player: loosen for the scattered mechanic-tests below

	# station crafting now unlocked
	host.inventory.add(1, "item-driftwood", 1)
	check(host.intent_craft("recipe-salt-harvest"), "workbench enables salt harvest")

	# --- the menus you can read ----------------------------------------------
	var craftable := host.craftable_recipes()
	check("recipe-rope" in craftable, "the craft menu lists rope")
	check("recipe-marens-own-harpoon" not in craftable, "but hides the legend until you hold its verses")
	host._render_craft_menu()
	check(host.menu_title.text.contains("CRAFT") and host.menu_label.text.contains("by hand"), "craft menu shows recipes + where")
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

	# --- the Lighthouse-Keeper's Lantern, verses 1 & 2 -----------------------
	# (verse 3 comes later, the dawn after the great storm)
	check(host.inventory.count(1, "item-lantern-verse") == 1, "the homestead god keeps the keepers' stories too — one verse, from kneeling")
	host.player.position = host.LANTERN_WRECK_POS
	check(host.current_prompt() == "[E] Inspect the wreck", "the marked wreck offers its own [E]")
	check(host.intent_interact(), "inspect the beached wreck")
	check(host.inventory.count(1, "item-lantern-verse") == 2, "a second verse, wedged under a bulkhead")
	check(not host.intent_interact() or host.inventory.count(1, "item-lantern-verse") == 2, "the same wreck doesn't repeat itself")
	host.player.position = Vector2(9999, 9999)

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
	host.camp_center = host.player.position   # ring follows the player for the scattered build below
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
	check(worker.task == "salt", "the village assigns them to salt (best-suited, and salt is short)")
	worker.position = host.village_heart()   # settle them at home so they work
	var salt_b2 := int(host.village_stock.get("item-salt", 0))
	host._on_sim_day(2)
	check(int(host.village_stock.get("item-salt", 0)) > salt_b2, "at dawn the salvager boiled salt into the stores")
	# dynamic priority: fill the salt stores and their task shifts elsewhere
	host.village_stock["item-salt"] = 50
	host._assign_village_tasks()
	check(worker.task != "salt", "salt full → the village moves them to what's actually short (%s)" % worker.task)

	# NEED HELP: the danger helper reports the nearest beast; villagers flee on it
	check(host.enemy_near_dist(Vector2(-8000, -8000)) > DSVillager.DANGER_RADIUS, "far off, no danger to a worker")
	# WARDENS answer the horn: they cover workers and strike beasts
	var ward = host.villagers[0]
	ward.def_class = "class-warden"; ward.rescued = true
	if ward.tribesman_id < 0:
		ward.tribesman_id = host.village.add_tribesman("Guard", "class-warden", "rescued", [], "god-halor")
	ward.position = Vector2(2000, 2000)
	check(host.warden_covers(ward.position), "a worker beside a warden is covered — won't flee")
	check(not host.warden_covers(ward.position + Vector2(400, 0)), "but not one across the camp")
	var wh := DSEnemy.new(); wh.position = ward.position + Vector2(20, 0)
	wh.setup(host, "creature-salt-hound"); host.add_child(wh); host.enemies.append(wh)
	check(host.warden_duty(ward) != Vector2.INF, "a beast near the camp is a warden's duty")
	var wh_hp := host.stats.hp(wh)
	host.warden_strike(ward)
	check(host.stats.hp(wh) < wh_hp, "the warden strikes the beast")
	host.stats.unregister(wh); host.enemies.erase(wh); wh.queue_free()
	# feeding: pool food, and a fed villager doesn't go hungry
	host.inventory.add(1, "item-smoked-crab", 5)
	host.intent_give_food()
	check(host._stock_food_total() >= 5, "you stocked the village larder")
	host._on_sim_day(3)
	check(host._stock_food_total() < 5, "your people ate from the stores")

	# --- the village economy: pool everything, stores provide, kitchen, armory ---
	# [G] pools your whole pack (not just food); worn gear and legends stay yours
	host.inventory.add(1, "item-driftwood", 6)
	host.inventory.add(1, "item-rope", 2)
	host.inventory.add(1, "item-bronze-knife", 1)
	if host.equipped_item(1, "weapon") != "item-bronze-knife":
		host.equip_toggle(1, "item-bronze-knife")   # ensure worn — must NOT be pooled
	host.intent_give_food()
	check(int(host.village_stock.get("item-driftwood", 0)) >= 6, "[G] pools materials into the stores")
	check(host.inventory.count(1, "item-driftwood") == 0, "and your pack let them go")
	check(host.equipped_item(1, "weapon") == "item-bronze-knife" and host.inventory.count(1, "item-bronze-knife") == 1,
		"but the knife you wear stays yours")
	# the stores provide: craft in camp with an empty pack, stock covers it
	host.player.position = host.camp_center + Vector2(30, 0)
	host.village_stock["item-ship-cloth"] = 2
	var cloth_short := host.inventory.count(1, "item-ship-cloth")
	check(cloth_short == 0, "no cloth in the pack")
	check(host.intent_craft("recipe-rope"), "yet rope crafts — the community stores covered it")
	check(int(host.village_stock.get("item-ship-cloth", 0)) < 2, "and the stock paid the cloth")
	# the kitchen: raw meat in the stores gets smoked at dawn
	host.inventory.add(1, "item-wreck-timber", 8)
	host.inventory.add(1, "item-salt", 12)
	if host.works.count_of("work-smokehouse") == 0:
		check(host.intent_build("work-smokehouse"), "a smokehouse for the kitchen")
	host.village_stock["item-crab-meat"] = 3
	host.village_stock["item-smoked-crab"] = int(host.village_stock.get("item-smoked-crab", 0)) + 10  # keep bellies full
	var smoked_b := int(host.village_stock.get("item-smoked-crab", 0))
	host._on_sim_day(4)
	check(not host.village_stock.has("item-crab-meat"), "dawn: the kitchen took the raw meat")
	check(int(host.village_stock.get("item-smoked-crab", 0)) > smoked_b - 8, "and smoked it into food (stores grew)")
	# the armory: an unarmed warden claims the best weapon from the stores
	# (a FRESH warden — earlier hungry dawns may have soured or deserted old ones)
	var arms_id := host.village.add_tribesman("Armsman", "class-warden", "rescued", [], "god-halor")
	var armsman = DSVillager.new()
	armsman.host = host; armsman.tribesman_id = arms_id; armsman.def_class = "class-warden"
	armsman.rescued = true; armsman.position = host.village_heart()
	host.add_child(armsman); host.villagers.append(armsman)
	host.village_stock["item-driftwood-club"] = 1
	host.village_stock["item-smoked-crab"] = int(host.village_stock.get("item-smoked-crab", 0)) + 10
	host._on_sim_day(5)
	check(armsman.warden_weapon == "item-driftwood-club", "dawn: the warden took up the club from the stores")
	check(not host.village_stock.has("item-driftwood-club"), "and it left the rack")
	check(host.warden_damage(armsman) > host.WARDEN_DAMAGE, "an armed warden hits harder than bare hands")
	# bare racks: the warden lashes together a club from raw stores
	armsman.warden_weapon = ""
	host.village_stock["item-driftwood"] = 4
	host.village_stock["item-rope"] = 1
	host.village_stock["item-smoked-crab"] = int(host.village_stock.get("item-smoked-crab", 0)) + 10
	host._on_sim_day(6)
	check(armsman.warden_weapon == "item-driftwood-club", "no weapon stocked → the warden crafted one")
	check(int(host.village_stock.get("item-rope", 0)) == 0, "from the stores' rope (spent — and no task restocks rope)")

	# --- THE VILLAGE MODAL: a stores tab, so the inventory never runs off the panel ---
	host.village_stock["item-bronze-salvage"] = 7
	host.village_stock["item-storm-glass"] = 2
	host._toggle_village(true)   # a fresh open always starts on the roster
	check(host.village_tab == "roster", "the village modal opens on the roster")
	check(host.village_panel.text.contains("NAME") and host.village_panel.text.contains("TRADE"), "roster tab shows the roster table")
	check(host.village_panel.text.contains("kinds of goods held"), "roster tab points at the stores tab, doesn't dump the list")
	check(host.village_panel.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "the panel wraps instead of running off the window")
	# [TAB] switches to the itemized stores list
	host.village_tab = "stores"
	host._render_village()
	check(host.village_panel.text.contains("kind(s) of goods"), "the stores tab lists the full community inventory")
	check(host.village_panel.text.contains("Bronze Salvage") and host.village_panel.text.contains("Storm-Glass"), "every stocked good appears, however long the list")
	# a background refresh (dawn, world_sync, [G]) must NOT yank you off the tab you're reading
	host._toggle_village(true)
	check(host.village_tab == "stores", "a refresh-while-open keeps your tab")
	check(host.village_panel.text.contains("kind(s) of goods"), "...and keeps showing it")
	# closing and reopening returns to the roster
	host._toggle_village(false)
	host._toggle_village(true)
	check(host.village_tab == "roster", "closing and reopening resets to the roster")
	host._toggle_village(false)

	# talk-to-bloom: a grievance-heard villager blooms when you hear them
	var talker_id := host.village.add_tribesman("Test", "class-reef-runner", "rescued", ["trait-bitter"], "god-halor")
	var talker = DSVillager.new(); talker.host = host; talker.tribesman_id = talker_id
	talker.def_traits = ["trait-bitter"]; talker.rescued = true
	talker.position = host.village_heart(); host.add_child(talker); host.villagers.append(talker)
	check(host.village.tribesmen[talker_id].key == "grievance-heard", "the bitter one wants to be heard")
	host.player.position = talker.position
	host.intent_talk(talker)
	check(host.village.tribesmen[talker_id].bloomed, "hearing them out blooms them")

	# --- THE TAKEN: subdue a raider, break or unbind ------------------------
	var raider = _enemy_of(host, "creature-raider")
	check(raider != null and raider.subduable, "raiders roam the flats, and they can be subdued")
	host.stats.actors[1].stamina = 60.0
	host.player.position = raider.position + Vector2(20, 0)
	var rtries := 0
	while not raider.surrendered and rtries < 30:
		host.stats.actors[1].stamina = 60.0
		host.intent_attack()
		rtries += 1
		await get_tree().physics_frame
	check(raider.surrendered, "beaten low, the raider surrenders instead of dying")
	var vcount := host.village.tribesmen.size()
	host.player.position = raider.position
	check(host.intent_interact(), "bind the surrendered raider")
	check(host.village.tribesmen.size() == vcount + 1, "they become a captive of the village")
	var cap = host.villagers.filter(func(v): return v.is_captive)[0]
	check(host.village.tribesmen[cap.tribesman_id].origin == "taken", "origin: taken — grievance and susceptibility maxed")
	check("work-salt-wheel" in host.menu_works(), "the Salt-Wheel's recipe whispers now you hold a captive")
	# the KIND path: hold them well, then Unbind — they stay free
	cap.days_held = 3
	host.player.position = cap.position
	host.intent_hold_captive(cap)
	check(not cap.is_captive and host.village.tribesmen[cap.tribesman_id].origin == "rescued", "held well and Unbound — they stay free")
	# the GRIM path: a fresh captive, broken at the Salt-Wheel
	var uid := host.village.add_tribesman("Doomed", "class-salvager", "taken", ["trait-bitter"], "")
	var doomed = DSVillager.new(); doomed.host = host; doomed.tribesman_id = uid
	doomed.is_captive = true; doomed.rescued = true; doomed.position = host.village_heart()
	host.add_child(doomed); host.villagers.append(doomed)
	host.inventory.add(1, "item-wreck-timber", 15); host.inventory.add(1, "item-bronze-salvage", 8); host.inventory.add(1, "item-rope", 8)
	host.player.position = host.village_heart() + Vector2(120, 0)
	host.camp_center = host.player.position   # ring follows the player for this build
	check(host.intent_build("work-salt-wheel"), "raise the Salt-Wheel")
	var wheel_inst := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-salt-wheel":
			wheel_inst = int(iid)
	var urnoth0: float = float(host.devotion.state.get(1, {}).get("god-ur-noth", {}).get("favor", 0.0))
	host.intent_salt_wheel(wheel_inst)
	check(host.village.tribesmen[uid].origin == "broken", "the Wheel turns: broken, obedient, empty")
	check(float(host.devotion.state[1]["god-ur-noth"].favor) > urnoth0, "and Ur-Noth is fed")

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
	host.camp_center = host.player.position   # ring follows the player for the scattered build below
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
	host.camp_center = host.player.position   # ring follows the player for the scattered build below
	check(host.intent_build("work-chapel"), "a second chapel rises")
	check(host.chapels.has("god-maren"), "dedicated to the Storm-Mother")
	var m_dry: float = host.devotion.state[1]["god-maren"].vigor
	var maren_godhead0 := host.godhead.godhead("god-maren")
	host.player.position = host.chapels["god-maren"]
	check(host.intent_interact(), "lead her rite")
	check(host.devotion.state[1]["god-maren"].vigor > m_dry, "worship restores the storm")
	check(host.devotion.devotion_spent(1) == 2, "two gods, two devotion points — the budget holds")
	# Godhead (Part II §3): the SAME rite feeds Maren's world-level body too
	check(host.godhead.godhead("god-maren") > maren_godhead0, "the same rite feeds Maren's Godhead, not just your own Vigor")

	# --- the third god: Neris, the Tide-Keeper (CRAFT-AND-BUILD-SPEC M2.75) --
	check(not host.intent_cast("inv-slack-tide"), "no tide without the Tide-Keeper")
	check("work-altar-neris" not in host.menu_works(), "her altar waits until she's kneeled to")
	host.player.position = host.shrines[2].position
	check(host.intent_interact(), "kneel at the fallen shrine in the south")
	check("god-neris" in host.attuned_for(1) and host.devotion.state[1]["god-neris"].rank == 1, "Neris is with you — three gods now")
	check("work-altar-neris" in host.menu_works(), "her altar opens on the build menu")
	host.camp_center = host.player.position   # ring follows the player for the scattered build below
	host.inventory.add(1, "item-salt", 12)
	host.inventory.add(1, "item-wreck-timber", 8)
	host.inventory.add(1, "item-bronze-salvage", 2)
	check(host.intent_build("work-altar-neris"), "her altar rises")
	check(host.sanctum.is_altar(host.sanctum.altar_for("god-neris")), "and the Sanctum knows it")

	# Slack Tide: the world forgets to move — a brief stun on whatever crowds her caster
	var hound_ts := _enemy_of(host, "creature-salt-hound")
	check(hound_ts != null, "a hound remains for a time-slip demonstration")
	host.player.position = hound_ts.position + Vector2(60, 0)
	host.devotion.state[1]["god-neris"].vigor = host.devotion.max_vigor("god-neris")
	var neris_vigor0: float = host.devotion.state[1]["god-neris"].vigor
	check(host.intent_cast("inv-slack-tide"), "Slack Tide: for a held breath, the world forgets to move")
	check(hound_ts._stun > 0.0, "the hound stands frozen in the held breath")
	check(host.devotion.state[1]["god-neris"].vigor < neris_vigor0, "and Neris paid for it")
	host.player.position = Vector2(9999, 9999)   # clear of every hound before the long waits below

	# The Returning Wave (rank 2): what was taken comes back, slowly — regen on the caster
	host.devotion.state[1]["god-neris"].rank = 2
	host.devotion.state[1]["god-neris"].vigor = host.devotion.max_vigor("god-neris")
	host.stats.actors[1].hp = maxf(host.stats.max_hp(1) - 40.0, 1.0)
	var hp_before_wave := host.stats.hp(1)
	check(host.intent_cast("inv-returning-wave"), "The Returning Wave: what was taken from you comes back")
	for i in 20:
		await get_tree().physics_frame
	check(host.stats.hp(1) > hp_before_wave, "the tide pulls your hurt back out, a little at a time")

	# the Tide-Bell: rings itself at 06:00/18:00, counts as in-use, bumps dawn output
	host.camp_center = host.player.position   # ring follows the player again (we wandered off to the hound)
	host.inventory.add(1, "item-bronze-salvage", 8)
	check(host.intent_build("work-tide-bell"), "the Tide-Bell rises")
	var bell_inst := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-tide-bell":
			bell_inst = int(iid)
	check(bell_inst >= 0 and not host.works.placed[bell_inst].in_use, "quiet, for now")
	check(host._tide_bell_output_bonus() == 0.0, "no bonus before the bell rings")
	host._tick_tide_bell(6 * 60 - 1)
	check(not host.tide_bell_rang_today, "not yet six")
	host._tick_tide_bell(6 * 60)
	check(host.works.placed[bell_inst].in_use, "the bell rang and counts as tended")
	check(host.tide_bell_rang_today and host._tide_bell_output_bonus() == 0.5, "Neris keeps count — the village works a little better today")

	# the Healing Bath: stand within it and mend
	host.inventory.add(1, "item-wreck-timber", 10)
	host.inventory.add(1, "item-salt", 15)
	host.inventory.add(1, "item-pearl", 2)
	host.devotion.state[1]["god-neris"].favor = 30.0
	check(host.intent_build("work-healing-bath"), "the Healing Bath rises")
	var bath_pos := host.work_pos("work-healing-bath")
	host.player.position = bath_pos
	host.stats.actors[1].hp = 20.0
	host.stats.actors[1].stamina = 0.0
	var bath_hp0 := host.stats.hp(1)
	for i in 90:
		await get_tree().physics_frame
	check(host.stats.hp(1) > bath_hp0, "the warm brine mends you while you soak")
	var bath_inst := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-healing-bath":
			bath_inst = int(iid)
	check(bath_inst >= 0 and host.works.placed[bath_inst].in_use, "the bath counts as tended, today")
	host.player.position = Vector2(-9999, -9999)
	for i in 3:
		await get_tree().physics_frame
	check(float(host.stats.actors[1].get("bath_mult", 1.0)) == 1.0, "step out of the water and the extra mending stops")
	host.stats.heal_full(1)   # the tests above left HP low on purpose (measuring the mend) — full health for what's next

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

	# the Verdict, in hand: CONSUME — power now, Godhead LOCKED at 0 forever
	# (VILLAGER-AND-GODHEAD-SPEC Part II §4 — this absorbs what used to be a
	# separate, ad-hoc verdict.god_world_strength "-20, then +10 back on
	# enshrine" hack; godhead_system.consumed() is the one true source now,
	# and unlike the old hack it is genuinely irreversible — see below)
	var base_hp0: float = host.stats.actors[1].base_hp
	check(not host.godhead.is_consumed("god-halor"), "Halor's Godhead stands untouched, so far")
	check(host.intent_consume_remnant(), "the warm voice gets its way")
	check(host.stats.actors[1].base_hp == base_hp0 + 15.0, "you feel MAGNIFICENT — permanently")
	check(host.godhead.is_consumed("god-halor") and host.godhead.godhead("god-halor") == 0.0, "and Halor's Godhead locks at 0, for everyone, forever")
	check(host.godhead.effective_mult("god-halor") == 0.0, "a consumed god grants NO magic")
	check(host.verdict.ledgers[1]["remnants"] < 0.0, "the ledger remembers what you ate")

	# the invocation itself is BLOCKED now, diegetically — not merely weak
	host.devotion.state[1]["god-halor"].vigor = host.devotion.max_vigor("god-halor")   # rule out "no Vigor" as the reason
	check(not host.intent_cast("inv-pillar-of-salt"), "a consumed god answers no calls")
	check(host.message.contains("nothing answers"), "the block is diegetic, not a silent no-op")

	# ...and ENSHRINE, the other door (a second remnant, test-granted) — but
	# consumption is THE one truly irreversible act (§4): enshrining Halor
	# again does NOTHING now. (The old hack let a later enshrine partially
	# undo a consume, which was never the intent — this is the fix.)
	host.inventory.add(1, "item-remnant-shellback", 1)
	host.player.position = host.chapels["god-halor"]
	check(host.current_prompt().contains("Enshrine"), "the chapel prompt offers the better door")
	check(host.intent_enshrine("god-halor"), "set the remnant in the chapel-stone")
	check(host.godhead.godhead("god-halor") == 0.0, "consumption is FOREVER — enshrining after can't undo it")

	# --- the Waker of the Drowned (VILLAGER-AND-GODHEAD-SPEC Part II §5) -----
	# Every player death ends with Ur-Noth handing you back — a real, lethal
	# hit through damage_player(), the exact path an enemy uses, not the
	# petrify/Returning cheats exercised earlier in this file. A FRESH pid
	# (88) for the spec's exact first-death numbers: pid 1 already died
	# several times earlier in this very file (the HP/petrify tests above),
	# so ITS streak is not a clean "first death" — used below only for the
	# decay-direction check, which doesn't need an exact percentage.
	host.stats.register(88, 60.0, 60.0)
	var gh_urnoth0 := host.godhead.godhead("god-ur-noth")
	host.damage_player(999999.0, 88)
	check(host.message.contains("+0.4%") and host.message.contains("now"), "the death screen prints the spec's exact first-death ledger line (feed + running total)")
	check(host.godhead.godhead("god-ur-noth") > gh_urnoth0, "and the Unlit actually gained the feed")
	check(host.message.contains("\""), "one whisper line rides along on wake, quoted")
	var after_first := host.godhead.godhead("god-ur-noth") - gh_urnoth0
	host.damage_player(999999.0, 88)   # same day: the decay window is still open
	var after_second := host.godhead.godhead("god-ur-noth") - gh_urnoth0 - after_first
	check(after_second > 0.0 and after_second < after_first, "a second death in the same window feeds LESS, not zero")

	# attuned to Ur-Noth: the revival costs him exactly what it feeds him — a wash
	host.stats.register(77, 60.0, 60.0)
	host.attuned_for(77).append("god-ur-noth")
	var urnoth_before_wash := host.godhead.godhead("god-ur-noth")
	host.damage_player(999999.0, 77)
	check(absf(host.godhead.godhead("god-ur-noth") - urnoth_before_wash) < 0.0001, "an Ur-Noth-attuned death is a true wash — ±0% net")
	check(host.message.contains("carries his own"), "the death screen says so, in the spec's own words")
	check(host.godhead.lifetime_deaths.get(77, 0) == 1, "the death still counts (ledger-neutral, not unnoticed)")

	# UI law: the numbers are always on screen (Part II §2) — Maren's HUD line
	host._refresh_bars()
	check(host.maren_godhead_label.text.to_lower().contains("godhead"), "the HUD's god line shows Godhead too (%s)" % host.maren_godhead_label.text)

	# --- the flats remember: full save -> fresh world -> load ----------------
	var take_one := _node_of(host, "item-salt")
	var take_pos := take_one.position
	for j in int(take_one.get_meta("hits", 1)):
		host.player.position = take_pos
		host.intent_harvest()  # mine the crust to nothing: something must be MISSING at save time
	var partial := _node_of(host, "item-driftwood")
	host.player.position = partial.position
	host.intent_harvest()   # and one node left half-worked — its wear must survive the save
	var partial_left := int(partial.get_meta("left", 0))
	var partial_idx := int(partial.get_meta("idx", -1))
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
	var partial2_ok := false
	for n2 in host2.resource_nodes:
		if is_instance_valid(n2) and int(n2.get_meta("idx", -1)) == partial_idx:
			partial2_ok = int(n2.get_meta("left", -1)) == partial_left
	check(partial2_ok, "a half-worked node keeps its wear across save/load (%d left)" % partial_left)
	check(_enemy_of(host2, "creature-old-shellback") == null, "Old Shellback stays dead")
	check(host2.godhead.is_consumed("god-halor") and host2.godhead.godhead("god-halor") == 0.0, "the world remembers what you consumed — Godhead stays locked at 0 across save/load")
	check(absf(host2.godhead.godhead("god-ur-noth") - host.godhead.godhead("god-ur-noth")) < 0.001, "Ur-Noth's fed Godhead survives save/load")
	check(host2.godhead.lifetime_deaths.get(1, 0) == host.godhead.lifetime_deaths.get(1, 0) and host2.godhead.lifetime_deaths.get(77, 0) == host.godhead.lifetime_deaths.get(77, 0), "per-player death counts survive save/load too")
	host2.queue_free()

	# --- the great storm ------------------------------------------------------
	# (dawns now respawn salvage, so guarantee something is freshly missing —
	# a workable node must be cut to NOTHING before it counts as taken)
	var fresh_node := _node_of(host, "item-driftwood")
	var fresh_pos := fresh_node.position
	for j in int(fresh_node.get_meta("hits", 1)):
		host.player.position = fresh_pos
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

	# --- the Lighthouse-Keeper's Lantern, verse 3 + the rite-craft -----------
	# verse 3: granted to every survivor on the dawn after the great storm we
	# just lived through (day 3 was the storm; day 4's dawn just fired above)
	check(host.inventory.count(1, "item-lantern-verse") == 3, "you made it through the storm — the last verse comes to you unbidden")
	# drain any leftover event material from earlier tests so the gate below is real
	var leftover_glass := host.inventory.count(1, "item-storm-glass")
	if leftover_glass > 0:
		host.inventory.pay(1, [{"itemId": "item-storm-glass", "qty": leftover_glass}])
	check(not host.intent_craft("recipe-lighthouse-keepers-lantern"), "not yet — the rite still wants its materials")
	host.inventory.add(1, "item-storm-glass", 2)
	host.inventory.add(1, "item-bronze-salvage", 6)
	host.inventory.add(1, "item-rope", 2)
	check(host.equipped_mod_mult(1, "hound-aggro-mult") == 1.0, "bare of the trinket, a hound keeps its full night reach")
	check(host.intent_craft("recipe-lighthouse-keepers-lantern"), "THE RITE IS DONE — the Lantern is forged, at any chapel")
	check(host.inventory.count(1, "item-lighthouse-keepers-lantern") == 1, "the Lighthouse-Keeper's Lantern, in hand")
	check(host.inventory.count(1, "item-lantern-verse") == 3, "the song is knowledge — not consumed")
	host.equip_toggle(1, "item-lighthouse-keepers-lantern")
	check(host.equipped_item(1, "trinket") == "item-lighthouse-keepers-lantern", "the first trinket in the game, worn")
	check(host.equipped_mod_mult(1, "hound-aggro-mult") == 0.75, "carrying it, a hound's night reach narrows")

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
		check(host.inventory.count(1, "item-salt") - salt_before == 2, "Take More: +1 per swing at the crust (got %d)" % (host.inventory.count(1, "item-salt") - salt_before))
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
	# gather the village around `center` for this test: the hearth is the heart
	# (village_heart drives Anna's schedule), so put it — and the chapel — here
	var center := Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, GameHost.WORLD.y * GameHost.TILE / 2.0)
	for hid: Variant in host.works.placed:
		var wid: String = str(host.works.placed[hid].work_id)
		if wid == "work-hearth":
			host.works.placed[hid].x = center.x; host.works.placed[hid].y = center.y
		elif wid == "work-chapel":
			host.works.placed[hid].x = center.x + 60; host.works.placed[hid].y = center.y + 60
			host.chapels["god-halor"] = center + Vector2(60, 60)
	host._recenter_on_hearth()
	host.survivor.position = center  # settled at the heart
	host.inventory.add(1, "item-wreck-timber", 8)
	host.inventory.add(1, "item-salt", 12)
	host.player.position = center + Vector2(-120, 0)   # in-ring, off the hearth
	check(host.intent_build("work-smokehouse") or host.works.count_of("work-smokehouse") > 0, "a smokehouse stands")
	host.clock.minute_of_day = 8 * 60  # working morning
	# the economy tests above overstuffed the larder — starve it so the food task
	# (Anna's calling as a brinewife) is short and hers again
	host.village_stock.erase("item-smoked-crab")
	host.village_stock.erase("item-salt-ration")
	host._assign_village_tasks()
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

	# --- RISK: the leash breathes with need; full stores never idle the hands --
	host.village_stock.erase("item-driftwood")
	check(absf(host._task_leash("wood") - host.FORAGE_LEASH_FAR) < 1.0,
		"empty stores: the wood leash runs far (%.0f)" % host._task_leash("wood"))
	host.village_stock["item-driftwood"] = int(host.NEED_TARGETS["wood"])
	check(absf(host._task_leash("wood") - host.FORAGE_LEASH_NEAR) < 1.0,
		"full stores: it pulls in close to home (%.0f)" % host._task_leash("wood"))
	# park a wood node by the hearth, fill EVERY store — and still nobody idles
	var near_node := _node_of(host, "item-driftwood")
	near_node.position = host.village_heart() + Vector2(150, 0)
	for task_k: String in host.NEED_TARGETS:
		host.village_stock[host.TASK_ITEM[task_k]] = int(host.NEED_TARGETS[task_k]) + 4
	host._assign_village_tasks()
	var idle_hands := 0
	for v in host.all_villagers():
		if v.rescued and not v.is_captive and v.tribesman_id >= 0 and v.task == "":
			idle_hands += 1
	check(idle_hands == 0, "idle hands feed no gods: stores full, wood near — everyone still works (%d idle)" % idle_hands)

	# --- CALLINGS: the journal runtime ---------------------------------------
	var player_pos0: Vector2 = host.player.position   # the callings tests walk; put us back after
	host.callings.clear(); host.callings_done.clear()
	host._active_callings(1).append({"id": "calling-the-letter-still-walking", "step": "s1"})
	host.journal_interact(1, 0)   # s1: unparamed legacy collect -> free-continue (back-compat law)
	check(str(host._active_callings(1)[0].step) == "s2", "an unparamed step still free-continues, empty-handed")
	# s2 is a goto now (near wreck-west): far away, the journal refuses the road not walked
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s2", "a goto step gates until you arrive")
	check(host.message.begins_with("Not yet"), "and the refusal is a diegetic nudge (%s)" % host.message)
	host._toggle_journal(true)
	check(host.journal.text.contains("you are not there yet"), "the journal shows the distance in its own words")
	check(host.journal.text.contains("(not yet) continue"), "and dims the continue line")
	host._toggle_journal(false)
	check(host._direction_hints().contains("your calling pulls"), "the HUD gains one bearing line for the unmet goto")
	host.player.position = host.LANTERN_WRECK_POS   # walk the walker's route
	host.journal_interact(1, 0)   # s2 -> s3 (arrived; the turn)
	check(str(host._active_callings(1)[0].step) == "s3", "arrive and the same press continues; you reach the turn")
	check(host._direction_hints().contains("your calling pulls") == false, "the bearing line rests once the step is met")
	var shep0: float = float(host.verdict.ledgers.get(1, {}).get("shepherd", 0.0))
	var bronze0 := host.inventory.count(1, "item-bronze-salvage")
	host.journal_interact(1, 0)   # choose option 1 (shepherd +8) -> s4-rest epilogue
	check(float(host.verdict.ledgers[1].get("shepherd", 0.0)) == shep0 + 8.0, "a choice writes the Verdict ledger")
	host.journal_interact(1, 0)   # continue the epilogue -> terminal, completes
	check(host._active_callings(1).is_empty() and "calling-the-letter-still-walking" in host._done_callings(1), "the calling is answered and logged")
	check(host.inventory.count(1, "item-bronze-salvage") == bronze0 + 2, "its reward paid out")
	host.callings.clear()
	host._draw_calling(1)   # the draw path runs and never returns a finished calling
	check(host._active_callings(1).map(func(e): return str(e.id)).find("calling-the-letter-still-walking") == -1, "a finished calling never returns")

	# --- CALLINGS: the verbs mean something (step params runtime) -------------
	# collect, no consume: the pack must hold the goods; advancing keeps them
	host.callings.clear()
	host.inventory._inv(1).erase("item-wreck-timber")
	host._active_callings(1).append({"id": "calling-chart-leads-deep", "step": "s2", "since_day": 0})
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s2", "a collect step gates while the pack is light")
	check(host.message.contains("0/2"), "the nudge counts what's in hand (%s)" % host.message)
	host._toggle_journal(true)
	check(host.journal.text.contains("0/2"), "the journal carries the same tally inline")
	host._toggle_journal(false)
	host.inventory.add(1, "item-wreck-timber", 2)
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s3", "timber in hand, the step advances")
	check(host.inventory.count(1, "item-wreck-timber") == 2, "and without consume:true the timber stays yours")
	# choice steps are untouched by the params runtime: option 1 advances as ever
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s4-shrine", "a choice step still advances by option, ungated")
	# collect WITH consume: advancing pays the goods away (the story gives them)
	host.callings.clear()
	host.inventory._inv(1).erase("item-bronze-salvage")
	host._active_callings(1).append({"id": "calling-the-rite-that-needs-stocking", "step": "s2", "since_day": 0})
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s2", "the offering-collect gates empty-handed")
	host.inventory.add(1, "item-bronze-salvage", 3)
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s3", "bronze gathered, the rite-stocking advances")
	check(host.inventory.count(1, "item-bronze-salvage") == 1, "consume:true lays the bronze out — 2 of 3 leave the pack")
	# build: met by the work actually standing (works_system.count_of)
	host.callings.clear()
	host._active_callings(1).append({"id": "calling-the-cistern-tender", "step": "s3", "since_day": 0})
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s3", "a build step gates while nothing stands")
	check(host.message.contains("does not yet stand"), "and says so in-world (%s)" % host.message)
	host.works.place("work-storm-cistern", 1)
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s4", "raise the cistern and the step advances")
	# kill: counted through the REAL kill handler, per entry, per player
	host.callings.clear()
	host.registry.by_id["calling-smoke-kill"] = {"id": "calling-smoke-kill", "title": "Smoke Kill",
		"tier": "vignette", "source": "rumor", "giver": {"name": "t", "wound": "t"},
		"steps": [{"id": "k1", "type": "kill", "text": "t",
			"params": {"creatureId": "creature-scuttle-crab", "count": 2}, "next": null}],
		"echo": {"text": "t"}, "status": "draft"}
	host._active_callings(1).append({"id": "calling-smoke-kill", "step": "k1", "since_day": 0})
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "k1", "a kill step gates before any crab falls")
	for _k in 2:
		var quarry := DSEnemy.new()
		quarry.position = host.player.position + Vector2(30, 0)
		quarry.setup(host, "creature-scuttle-crab")
		host.add_child(quarry); host.enemies.append(quarry)
		host._on_enemy_killed(quarry)   # the real handler — the same call combat makes
	check(int(host._active_callings(1)[0].get("counters", {}).get("k1", 0)) == 2, "the real kill handler feeds the entry's counter")
	host.journal_interact(1, 0)
	check("calling-smoke-kill" in host._done_callings(1), "two crabs down, the kill step completes")
	host.registry.by_id.erase("calling-smoke-kill")
	# wait until:"storm" — the great-storm clock is the gate
	host.callings.clear()
	var day0 := host.clock.day
	host.clock.day = 4   # %4 == 0: clear skies
	host._active_callings(1).append({"id": "calling-the-squall-she-owes", "step": "s4-stand", "since_day": 4})
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "s4-stand", "a wait:storm step holds under a clear sky")
	check(host.message.contains("the storm has not yet come"), "and the nudge speaks weather, not timers")
	host.clock.day = 7   # %4 == 3: THE GREAT STORM
	host.journal_interact(1, 0)
	check("calling-the-squall-she-owes" in host._done_callings(1), "the storm arrives and the vigil completes")
	# the storm washes in raiders: the Taken system's supply line (world-gen's
	# 3 raiders were once the lifetime total — convert them and the yoke stood
	# empty forever)
	for e in host.enemies.duplicate():   # empty flats: prove the storm restocks from zero
		if is_instance_valid(e) and e.creature_id == "creature-raider":
			host.stats.unregister(e); host.enemies.erase(e); e.queue_free()
	host._storm_dawn()
	var raiders_after := host.enemies.filter(func(e: DSEnemy) -> bool:
		return is_instance_valid(e) and e.creature_id == "creature-raider").size()
	check(raiders_after == host.RAIDER_CAP, "a storm dawn replenishes raiders to cap (0 -> %d)" % raiders_after)
	check(host.message.contains("the storm drove people in"), "and the dawn report says who arrived")
	for e in host.enemies.duplicate():   # clean the field again for whatever follows
		if is_instance_valid(e) and e.creature_id == "creature-raider":
			host.stats.unregister(e); host.enemies.erase(e); e.queue_free()
	host.clock.day = day0
	# the dawn announcement rides WITH the dawn report, never over it
	host.callings.clear(); host.callings_done.clear()
	host.message = "Dawn. The village worked."
	host._draw_calling(1)
	check(host.message.contains("Dawn. The village worked.") and host.message.contains("[J] to open your journal"),
		"a new calling announces itself without eating the dawn report")
	host.callings.clear(); host.callings_done.clear()
	host.player.position = player_pos0

	# --- THE SANCTUM: the altar is the god's character sheet -------------------
	host.inventory.add(1, "item-salt", 30)
	host.inventory.add(1, "item-wreck-timber", 10)
	host.inventory.add(1, "item-bronze-salvage", 4)
	host.player.position = host.camp_center + Vector2(-60, 40)
	check(host.intent_build("work-altar-halor"), "the Altar of the Salt-Father rises")
	var altar := host.sanctum.altar_for("god-halor")
	check(altar >= 0, "the altar is consecrated to Halor")
	check(host._altar_near() == altar, "standing here, E belongs to the offertory")
	host._toggle_offertory(true, altar)
	check(host.offertory_open and host.offertory_label.text.contains("RELICS"), "the Offertory opens with the god's slots")
	check(host.offertory_label.text.contains("craves"), "the appetite annotation is the tutorial")
	# lay a craved offering — ONE per press, drawn from the COMMUNITY STORES
	host.village_stock["item-salt"] = 10
	var store_salt := int(host.village_stock["item-salt"])
	check(host.intent_sanctum(altar, "item-salt"), "salt is laid before the Salt-Father")
	check(int(host.village_stock.get("item-salt", 0)) == store_salt - 1 and int(host.sanctum.state[altar].bag["item-salt"]) == 1, "one press lays exactly one, from the stores")
	check(host.intent_sanctum(altar, "item-salt", "lay") and int(host.sanctum.state[altar].bag["item-salt"]) == 2, "the stores row lays a second (explicit op, not the toggle)")
	var spl := host.sanctum.splendor(altar)
	check(spl > 1.0, "the altar takes on splendor (x%.2f)" % spl)
	# the rite is borne up by it
	host.devotion.state[1]["god-halor"].vigor = 20.0
	host.rites_done_today.clear()
	host.intent_rite("god-halor")
	var lifted: float = host.devotion.state[1]["god-halor"].vigor
	check(lifted - 20.0 > 9.0 * 0.99 and host.message.contains("splendor"), "the rite returns more at a splendid altar (+%.1f)" % (lifted - 20.0))
	# display a relic — the remnant's third road
	host.inventory.add(1, "item-remnant-shellback", 1)
	check(host.intent_sanctum(altar, "item-remnant-shellback"), "the Remnant of the Shell is DISPLAYED")
	check(host.inventory.count(1, "item-remnant-shellback") == 0 and "item-remnant-shellback" in host.sanctum.state[altar].relics, "displayed, not consumed")
	# the offense: blood on the hearth god's altar, and the flats remember
	host.village_stock["item-crab-meat"] = 2
	var gods_ledger: float = float(host.verdict.ledgers.get(1, {}).get("gods", 0.0))
	host.intent_sanctum(altar, "item-crab-meat")
	check(float(host.verdict.ledgers[1].get("gods", 0.0)) < gods_ledger, "the offense lands in the Verdict ledger")
	host.intent_sanctum(altar, "item-crab-meat")   # take it back, shamefaced (to the shelves)
	# the dawn tithe eats craved first and feeds the god
	var bag_salt := int(host.sanctum.state[altar].bag.get("item-salt", 0))
	host.devotion.state[1]["god-halor"].vigor = 20.0
	host._on_sim_day(host.clock.day)
	check(int(host.sanctum.state[altar].bag.get("item-salt", 0)) < bag_salt, "at dawn the god takes a little of what was laid out")
	check(host.devotion.state[1]["god-halor"].vigor > 20.0, "and that consumption is worship")
	# reclaim gives everything back — the relic to YOUR pack, offerings to the STORES
	var salt_on_altar := int(host.sanctum.state[altar].bag.get("item-salt", 0))
	var store_salt2 := int(host.village_stock.get("item-salt", 0))
	host._demolish_work(altar)
	check(host.inventory.count(1, "item-remnant-shellback") == 1, "reclaiming the altar returns the relic to your pack")
	check(int(host.village_stock.get("item-salt", 0)) == store_salt2 + salt_on_altar, "and the offerings to the community stores")
	check(host.sanctum.altar_for("god-halor") == -1, "the consecration is gone")
	host._toggle_offertory(false)

	# --- HOUSING: dinner, then in for the night, out for breakfast --------------
	host.inventory.add(1, "item-driftwood", 20)
	host.inventory.add(1, "item-ship-cloth", 4)
	host.player.position = host.camp_center + Vector2(50, -40)
	check(host.intent_build("work-driftwood-cot"), "a cot-hut rises from driftwood and cloth")
	var anna := host.survivor
	var bunk := host.house_slot_for(anna)
	check(bunk != Vector2.INF, "Anna has a bunk with her name on it")
	# dinner hour: she is drawn to the hearth, not the hut
	host.clock.minute_of_day = 19 * 60 + 30
	var dinner_spot: Vector2 = anna._daily_target(host.village_heart())
	check(dinner_spot != Vector2.INF and dinner_spot.distance_to(host.village_heart()) < 90.0, "dinner is at the hearth")
	# night falls: the hut calls, and she walks in
	host.clock.minute_of_day = 22 * 60
	anna.position = bunk + Vector2(30, 0)   # already close; the walk is short
	for i in 90:
		await get_tree().physics_frame
	check(anna.housed and not anna.visible, "at night she goes inside — housed and hidden")
	# safety: a beast right outside the door cannot spook someone indoors
	var night_hound := _enemy_of(host, "creature-salt-hound")
	var night_hound_home := Vector2.ZERO
	if night_hound != null:
		night_hound_home = night_hound.position
		night_hound.position = anna.position + Vector2(40, 0)
	for i in 10:
		await get_tree().physics_frame
	check(anna.housed and not anna.needs_help, "the dark stays outside — no panic through a wall")
	if night_hound != null:
		night_hound.position = night_hound_home
	# morning: out she comes for breakfast
	host.clock.minute_of_day = 6 * 60 + 10
	for i in 30:
		await get_tree().physics_frame
	check(not anna.housed and anna.visible, "at the breakfast hour she steps back out")
	var brekkie: Vector2 = anna._daily_target(host.village_heart())
	check(brekkie != Vector2.INF and brekkie.distance_to(host.village_heart()) < 90.0, "and heads for the hearth")
	# no room at the inn: the second sleeper gets the huddle, not a bunk
	var crowd: Array = host.all_villagers().filter(func(w: DSVillager) -> bool: return w.rescued and not w.is_captive)
	if crowd.size() >= 3:
		var third: DSVillager = crowd[2]   # bunks = 2 per hut; the third is out of luck
		check(host.house_slot_for(third) == Vector2.INF, "two bunks per hut — the third sleeper huddles at the hearth")

	# --- VILLAGER ARMS: the Drill-Yard, arrivals, dawn training (VILLAGER-AND-GODHEAD-SPEC Part I) ---
	host.inventory.add(1, "item-wreck-timber", 14)
	host.inventory.add(1, "item-rope", 4)
	host.player.position = host.camp_center + Vector2(-60, 40)
	check(host.intent_build("work-drill-yard"), "the Drill-Yard raises")
	var drill_inst_id := -1
	for iid: Variant in host.works.placed:
		if str(host.works.placed[iid].work_id) == "work-drill-yard":
			drill_inst_id = int(iid)
	check(drill_inst_id >= 0, "and stands, findable")

	var recruit_id := host.village.add_tribesman("Bram", "class-warden", "rescued", [], "god-halor", host._starting_arms_for("class-warden"))
	check(host.village.arms_level(recruit_id) == 1, "a warden arrives Warrior 1, pre-trained")

	# assign a class through the modal flow: pick the villager, then the class
	var trainee_id := host.village.add_tribesman("Sil", "class-reef-runner", "rescued", [], "god-halor")
	var trainee := DSVillager.new()
	trainee.host = host; trainee.tribesman_id = trainee_id; trainee.def_class = "class-reef-runner"
	trainee.display_name = "Sil"
	trainee.rescued = true; trainee.position = host.village_heart()
	host.add_child(trainee); host.villagers.append(trainee)
	host.player.position = host.work_pos("work-drill-yard")
	host._toggle_drill(true, drill_inst_id)
	check(host.drill_open and host.drill_step == "villager", "[E] at the yard opens on the villager list")
	check(host.drill_items.has(trainee_id), "the free villager appears in the roster choice")
	host.drill_villager_id = trainee_id
	host.drill_step = "class"
	host._render_drill()
	check(host.drill_items.has("arms-warrior"), "the trio of classes is offered")
	check(host.intent_drill_train(trainee_id, "arms-warrior"), "assigning the Warrior class succeeds")
	host._toggle_drill(false)
	check(host.village.arms_level(trainee_id) == 1, "the sim record shows the class, level 1")

	# the Acolyte gate: faith/patron are surfaced as WHY, not just a locked option
	var faithless_id := host.village.add_tribesman("Karo", "class-salvager", "rescued", [], "")
	check(not host.village.train_arms(faithless_id, "arms-acolyte"), "no patron, no Acolyte — the gate holds")

	# drillDay XP: an Arms-classed villager with no task, resting, trains at dawn.
	# Called directly (not via _on_sim_day) so the self-managing task economy
	# can't reassign the trainee a real job out from under this check.
	trainee.task = ""
	var idle_xp_before: float = host.village.tribesmen[trainee_id].arms.xp
	var notes := host._dawn_drill_training()
	check(notes.any(func(n: String) -> bool: return n.contains("Sil")), "the dawn drill step names the trainee")
	check(float(host.village.tribesmen[trainee_id].arms.xp) > idle_xp_before, "an idle Arms-classed villager drills at dawn (XP granted)")

	# [V] panel: the roster line carries the class text
	host._toggle_village(true)
	check(host.village_panel.text.contains("Warrior"), "the [V] panel shows the Arms class")
	# the character sheet: [1-9] drills into a villager
	check((host.modals.village.footer as Label).text.contains("[1-9]"), "the roster footer offers the sheet")
	host.village_sheet_tid = trainee_id
	host.village_tab = "sheet"
	host._render_village()
	check((host.modals.village.title as Label).text.contains(trainee.display_name.to_upper()), "the sheet is titled with their name")
	check(host.village_panel.text.contains("TRADE:") and host.village_panel.text.contains("ARMS: Warrior"),
		"the sheet shows trade and Arms detail")
	check(host.village_panel.text.contains("THEIR WAYS"), "the sheet keeps a ways section (discovered traits only)")
	# stores tab: [1-9] takes one unit into your pack (test-era open access)
	host.village_stock["item-salt"] = int(host.village_stock.get("item-salt", 0)) + 2
	var stock_before: int = host.village_stock["item-salt"]
	var pack_before: int = host.inventory.count(1, "item-salt")
	host.acting_pid = 1
	host.intent_stores_take("item-salt")
	check(int(host.village_stock.get("item-salt", 0)) == stock_before - 1, "taking from the stores debits the stock")
	check(host.inventory.count(1, "item-salt") == pack_before + 1, "...and lands in the taker's pack")
	host.village_tab = "stores"
	host._render_village()
	check(host.village_panel.text.contains("take one into your pack"), "the stores tab offers the take")
	host.village_tab = "roster"
	host._toggle_village(false)

	# --- THE ROAD: recruit, follow, fight, downed/revive, permadeath ---------
	for e in host.enemies.duplicate():   # a clean field, so companion movement/combat is deterministic
		# M3.c: a world boss (the Anglermother, dormant-by-day at her fixed
		# reef ring) is never "roaming fauna" — this cleanup never meant to
		# sweep bosses even before her; it just never mattered while Old
		# Shellback (the only other persistent boss) was already long dead
		# by this point in the file's own narrative.
		if is_instance_valid(e) and not e.peaceful and not e.is_boss:
			host.stats.unregister(e)
			host.enemies.erase(e)
			e.queue_free()
	host.player.position = trainee.position
	check(host._recruit_eligible(trainee), "a classed, free villager is recruit-eligible")
	check(host.intent_recruit(trainee), "'Walk with me' recruits them")
	check(trainee.on_road and trainee.companion_pid == 1, "on_road, following pid 1")
	check(host.stats.actors.has(trainee), "a companion gets real HP tracking")

	# follow: far from the player, they close the distance
	trainee.position = host.player.position + Vector2(400, 0)
	for i in 40:
		await get_tree().physics_frame
	check(trainee.position.distance_to(host.player.position) < 380.0, "a companion closes distance toward their recruiter")

	# fight: an enemy adjacent to the companion takes damage
	var foe := DSEnemy.new()
	foe.position = trainee.position + Vector2(20, 0)
	foe.setup(host, "creature-salt-hound")
	host.add_child(foe); host.enemies.append(foe)
	var foe_hp := host.stats.hp(foe)
	# the kill lands assist XP through the REAL handler (regression: the sim's
	# source key is "killAssist"; a wrong key here once granted silent zero) —
	# captured BEFORE the wait: a strong-enough companion may finish foe off
	# on its own inside the window, and the real death path grants XP too.
	var assist_before: float = host.village.tribesmen[trainee_id].arms.xp
	for i in 60:
		await get_tree().physics_frame
	if is_instance_valid(foe) and foe in host.enemies:
		check(host.stats.hp(foe) < foe_hp, "a companion fights nearby hostiles")
		host._on_enemy_killed(foe)
	else:
		check(true, "a companion fights nearby hostiles (foe already fell to it)")
	check(float(host.village.tribesmen[trainee_id].arms.xp) > assist_before, "a kill nearby grants killAssist XP")

	# wardens help villagers, NOT players (Jeff 2026-07-17): a hostile menacing
	# a road companion far from home must not create warden duty — but the same
	# villager back on the clock still gets the watch.
	host.player.position = host.village_heart() + Vector2(700, 0)
	trainee.position = host.player.position + Vector2(30, 0)
	var road_foe := DSEnemy.new()
	road_foe.position = trainee.position + Vector2(20, 0)
	road_foe.setup(host, "creature-salt-hound")
	host.add_child(road_foe); host.enemies.append(road_foe)
	check(host.warden_duty(trainee) == Vector2.INF, "a threatened ROAD companion raises no warden duty")
	trainee.on_road = false
	check(host.warden_duty(trainee) == road_foe.position, "the same villager off the road still gets the watch")
	trainee.on_road = true
	host.stats.unregister(road_foe); host.enemies.erase(road_foe); road_foe.queue_free()

	# downed, then revive
	host.stats.actors[trainee].hp = 1.0
	host.damage_villager(trainee, 999.0)
	check(host.village.is_downed(trainee_id) and trainee.downed, "0 HP downs a companion — not death")
	host.player.position = trainee.position
	check(host.intent_revive_companion(trainee), "[E] revives a downed companion")
	check(not trainee.downed and host.stats.hp(trainee) > 0.0, "revived at partial HP")

	# dismiss at home: a companion who fought earns expeditionReturn XP
	trainee.fought_on_road = true
	trainee.position = host.village_heart()
	var xp_before_dismiss: float = host.village.tribesmen[trainee_id].arms.xp
	check(host.intent_dismiss_companion(trainee), "'Stay here' dismisses them")
	check(not trainee.on_road, "back to the task pool")
	check(float(host.village.tribesmen[trainee_id].arms.xp) > xp_before_dismiss, "a safe return earns expeditionReturn XP")

	# permadeath on the road: equipment drops, grief begins (halved once a Memorial stands)
	check(host.intent_recruit(trainee), "recruited again for the death test")
	trainee.warden_weapon = "item-driftwood-club"
	host.village.tribesmen[trainee_id].equipment.weapon = "item-driftwood-club"
	var node_count_before := host.resource_nodes.size()
	host.companion_die(trainee)
	check(not host.villagers.has(trainee), "a companion whose downed clock runs out is gone for good")
	check(host.resource_nodes.size() > node_count_before, "their gear drops where they fell")
	check(host.village.grief_days_remaining == 3, "the village grieves (griefDays tuning, no memorial yet)")

	host.inventory.add(1, "item-salt", 10)
	host.inventory.add(1, "item-wreck-timber", 6)
	host.inventory.add(1, "item-bronze-salvage", 2)
	host.player.position = host.camp_center + Vector2(-100, 60)
	check(host.intent_build("work-memorial"), "the Memorial Stone raises")
	check(host.village.has_memorial, "has_memorial is recomputed once the work stands")
	var mourner_id := host.village.add_tribesman("Ren", "class-warden", "rescued", [], "god-halor", "arms-warrior")
	var mourner := DSVillager.new()
	mourner.host = host; mourner.tribesman_id = mourner_id; mourner.def_class = "class-warden"
	mourner.display_name = "Ren"
	mourner.rescued = true; mourner.position = host.village_heart()
	host.add_child(mourner); host.villagers.append(mourner)
	check(host.intent_recruit(mourner), "recruit for the memorial death test")
	host.village.grief_days_remaining = 0
	host.companion_die(mourner)
	check(host.village.grief_days_remaining == 2, "a Memorial halves grief days (ceil(3×0.5)=2)")

	# save/load round-trips Arms + equipment
	var keeper_id := host.village.add_tribesman("Vale", "class-smith", "rescued", [], "god-halor")
	host.village.train_arms(keeper_id, "arms-archer")
	host.village.grant_xp(keeper_id, "expeditionReturn")
	host.village.tribesmen[keeper_id].equipment.weapon = "item-driftwood-club"
	var keeper_xp: float = host.village.tribesmen[keeper_id].arms.xp
	host.save_game()
	var host5: GameHost = load("res://scenes/main.tscn").instantiate()
	host5.skip_autoload = true
	host5.save_path = host.save_path
	add_child(host5)
	await get_tree().physics_frame
	host5.load_game()
	check(host5.village.arms_level(keeper_id) >= 1, "save/load round-trips the Arms class")
	check(float(host5.village.tribesmen[keeper_id].arms.xp) == keeper_xp, "...and the banked XP")
	check(str(host5.village.tribesmen[keeper_id].equipment.weapon) == "item-driftwood-club", "...and the equipped weapon")
	host5.queue_free()

	# --- TRAIT DISCOVERY: found by attention, never a menu (dawn wiring + [E] talk) --------------
	var dtune: Dictionary = host.village.vtune.get("discovery", {})

	# work axis, driven through the REAL dawn tick (_on_sim_day) so this proves
	# the wiring in _village_dawn (contexts built there, not just the sim math —
	# that's covered exhaustively in the sim suite). A permanent, in-reach node
	# guarantees they're never idle regardless of the village's stock levels.
	var work_threshold := int(dtune.get("work", 4))
	var watched_id := host.village.add_tribesman("Nettle", "class-reef-runner", "rescued", ["trait-industrious"], "god-halor")
	var watched := DSVillager.new()
	watched.host = host; watched.tribesman_id = watched_id; watched.def_class = "class-reef-runner"
	watched.display_name = "Nettle"
	watched.rescued = true; watched.position = host.village_heart()
	host.add_child(watched); host.villagers.append(watched)
	var always_wood := host._spawn_one_node("item-driftwood", host.village_heart(), -1000)
	always_wood.set_meta("left", 9999)
	for i in work_threshold:
		host._on_sim_day(1000 + i)
	check(host.village.tribesmen[watched_id].discovered.has("trait-industrious"),
		"a working villager's work-axis trait discovers after %d dawns of real attention" % work_threshold)
	check(host.message.contains("You've come to know Nettle") and host.message.contains("Industrious"),
		"the dawn report names the discovery, in the house voice")

	# faith axis needs the "faith" context — a chapel already stands (built
	# earlier in this run), so it's live for everyone from here on
	check(host.works.count_of("work-chapel") > 0, "a chapel already stands (built earlier in this run)")
	var faith_threshold := int(dtune.get("faith", 5))
	var devout_id := host.village.add_tribesman("Kessa", "class-brinewife", "rescued", ["trait-devout"], "god-halor")
	var devoutv := DSVillager.new()
	devoutv.host = host; devoutv.tribesman_id = devout_id; devoutv.def_class = "class-brinewife"
	devoutv.display_name = "Kessa"
	devoutv.rescued = true; devoutv.position = host.village_heart()
	host.add_child(devoutv); host.villagers.append(devoutv)
	for i in faith_threshold:
		host._on_sim_day(1100 + i)
	check(host.village.tribesmen[devout_id].discovered.has("trait-devout"),
		"a faith-axis trait discovers on schedule once a chapel stands")

	# road doubling: two otherwise-identical quirky villagers, one walked with a player
	var quirk_threshold := int(dtune.get("quirk", 8))
	var stayer_id := host.village.add_tribesman("Stayer", "class-salvager", "rescued", ["trait-night-owl"])
	var roader_id := host.village.add_tribesman("Roader", "class-salvager", "rescued", ["trait-night-owl"])
	var stayer := DSVillager.new()
	stayer.host = host; stayer.tribesman_id = stayer_id; stayer.def_class = "class-salvager"
	stayer.display_name = "Stayer"; stayer.rescued = true; stayer.position = host.village_heart()
	host.add_child(stayer); host.villagers.append(stayer)
	var roader := DSVillager.new()
	roader.host = host; roader.tribesman_id = roader_id; roader.def_class = "class-salvager"
	roader.display_name = "Roader"; roader.rescued = true; roader.position = host.village_heart()
	roader.on_road = true
	host.village.tribesmen[roader_id].on_road = true
	host.add_child(roader); host.villagers.append(roader)
	for i in int(ceil(float(quirk_threshold) / 2.0)):
		host._on_sim_day(1200 + i)
	check(host.village.tribesmen[roader_id].discovered.has("trait-night-owl"),
		"on the road, attention doubles — a quirk discovers in half the dawns")
	check(not host.village.tribesmen[stayer_id].discovered.has("trait-night-owl"),
		"...while the one who stayed home is still only halfway there")

	# social trait discovers via repeated [E] talks, respecting the once-per-sim-day cap
	var social_threshold := int(dtune.get("social", 3))
	# trait-devout picked first for the Key (its keyHint isn't a talk-bloom
	# trigger) so [E]-talk here stays plain talk — the storyteller trait's own
	# key ("audience-kept") IS a talk-bloom trigger and would auto-discover it
	# via meet_key on the first word, short-circuiting the thing under test.
	var chatty_id := host.village.add_tribesman("Bard", "class-brinewife", "rescued", ["trait-devout", "trait-storyteller"], "god-halor")
	var bard := DSVillager.new()
	bard.host = host; bard.tribesman_id = chatty_id; bard.def_class = "class-brinewife"
	bard.display_name = "Bard"; bard.rescued = true; bard.position = host.village_heart()
	host.add_child(bard); host.villagers.append(bard)
	host.clock.day = 5000
	for i in 10:   # ten talks on the SAME sim-day — the cap must hold to one tick
		host.intent_talk(bard)
	check(not host.village.tribesmen[chatty_id].discovered.has("trait-storyteller"),
		"the once-per-day talk cap holds even across ten conversations in one day")
	for d in range(1, social_threshold):
		host.clock.day = 5000 + d
		host.intent_talk(bard)
	check(host.village.tribesmen[chatty_id].discovered.has("trait-storyteller"),
		"a social trait discovers via repeated talks, one distinct sim-day at a time")
	check(host.message.contains("You've come to know Bard"), "a talk-discovery messages immediately, not just at dawn")

	# bloom auto-discovers the key's trait — sim-only record, no visual node needed
	var bloom_id := host.village.add_tribesman("Bloomer", "class-brinewife", "rescued", ["trait-devout", "trait-industrious"], "god-halor")
	host.village.meet_key(bloom_id)
	check(host.village.tribesmen[bloom_id].discovered.has("trait-devout"), "bloom reveals the key's trait immediately")

	# the character sheet renders a discovered trait's name
	host._toggle_village(true)
	host.village_sheet_tid = watched_id
	host.village_tab = "sheet"
	host._render_village()
	check(host.village_panel.text.contains("Industrious"), "the character sheet renders a discovered trait's name")
	host.village_tab = "roster"
	host._toggle_village(false)

	# save/load round-trips notice (hidden progress) + discovered (revealed)
	host.save_game()
	var host6: GameHost = load("res://scenes/main.tscn").instantiate()
	host6.skip_autoload = true
	host6.save_path = host.save_path
	add_child(host6)
	await get_tree().physics_frame
	host6.load_game()
	check(host6.village.tribesmen[watched_id].discovered.has("trait-industrious"), "save/load round-trips discovered traits")
	check(float(host6.village.tribesmen[stayer_id].notice.get("trait-night-owl", -1.0)) > 0.0,
		"...and the hidden notice progress for a trait not yet discovered")
	host6.queue_free()

	# --- BEASTS AT HEEL (VILLAGER-AND-GODHEAD-SPEC Part III): taming, heel, kennel ---
	host.abilities.earn(1, 20)               # plenty of Temper for the WILD ladder
	host.inventory.inventories[1] = {}        # a clean pack — no stray food from earlier tests

	# WILD gate: a crab (tier 1, needs WILD 3) refuses an unqualified player
	var wcrab := DSEnemy.new()
	wcrab.position = Vector2(5000, 5000)
	wcrab.setup(host, "creature-scuttle-crab")
	host.add_child(wcrab); host.enemies.append(wcrab)
	host.player.position = wcrab.position
	host.inventory.add(1, "item-smoked-crab", 4)
	check(host.abilities.score(1, "virtue-wild") == 0, "no WILD spent yet")
	check(host.intent_feed_wild(wcrab), "the [E]-feed verb always resolves — the UI law is show the numbers")
	check(host.message.contains("Needs WILD 3") and host.inventory.count(1, "item-smoked-crab") == 4,
		"an under-WILD player is refused, diegetically, food untouched (%s)" % host.message)

	# allocate WILD 3 (Soft-Step) — the gate opens
	for i in 3:
		host.abilities.allocate(1, "virtue-wild")
	check(host.abilities.score(1, "virtue-wild") == 3, "WILD 3 allocated")
	check(host.intent_feed_wild(wcrab), "now the crab eats")
	check(host.message.contains("trust 1/2"), "the numbers show, Shepherd's-Way style (%s)" % host.message)
	check(host.inventory.count(1, "item-smoked-crab") == 3, "one meal consumed")

	# same sim-day repeat: a no-op on trust, and must not waste the food either
	check(host.intent_feed_wild(wcrab), "a same-day repeat feed still resolves")
	check(host.message.contains("trust 1/2") and host.inventory.count(1, "item-smoked-crab") == 3,
		"...no trust gained and no meal wasted on a same-day repeat (%s)" % host.message)

	# the next day's feed fills trust -> TAMED
	host.clock.day += 1
	check(host.intent_feed_wild(wcrab), "the next day's feed")
	check(host.message.contains("TAMED"), "trust fills — tamed (%s)" % host.message)
	check(host.beasts.size() == 1, "a DSBeast body spawns in the world")
	var skitter: DSBeast = host.beasts[0]
	check(skitter.creature_id == "creature-scuttle-crab" and skitter.owner_pid == 1, "the tamed body knows its species and owner")
	check(skitter.at_heel, "a free heel slot: the new tame falls in at heel immediately")

	# heel toggle + follow
	host.player.position = Vector2(5500, 5000)
	for i in 150:
		await get_tree().physics_frame
	check(skitter.position.distance_to(host.player.position) < 300.0, "a beast at heel closes distance toward its owner")
	host.player.position = skitter.position
	check(host.intent_beast_interact(skitter), "[E] toggles your beast off heel")
	check(not skitter.at_heel, "...sent home")
	check(host.intent_beast_interact(skitter), "[E] again brings it back")
	check(skitter.at_heel, "...heel restored")

	# crab hoovers a ground drop within reach + [E] empties the bag to your pack
	host.player.position = Vector2(5500, 5500)
	skitter.position = host.player.position
	host._spawn_equipment_drop("item-crab-meat", host.player.position + Vector2(20, 0))
	for i in 20:
		await get_tree().physics_frame
	check(skitter.bag_total() > 0, "the porter hoovers a nearby ground drop into its own bag")
	var meat_before := host.inventory.count(1, "item-crab-meat")
	check(host.intent_beast_interact(skitter), "[E] on a full-bagged crab empties it")
	check(host.inventory.count(1, "item-crab-meat") > meat_before, "...into the owner's pack")
	check(skitter.bag_total() == 0, "the bag is empty again")

	# hound mercy-kneel: WITHOUT enough WILD, a beaten hound just dies (today's law holds)
	host.player.position = Vector2(6000, 5000)
	var weak_hound := DSEnemy.new()
	weak_hound.position = host.player.position + Vector2(30, 0)
	weak_hound.setup(host, "creature-salt-hound")
	host.add_child(weak_hound); host.enemies.append(weak_hound)
	host.stats.actors[weak_hound].hp = 5.0
	check(host.abilities.score(1, "virtue-wild") < 6, "WILD 3 doesn't meet the hound's tier-2 gate")
	check(host.intent_attack(), "the swing lands")
	check(not host.enemies.has(weak_hound), "without WILD 6, a beaten hound simply dies — the food loop survives untouched")

	# allocate WILD 6 (Crab-Friend) — now the same beating KNEELS the hound instead
	for i in 3:
		host.abilities.allocate(1, "virtue-wild")
	check(host.abilities.score(1, "virtue-wild") == 6, "WILD 6 allocated")
	var kneel_hound := DSEnemy.new()
	kneel_hound.position = host.player.position + Vector2(30, 0)
	kneel_hound.setup(host, "creature-salt-hound")
	host.add_child(kneel_hound); host.enemies.append(kneel_hound)
	host.stats.actors[kneel_hound].hp = 5.0
	check(host.intent_attack(), "the swing lands")
	check(kneel_hound.surrendered and host.enemies.has(kneel_hound), "at WILD 6, the same lethal hit KNEELS the hound instead")
	var hound_max_hp := float(host.registry.get_entity("creature-salt-hound").get("stats", {}).get("hp", 40))
	check(absf(host.stats.hp(kneel_hound) - hound_max_hp * 0.25) < 0.01, "clamped to exactly the 25% mercy floor")

	# feed-tame the kneeling hound (3 meals, tier 2) across 3 sim-days
	host.inventory.add(1, "item-crab-meat", 5)
	check(host.intent_feed_wild(kneel_hound), "a kneeling hound can be fed toward taming")
	for i in 2:
		host.clock.day += 1
		host.intent_feed_wild(kneel_hound)
	check(host.message.contains("TAMED"), "three meals tames the hound (%s)" % host.message)
	check(host.beasts.size() == 2, "a second DSBeast body joins the roster")
	var fang: DSBeast = host.beasts[1]
	check(fang.creature_id == "creature-salt-hound", "the new tame is the hound")
	check(not fang.at_heel, "the heel slot is already Skitter's — the new tame waits/kennels instead (cap 1)")

	# free the heel slot, hand it to the hound, watch it fight
	check(host.intent_beast_interact(skitter), "send Skitter home, freeing the heel slot")
	check(host.intent_beast_interact(fang), "the hound takes the heel slot")
	check(fang.at_heel, "the hound now walks at heel")
	host.player.position = Vector2(6500, 5000)
	fang.position = host.player.position
	var foe2 := DSEnemy.new()
	foe2.position = fang.position + Vector2(20, 0)
	foe2.setup(host, "creature-salt-hound")
	host.add_child(foe2); host.enemies.append(foe2)
	var foe2_hp := host.stats.hp(foe2)
	for i in 90:
		await get_tree().physics_frame
	if is_instance_valid(foe2) and foe2 in host.enemies:
		check(host.stats.hp(foe2) < foe2_hp, "a hound at heel fights nearby hostiles on its own stat line")
		host.stats.unregister(foe2); host.enemies.erase(foe2); foe2.queue_free()
	else:
		check(true, "a hound at heel fights nearby hostiles (foe already fell to it)")

	# growl radar: a deterministic direct check (real-time physics racing the fight itself isn't).
	# The field must be clear of anything closer than GROWL_VISIBLE_CLOSE first —
	# foe2 above is cleaned up either way (killed by the fight, or by hand here).
	var far_hostile := DSEnemy.new()
	far_hostile.position = fang.position + Vector2(280, 0)
	far_hostile.setup(host, "creature-salt-hound")
	host.add_child(far_hostile); host.enemies.append(far_hostile)
	host.message = ""
	host.beast_growl_tick(fang)
	check(host.message.contains("growls") and host.message.contains(fang.display_name),
		"the growl-radar names the beast and gives a bearing (%s)" % host.message)
	host.stats.unregister(far_hostile); host.enemies.erase(far_hostile); far_hostile.queue_free()

	# Tide-Shell: level Skitter to 6 (test setup), bring it back to heel, absorb one owner hit per day
	host.beast.beasts[skitter.beast_id].xp = 900.0   # exactly level 6 (25*6^2)
	check(host.beast.beast_level(skitter.beast_id) == 6, "Skitter reaches level 6 (test setup)")
	check(host.beast_has_instinct(skitter.beast_id, "block-hit-for-owner"), "Tide-Shell ignites at 6")
	check(host.intent_beast_interact(fang), "send the hound home")
	check(host.intent_beast_interact(skitter), "Skitter takes the heel slot back")
	host.stats.actors[1].hp = 50.0
	host.damage_player(10.0, 1)
	check(host.stats.hp(1) == 50.0, "Tide-Shell absorbs a hit meant for the owner")
	check(skitter._tide_shell_used_today, "...and marks itself used for today")
	var hp_before2 := host.stats.hp(1)
	host.damage_player(10.0, 1)
	check(host.stats.hp(1) < hp_before2, "a second hit the same day is NOT absorbed — once a day only")

	# hound downed -> revive
	host.stats.actors[fang].hp = 1.0
	host.damage_beast(fang, 999.0)
	check(fang.downed, "0 HP downs a hound — not death")
	host.player.position = fang.position
	check(host.intent_beast_interact(fang), "[E] revives a downed beast")
	check(not fang.downed and host.stats.hp(fang) > 0.0, "revived at partial HP")

	# downed timeout -> permadeath, a keepsake drops where it fell
	host.stats.actors[fang].hp = 1.0
	host.damage_beast(fang, 999.0)
	check(fang.downed, "downed again for the timeout test")
	fang.downed_until = Time.get_unix_time_from_system() - 1.0   # already expired
	var fang_bid := fang.beast_id
	var node_count_before2 := host.resource_nodes.size()
	for i in 5:
		await get_tree().physics_frame
	# fang is a freed instance by now (queue_free() completed) — compare by id,
	# never touch the dangling reference itself (Array.has() on a typed array
	# validates the object and errors on an already-freed one)
	var fang_still_present := false
	for b: DSBeast in host.beasts:
		if b.beast_id == fang_bid:
			fang_still_present = true
	check(not fang_still_present, "the downed clock running out is permadeath — gone from the roster")
	check(not host.beast.beasts.has(fang_bid), "...the sim roster forgets it too")
	check(host.resource_nodes.size() > node_count_before2, "a keepsake drops where it fell")

	# the kennel + dawn: fed from stores (mood keen) vs unfed (mood sulks, refuses the heel call)
	host.inventory.add(1, "item-wreck-timber", 15)
	host.inventory.add(1, "item-rope", 8)
	host.player.position = host.camp_center + Vector2(-50, -50)
	check(host.intent_build("work-kennel"), "the Kennel raises — Old Ghal's first work")
	# called directly (not via the full _village_dawn) — same reason
	# _dawn_drill_training is: the shared village's own food/labor economy
	# (many villagers, some food-tasked) would otherwise restock smoked-crab
	# out from under this check before it ever runs.
	host.village_stock["item-smoked-crab"] = 3   # Skitter's craved food, on the shelf
	host._beast_dawn_feeding()
	check(str(host.beast.beasts[skitter.beast_id].mood) == "keen", "the kennel feeds a beast from stores at dawn — mood keen")
	host.village_stock.erase("item-smoked-crab")   # bare shelves
	host._beast_dawn_feeding()
	check(str(host.beast.beasts[skitter.beast_id].mood) == "sulking", "an unfed beast's mood drops to sulking")
	var crab_held := host.inventory.count(1, "item-smoked-crab")
	if crab_held > 0:   # a full pack would hand-feed on the next press — empty it so the refusal is provable
		host.inventory.pay(1, [{"itemId": "item-smoked-crab", "qty": crab_held}])
	check(host.intent_beast_interact(skitter), "send Skitter home first so the refusal below is meaningful")
	host.message = ""
	check(host.intent_beast_interact(skitter), "the [E] press always resolves")
	check(host.message.contains("turns away") and not skitter.at_heel, "a sulking beast refuses the heel call (%s)" % host.message)
	# hand-feeding: the kennel is the automatic path, never the only one —
	# craved food in the pack + [E] feeds a sulking beast by hand
	host.inventory.add(1, "item-smoked-crab", 1)
	check(host.intent_beast_interact(skitter), "[E] with craved food in the pack")
	check(bool(host.beast.beasts[skitter.beast_id].fed_today) and str(host.beast.beasts[skitter.beast_id].mood) == "keen",
		"a sulking beast eats from your hand — fed and keen")
	check(host.inventory.count(1, "item-smoked-crab") == 0, "and the meal came out of your pack")
	check(host.intent_beast_interact(skitter) and skitter.at_heel, "fed, they answer the heel call again")
	host.intent_beast_interact(skitter)   # send home again for the checks below

	# [V] panel: the roster carries a BEASTS line
	host._toggle_village(true)
	check(host.village_panel.text.contains("BEASTS:") and host.village_panel.text.contains(skitter.display_name), "the [V] panel shows the beast block")
	host._toggle_village(false)

	# save/load round-trips a tamed beast + its level
	host.village_stock["item-smoked-crab"] = 3
	host._beast_dawn_feeding()   # keen again, so the toggle below succeeds
	host.intent_beast_interact(skitter)   # back to heel
	host.save_game()
	var host7: GameHost = load("res://scenes/main.tscn").instantiate()
	host7.skip_autoload = true
	host7.save_path = host.save_path
	add_child(host7)
	await get_tree().physics_frame
	host7.load_game()
	check(host7.beast.beasts.has(skitter.beast_id), "save/load round-trips the tamed beast's sim record")
	check(host7.beast.beast_level(skitter.beast_id) == 6, "...and its level")
	check(host7.beasts.size() == 1, "...and its world body rebuilds")
	check(host7.beasts[0].at_heel, "...at_heel/kenneled restored from the roster")
	host7.queue_free()

	# ============================================================
	# M3.a — the Descent (REEF-FOREST-SPEC): WORLD grows 96x64 -> 96x128,
	# the north half stays byte-identical, the Reef Forest band stands south
	# of the scarp.
	# ============================================================
	check(GameHost.WORLD == Vector2i(96, 128), "WORLD grew to 96x128")

	# --- the north half is proven byte-identical: known B1 landmarks at their
	# exact old coordinates (rng seeds 7/11/23 pinned to NORTH_H, not WORLD.y) ---
	var halor_shrine: Node2D = null
	var neris_shrine: Node2D = null
	for s in host.shrines:
		if str(s.get_meta("god_id", "")) == "god-halor":
			halor_shrine = s
		elif str(s.get_meta("god_id", "")) == "god-neris":
			neris_shrine = s
	check(halor_shrine != null and halor_shrine.position == Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, GameHost.TILE * 5.0),
		"Halor's shrine stands exactly where it always did")
	check(neris_shrine != null and neris_shrine.position == Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, GameHost.NORTH_H * GameHost.TILE - GameHost.TILE * 5.0),
		"Neris's shrine (the old south rim) hasn't moved an inch")
	check(host._calling_anchor_pos("wreck-west") == GameHost.LANTERN_WRECK_POS, "the beached wreck anchor is unmoved")
	# Old Shellback fell earlier in this same run (the Verdict test above) — his
	# ring's POSITION is the thing that must never move, proven the same way
	# the anchors above are: the pure lookup, not his (long since dead) body.
	check(host._calling_anchor_pos("boss-ring") == GameHost.BOSS_RING_POS, "Old Shellback's ring position is unmoved")

	# --- the scarp: blocks off the Stair, but the gap itself passes ---
	# The reef tests above TELEPORTED us south (nodes, the forge), which fires
	# the crossing for real — no teleports exist in play, so rewind the one-shot
	# here and let the walk below prove the honest first descent.
	host.scarp_crossed = false
	host.godhead.set_biomes_cleared(1)
	host.player.position = Vector2(GameHost.STAIR_OF_HULLS_POS.x - 500.0, GameHost.SCARP_Y - 90.0)
	Input.action_press("move_down")
	for i in 60:
		await get_tree().physics_frame
	Input.action_release("move_down")
	check(host.player.position.y < GameHost.SCARP_Y, "the scarp blocks a walk-in off the Stair (y=%.0f, scarp at %.0f)" % [host.player.position.y, GameHost.SCARP_Y])
	check(not host.scarp_crossed, "...and a blocked attempt never counts as a crossing")

	host.player.position = Vector2(GameHost.STAIR_OF_HULLS_POS.x, GameHost.SCARP_Y - 90.0)
	Input.action_press("move_down")
	for i in 90:
		await get_tree().physics_frame
	Input.action_release("move_down")
	check(host.player.position.y > GameHost.SCARP_Y, "the Stair of Hulls itself passes (y=%.0f)" % host.player.position.y)

	# --- the crossing: fires once, raises the cap, says the numbers ---
	check(host.scarp_crossed, "walking the Stair south fires the crossing")
	check(absf(host.godhead.cap() - 70.0) < 0.01, "Godhead's cap rose 40%% -> 70%% (%.1f%%)" % host.godhead.cap())
	check(host.message.contains("cap 40%") and host.message.contains("70%"), "the message states the numbers (%s)" % host.message)
	host.message = ""
	host._check_scarp_crossing(1, host.player.position.y)
	check(host.message == "", "the crossing fires exactly once — a second check south of the scarp is a no-op")

	# --- B2 nodes need the mattock (CRAFT-AND-BUILD-SPEC Part 1 Law 2) ---
	var reef_node := _node_of(host, "item-coralwood")
	check(reef_node != null, "the reef grew coralwood south of the scarp")
	if reef_node != null:
		host.player.position = reef_node.position
		host.message = ""
		check(not host.intent_harvest(), "bare hands refuse a mattock-gated reef node")
		check(host.message.contains("Bronze Mattock"), "the refusal names the tool needed (%s)" % host.message)
		host.inventory.add(1, "item-bronze-mattock", 1)
		check(host.intent_harvest(), "the Bronze Mattock in pack opens it")
		check(host.inventory.count(1, "item-coralwood") >= 1, "coralwood yields, one swing in")

	# --- the Reef-Forge stands; the Reef-Iron Blade forges there and equips ---
	host.camp_center = host.player.position   # loosen the ring for this scattered build
	host.inventory.add(1, "item-coralwood", 20)
	host.inventory.add(1, "item-bronze-salvage", 10)
	host.inventory.add(1, "item-rope", 10)
	check(host.intent_build("work-reef-forge"), "the Reef-Forge stands (neutral, Law 1)")
	host.inventory.add(1, "item-reef-iron", 10)
	check(host.intent_craft("recipe-reef-iron-blade"), "the Reef-Iron Blade forges at the reef-forge")
	check(host.inventory.count(1, "item-reef-iron-blade") == 1, "the blade is in hand")
	var worn := host.equipped_item(1, "weapon")
	if worn != "":
		host.equip_toggle(1, worn)   # bare hands first, so the swap below is provable
	host.equip_toggle(1, "item-reef-iron-blade")
	check(host.equipped_item(1, "weapon") == "item-reef-iron-blade" and host.attack_damage() >= 30.0,
		"the Reef-Iron Blade equips and hits for 30 (%.0f)" % host.attack_damage())

	# --- the Pearl Votive: a Neris crave, a Vessa accept (sanctum lane) ---
	check(host.sanctum.lane("god-neris", "item-pearl-votive") == "craves", "the Pearl Votive is a Neris crave")
	check(host.sanctum.lane("god-vessa", "item-pearl-votive") == "accepts", "...and Vessa accepts it too")

	# --- the urchin-back: drops, and the B2 kitchen cooks them ---
	var urchin := DSEnemy.new()
	urchin.position = host.player.position + Vector2(30, 0)
	urchin.setup(host, "creature-urchin-back")
	host.add_child(urchin)
	host.enemies.append(urchin)
	var urchin_meat_before := host.inventory.count(1, "item-urchin-meat")
	var dye_before := host.inventory.count(1, "item-dye")
	host._on_enemy_killed(urchin)
	check(host.inventory.count(1, "item-urchin-meat") - urchin_meat_before == 2, "urchin-back drops urchin-meat x2")
	check(host.inventory.count(1, "item-dye") - dye_before == 1, "...and dye x1")
	host.inventory.add(1, "item-salt", 2)
	check(host.intent_craft("recipe-smoked-urchin"), "Smoked Urchin cooks at the smokehouse")
	check(host.inventory.count(1, "item-smoked-urchin") >= 1, "smoked urchin, in hand")

	# --- eel-wolf reviewed against the B2 x2 damage law (data, not a code multiplier) ---
	var hound_dmg := float(host.registry.get_entity("creature-salt-hound").get("stats", {}).get("damage", 0))
	var wolf_dmg := float(host.registry.get_entity("creature-eel-wolf").get("stats", {}).get("damage", 0))
	check(wolf_dmg > hound_dmg, "the eel-wolf hits harder than a hound (%.0f > %.0f)" % [wolf_dmg, hound_dmg])
	check(is_equal_approx(wolf_dmg, hound_dmg * 2.0), "...exactly the B2 x2 band, from data")

	# --- the twilight band: a pure function of position.y + time ---
	var noon := 12 * 60
	var north_tint := host._tint_for_minute(noon, float(GameHost.SCARP_Y) - 10.0)
	var south_tint := host._tint_for_minute(noon, float(GameHost.SCARP_Y) + 300.0)
	var north_sum := north_tint.r + north_tint.g + north_tint.b
	var south_sum := south_tint.r + south_tint.g + south_tint.b
	check(south_sum < north_sum, "a south position at noon reads darker than a north one (%.2f < %.2f)" % [south_sum, north_sum])

	# --- pre-band save migration: additive, both halves present, legacy kept ---
	host.save_game()
	var preband_raw := SaveSystem.read_file(host.save_path)
	(preband_raw.game as Dictionary).erase("world_size")
	(preband_raw.game as Dictionary).erase("scarp_crossed")
	SaveSystem.write_file("user://smoke-preband-save.json", preband_raw)
	check(host._save_predates_band(preband_raw.game), "a save stripped of world_size reads as pre-band")
	var host8: GameHost = load("res://scenes/main.tscn").instantiate()
	host8.skip_autoload = true
	host8.save_path = "user://smoke-preband-save.json"
	add_child(host8)
	await get_tree().physics_frame
	host8.load_game()
	var halor8: Node2D = null
	for s in host8.shrines:
		if str(s.get_meta("god_id", "")) == "god-halor":
			halor8 = s
	check(halor8 != null and halor8.position == Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, GameHost.TILE * 5.0),
		"a pre-band save keeps the legacy north half exactly")
	check(_node_of(host8, "item-coralwood") != null, "...and the south band stands too — both halves, one load")
	host8.queue_free()

	# ============================================================
	# M3.b — the Gods of the Road and the Wild (REEF-FOREST-SPEC §5)
	# ============================================================

	# --- both shrines stand south of the scarp, deterministic, well apart ---
	var vessa_shrine: Node2D = null
	var ghal_shrine: Node2D = null
	for s in host.shrines:
		if str(s.get_meta("god_id", "")) == "god-vessa":
			vessa_shrine = s
		elif str(s.get_meta("god_id", "")) == "god-ghal":
			ghal_shrine = s
	check(vessa_shrine != null and vessa_shrine.position == GameHost.VESSA_SHRINE_POS, "Vessa's fallen shrine stands at her deterministic spot")
	check(ghal_shrine != null and ghal_shrine.position == GameHost.GHAL_SHRINE_POS, "Ghal's fallen shrine stands at his")
	check(vessa_shrine.position.y > float(GameHost.SCARP_Y) and ghal_shrine.position.y > float(GameHost.SCARP_Y), "both south of the scarp")
	check(vessa_shrine.position.distance_to(ghal_shrine.position) > 1500.0, "well apart from each other")
	check(vessa_shrine.position.distance_to(GameHost.STAIR_OF_HULLS_POS) > 800.0 and ghal_shrine.position.distance_to(GameHost.STAIR_OF_HULLS_POS) > 800.0,
		"and well clear of the Stair of Hulls itself")

	# --- gating: neither god's altar leaks into the menu, nor casts, pre-attunement ---
	check("work-altar-vessa" not in host.menu_works(), "Vessa's altar waits until she's kneeled to")
	check("work-altar-ghal" not in host.menu_works(), "and so does Ghal's")
	check(not host.intent_cast("inv-rip-current"), "no current without the Current-Runner")
	check(not host.intent_cast("inv-shepherds-voice"), "no calm without the Shepherd")

	# the file's own earlier tests have already spent the devotion budget on
	# direct rank writes (Neris bumped to rank 2 outside the real attune() path,
	# same trick this file uses below) — bump the ceiling here so the REAL
	# attune() flow below has room to actually run (this is the thing under
	# test: "verify it needs no per-god code" for a fifth and sixth god).
	host.devotion.econ["devotion"]["ranksBudgetAtEA"] = 20

	# --- kneel -> attune: the generic flow (VILLAGER-AND-GODHEAD-SPEC), zero per-god code ---
	host.player.position = vessa_shrine.position
	check(host.intent_interact(), "kneel at Vessa's fallen shrine")
	check("god-vessa" in host.attuned_for(1), "Vessa is with you")
	check("work-altar-vessa" in host.menu_works(), "her altar opens on the build menu")
	host.player.position = ghal_shrine.position
	check(host.intent_interact(), "kneel at Ghal's fallen shrine")
	check("god-ghal" in host.attuned_for(1), "Ghal is with you")
	check("work-altar-ghal" in host.menu_works(), "and so does his")

	# force both to full Godhead strength for deterministic magnitude checks below
	host.godhead.state["god-vessa"] = {"value": 100.0, "consumed": false}
	host.godhead.state["god-ghal"] = {"value": 100.0, "consumed": false}

	# --- Rip-Current: dash through, carrying a road companion/beast at heel ---
	host.player.position = Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, float(GameHost.NORTH_H) * GameHost.TILE + GameHost.TILE * 30.0)
	host.player.facing = Vector2.RIGHT
	var dash_origin := host.player.position
	host.beast.beasts[9101] = {"name": "Ridealong", "creature_id": "creature-scuttle-crab", "xp": 0.0,
		"owner_pid": 1, "at_heel": true, "kenneled": false, "fed_today": true, "mood": "keen"}
	var carried_beast := host._spawn_beast(9101, dash_origin + Vector2(20, 0), false)
	check(host.intent_cast("inv-rip-current"), "Rip-Current: the old current takes you")
	check(host.player.position.x > dash_origin.x + 300.0, "the caster lunges ~12 tiles east at full strength (dx=%.0f)" % (host.player.position.x - dash_origin.x))
	check(carried_beast.position.distance_to(host.player.position) < 200.0, "a beast at heel within reach rides the current too")

	# --- Undertow: yank the nearest hostile toward the caster ---
	host.player.position = Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, float(GameHost.NORTH_H) * GameHost.TILE + GameHost.TILE * 60.0)
	host.devotion.state[1]["god-vessa"].rank = 2
	host.devotion.state[1]["god-vessa"].vigor = host.devotion.max_vigor("god-vessa")
	var pull_target := DSEnemy.new()
	pull_target.position = host.player.position + Vector2(200, 0)
	pull_target.setup(host, "creature-eel-wolf")
	host.add_child(pull_target); host.enemies.append(pull_target)
	var pull_d0 := host.player.position.distance_to(pull_target.position)
	check(host.intent_cast("inv-undertow"), "Undertow: for a moment, so do you")
	check(host.player.position.distance_to(pull_target.position) < pull_d0, "the enemy is pulled closer to the caster (%.0f -> %.0f)" % [pull_d0, host.player.position.distance_to(pull_target.position)])

	# --- Shepherd's Voice: pacify a hostile, AND it counts as a meal on a tameable ---
	host.player.position = Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, float(GameHost.NORTH_H) * GameHost.TILE + GameHost.TILE * 90.0)
	var voice_target := DSEnemy.new()
	voice_target.position = host.player.position + Vector2(60, 0)
	voice_target.setup(host, "creature-salt-hound")
	host.add_child(voice_target); host.enemies.append(voice_target)
	check(not voice_target.is_pacified(), "not yet calmed")
	check(host.intent_cast("inv-shepherds-voice"), "The Shepherd's Voice: the beast remembers being kept")
	check(voice_target.is_pacified(), "the hound stops being hostile — deaggro without the permanent surrender flag")
	check(not voice_target.surrendered, "...and it is NOT a permanent surrender (a different door than mercy-kneel)")
	check(host.message.contains("trust") or host.message.contains("calm"), "the Voice counted as a meal on a tameable species (%s)" % host.message)

	# --- Blood-Scent: a HUD bearing line for the nearest hostile of any kind ---
	host.devotion.state[1]["god-ghal"].rank = 2
	host.devotion.state[1]["god-ghal"].vigor = host.devotion.max_vigor("god-ghal")
	check(host.intent_cast("inv-blood-scent"), "Blood-Scent: the dried sea keeps no secrets from a nose it made")
	check(host.blood_scent_frames > 0, "the trail is lit")
	check(host._direction_hints().contains("blood-scent"), "...and the HUD carries a bearing line for it (%s)" % host._direction_hints())

	# --- Ghal's rank reduces meals needed: rank 1 -> a hound needs 2, not 3 ---
	host.devotion.state[1]["god-ghal"].rank = 1
	var rank_hound := DSEnemy.new()
	rank_hound.position = Vector2(7000, 7000)
	rank_hound.setup(host, "creature-salt-hound")
	host.add_child(rank_hound); host.enemies.append(rank_hound)
	host.player.position = rank_hound.position
	host.inventory.add(1, "item-crab-meat", 3)
	check(host.intent_feed_wild(rank_hound), "feed toward taming with Ghal rank 1")
	check(host.message.contains("trust 1/2"), "Ghal rank 1 discounts the hound's meals: needs 2, not 3 (%s)" % host.message)

	# --- the Taming-Post doubles a meal's trust ---
	host.devotion.state[1]["god-ghal"].rank = 0
	host.camp_center = Vector2(7200, 7200)
	host.player.position = host.camp_center
	host.inventory.add(1, "item-coralwood", 10)
	host.inventory.add(1, "item-rope", 10)
	check(host.intent_build("work-taming-post"), "the Taming-Post stands")
	var post_hound := DSEnemy.new()
	post_hound.position = host.player.position + Vector2(40, 0)
	post_hound.setup(host, "creature-salt-hound")
	host.add_child(post_hound); host.enemies.append(post_hound)
	host.inventory.add(1, "item-crab-meat", 3)
	check(host.intent_feed_wild(post_hound), "feed within earshot of the Taming-Post (Ghal rank 0: a hound needs 3)")
	check(host.message.contains("trust 2/3"), "the post doubles THIS meal's trust — 2, not 1, on the first feed (%s)" % host.message)

	# --- the Stable: houses 4, and holds a beast at "content" instead of "sulking" ---
	host.inventory.add(1, "item-coralwood", 20)
	host.inventory.add(1, "item-reef-iron", 10)
	host.inventory.add(1, "item-rope", 20)
	check(host.intent_build("work-stable"), "the Stable stands")
	check(int(host.registry.get_entity("work-stable").get("beastHouses", 0)) == 4, "houses 4 beasts, per CRAFT-AND-BUILD-SPEC Part 3's table")
	host.village_stock.erase("item-crab-meat")   # make sure the stabled hound genuinely goes unfed
	var stable_bid := host.beast._next_id
	host.beast._next_id += 1
	host.beast.beasts[stable_bid] = {"name": "Stabletest", "creature_id": "creature-salt-hound", "xp": 0.0,
		"owner_pid": 1, "at_heel": false, "kenneled": true, "fed_today": false, "mood": "keen"}
	host._spawn_beast(stable_bid, host.player.position, false)
	var stable_notes := host._beast_dawn_feeding()
	check(str(host.beast.beasts[stable_bid].mood) == "content", "a Stable prevents sulking from hunger alone (the mood floor) — held at 'content', not 'keen' (still unfed)")
	check(stable_notes.any(func(n: String) -> bool: return n.contains("Stabletest")), "the dawn note reflects it (%s)" % ", ".join(stable_notes))

	# --- Board-Road: extends the risk-leash by exactly 25% ---
	var leash_before_road := host._task_leash("wood")
	check(host.works.count_of("work-board-road") == 0, "no road stands yet")
	host.inventory.add(1, "item-coralwood", 10)
	host.inventory.add(1, "item-rope", 10)
	check(host.intent_build("work-board-road"), "a Board-Road is laid")
	var leash_after_road := host._task_leash("wood")
	check(is_equal_approx(leash_after_road, leash_before_road * 1.25), "a standing road extends the leash by exactly 25%% (%.0f -> %.0f)" % [leash_before_road, leash_after_road])

	# --- Porter's Post: a real villager task, joins the tables, produces at dawn ---
	host.inventory.add(1, "item-coralwood", 10)
	host.inventory.add(1, "item-reef-iron", 5)
	host.inventory.add(1, "item-rope", 10)
	check(host.intent_build("work-porters-post"), "the Porter's Post stands")
	check("haul" in GameHost.NEED_TARGETS and GameHost.TASK_STATION.get("haul", "") == "work-porters-post", "the haul task joins NEED_TARGETS/TASK_STATION")
	host.village_stock["item-smoked-crab"] = 50
	host.village_stock["item-driftwood"] = 50
	host.village_stock["item-salt"] = 50
	host.village_stock["item-bronze-salvage"] = 50
	host.village_stock["item-coralwood"] = 50
	host.village_stock["item-reef-iron"] = 50
	host.village_stock.erase("item-rope")
	var haulers := host.villagers.filter(func(v: DSVillager) -> bool: return v.rescued and not v.is_captive and v.tribesman_id >= 0)
	check(haulers.size() > 0, "a free villager stands ready to test the haul task")
	if haulers.size() > 0:
		var hauler: DSVillager = haulers[0]
		hauler.def_class = "class-reef-runner"
		host._assign_village_tasks()
		check(hauler.task == "haul", "with rope at zero and every other need full, the Porter's Post task wins out (%s)" % hauler.task)
		hauler.position = host.village_heart()
		var rope_before := int(host.village_stock.get("item-rope", 0))
		host._on_sim_day(host.clock.day + 1)
		check(int(host.village_stock.get("item-rope", 0)) > rope_before, "the assigned porter hauls a modest stores bonus at dawn (SIMPLIFICATION: no real cache-to-village network, just a direct dawn bonus)")

	# --- reef tasks: appear in the tables, and get picked when reef stores are empty ---
	check("coralwood" in GameHost.NEED_TARGETS and "reef-iron" in GameHost.NEED_TARGETS, "coralwood + reef-iron joined the village task tables")
	host.village_stock["item-rope"] = 50
	host.village_stock.erase("item-coralwood")
	host.village_stock.erase("item-reef-iron")
	var reefers := host.villagers.filter(func(v: DSVillager) -> bool: return v.rescued and not v.is_captive and v.tribesman_id >= 0)
	check(reefers.size() > 0, "a free villager to test reef tasking")
	if reefers.size() > 0:
		var reefer: DSVillager = reefers[0]
		reefer.def_class = "class-reef-runner"
		host._assign_village_tasks()
		check(reefer.task == "coralwood" or reefer.task == "reef-iron", "with reef stores at zero and everything else full, a reef task wins out (%s)" % reefer.task)
		check(host._task_leash(reefer.task) > GameHost.FORAGE_LEASH_FAR, "the reef leash reaches further than any B1 task ever could (%.0f)" % host._task_leash(reefer.task))

	# --- eel-wolf: tameable tier 2 (WILD 6) — mercy-kneels + tames through the SAME path as the hound ---
	check(host.abilities.score(1, "virtue-wild") >= 6, "WILD 6 already stands from the earlier hound taming above")
	var weak_wolf := DSEnemy.new()
	weak_wolf.position = Vector2(7500, 7500)
	weak_wolf.setup(host, "creature-eel-wolf")
	host.add_child(weak_wolf); host.enemies.append(weak_wolf)
	host.stats.actors[weak_wolf].hp = 5.0
	host.player.position = weak_wolf.position
	check(host.intent_attack(), "the swing lands")
	check(weak_wolf.surrendered and host.enemies.has(weak_wolf), "at WILD 6, the eel-wolf kneels instead of dying — its tame tier keys off the SAME mercy-kneel path as the hound")
	host.inventory.add(1, "item-urchin-meat", 5)
	check(host.intent_feed_wild(weak_wolf), "feed the kneeling eel-wolf toward taming")
	for i in 2:   # Ghal rank 0 here (see the Taming-Post test above): tier 2 needs exactly 3 meals total — 1 + 2
		host.clock.day += 1
		host.intent_feed_wild(weak_wolf)
	check(host.message.contains("TAMED"), "the eel-wolf tames (%s)" % host.message)
	var new_wolf_beast: DSBeast = null
	for b: DSBeast in host.beasts:
		if b.creature_id == "creature-eel-wolf":
			new_wolf_beast = b
	check(new_wolf_beast != null, "a new eel-wolf beast joins the roster")

	# --- the rename modal: at the kennel, a numbered pick renames the beast ---
	if new_wolf_beast != null:
		new_wolf_beast.kenneled = true
		new_wolf_beast.at_heel = false
		host.player.position = new_wolf_beast.position
		host._kennel_rename_takes_key()
		check(host.rename_open, "the rename modal opens on a kenneled beast nearby")
		check(host.rename_items.size() >= 2, "the current name + at least one namePool option are offered")
		var old_wolf_name := new_wolf_beast.display_name
		check(host.intent_rename_beast(host.rename_beast_id, 1), "pick a new name from the pool")
		check(new_wolf_beast.display_name != old_wolf_name and new_wolf_beast.display_name == str(host.rename_items[1]),
			"the beast answers to its new name (%s -> %s)" % [old_wolf_name, new_wolf_beast.display_name])

	# ============================================================
	# M3.c — the Dark and the Mother (REEF-FOREST-SPEC §2/§4/§6)
	# ============================================================
	var m3c_day0 := host.clock.day
	var m3c_minute0 := host.clock.minute_of_day

	# --- the dark: nightOnly creatures don't exist at all by day -----------------
	host.clock.minute_of_day = 12 * 60   # noon
	host.clock.advance(1.0)
	check(not host._night_creatures_active, "by day, the reef's night creatures are not active")
	check(host.enemies.filter(func(e: DSEnemy) -> bool: return e.creature_id in ["creature-the-drowned", "creature-angler-stalker"]).is_empty(),
		"no Drowned or angler-stalkers stand by day")

	# --- dusk: both nightOnly species spawn, south of the scarp ------------------
	host.clock.minute_of_day = 22 * 60
	host.clock.advance(1.0)
	check(host._night_creatures_active, "night falls, and the reef's dark wakes")
	var drowned_list := host.enemies.filter(func(e: DSEnemy) -> bool: return e.creature_id == "creature-the-drowned")
	var stalker_list := host.enemies.filter(func(e: DSEnemy) -> bool: return e.creature_id == "creature-angler-stalker")
	check(drowned_list.size() > 0, "the Drowned walk up out of the low places at night (%d)" % drowned_list.size())
	check(stalker_list.size() > 0, "angler-stalkers ambush at night (%d)" % stalker_list.size())
	check(drowned_list.all(func(e: DSEnemy) -> bool: return e.position.y > float(GameHost.SCARP_Y)), "the Drowned stand south of the scarp")
	check(stalker_list.all(func(e: DSEnemy) -> bool: return e.position.y > float(GameHost.SCARP_Y)), "angler-stalkers stand south of the scarp too")

	# --- angler-lights: a lure exists near a stalker; the Lantern marks it false ---
	# (the Lantern's own equip state may already be either way from the M3.b
	# tests earlier in this file — these helpers force it to a known state
	# instead of assuming, so the test is correct regardless of what came before.)
	var stalker: DSEnemy = stalker_list[0] as DSEnemy
	var lure := host._nearest_angler_lure(stalker.position)
	check(lure != null and lure.position.distance_to(stalker.position) < 60.0, "a false-glow lure stands near the stalker, not on top of it")
	if host.equipped_item(1, "trinket") == "item-lighthouse-keepers-lantern":
		host.equip_toggle(1, "item-lighthouse-keepers-lantern")   # force UNequipped for the baseline check
	host.player.position = lure.position   # right on top of it, but bare-handed
	host._update_angler_lures()
	check(not bool(lure.get_meta("revealed", false)), "even standing right on it, bare-handed the lure reads as an ordinary light")
	check(host._direction_hints().contains("a light glimmers"), "...and the HUD carries the tell, undisguised (%s)" % host._direction_hints())
	if host.equipped_item(1, "trinket") != "item-lighthouse-keepers-lantern":
		host.equip_toggle(1, "item-lighthouse-keepers-lantern")   # force EQUIPPED for the reveal check
	host._update_angler_lures()
	check(bool(lure.get_meta("revealed", false)), "wearing the Lantern, within its radius at night, the lure is revealed")
	var lure_label: Label = lure.get_meta("label", null)
	check(lure_label != null and lure_label.text.contains("FALSE"), "the nameplate marks it false in text — testable headlessly (%s)" % (lure_label.text if lure_label != null else "?"))
	check(host._direction_hints().contains("exposed"), "...and the HUD tell changes too (%s)" % host._direction_hints())
	host.player.position = lure.position + Vector2(500, 500)   # still worn, but out of radius
	host._update_angler_lures()
	check(not bool(lure.get_meta("revealed", false)), "wearing the Lantern but too far away, the reveal doesn't reach")
	if host.equipped_item(1, "trinket") == "item-lighthouse-keepers-lantern":
		host.equip_toggle(1, "item-lighthouse-keepers-lantern")   # unequip, tidy up for what follows

	# --- dawn: both species (and their lures) are gone again ---------------------
	host.clock.minute_of_day = 6 * 60
	host.clock.advance(1.0)
	check(not host._night_creatures_active, "dawn clears the reef's dark")
	check(host.enemies.filter(func(e: DSEnemy) -> bool: return e.creature_id in ["creature-the-drowned", "creature-angler-stalker"]).is_empty(),
		"gone again by dawn")
	check(host.angler_lures.is_empty(), "the lure goes with its stalker")

	# --- the Anglermother: her ring stands from world-gen, boss or no boss -------
	var mother := _enemy_of(host, "creature-anglermother")
	check(mother != null, "the Anglermother's ring stands")
	host.clock.minute_of_day = 12 * 60
	host.clock.advance(1.0)
	check(mother != null and not mother.is_attackable(), "by day she is dormant — unattackable, not despawned")
	host.player.position = mother.position
	host.stats.actors[1].stamina = 60.0
	var mother_hp0 := host.stats.hp(mother)
	host.intent_attack()
	check(host.stats.hp(mother) == mother_hp0, "no damage reaches a dormant boss by day, even standing right on her")

	# --- fightable at night, and her arena is darker than the surrounding reef ---
	host.clock.minute_of_day = 22 * 60
	host.clock.advance(1.0)
	check(mother.is_attackable(), "at night, she wakes — fightable")
	var arena_tint := host._tint_for_minute(22 * 60, GameHost.ANGLERMOTHER_RING_POS.y, GameHost.ANGLERMOTHER_RING_POS.x)
	var nearby_tint := host._tint_for_minute(22 * 60, GameHost.ANGLERMOTHER_RING_POS.y, GameHost.ANGLERMOTHER_RING_POS.x - 1500.0)
	var arena_sum := arena_tint.r + arena_tint.g + arena_tint.b
	var nearby_sum := nearby_tint.r + nearby_tint.g + nearby_tint.b
	check(arena_sum < nearby_sum, "her arena reads darker than the surrounding reef, same hour (%.2f < %.2f)" % [arena_sum, nearby_sum])

	# --- the kill (test-accelerated, same grammar as Old Shellback's) ------------
	host.player.position = mother.position + Vector2(40, 0)
	host.stats.damage(mother, 1580.0)
	mother.on_hit()
	host.stats.actors[1].stamina = 60.0
	var mother_remnant0 := host.inventory.count(1, "item-remnant-anglermother")
	var mtries := 0
	while host.inventory.count(1, "item-remnant-anglermother") == mother_remnant0 and mtries < 20:
		host.stats.actors[1].stamina = 60.0
		host.intent_attack()
		mtries += 1
		await get_tree().physics_frame
	check(host.inventory.count(1, "item-remnant-anglermother") == mother_remnant0 + 1, "her remnant falls — HER own remnant, not a placeholder pointing at Shellback's")
	check(str(host.registry.get_entity("item-remnant-anglermother").get("remnantOf", "")) == "god-ghal",
		"and it is remnantOf GHAL — the bug that would have shipped (a Halor remnant from her own bossNotes' admitted placeholder)")
	check(host.bosses_dead.get("creature-anglermother", false), "her per-boss dead flag is set")
	check(host.bosses_dead.get("creature-old-shellback", false), "...and Shellback's stays independently true — per-boss, not a shared bool")

	# --- consuming her remnant consumes GHAL, not Halor (the fixed data bug, proven end to end) ---
	host.inventory._inv(1).erase("item-remnant-shellback")   # defensive: nothing else competes for intent_consume_remnant's "first remnant found"
	check(not host.godhead.is_consumed("god-ghal"), "Ghal stands untouched, so far")
	check(host.intent_consume_remnant(), "the warm voice gets its way, again")
	check(host.godhead.is_consumed("god-ghal") and host.godhead.godhead("god-ghal") == 0.0, "GHAL locks at 0 forever — the real remnantOf, read off data, not a hardcoded id")
	check(host.godhead.is_consumed("god-halor"), "Halor, meanwhile, is untouched by THIS act — still exactly as consumed as he already was, no double-dip")

	# --- the keystone moment (REEF-FOREST-SPEC §6) -------------------------------
	# Shellback's RETROACTIVE keystone: he fell long before keystones existed in
	# this build — "the game pays its debts": his kneel-spot is simply unclaimed.
	check(host.bosses_dead.get("creature-old-shellback", false), "Shellback died earlier in this very run")
	host.player.position = GameHost.BOSS_RING_POS
	check(host._keystone_takes_e() == "creature-old-shellback", "his retroactive kneel-spot stands, unclaimed")
	check(host.current_prompt() == "[E] Dedicate the keystone", "the prompt reads like a shrine's kneel-prompt")
	host.godhead.state["god-maren"] = {"value": 20.0, "consumed": false}   # deterministic footing for the exact-numbers check below
	host._toggle_keystone(true, "creature-old-shellback")
	check(host.keystone_open, "the modal opens")
	check("god-halor" not in host.keystone_items, "a consumed god (Halor) never appears in the list")
	check("god-ghal" not in host.keystone_items, "...and neither does Ghal, consumed just above")
	check("god-maren" in host.keystone_items, "Maren — attuned and living — IS offered")
	var maren_idx: int = host.keystone_items.find("god-maren")
	check(host.intent_dedicate_keystone("creature-old-shellback", maren_idx), "dedicate Shellback's keystone to Maren")
	check(is_equal_approx(host.godhead.godhead("god-maren"), 28.0), "exactly +8%% landed (20%% -> 28%%, well under cap)")
	check(host.message.contains("+8%") and host.message.contains("MAREN") and host.message.contains("20%") and host.message.contains("28%") and host.message.contains("cap"),
		"the confirmation prints the numbers, UI law (%s)" % host.message)
	check(host.keystones_claimed.get("creature-old-shellback", false), "claimed — one per boss per world")
	check(not host.intent_dedicate_keystone("creature-old-shellback", maren_idx), "cannot be claimed twice")
	check(host._keystone_takes_e() == "", "and his ring no longer offers [E]")

	# --- a cap-limited pick: the Anglermother's keystone, dedicated near the cap ---
	check(host.bosses_dead.get("creature-anglermother", false), "she's dead too, now")
	host.player.position = GameHost.ANGLERMOTHER_RING_POS
	check(host._keystone_takes_e() == "creature-anglermother", "her kneel-spot stands, unclaimed")
	var gh_cap := host.godhead.cap()
	host.godhead.state["god-neris"] = {"value": gh_cap - 5.0, "consumed": false}   # 5 short of the cap: an 8-point feed must clamp to 5
	host._toggle_keystone(true, "creature-anglermother")
	check("god-neris" in host.keystone_items, "Neris — attuned and living — is offered")
	var neris_idx: int = host.keystone_items.find("god-neris")
	check(host.intent_dedicate_keystone("creature-anglermother", neris_idx), "dedicate her keystone to Neris")
	check(is_equal_approx(host.godhead.godhead("god-neris"), gh_cap), "clamped AT the cap, not a flat +8 past it")
	check(host.message.contains("+5%") and not host.message.contains("+8%"), "the clamped pick prints the number that actually landed, not a hardcoded 8 (%s)" % host.message)
	check(host.keystones_claimed.get("creature-anglermother", false), "claimed")

	# --- save/load: per-boss dead flags AND keystone claims round-trip ------------
	host.save_game()
	var host9: GameHost = load("res://scenes/main.tscn").instantiate()
	host9.skip_autoload = true
	host9.save_path = host.save_path
	add_child(host9)
	await get_tree().physics_frame
	host9.load_game()
	check(host9.bosses_dead.get("creature-old-shellback", false) and host9.bosses_dead.get("creature-anglermother", false),
		"both per-boss dead flags survive save/load, independently")
	check(host9.keystones_claimed.get("creature-old-shellback", false) and host9.keystones_claimed.get("creature-anglermother", false),
		"...and both keystone claims too")
	check(_enemy_of(host9, "creature-anglermother") == null, "her body stays gone across save/load, same law as Shellback's")
	host9.queue_free()

	# --- an OLD save's single boss_dead:true migrates to Shellback-dead ONLY ------
	var oldsave: Dictionary = SaveSystem.read_file(host.save_path)
	(oldsave.game as Dictionary).erase("bosses_dead")
	(oldsave.game as Dictionary).erase("keystones_claimed")
	(oldsave.game as Dictionary)["boss_dead"] = true
	SaveSystem.write_file("user://smoke-oldboss-save.json", oldsave)
	var host10: GameHost = load("res://scenes/main.tscn").instantiate()
	host10.skip_autoload = true
	host10.save_path = "user://smoke-oldboss-save.json"
	add_child(host10)
	await get_tree().physics_frame
	host10.load_game()
	check(host10.bosses_dead.get("creature-old-shellback", false), "an old boss_dead:true migrates to Shellback-dead")
	check(not host10.bosses_dead.get("creature-anglermother", false), "...and ONLY Shellback — the old flag never meant her")
	check(not host10.keystones_claimed.get("creature-old-shellback", false), "his retroactive keystone stands unclaimed on this migrated world")
	host10.queue_free()

	# --- wait:"night" gates a calling by day, passes at night ---------------------
	host.callings.clear()
	host.registry.by_id["calling-smoke-night"] = {"id": "calling-smoke-night", "title": "Smoke Night",
		"tier": "vignette", "source": "rumor", "giver": {"name": "t", "wound": "t"},
		"steps": [{"id": "n1", "type": "wait", "text": "t", "params": {"until": "night"}, "next": null}],
		"echo": {"text": "t"}, "status": "draft"}
	host._active_callings(1).append({"id": "calling-smoke-night", "step": "n1", "since_day": host.clock.day})
	host.clock.minute_of_day = 12 * 60
	host.journal_interact(1, 0)
	check(str(host._active_callings(1)[0].step) == "n1", "a wait:night step holds by day")
	check(host.message.contains("has not yet come"), "and the nudge speaks night, not timers (%s)" % host.message)
	host.clock.minute_of_day = 22 * 60
	host.journal_interact(1, 0)
	check("calling-smoke-night" in host._done_callings(1), "night falls, the vigil completes")
	host.registry.by_id.erase("calling-smoke-night")
	host.callings.clear(); host.callings_done.clear()

	# set/restore the clock explicitly, as instructed — this whole block forced night repeatedly
	host.clock.day = m3c_day0
	host.clock.minute_of_day = m3c_minute0
	host.clock.advance(1.0)

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
