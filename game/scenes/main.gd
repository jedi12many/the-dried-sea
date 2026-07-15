class_name GameHost
extends Node2D
## The host: owns Registry + all sim systems, builds the placeholder world,
## routes intents. Presentation stays thin — every rule lives in sim/.
## M1 slice: walk, harvest, hand-craft, build, day/night. Placeholder art only.

const TILE := 32
const WORLD := Vector2i(48, 32)
const HARVEST_RANGE := 56.0
const ATTACK_RANGE := 44.0
const ATTACK_DAMAGE := 12.0     # bare hands + salvage; tool scaling at M1-end
const ATTACK_STAMINA := 15.0
const LOCAL_PLAYER := 1

var registry := Registry.new()
var clock := SimClock.new()
var devotion: DevotionSystem
var village: VillageSystem
var works: WorksSystem
var verdict: VerdictSystem
var inventory: InventorySystem
var stats: StatsSystem
var abilities: AbilitiesSystem

# the Six Virtues (character sheet)
var sheet_label: Label
var sheet_back: ColorRect
var sheet_open := false
var consumed_hp_bonus := 0.0       # permanent strength eaten from gods
var cheat_death_used_today := false

var player: DSPlayer
var hud: Label
var hp_bar: ColorRect
var stamina_bar: ColorRect
var vigor_bar: ColorRect
var maren_bar: ColorRect
var boss_bar: ColorRect
var boss_name: Label
var daynight: CanvasModulate
var resource_nodes: Array[Area2D] = []
var enemies: Array[DSEnemy] = []
var _minutes_since_hour := 0

# the soul, playable
const INTERACT_RANGE := 56.0
var shrines: Array[Node2D] = []
var survivor: DSVillager
var chapels: Dictionary = {}          # god_id -> position
var attuned_gods: Array[String] = []
var rites_done_today: Dictionary = {} # god_id -> bool
var petrify_frames := 0
var message := "Something pale stands in the north flats. It looks like it is waiting."
var menu_label: Label
var menu_open := false

# persistence
var save_path := "user://dried-sea-save.json"
var skip_autoload := false        # tests and --fresh runs start clean
var harvested_indices: Array = [] # which resource nodes are gone
var boss_dead := false
var node_defs: Array = []         # deterministic layout: storms respawn from this

# the great storm (every 4th day; Maren's country)
const STORM_GLASS_IDX_BASE := 1000  # ephemeral nodes: never persisted
var storm_flash := 0.0

# STYLE-BIBLE salt-shallows palette (placeholder blocks, right colors)
const ITEM_COLORS := {
	"item-driftwood": Color("a08768"), "item-wreck-timber": Color("6e5138"),
	"item-ship-cloth": Color("d9d2bf"), "item-salt": Color("f2efe8"),
	"item-bronze-salvage": Color("b87333"), "item-rope": Color("8a7a5c"),
}

func _ready() -> void:
	_setup_input()
	if not registry.load_all():
		push_error("registry failed: %s" % ", ".join(registry.load_errors))
		get_tree().quit(1)
		return
	devotion = DevotionSystem.new(registry)
	village = VillageSystem.new(registry)
	works = WorksSystem.new(registry, devotion)
	verdict = VerdictSystem.new(registry)
	inventory = InventorySystem.new(registry)
	stats = StatsSystem.new()
	stats.register(LOCAL_PLAYER, 60.0, 60.0)   # unfed floor — food raises the ceiling
	abilities = AbilitiesSystem.new(registry)
	abilities.earn(LOCAL_PLAYER, 6)            # the flats have already tempered you a little
	abilities.changed.connect(func(_p: int) -> void: _recompute_vitals())
	devotion.ledger_event.connect(func(p: int, l: String, a: float, n: String) -> void: verdict.record(p, l, a, n, clock.day))
	village.ledger_event.connect(func(l: String, a: float, n: String) -> void: verdict.record(LOCAL_PLAYER, l, a, n, clock.day))

	_build_ground()
	_spawn_resource_nodes()
	player = DSPlayer.new()
	player.position = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
	add_child(player)
	_spawn_enemies()
	_spawn_shrines()
	_spawn_survivor()
	clock.sim_day.connect(_on_sim_day)
	daynight = CanvasModulate.new()
	add_child(daynight)
	_build_hud()
	clock.sim_minute.connect(_on_sim_minute)
	_refresh_hud()

	if "--fresh" in OS.get_cmdline_user_args():
		skip_autoload = true
	if not skip_autoload and FileAccess.file_exists(save_path):
		load_game()
	if "--screenshot-sheet" in OS.get_cmdline_user_args():
		abilities.earn(LOCAL_PLAYER, 6)
		for i in 4:
			abilities.allocate(LOCAL_PLAYER, "virtue-grit")
		for i in 3:
			abilities.allocate(LOCAL_PLAYER, "virtue-hunger")
		_toggle_sheet(true)
		_screenshot_and_quit()
	elif "--screenshot-boss" in OS.get_cmdline_user_args():
		player.position = Vector2(TILE * 9.0, TILE * 7.0)
		_screenshot_and_quit()
	elif "--screenshot" in OS.get_cmdline_user_args():
		_screenshot_and_quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not skip_autoload:
		save_game()

## --- persistence: the flats remember -------------------------------------------
func save_game() -> void:
	var s := SaveSystem.to_save(clock, devotion, village, works, verdict)
	s["game"] = {
		"inventory": inventory.inventories.duplicate(true),
		"player_stats": stats.actors.get(LOCAL_PLAYER, {}).duplicate(true),
		"player_pos": [player.position.x, player.position.y],
		"attuned_gods": attuned_gods.duplicate(),
		"chapels": _chapels_to_dict(),
		"rites_done_today": rites_done_today.duplicate(),
		"harvested_indices": harvested_indices.duplicate(),
		"boss_dead": boss_dead,
		"abilities": abilities.state.duplicate(true),
		"consumed_hp_bonus": consumed_hp_bonus,
		"cheat_death_used_today": cheat_death_used_today,
		"survivor": {"rescued": survivor.rescued if survivor != null else false,
			"tribesman_id": survivor.tribesman_id if survivor != null else -1,
			"pos": [survivor.position.x, survivor.position.y] if survivor != null else [0, 0]},
		"message": message,
	}
	SaveSystem.write_file(save_path, s)

