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

var player: DSPlayer
var hud: Label
var hp_bar: ColorRect
var stamina_bar: ColorRect
var vigor_bar: ColorRect
var daynight: CanvasModulate
var resource_nodes: Array[Area2D] = []
var enemies: Array[DSEnemy] = []
var _minutes_since_hour := 0

# the soul, playable
const INTERACT_RANGE := 56.0
var shrine: Node2D
var survivor: DSVillager
var chapel_pos := Vector2.INF
var attuned := false
var rite_done_today := false
var petrify_frames := 0
var message := "Something pale stands in the north flats. It looks like it is waiting."
var menu_label: Label
var menu_open := false

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
	devotion.ledger_event.connect(func(p: int, l: String, a: float, n: String) -> void: verdict.record(p, l, a, n, clock.day))
	village.ledger_event.connect(func(l: String, a: float, n: String) -> void: verdict.record(LOCAL_PLAYER, l, a, n, clock.day))

	_build_ground()
	_spawn_resource_nodes()
	player = DSPlayer.new()
	player.position = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
	add_child(player)
	_spawn_enemies()
	_spawn_shrine()
	_spawn_survivor()
	clock.sim_day.connect(_on_sim_day)
	daynight = CanvasModulate.new()
	add_child(daynight)
	_build_hud()
	clock.sim_minute.connect(_on_sim_minute)
	_refresh_hud()

	if "--screenshot" in OS.get_cmdline_user_args():
		_screenshot_and_quit()

func _physics_process(delta: float) -> void:
	clock.advance(delta)
	stats.tick(delta)
	if petrify_frames > 0:
		petrify_frames -= 1
		if petrify_frames == 0:
			player.modulate = Color.WHITE
			message = "The salt lets you go. Halor's strength is spent — worship gives it back."
			_refresh_hud()
	_refresh_bars()

func _unhandled_input(event: InputEvent) -> void:
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
		intent_cast()

## --- intents (the only door into the sim from presentation) --------------------
## E is contextual: kneel at the shrine, rescue the stranded, hold a rite, else harvest.
func intent_interact() -> bool:
	if shrine != null and player.position.distance_to(shrine.position) < INTERACT_RANGE and not attuned:
		return intent_kneel()
	if survivor != null and not survivor.rescued and player.position.distance_to(survivor.position) < INTERACT_RANGE:
		return intent_rescue()
	if chapel_pos != Vector2.INF and player.position.distance_to(chapel_pos) < INTERACT_RANGE:
		return intent_rite()
	return intent_harvest()

func intent_kneel() -> bool:
	if not devotion.attune(LOCAL_PLAYER, "god-halor"):
		return false
	attuned = true
	message = "You kneel at the fallen shrine. A slow, warm voice: 'The sea left. The salt stayed.'\nHALOR is with you — [Q] Pillar of Salt, when the pinch comes. His strength is not endless."
	_refresh_hud()
	return true

func intent_cast() -> bool:
	if not attuned:
		return false
	var inv: Dictionary = devotion.cast(LOCAL_PLAYER, "inv-pillar-of-salt")
	if inv.is_empty():
		message = "Halor has nothing left to give. Build him a chapel; hold a rite."
		_refresh_hud()
		return false
	petrify_frames = 6 * 60  # rooted and untouchable
	player.modulate = Color("cfd0ce")
	message = "You become the thing the sea could never wear down."
	_refresh_hud()
	return true

func intent_rescue() -> bool:
	survivor.rescue()
	message = "%s, of the drowned coast towns. She follows you home — give her a hearth and she'll keep it.\nShe is devout: her prayers feed Halor a little every day." % survivor.display_name
	_refresh_hud()
	return true

func intent_rite() -> bool:
	if rite_done_today:
		message = "The rite is held once a day. Halor keeps slow time."
		_refresh_hud()
		return false
	rite_done_today = true
	devotion.rite_day(LOCAL_PLAYER, "god-halor", "chapel", 1)
	message = "You lead the evening rite. The shrine-light steadies a little."
	_refresh_hud()
	return true

