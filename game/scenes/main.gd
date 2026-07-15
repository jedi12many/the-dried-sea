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
var daynight: CanvasModulate
var resource_nodes: Array[Area2D] = []
var enemies: Array[DSEnemy] = []
var _minutes_since_hour := 0

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
	stats.register(LOCAL_PLAYER, 100.0, 100.0)
	devotion.ledger_event.connect(func(p: int, l: String, a: float, n: String) -> void: verdict.record(p, l, a, n, clock.day))
	village.ledger_event.connect(func(l: String, a: float, n: String) -> void: verdict.record(LOCAL_PLAYER, l, a, n, clock.day))

	_build_ground()
	_spawn_resource_nodes()
	player = DSPlayer.new()
	player.position = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
	add_child(player)
	_spawn_enemies()
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
	_refresh_bars()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		intent_harvest()
	elif event.is_action_pressed("craft"):
		intent_craft_first()
	elif event.is_action_pressed("build"):
		intent_build("work-workbench")
	elif event.is_action_pressed("attack"):
		intent_attack()

## --- intents (the only door into the sim from presentation) --------------------
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
	var rect := ColorRect.new()
	rect.size = Vector2(28, 28)
	rect.position = player.position + Vector2(24, -14)
	rect.color = Color("6e5138") if not work.get("grim", false) else Color("5b3a6e")
	add_child(rect)
	_refresh_hud()
	return true

## --- world (placeholder) ---------------------------------------------------------
func _build_ground() -> void:
	var ground := ColorRect.new()
	ground.size = Vector2(WORLD.x * TILE, WORLD.y * TILE)
	ground.color = Color("e8e2d4")   # blinding flats, high-key
	ground.z_index = -10
	add_child(ground)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:  # salt pillars + brine stains: the flats aren't flat
		var deco := ColorRect.new()
		var pillar := rng.randf() < 0.5
		deco.size = Vector2(rng.randi_range(8, 20), rng.randi_range(8, 28) if pillar else rng.randi_range(6, 10))
		deco.color = Color("f7f5ee") if pillar else Color("cfd8d2")
		deco.position = Vector2(rng.randi_range(0, WORLD.x * TILE), rng.randi_range(0, WORLD.y * TILE))
		deco.z_index = -9
		add_child(deco)

func _spawn_resource_nodes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var biome := registry.get_entity("biome-salt-shallows")
	for item_id: String in biome.get("resourceItemIds", []):
		for i in 8:
			var node := Area2D.new()
			node.position = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(2, WORLD.y - 2) * TILE)
			node.set_meta("item_id", item_id)
			node.set_meta("qty", 2)
			var rect := ColorRect.new()
			rect.size = Vector2(16, 16)
			rect.position = Vector2(-8, -8)
			rect.color = ITEM_COLORS.get(item_id, Color.MAGENTA)
			if item_id == "item-salt":  # white-on-white is thematically perfect and practically invisible
				var glint := ColorRect.new()
				glint.size = Vector2(18, 18)
				glint.position = Vector2(-9, -9)
				glint.color = Color("aebfc9")
				node.add_child(glint)
				node.move_child(glint, 0)
			node.add_child(rect)
			add_child(node)
			resource_nodes.append(node)

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
		add_child(hound)
		hound.setup(self, "creature-salt-hound")
		enemies.append(hound)

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
	hp_back.position = Vector2(12, 80)
	hp_back.size = Vector2(160, 10)
	hp_back.color = Color("4a3021")
	layer.add_child(hp_back)
	hp_bar = ColorRect.new()
	hp_bar.position = Vector2(13, 81)
	hp_bar.size = Vector2(158, 8)
	hp_bar.color = Color("b0483c")
	layer.add_child(hp_bar)
	var st_back := ColorRect.new()
	st_back.position = Vector2(12, 94)
	st_back.size = Vector2(160, 10)
	st_back.color = Color("4a3021")
	layer.add_child(st_back)
	stamina_bar = ColorRect.new()
	stamina_bar.position = Vector2(13, 95)
	stamina_bar.size = Vector2(158, 8)
	stamina_bar.color = Color("c9a648")
	layer.add_child(stamina_bar)

func _refresh_bars() -> void:
	if hp_bar == null:
		return
	hp_bar.size.x = 158.0 * stats.hp(LOCAL_PLAYER) / 100.0
	stamina_bar.size.x = 158.0 * stats.stamina(LOCAL_PLAYER) / 100.0

func _refresh_hud() -> void:
	if hud == null:
		return
	var inv := ""
	for item_id: String in inventory._inv(LOCAL_PLAYER):
		inv += "%s ×%d   " % [str(registry.get_entity(item_id).get("name", item_id)), inventory.count(LOCAL_PLAYER, item_id)]
	hud.text = "Day %d, %02d:%02d%s\n%s\n[WASD] move  [E] harvest  [C] craft  [B] build  [SPACE] attack" % [
		clock.day + 1, clock.minute_of_day / 60, clock.minute_of_day % 60,
		"  — night" if clock.is_night() else "", inv if inv != "" else "(empty hands)"]

## --- helpers ------------------------------------------------------------------------
static func _setup_input() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"interact": [KEY_E], "craft": [KEY_C], "build": [KEY_B],
		"attack": [KEY_SPACE, KEY_J],
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