func load_game() -> void:
	var s := SaveSystem.read_file(save_path)
	if s.is_empty():
		return
	SaveSystem.apply(s, clock, devotion, village, works, verdict)
	var g: Dictionary = s.get("game", {})
	inventory.inventories = SaveSystem._int_keys(g.get("inventory", {}))
	if g.has("player_stats"):
		stats.actors[LOCAL_PLAYER] = g.player_stats
	var pp: Array = g.get("player_pos", [WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0])
	player.position = Vector2(float(pp[0]), float(pp[1]))
	attuned_gods.assign(g.get("attuned_gods", []))
	rites_done_today = g.get("rites_done_today", {})
	message = str(g.get("message", "The flats are as you left them."))
	# world state: remove harvested nodes, rebuild work visuals, restore the boss & Anna
	# (JSON floats -> ints: Array.has is TYPE-STRICT — 40 in [40.0] is false)
	harvested_indices = (g.get("harvested_indices", []) as Array).map(func(v: Variant) -> int: return int(v))
	for node in resource_nodes.duplicate():
		if int(node.get_meta("idx", -1)) in harvested_indices:
			resource_nodes.erase(node)
			node.queue_free()
	chapels.clear()
	var chapel_dict: Dictionary = g.get("chapels", {})
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		_spawn_work_visual(str(inst.work_id), Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))), chapel_dict)
	boss_dead = bool(g.get("boss_dead", false))
	if g.has("abilities"):
		abilities.state = SaveSystem._int_keys(g.get("abilities", {}))
	else:
		# pre-Tally save: back-pay everything the flats already owe this player
		var back_pay := 6 + clock.day * 2 + (2 if boss_dead else 0) + attuned_gods.size() \
			+ (1 if bool(g.get("survivor", {}).get("rescued", false)) else 0)
		abilities.state[LOCAL_PLAYER] = {"earned": back_pay, "alloc": {}}
		message += "\nThe flats have been keeping count: %d TEMPER owed. [T] to spend it." % back_pay
	consumed_hp_bonus = float(g.get("consumed_hp_bonus", 0.0))
	cheat_death_used_today = bool(g.get("cheat_death_used_today", false))
	_recompute_vitals()
	if boss_dead:
		for e in enemies.duplicate():
			if is_instance_valid(e) and e.is_boss:
				stats.unregister(e)
				enemies.erase(e)
				e.queue_free()
	var sv: Dictionary = g.get("survivor", {})
	if bool(sv.get("rescued", false)) and survivor != null:
		survivor.rescued = true
		survivor.tribesman_id = int(sv.get("tribesman_id", -1))
		survivor.set_label_name()
		var sp: Array = sv.get("pos", [0, 0])
		survivor.position = Vector2(float(sp[0]), float(sp[1]))
	_refresh_hud()

## Where the first instance of a work stands (villager duty posts).
func work_pos(work_id: String) -> Vector2:
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		if str(inst.work_id) == work_id:
			return Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
	return Vector2.INF

func _chapels_to_dict() -> Dictionary:
	var out := {}
	for god_id: String in chapels:
		out[god_id] = [chapels[god_id].x, chapels[god_id].y]
	return out

func _physics_process(delta: float) -> void:
	clock.advance(delta)
	stats.tick(delta)
	if petrify_frames > 0:
		petrify_frames -= 1
		if petrify_frames == 0:
			player.modulate = Color.WHITE
			message = "The salt lets you go. Halor's strength is spent — worship gives it back."
			_refresh_hud()
	if storm_flash > 0.0:
		storm_flash = maxf(storm_flash - delta * 2.0, 0.0)
		daynight.color = daynight.color.lerp(Color(1.6, 1.6, 1.7), storm_flash)
	_update_prompt()
	_update_boss_bar()
	_refresh_bars()

## The big red bar appears when you walk into a boss's world.
func _update_boss_bar() -> void:
	if boss_bar == null:
		return
	var near_boss: DSEnemy = null
	for e in enemies:
		if is_instance_valid(e) and e.is_boss and player.position.distance_to(e.position) < 420.0:
			near_boss = e
			break
	var show := near_boss != null
	boss_bar.visible = show
	(boss_bar.get_meta("back") as ColorRect).visible = show
	boss_name.visible = show
	if show:
		var creature := registry.get_entity(near_boss.creature_id)
		boss_name.text = str(creature.name)
		var max_hp := float(creature.get("stats", {}).get("hp", 100))
		boss_bar.size.x = 396.0 * clampf(stats.hp(near_boss) / max_hp, 0.0, 1.0)

## The floating [E] prompt above the survivor's head — mirrors intent_interact's priority.
func _update_prompt() -> void:
	if player == null or player.prompt == null:
		return
	player.prompt.text = current_prompt()

func current_prompt() -> String:
	for s in shrines:
		if player.position.distance_to(s.position) < interact_range() and s.get_meta("god_id") not in attuned_gods:
			return "[E] Kneel"
	if survivor != null and not survivor.rescued and player.position.distance_to(survivor.position) < interact_range():
		return "[E] Rescue her"
	for god_id: String in chapels:
		if player.position.distance_to(chapels[god_id]) < interact_range():
			if _carrying_remnant():
				return "[E] Enshrine the remnant"
			return "[E] Hold the rite" if not rites_done_today.get(god_id, false) else "(rite already held today)"
	var best := harvest_range()
	var best_item := ""
	for node in resource_nodes:
		if is_instance_valid(node) and player.position.distance_to(node.position) < best:
			best = player.position.distance_to(node.position)
			best_item = str(registry.get_entity(node.get_meta("item_id")).get("name", ""))
	if best_item != "":
		return "[E] Gather %s" % best_item
	for e in enemies:
		if is_instance_valid(e) and player.position.distance_to(e.position) < ATTACK_RANGE:
			return "[SPACE] Attack"
	return ""

func _unhandled_input(event: InputEvent) -> void:
	if sheet_open and event is InputEventKey and event.pressed:
		var skey := (event as InputEventKey).physical_keycode
		if skey >= KEY_1 and skey <= KEY_6:
			var virtues := registry.all_of("virtue")
			var virtue_id := str(virtues[int(skey - KEY_1)].id)
			if (event as InputEventKey).shift_pressed:
				abilities.deallocate(LOCAL_PLAYER, virtue_id)
			else:
				abilities.allocate(LOCAL_PLAYER, virtue_id)
			_toggle_sheet(true)
			return
		if skey == KEY_ESCAPE or skey == KEY_T:
			_toggle_sheet(false)
			return
	if menu_open and event is InputEventKey and event.pressed:
		var key := (event as InputEventKey).physical_keycode
		if key >= KEY_1 and key <= KEY_9:
			var idx := int(key - KEY_1)
			var options := menu_works()
			if idx < options.size():
				intent_build(str(options[idx]))
			_toggle_build_menu(false)
			return
		if key == KEY_ESCAPE or key == KEY_B:
			_toggle_build_menu(false)
			return
	if event.is_action_pressed("interact"):
		intent_interact()
	elif event.is_action_pressed("craft"):
		intent_craft_first()
	elif event.is_action_pressed("build"):
		_toggle_build_menu(not menu_open)
	elif event.is_action_pressed("eat"):
		intent_eat()
	elif event.is_action_pressed("attack"):
		intent_attack()
	elif event.is_action_pressed("cast"):
		intent_cast("inv-pillar-of-salt")
	elif event.is_action_pressed("cast_2"):
		intent_cast("inv-call-squall")
	elif event.is_action_pressed("consume"):
		intent_consume_remnant()
	elif event.is_action_pressed("sheet"):
		_toggle_sheet(not sheet_open)
	elif event.is_action_pressed("save"):
		save_game()
		message = "The flats will remember. (saved)"
		_refresh_hud()