func intent_harvest() -> bool:
	var nearest: Area2D = null
	var best := HARVEST_RANGE
	for node in resource_nodes:
		if not is_instance_valid(node):
			continue
		var d := player.position.distance_to(node.position)
		if d < best:
			best = d
			nearest = node
	if nearest == null:
		return false
	inventory.add(LOCAL_PLAYER, nearest.get_meta("item_id"), int(nearest.get_meta("qty")))
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
	var attuned_gods := ["neutral"]
	if attuned:
		attuned_gods.append("god-halor")
	var out: Array = []
	for god_id: String in order:
		if god_id not in attuned_gods:
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
	for i in options.size():
		var work := registry.get_entity(str(options[i]))
		var cost_bits: Array[String] = []
		for c: Dictionary in work.get("buildCost", []):
			cost_bits.append("%s×%d" % [str(registry.get_entity(str(c.itemId)).get("name", c.itemId)), int(c.qty)])
		var afford := inventory.can_afford(LOCAL_PLAYER, work.get("buildCost", []))
		lines.append("%d. %s%s — %s" % [i + 1, str(work.name), "" if afford else "  (can't afford)", ", ".join(cost_bits)])
	menu_label.text = "\n".join(lines)

func intent_craft(recipe_id: String) -> bool:
	var ok := inventory.craft(LOCAL_PLAYER, recipe_id, works)
	_refresh_hud()
	return ok

func intent_craft_first() -> void:
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
	if not stats.spend_stamina(LOCAL_PLAYER, ATTACK_STAMINA):
		return false
	if stats.damage(target, ATTACK_DAMAGE):
		_on_enemy_killed(target)
	return true

func damage_player(amount: float) -> void:
	if petrify_frames > 0:
		return  # the salt holds
	if stats.damage(LOCAL_PLAYER, amount):
		# Death penalty is an open design question (GAME-SPEC); M1 placeholder:
		# wake at the village center, hurt pride only.
		player.position = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
		stats.heal_full(LOCAL_PLAYER)
	_refresh_bars()

func _on_enemy_killed(enemy: DSEnemy) -> void:
	for drop: Dictionary in registry.get_entity(enemy.creature_id).get("drops", []):
		inventory.add(LOCAL_PLAYER, str(drop.itemId), int(drop.qty))
	stats.unregister(enemy)
	enemies.erase(enemy)
	enemy.queue_free()
	_refresh_hud()

func intent_build(work_id: String) -> bool:
	var work := registry.get_entity(work_id)
	if work.is_empty() or not inventory.pay(LOCAL_PLAYER, work.get("buildCost", [])):
		_refresh_hud()
		return false
	works.place(work_id, LOCAL_PLAYER)
	var work_sprites := {
		"work-workbench": "workbench", "work-chapel": "chapel", "work-smokehouse": "smokehouse",
		"work-hearth": "hearth", "work-driftwood-wall": "wall",
	}
	var fallback := Color("6e5138") if not work.get("grim", false) else Color("5b3a6e")
	if work_id == "work-chapel":
		fallback = Color("f2efe8")
	var visual := SpriteKit.sprite(work_sprites.get(work_id, "none"),
		Vector2(28, 28) if work_id != "work-chapel" else Vector2(40, 48), fallback)
	visual.position = player.position + Vector2(40, 0)
	if work_id == "work-chapel":
		chapel_pos = visual.position
		message = "A chapel to Halor, raised from wreck-timber. Hold rites here [E] — his strength returns through worship."
	add_child(visual)
	_refresh_hud()
	return true

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

func _spawn_resource_nodes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var node_sprites := {
		"item-driftwood": "driftwood", "item-wreck-timber": "timber",
		"item-ship-cloth": "cloth", "item-salt": "salt_mound", "item-bronze-salvage": "bronze",
		"item-rope": "rope",
	}
	var biome := registry.get_entity("biome-salt-shallows")
	for item_id: String in biome.get("resourceItemIds", []):
		for i in 8:
			var node := Area2D.new()
			node.position = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(2, WORLD.y - 2) * TILE)
			node.set_meta("item_id", item_id)
			node.set_meta("qty", 2)
			var visual := SpriteKit.sprite(node_sprites.get(item_id, "none"),
				Vector2(16, 16), ITEM_COLORS.get(item_id, Color.MAGENTA))
			if item_id == "item-salt" and SpriteKit.texture("salt_mound") == null:
				var glint := ColorRect.new()   # fallback-only: white-on-white needs help
				glint.size = Vector2(18, 18)
				glint.position = Vector2(-9, -9)
				glint.color = Color("aebfc9")
				node.add_child(glint)
			node.add_child(visual)
			add_child(node)
			resource_nodes.append(node)