## --- intents (the only door into the sim from presentation) --------------------
## E is contextual: kneel at a shrine, rescue the stranded, hold a rite, else harvest.
func interact_range() -> float:
	return INTERACT_RANGE + abilities.mod_add(LOCAL_PLAYER, "interact-range")

func harvest_range() -> float:
	return HARVEST_RANGE + abilities.mod_add(LOCAL_PLAYER, "interact-range")

func intent_interact() -> bool:
	for s in shrines:
		var god_id: String = s.get_meta("god_id")
		if player.position.distance_to(s.position) < interact_range() and god_id not in attuned_gods:
			return intent_kneel(god_id)
	if survivor != null and not survivor.rescued and player.position.distance_to(survivor.position) < interact_range():
		return intent_rescue()
	for god_id: String in chapels:
		if player.position.distance_to(chapels[god_id]) < interact_range():
			if _carrying_remnant():
				return intent_enshrine(god_id)
			return intent_rite(god_id)
	return intent_harvest()

func _carrying_remnant() -> bool:
	for item_id: String in inventory._inv(LOCAL_PLAYER).keys():
		if registry.get_entity(item_id).get("category", "") == "remnant":
			return true
	return false

const KNEEL_HINTS := {
	"god-halor": "[Q] Pillar of Salt, when the pinch comes.",
	"god-maren": "[R] Call the Squall, when they crowd you.",
}

func intent_kneel(god_id: String) -> bool:
	if not devotion.attune(LOCAL_PLAYER, god_id):
		return false
	attuned_gods.append(god_id)
	var god := registry.get_entity(god_id)
	message = "You kneel at the fallen shrine. %s: '%s'\n%s is with you — %s Their strength is not endless." % [
		str(god.voice.tone).split(";")[0], str(god.voice.sampleLine),
		str(god.name).to_upper(), str(KNEEL_HINTS.get(god_id, ""))]
	if god_id == "god-maren":
		inventory.add(LOCAL_PLAYER, "item-harpoon-verse", 1)
		message += "\nTucked in the shrine-stones: a VERSE OF THE HARPOON-SONG. Whalers say there are three."
	abilities.earn(LOCAL_PLAYER, 1)   # kneeling to a god tempers you
	_toggle_build_menu(false)
	_refresh_hud()
	return true

## Cast an invocation and hand its data-defined effects to the executor.
func intent_cast(invocation_id: String = "inv-pillar-of-salt") -> bool:
	var inv: Dictionary = devotion.cast(LOCAL_PLAYER, invocation_id)
	if inv.is_empty():
		var found := devotion._find_invocation(invocation_id)
		if not found.is_empty() and found.god_id in attuned_gods:
			message = "%s has nothing left to give. Build them a chapel; hold a rite." % str(registry.get_entity(found.god_id).name)
			_refresh_hud()
		return false
	for effect: Dictionary in inv.get("effects", []):
		_apply_effect(effect)
	# cost relief: storms make Maren generous; Squall-Born makes her yours
	var found2 := devotion._find_invocation(invocation_id)
	if found2.get("god_id", "") == "god-maren":
		var relief := 0.0
		if is_storm_day():
			relief += 0.5
		if invocation_id == "inv-call-squall":
			relief += 1.0 - abilities.mod_mult(LOCAL_PLAYER, "squall-cost-mult")
		if relief > 0.0:
			devotion._restore(LOCAL_PLAYER, "god-maren",
				float(found2.inv.vigorCost) * devotion.max_vigor("god-maren") * minf(relief, 0.9))
	message = str(inv.text)
	_refresh_hud()
	return true

## The effect executor: data-defined invocation effects become world changes.
func _apply_effect(effect: Dictionary) -> void:
	match str(effect.get("type", "")):
		"petrify-invulnerable":
			petrify_frames = int(float(effect.get("duration", 6)) * 60.0 * abilities.mod_mult(LOCAL_PLAYER, "petrify-mult"))
			player.modulate = Color("cfd0ce")
		"aoe-knockdown":
			var radius := float(effect.get("radius", 8)) * TILE
			for e in enemies.duplicate():
				if is_instance_valid(e) and player.position.distance_to(e.position) <= radius:
					e.stun(2.5)
		"lightning-strikes":
			var strikes := int(effect.get("magnitude", 3))
			var radius := float(effect.get("radius", 8)) * TILE
			var in_range := enemies.filter(func(e: DSEnemy) -> bool:
				return is_instance_valid(e) and player.position.distance_to(e.position) <= radius)
			in_range.sort_custom(func(a: DSEnemy, b: DSEnemy) -> bool:
				return player.position.distance_to(a.position) < player.position.distance_to(b.position))
			for i in mini(strikes, in_range.size()):
				var target: DSEnemy = in_range[i]
				_flash_bolt(target.position)
				target.on_hit()
				if stats.damage(target, 25.0):
					_on_enemy_killed(target)
		_:
			pass  # unimplemented effect types are silently inert at this stage

func _flash_bolt(at: Vector2) -> void:
	var bolt := ColorRect.new()
	bolt.size = Vector2(3, 40)
	bolt.position = at + Vector2(-1, -40)
	bolt.color = Color("c9a648")
	add_child(bolt)
	get_tree().create_timer(0.25).timeout.connect(bolt.queue_free)

func intent_rescue() -> bool:
	survivor.rescue()
	abilities.earn(LOCAL_PLAYER, 1)   # saving someone tempers you differently
	message = "%s, of the drowned coast towns. She follows you home — give her a hearth and she'll keep it.\nShe is devout: her prayers feed Halor a little every day." % survivor.display_name
	_check_village_keys()  # if her need already stands built, she blooms on arrival
	_refresh_hud()
	return true

func intent_rite(god_id: String) -> bool:
	if rites_done_today.get(god_id, false):
		message = "The rite is held once a day. The gods keep slow time."
		_refresh_hud()
		return false
	rites_done_today[god_id] = true
	devotion.rite_day(LOCAL_PLAYER, god_id, "chapel", 1)
	message = "You lead the rite at %s's chapel. The shrine-light steadies a little." % str(registry.get_entity(god_id).name)
	_refresh_hud()
	return true

func intent_harvest() -> bool:
	var nearest: Area2D = null
	var best := harvest_range()
	for node in resource_nodes:
		if not is_instance_valid(node):
			continue
		var d := player.position.distance_to(node.position)
		if d < best:
			best = d
			nearest = node
	if nearest == null:
		return false
	inventory.add(LOCAL_PLAYER, nearest.get_meta("item_id"),
		int(nearest.get_meta("qty")) + int(abilities.mod_add(LOCAL_PLAYER, "harvest-bonus-qty")))
	if str(nearest.get_meta("item_id")) == "item-storm-glass" and inventory.count(LOCAL_PLAYER, "item-harpoon-verse") == 2:
		inventory.add(LOCAL_PLAYER, "item-harpoon-verse", 1)
		message = "Folded inside the storm-glass, impossibly: the LAST VERSE of the harpoon-song.\nYou know the whole making now. It wants a rite at a chapel — bronze, storm-glass, and good timber."
	harvested_indices.append(int(nearest.get_meta("idx", -1)))
	resource_nodes.erase(nearest)
	nearest.queue_free()
	_refresh_hud()
	return true

## F eats the first food in your pack. Two slots; a full belly refuses.
func intent_eat() -> bool:
	for item_id: String in inventory._inv(LOCAL_PLAYER).keys():
		var item := registry.get_entity(item_id)
		var fstats: Dictionary = item.get("stats", {})
		if not fstats.has("foodHp"):
			continue
		if not stats.eat(LOCAL_PLAYER, float(fstats.foodHp), float(fstats.foodStamina), float(fstats.get("foodMinutes", 8)) * 60.0):
			message = "You're full. Come back to the rest of it when this wears off."
			_refresh_hud()
			return false
		inventory.pay(LOCAL_PLAYER, [{"itemId": item_id, "qty": 1}])
		message = "%s. You feel it in your arms — food is preparation here, not maintenance." % str(item.name)
		_refresh_hud()
		return true
	message = "Nothing to eat. The crabs are mostly harmless and excellent soup."
	_refresh_hud()
	return false

## The build menu: what you can raise, grouped by whose it is. A god's works
## appear once you're attuned — recipes arrive with faith.
func menu_works() -> Array:
	var order := ["neutral", "god-halor", "god-maren", "god-neris", "god-vessa", "god-ghal"]
	var visible_sets := ["neutral"]
	visible_sets.append_array(attuned_gods)
	var out: Array = []
	for god_id: String in order:
		if god_id not in visible_sets:
			continue
		for work: Dictionary in registry.all_of("work"):
			if work.get("godId", "") == god_id and not work.get("grim", false):
				out.append(str(work.id))
	return out

func _toggle_build_menu(open: bool) -> void:
	menu_open = open
	if menu_label == null:
		return
	menu_label.visible = open
	if not open:
		return
	var lines := ["BUILD — press a number, [B] to close"]
	var options := menu_works()
	var last_god := ""
	for i in options.size():
		var work := registry.get_entity(str(options[i]))
		var god_id: String = work.get("godId", "neutral")
		if god_id != last_god:
			last_god = god_id
			lines.append("· %s ·" % ("salvage" if god_id == "neutral" else str(registry.get_entity(god_id).name) + "'s works"))
		var cost_bits: Array[String] = []
		for c: Dictionary in work.get("buildCost", []):
			cost_bits.append("%s×%d" % [str(registry.get_entity(str(c.itemId)).get("name", c.itemId)), int(c.qty)])
		var afford := inventory.can_afford(LOCAL_PLAYER, work.get("buildCost", []))
		lines.append("%d. %s%s — %s" % [i + 1, str(work.name), "" if afford else "  (can't afford)", ", ".join(cost_bits)])
	if attuned_gods.size() < 2:
		lines.append("· more works open when you kneel at new shrines ·")
	menu_label.text = "\n".join(lines)

func intent_craft(recipe_id: String) -> bool:
	var ok := inventory.craft(LOCAL_PLAYER, recipe_id, works)
	if ok:
		var recipe := registry.get_entity(recipe_id)
		if recipe.get("track", "") == "legend":
			var item := registry.get_entity(str(recipe.output.itemId))
			message = "THE RITE IS DONE. %s is yours.\n%s" % [str(item.name).to_upper(), str(item.get("legend", {}).get("history", ""))]
	_refresh_hud()
	return ok

func intent_craft_first() -> void:
	# a known legend always takes precedence — you don't accidentally make rope instead
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "legend" and intent_craft(str(recipe.id)):
			return
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "tree" and intent_craft(str(recipe.id)):
			return

## Swing at the nearest enemy in arc range. Costs stamina — tired arms miss nothing, they just can't.
func intent_attack() -> bool:
	var target: DSEnemy = null
	var best := ATTACK_RANGE
	for e in enemies:
		if not is_instance_valid(e):
			continue
		var d := player.position.distance_to(e.position)
		if d < best:
			best = d
			target = e
	if target == null:
		return false
	if not stats.spend_stamina(LOCAL_PLAYER, attack_stamina_cost()):
		message = "Too winded to swing. Breath comes back — or food raises the ceiling."
		_refresh_hud()
		return false
	_flash_swing(target.position)
	target.on_hit()
	if inventory.count(LOCAL_PLAYER, "item-marens-own-harpoon") > 0 \
			or abilities.talent_active(LOCAL_PLAYER, "talent-bolt-marked"):
		_flash_bolt(target.position)   # strike true and the bolt comes down on your mark
	if stats.damage(target, attack_damage()):
		_on_enemy_killed(target)
	return true

func attack_damage() -> float:
	# the legend in your hands changes what your hands can do — and so do your virtues
	var dmg := 26.0 if inventory.count(LOCAL_PLAYER, "item-marens-own-harpoon") > 0 else ATTACK_DAMAGE
	dmg = abilities.mod_add(LOCAL_PLAYER, "melee-damage", dmg)
	dmg = abilities.mod_add(LOCAL_PLAYER, "bolt-on-swing", dmg)
	return dmg

func attack_stamina_cost() -> float:
	return maxf(ATTACK_STAMINA - abilities.mod_add(LOCAL_PLAYER, "attack-cost-reduction"), 5.0)

## Recompute everything the virtues touch on the body. Called on every
## allocation change, load, and remnant consumption.
func _recompute_vitals() -> void:
	var a: Dictionary = stats.actors.get(LOCAL_PLAYER, {})
	if a.is_empty():
		return
	a.base_hp = 60.0 + consumed_hp_bonus + abilities.mod_add(LOCAL_PLAYER, "base-hp")
	a.food_slots = StatsSystem.FOOD_SLOTS + int(abilities.mod_add(LOCAL_PLAYER, "food-slots"))
	a.regen_mult = abilities.mod_mult(LOCAL_PLAYER, "stamina-regen-mult")
	a.eat_mult = abilities.mod_mult(LOCAL_PLAYER, "eat-restore-mult")
	a.hp = minf(float(a.hp), stats.max_hp(LOCAL_PLAYER))
	_refresh_bars()
	if sheet_open:
		_toggle_sheet(true)

## A short slash flash toward the target — SPACE should feel like something.
func _flash_swing(toward: Vector2) -> void:
	var dir := (toward - player.position).normalized()
	var slash := ColorRect.new()
	slash.size = Vector2(22, 4)
	slash.rotation = dir.angle()
	slash.position = player.position + dir * 20.0
	slash.color = Color("f7f5ee")
	add_child(slash)
	get_tree().create_timer(0.1).timeout.connect(slash.queue_free)