func _spawn_shrine() -> void:
	shrine = Node2D.new()
	shrine.position = Vector2(WORLD.x * TILE / 2.0, TILE * 5.0)  # the north flats
	var visual := SpriteKit.sprite("shrine", Vector2(44, 44), Color("dce8e4"))
	shrine.add_child(visual)
	if SpriteKit.texture("shrine") == null:
		for offset: Vector2 in [Vector2(-12, -6), Vector2(0, -14), Vector2(12, -4)]:
			var pillar := ColorRect.new()
			pillar.size = Vector2(8, 24)
			pillar.position = offset + Vector2(-4, -6)
			pillar.color = Color("f7f5ee")
			shrine.add_child(pillar)
	add_child(shrine)

func _spawn_survivor() -> void:
	survivor = DSVillager.new()
	survivor.host = self
	survivor.position = Vector2(TILE * 6.0, WORLD.y * TILE - TILE * 5.0)  # far southwest, by the wrecks
	add_child(survivor)

func _on_sim_day(_day: int) -> void:
	var conditions: Array = ["rested"]
	if rite_done_today:
		conditions.append("riteAttended")
	rite_done_today = false
	for id: int in village.tribesmen:
		village.drift_day(id, conditions)
	devotion.villager_trickle_day(LOCAL_PLAYER, "god-halor", village.devout_count("god-halor"))
	village.end_of_day()

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

## --- day/night + HUD ---------------------------------------------------------------
func _on_sim_minute(_m: int) -> void:
	_minutes_since_hour += 1
	if _minutes_since_hour >= 60:
		_minutes_since_hour = 0
		works.favor_hour()
	var night := Color(0.42, 0.46, 0.62)
	var day := Color(1, 1, 1)
	daynight.color = night if clock.is_night() else day
	_refresh_hud()

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
	vigor_bar.color = Color("5da8a0")   # the votive flame, placeholder-shaped
	layer.add_child(vigor_bar)
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
	if attuned:
		var s: Dictionary = devotion.state.get(LOCAL_PLAYER, {}).get("god-halor", {})
		vigor_bar.size.x = 158.0 * float(s.get("vigor", 0)) / devotion.max_vigor("god-halor")
	else:
		vigor_bar.size.x = 0.0

func _refresh_hud() -> void:
	if hud == null:
		return
	var inv := ""
	for item_id: String in inventory._inv(LOCAL_PLAYER):
		inv += "%s ×%d   " % [str(registry.get_entity(item_id).get("name", item_id)), inventory.count(LOCAL_PLAYER, item_id)]
	var fed: int = (stats.actors.get(LOCAL_PLAYER, {}).get("foods", []) as Array).size()
	hud.text = "Day %d, %02d:%02d%s%s\n%s\n[WASD] move  [E] interact  [C] craft  [B] build  [F] eat  [SPACE] attack%s\n%s" % [
		clock.day + 1, clock.minute_of_day / 60, clock.minute_of_day % 60,
		"  — night. NIGHT BELONGS TO THE HOUNDS." if clock.is_night() else "",
		"  |  fed ×%d" % fed if fed > 0 else "",
		inv if inv != "" else "(empty hands)",
		"  [Q] Pillar of Salt" if attuned else "", message]

## --- helpers ------------------------------------------------------------------------
static func _setup_input() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"interact": [KEY_E], "craft": [KEY_C], "build": [KEY_B], "eat": [KEY_F],
		"attack": [KEY_SPACE, KEY_J], "cast": [KEY_Q],
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