func damage_player(amount: float) -> void:
	if petrify_frames > 0:
		return  # the salt holds
	# The Returning: what goes out comes back — once a day, even you
	if abilities.talent_active(LOCAL_PLAYER, "talent-the-returning") and not cheat_death_used_today \
			and stats.hp(LOCAL_PLAYER) - amount <= 0.0:
		cheat_death_used_today = true
		stats.actors[LOCAL_PLAYER].hp = 1.0
		message = "The tide takes you out — and brings you back. Once a day, Neris keeps that promise."
		_refresh_hud()
		_refresh_bars()
		return
	if stats.damage(LOCAL_PLAYER, amount):
		# Death penalty is an open design question (GAME-SPEC); M1 placeholder:
		# wake at the village center, hurt pride only.
		player.position = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
		stats.heal_full(LOCAL_PLAYER)
	_refresh_bars()

func _on_enemy_killed(enemy: DSEnemy) -> void:
	var creature := registry.get_entity(enemy.creature_id)
	for drop: Dictionary in creature.get("drops", []):
		var qty := int(drop.qty)
		if enemy.creature_id == "creature-scuttle-crab" and str(drop.itemId) == "item-crab-meat":
			qty += int(abilities.mod_add(LOCAL_PLAYER, "crab-bonus-drop"))  # the respectful way
		inventory.add(LOCAL_PLAYER, str(drop.itemId), qty)
	if enemy.is_boss:
		boss_dead = true
		abilities.earn(LOCAL_PLAYER, 2)   # nothing tempers like a king
		# the wreck-ring opens: his hoard becomes salvage ground
		var hoard_rng := RandomNumberGenerator.new()
		hoard_rng.seed = 77
		for i in 6:
			var item := "item-bronze-salvage" if i % 2 == 0 else "item-wreck-timber"
			var pos := enemy.spawn_pos + Vector2(hoard_rng.randf_range(-120, 120), hoard_rng.randf_range(-100, 100))
			var def_idx := node_defs.size()
			node_defs.append({"item_id": item, "pos": pos, "idx": def_idx})
			_spawn_one_node(item, pos, def_idx)
	var remnant_id: String = creature.get("remnantItemId", "")
	if remnant_id != "":
		inventory.add(LOCAL_PLAYER, remnant_id, 1)
		message = "%s falls — the oldest sailor left, out of his depth at last. His wreck-ring is yours to salvage.\nSomething divine remains in him. A warm, reasonable voice: 'They'd ask you to feed it to them. I only ever ask you to eat.'\n[E] at a chapel to ENSHRINE it — or [X] to consume it. Some doors only open once." % str(creature.name)
	stats.unregister(enemy)
	enemies.erase(enemy)
	enemy.queue_free()
	_refresh_hud()

## The Verdict, in your hands: consume a remnant for permanent strength —
## and the god it belonged to dims, for everyone, forever.
func intent_consume_remnant() -> bool:
	for item_id: String in inventory._inv(LOCAL_PLAYER).keys():
		var item := registry.get_entity(item_id)
		if item.get("category", "") != "remnant":
			continue
		var god_id: String = item.get("remnantOf", "god-halor")
		inventory.pay(LOCAL_PLAYER, [{"itemId": item_id, "qty": 1}])
		consumed_hp_bonus += 15.0 + abilities.mod_add(LOCAL_PLAYER, "consume-bonus-hp")
		_recompute_vitals()
		verdict.remnant_consume(LOCAL_PLAYER, god_id)
		message = "You eat what was left of a god's strength. You feel MAGNIFICENT.\nSomewhere, %s grows quieter — for everyone, forever. The warm voice sounds pleased." % str(registry.get_entity(god_id).name)
		_refresh_hud()
		return true
	return false

func intent_enshrine(god_id_of_chapel: String) -> bool:
	for item_id: String in inventory._inv(LOCAL_PLAYER).keys():
		var item := registry.get_entity(item_id)
		if item.get("category", "") != "remnant":
			continue
		var god_id: String = item.get("remnantOf", god_id_of_chapel)
		inventory.pay(LOCAL_PLAYER, [{"itemId": item_id, "qty": 1}])
		verdict.remnant_enshrine(LOCAL_PLAYER, god_id)
		message = "You set the remnant in the chapel-stone. %s steadies — the whole world's worth of them.\nThe warm voice says nothing at all." % str(registry.get_entity(god_id).name)
		_refresh_hud()
		return true
	return false

func intent_build(work_id: String) -> bool:
	var work := registry.get_entity(work_id)
	if work.is_empty() or not inventory.pay(LOCAL_PLAYER, work.get("buildCost", [])):
		_refresh_hud()
		return false
	var pos := player.position + Vector2(40, 0)
	works.place(work_id, LOCAL_PLAYER, pos)
	if work_id == "work-chapel":
		# dedicate to the first attuned god who lacks one
		for god_id: String in attuned_gods:
			if not chapels.has(god_id):
				message = "A chapel to %s, raised from wreck-timber. Hold rites here [E] — their strength returns through worship." % str(registry.get_entity(god_id).name)
				break
	_spawn_work_visual(work_id, pos, {})
	_check_village_keys()
	_refresh_hud()
	return true

## --- the sheet: what the sea left in you ------------------------------------------
func _toggle_sheet(open: bool) -> void:
	sheet_open = open
	if sheet_label == null:
		return
	sheet_label.visible = open
	sheet_back.visible = open
	if not open:
		return
	var lines := ["THE TALLY — what the sea left in you",
		"Temper: %d unspent (of %d)   [1-6] +1  [SHIFT+1-6] take back  [T] close" % [
			abilities.available(LOCAL_PLAYER), abilities.earned(LOCAL_PLAYER)]]
	var virtues := registry.all_of("virtue")
	for i in virtues.size():
		var v: Dictionary = virtues[i]
		var s := abilities.score(LOCAL_PLAYER, str(v.id))
		var pips := ""
		for p in AbilitiesSystem.VIRTUE_CAP:
			pips += "●" if p < s else "·"
		lines.append("%d. %-8s %s %2d   (%s)" % [i + 1, str(v.name), pips, s, str(registry.get_entity(str(v.godId)).name)])
		for talent: Dictionary in v.talents:
			var lit := s >= int(talent.threshold)
			lines.append("    %s %s (%d) — %s" % ["■" if lit else "□", str(talent.name), int(talent.threshold), str(talent.text)])
	sheet_label.text = "\n".join(lines)

## Shared by building and loading: the physical body of a placed work.
## chapel_hint maps god_id -> [x, y] from a save; empty when building live.
func _spawn_work_visual(work_id: String, pos: Vector2, chapel_hint: Dictionary) -> void:
	var work := registry.get_entity(work_id)
	var work_sprites := {
		"work-workbench": "workbench", "work-chapel": "chapel", "work-smokehouse": "smokehouse",
		"work-hearth": "hearth", "work-driftwood-wall": "wall",
	}
	var fallback := Color("6e5138") if not work.get("grim", false) else Color("5b3a6e")
	if work_id == "work-chapel":
		fallback = Color("f2efe8")
	var visual := SpriteKit.sprite(work_sprites.get(work_id, "none"),
		Vector2(28, 28) if work_id != "work-chapel" else Vector2(40, 48), fallback)
	visual.position = pos
	if work_id == "work-chapel":
		var god_id := ""
		if chapel_hint.is_empty():
			for g: String in attuned_gods:
				if not chapels.has(g):
					god_id = g
					break
		else:
			for g: Variant in chapel_hint:
				var hp: Array = chapel_hint[g]
				if Vector2(float(hp[0]), float(hp[1])).distance_to(pos) < 4.0:
					god_id = str(g)
					break
		if god_id != "":
			chapels[god_id] = pos
			if god_id == "god-maren":
				visual.modulate = Color(0.82, 0.88, 1.0)
			visual.add_child(_world_label("chapel of %s" % str(registry.get_entity(god_id).name), Vector2(0, 30)))
	add_child(visual)

## Some works ARE what a villager needed (their Key). The chapel gives the
## devout their shrine; the hearth gives the storyteller their fire.
const WORK_KEYS := {"work-chapel": "shrine-access", "work-hearth": "audience-kept"}

func _check_village_keys() -> void:
	for work_id: String in WORK_KEYS:
		if works.count_of(work_id) == 0:
			continue
		for id: int in village.tribesmen:
			var rec: Dictionary = village.tribesmen[id]
			if rec.key == WORK_KEYS[work_id] and not rec.key_met:
				village.meet_key(id)
				message = "%s has what they needed — watch them work now." % str(rec.name)
				if survivor != null and survivor.tribesman_id == id:
					survivor.modulate = Color(1.12, 1.04, 0.92)  # bloomed: a touch warmer

## --- world (placeholder) ---------------------------------------------------------
func _build_ground() -> void:
	var ground_tex := SpriteKit.texture("ground")
	if ground_tex != null:
		var ground := TextureRect.new()
		ground.texture = ground_tex
		ground.stretch_mode = TextureRect.STRETCH_TILE
		ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ground.size = Vector2(WORLD.x * TILE, WORLD.y * TILE)
		ground.z_index = -10
		add_child(ground)
	else:
		var flat := ColorRect.new()
		flat.size = Vector2(WORLD.x * TILE, WORLD.y * TILE)
		flat.color = Color("e8e2d4")   # blinding flats, high-key
		flat.z_index = -10
		add_child(flat)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:  # salt pillars + brine pools: the flats aren't flat
		var pillar := rng.randf() < 0.5
		var deco := SpriteKit.sprite("salt_pillar" if pillar else "brine_pool",
			Vector2(14, 22) if pillar else Vector2(18, 8),
			Color("f7f5ee") if pillar else Color("cfd8d2"))
		deco.position = Vector2(rng.randi_range(16, WORLD.x * TILE - 16), rng.randi_range(16, WORLD.y * TILE - 16))
		deco.z_index = -9
		add_child(deco)
	# the dead fleet: beached wrecks, the bones of the coast towns
	for pos: Vector2 in [Vector2(TILE * 10, TILE * 26), Vector2(TILE * 38, TILE * 8), Vector2(TILE * 30, TILE * 27)]:
		var wreck := SpriteKit.sprite("wreck", Vector2(60, 40), Color("6e5138"))
		wreck.position = pos
		wreck.z_index = -8
		wreck.modulate = Color(1, 1, 1, 0.96)
		add_child(wreck)

func _spawn_resource_nodes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var biome := registry.get_entity("biome-salt-shallows")
	var idx := 0
	var taken_tiles := {}
	for item_id: String in biome.get("resourceItemIds", []):
		for i in 14:
			var tile := Vector2i(rng.randi_range(2, WORLD.x - 2), rng.randi_range(2, WORLD.y - 2))
			while taken_tiles.has(tile):
				tile = Vector2i(rng.randi_range(2, WORLD.x - 2), rng.randi_range(2, WORLD.y - 2))
			taken_tiles[tile] = true
			var pos := Vector2(tile.x * TILE, tile.y * TILE)
			node_defs.append({"item_id": item_id, "pos": pos, "idx": idx})
			_spawn_one_node(item_id, pos, idx)
			idx += 1

const NODE_SPRITES := {
	"item-driftwood": "driftwood", "item-wreck-timber": "timber",
	"item-ship-cloth": "cloth", "item-salt": "salt_mound", "item-bronze-salvage": "bronze",
	"item-rope": "rope", "item-storm-glass": "bronze",
}

func _spawn_one_node(item_id: String, pos: Vector2, idx: int) -> Area2D:
	var node := Area2D.new()
	node.position = pos
	node.set_meta("item_id", item_id)
	node.set_meta("qty", 3)
	node.set_meta("idx", idx)
	var visual := SpriteKit.sprite(NODE_SPRITES.get(item_id, "none"),
		Vector2(16, 16), ITEM_COLORS.get(item_id, Color("c9a648")))
	if item_id == "item-storm-glass":
		visual.modulate = Color(1.3, 1.25, 0.7)   # fused sand, still warm from the sky
	node.add_child(visual)
	add_child(node)
	resource_nodes.append(node)
	return node

func _spawn_shrines() -> void:
	# Halor waits in the north; Maren on the east edge, where the weather comes from.
	_spawn_one_shrine("god-halor", Vector2(WORLD.x * TILE / 2.0, TILE * 5.0), Color.WHITE)
	_spawn_one_shrine("god-maren", Vector2(WORLD.x * TILE - TILE * 4.0, WORLD.y * TILE / 2.0), Color(0.82, 0.88, 1.0))

func _spawn_one_shrine(god_id: String, pos: Vector2, tint: Color) -> void:
	var s := Node2D.new()
	s.position = pos
	s.set_meta("god_id", god_id)
	var visual := SpriteKit.sprite("shrine", Vector2(44, 44), Color("dce8e4"))
	visual.modulate = tint
	s.add_child(visual)
	s.add_child(_world_label("a fallen shrine", Vector2(0, 24)))
	add_child(s)
	shrines.append(s)

## Small in-world nameplates so landmarks read as themselves.
func _world_label(text: String, offset: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.position = offset + Vector2(-70, 0)
	l.custom_minimum_size = Vector2(140, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color("8a7a5c"))
	l.add_theme_font_size_override("font_size", 10)
	return l

func _spawn_survivor() -> void:
	survivor = DSVillager.new()
	survivor.host = self
	survivor.position = Vector2(TILE * 6.0, WORLD.y * TILE - TILE * 5.0)  # far southwest, by the wrecks
	add_child(survivor)

func _on_sim_day(_day: int) -> void:
	var conditions: Array = ["rested"]
	if rites_done_today.values().any(func(v: bool) -> bool: return v):
		conditions.append("riteAttended")
	rites_done_today.clear()
	for id: int in village.tribesmen:
		village.drift_day(id, conditions)
	devotion.villager_trickle_day(LOCAL_PLAYER, "god-halor", village.devout_count("god-halor"))
	village.end_of_day()
	cheat_death_used_today = false
	abilities.earn(LOCAL_PLAYER, 2)   # every survived day tempers you
	_storm_dawn()
	if not skip_autoload:
		save_game()  # each dawn, the flats remember

## --- the great storm: every 4th day the sea's weather comes home -----------------
func is_storm_day() -> bool:
	return clock.day % 4 == 3

func _storm_dawn() -> void:
	# yesterday's storm-glass sinks back into the flats
	for node in resource_nodes.duplicate():
		if is_instance_valid(node) and int(node.get_meta("idx", -1)) >= STORM_GLASS_IDX_BASE:
			resource_nodes.erase(node)
			node.queue_free()
	# every dawn uncovers a little; storm dawns uncover a lot
	var respawned := 0
	var respawn_cap := 12 if is_storm_day() else 5
	for def: Dictionary in node_defs:
		if respawned >= respawn_cap:
			break
		if int(def.idx) in harvested_indices:
			harvested_indices.erase(int(def.idx))
			_spawn_one_node(str(def.item_id), def.pos, int(def.idx))
			respawned += 1
	# and the flats restock their fauna (the food chain survives your appetite)
	var crabs := 0
	var hounds := 0
	for e in enemies:
		if is_instance_valid(e):
			if e.creature_id == "creature-scuttle-crab":
				crabs += 1
			elif e.creature_id == "creature-salt-hound":
				hounds += 1
	var fauna_rng := RandomNumberGenerator.new()
	fauna_rng.seed = 500 + clock.day
	var center := Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
	while crabs < 8:
		var crab := DSEnemy.new()
		crab.position = Vector2(fauna_rng.randi_range(2, WORLD.x - 2) * TILE, fauna_rng.randi_range(2, WORLD.y - 2) * TILE)
		crab.setup(self, "creature-scuttle-crab")
		add_child(crab)
		enemies.append(crab)
		crabs += 1
	# the king is gone: scavengers fill a throne faster than grief does
	var hound_cap := 8 if boss_dead else 6
	while hounds < hound_cap:
		var hound := DSEnemy.new()
		var pos := center
		while pos.distance_to(center) < 350.0:
			pos = Vector2(fauna_rng.randi_range(2, WORLD.x - 2) * TILE, fauna_rng.randi_range(2, WORLD.y - 2) * TILE)
		hound.position = pos
		hound.setup(self, "creature-salt-hound")
		add_child(hound)
		enemies.append(hound)
		hounds += 1
	if not is_storm_day():
		return
	# and the sky leaves gifts: storm-glass, today only
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + clock.day
	for i in 3:
		var pos := Vector2(rng.randi_range(3, WORLD.x - 3) * TILE, rng.randi_range(3, WORLD.y - 3) * TILE)
		_spawn_one_node("item-storm-glass", pos, STORM_GLASS_IDX_BASE + i)
	message = "THE GREAT STORM. The seabed shifts — old salvage uncovered, and storm-glass smokes on the flats.\nGather it before the sky takes it back. Maren is EVERYWHERE today: her magic costs half."

func _spawn_enemies() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var center := Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
	for i in 6:
		var hound := DSEnemy.new()
		var pos := center
		while pos.distance_to(center) < 350.0:  # never spawn on the player's doorstep
			pos = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(2, WORLD.y - 2) * TILE)
		hound.position = pos
		hound.setup(self, "creature-salt-hound")
		add_child(hound)
		enemies.append(hound)
	for i in 8:  # scuttle-crabs: mostly harmless, excellent soup
		var crab := DSEnemy.new()
		crab.position = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(2, WORLD.y - 2) * TILE)
		crab.setup(self, "creature-scuttle-crab")
		add_child(crab)
		enemies.append(crab)
	# Old Shellback guards the northwest wreck-ring. The first name you learn to fear.
	var boss := DSEnemy.new()
	boss.position = Vector2(TILE * 5.0, TILE * 5.0)
	boss.setup(self, "creature-old-shellback")
	boss.add_child(_world_label("Old Shellback", Vector2(0, 22)))
	add_child(boss)
	enemies.append(boss)

## --- day/night + HUD ---------------------------------------------------------------
func _on_sim_minute(_m: int) -> void:
	_minutes_since_hour += 1
	if _minutes_since_hour >= 60:
		_minutes_since_hour = 0
		works.favor_hour()
	var tint := _tint_for_minute(clock.minute_of_day)
	if is_storm_day():
		tint = tint * Color(0.72, 0.76, 0.86)   # storm-gray over everything
		if clock.minute_of_day % 47 == 0:
			storm_flash = 0.65                   # lightning somewhere over the flats
	daynight.color = tint
	_refresh_hud()

## Gradual light: night -> warm dawn -> blinding day -> gold dusk -> night.
func _tint_for_minute(m: int) -> Color:
	const NIGHT := Color(0.42, 0.46, 0.62)
	const DAWN := Color(0.95, 0.82, 0.72)
	const DAY := Color(1, 1, 1)
	const DUSK := Color(1.0, 0.85, 0.62)
	var h := m / 60.0
	if h < 4.0:
		return NIGHT
	if h < 5.0:
		return NIGHT.lerp(DAWN, h - 4.0)
	if h < 7.0:
		return DAWN.lerp(DAY, (h - 5.0) / 2.0)
	if h < 18.0:
		return DAY
	if h < 20.0:
		return DAY.lerp(DUSK, (h - 18.0) / 2.0)
	if h < 21.5:
		return DUSK.lerp(NIGHT, (h - 20.0) / 1.5)
	return NIGHT

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_color_override("font_color", Color("3b3428"))
	hud.add_theme_font_size_override("font_size", 14)
	layer.add_child(hud)
	var hp_back := ColorRect.new()
	hp_back.position = Vector2(12, 140)
	hp_back.size = Vector2(160, 10)
	hp_back.color = Color("4a3021")
	layer.add_child(hp_back)
	hp_bar = ColorRect.new()
	hp_bar.position = Vector2(13, 141)
	hp_bar.size = Vector2(158, 8)
	hp_bar.color = Color("b0483c")
	layer.add_child(hp_bar)
	var st_back := ColorRect.new()
	st_back.position = Vector2(12, 154)
	st_back.size = Vector2(160, 10)
	st_back.color = Color("4a3021")
	layer.add_child(st_back)
	stamina_bar = ColorRect.new()
	stamina_bar.position = Vector2(13, 155)
	stamina_bar.size = Vector2(158, 8)
	stamina_bar.color = Color("c9a648")
	layer.add_child(stamina_bar)
	var vigor_back := ColorRect.new()
	vigor_back.position = Vector2(12, 168)
	vigor_back.size = Vector2(160, 10)
	vigor_back.color = Color("4a3021")
	layer.add_child(vigor_back)
	vigor_bar = ColorRect.new()
	vigor_bar.position = Vector2(13, 169)
	vigor_bar.size = Vector2(0, 8)
	vigor_bar.color = Color("5da8a0")   # Halor's votive flame, placeholder-shaped
	layer.add_child(vigor_bar)
	var maren_back := ColorRect.new()
	maren_back.position = Vector2(12, 182)
	maren_back.size = Vector2(160, 10)
	maren_back.color = Color("4a3021")
	layer.add_child(maren_back)
	maren_bar = ColorRect.new()
	maren_bar.position = Vector2(13, 183)
	maren_bar.size = Vector2(0, 8)
	maren_bar.color = Color("aebfc9")   # Maren's storm-light
	layer.add_child(maren_bar)
	boss_name = Label.new()
	boss_name.position = Vector2(440, 640)
	boss_name.custom_minimum_size = Vector2(400, 0)
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_name.add_theme_color_override("font_color", Color("3b3428"))
	boss_name.add_theme_font_size_override("font_size", 16)
	boss_name.visible = false
	layer.add_child(boss_name)
	var boss_back := ColorRect.new()
	boss_back.position = Vector2(440, 664)
	boss_back.size = Vector2(400, 12)
	boss_back.color = Color("4a3021")
	boss_back.visible = false
	layer.add_child(boss_back)
	boss_bar = ColorRect.new()
	boss_bar.position = Vector2(442, 666)
	boss_bar.size = Vector2(396, 8)
	boss_bar.color = Color("b0483c")
	boss_bar.visible = false
	layer.add_child(boss_bar)
	boss_bar.set_meta("back", boss_back)
	sheet_back = ColorRect.new()
	sheet_back.position = Vector2(560, 96)
	sheet_back.size = Vector2(700, 608)
	sheet_back.color = Color(0.949, 0.937, 0.910, 0.93)   # keepsake-paper cream
	sheet_back.visible = false
	layer.add_child(sheet_back)
	sheet_label = Label.new()
	sheet_label.position = Vector2(576, 106)
	sheet_label.custom_minimum_size = Vector2(668, 0)
	sheet_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sheet_label.add_theme_color_override("font_color", Color("3b3428"))
	sheet_label.add_theme_font_size_override("font_size", 12)
	sheet_label.visible = false
	layer.add_child(sheet_label)
	menu_label = Label.new()
	menu_label.position = Vector2(12, 200)
	menu_label.add_theme_color_override("font_color", Color("3b3428"))
	menu_label.add_theme_font_size_override("font_size", 14)
	menu_label.visible = false
	layer.add_child(menu_label)

func _refresh_bars() -> void:
	if hp_bar == null:
		return
	hp_bar.size.x = 158.0 * stats.hp(LOCAL_PLAYER) / maxf(stats.max_hp(LOCAL_PLAYER), 1.0)
	stamina_bar.size.x = 158.0 * stats.stamina(LOCAL_PLAYER) / maxf(stats.max_stamina(LOCAL_PLAYER), 1.0)
	if "god-halor" in attuned_gods:
		var s: Dictionary = devotion.state.get(LOCAL_PLAYER, {}).get("god-halor", {})
		vigor_bar.size.x = 158.0 * float(s.get("vigor", 0)) / devotion.max_vigor("god-halor")
	else:
		vigor_bar.size.x = 0.0
	if maren_bar != null:
		if "god-maren" in attuned_gods:
			var m: Dictionary = devotion.state.get(LOCAL_PLAYER, {}).get("god-maren", {})
			maren_bar.size.x = 158.0 * float(m.get("vigor", 0)) / devotion.max_vigor("god-maren")
		else:
			maren_bar.size.x = 0.0

func _refresh_hud() -> void:
	if hud == null:
		return
	var inv := ""
	for item_id: String in inventory._inv(LOCAL_PLAYER):
		inv += "%s ×%d   " % [str(registry.get_entity(item_id).get("name", item_id)), inventory.count(LOCAL_PLAYER, item_id)]
	var fed: int = (stats.actors.get(LOCAL_PLAYER, {}).get("foods", []) as Array).size()
	var weather := ""
	if is_storm_day():
		weather = "  — THE GREAT STORM"
	elif "god-maren" in attuned_gods and (clock.day + 1) % 4 == 3:
		weather = "  — Maren whispers: storm tomorrow"
	hud.text = "Day %d, %02d:%02d%s%s%s%s\n%s\n[WASD] move  [E] interact  [C] craft  [B] build  [F] eat  [T] tally  [SPACE] attack%s\n%s" % [
		clock.day + 1, clock.minute_of_day / 60, clock.minute_of_day % 60, weather,
		"  — night. NIGHT BELONGS TO THE HOUNDS." if clock.is_night() else "",
		"  |  fed ×%d" % fed if fed > 0 else "", _direction_hints(),
		inv if inv != "" else "(empty hands)",
		("  [Q] Pillar of Salt" if "god-halor" in attuned_gods else "") + ("  [R] Call the Squall" if "god-maren" in attuned_gods else ""), message]

## Where the unfinished business is: unvisited shrines, the stranded woman.
func _direction_hints() -> String:
	var bits: Array[String] = []
	for s in shrines:
		if s.get_meta("god_id") not in attuned_gods:
			bits.append("a pale shrine %s" % _bearing(s.position))
	if survivor != null and not survivor.rescued:
		bits.append("someone stranded %s" % _bearing(survivor.position))
	var verses := inventory.count(LOCAL_PLAYER, "item-harpoon-verse")
	if verses > 0 and verses < 3:
		bits.append("the harpoon-song: %d/3 verses" % verses)
	return "  |  " + ";  ".join(bits) if bits.size() > 0 else ""

func _bearing(to: Vector2) -> String:
	var d := to - player.position
	const DIRS := ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]
	var idx := wrapi(roundi(d.angle() / (PI / 4.0)), 0, 8)
	return "%s, %d paces" % [DIRS[idx], int(d.length() / 32.0)]

## --- helpers ------------------------------------------------------------------------
static func _setup_input() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"interact": [KEY_E], "craft": [KEY_C], "build": [KEY_B], "eat": [KEY_F],
		"attack": [KEY_SPACE, KEY_J], "cast": [KEY_Q], "cast_2": [KEY_R], "consume": [KEY_X],
		"save": [KEY_F5], "sheet": [KEY_T],
	}
	for action: String in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for keycode: Key in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)

func _screenshot_and_quit() -> void:
	await get_tree().create_timer(1.2).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://screenshot.png")
	print("screenshot saved: ", ProjectSettings.globalize_path("user://screenshot.png"))
	get_tree().quit(0)
