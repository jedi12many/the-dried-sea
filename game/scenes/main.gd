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
const GAME_VERSION := "0.4.0"
const NET_PORT := 7777
# NET: whose deed is this (server sets per intent), and whose screen is this
var acting_pid := 1
var my_pid := 1
var net_mode := "offline"            # offline | server | client
var peers: Dictionary = {}           # peer_id -> pid
var net_players: Dictionary = {}     # username -> pid (persisted)
var next_pid := 1
var avatars: Dictionary = {}         # pid -> Vector2 (server truth of player positions)
var remote_nodes: Dictionary = {}    # pid -> Node2D (client visuals for OTHER players)
var enemy_net_ids: Dictionary = {}   # DSEnemy -> int (server)
var _next_enemy_net_id := 1
var _pos_timer := 0.0
var work_visuals: Dictionary = {}    # works.placed id -> visual Node2D
var sound: SoundKit
var drag_work_id := -1               # click-and-drag: which work is in hand

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
var consumed_hp: Dictionary = {}   # pid -> permanent strength eaten from gods
var cheat_death_used: Dictionary = {}  # pid -> bool (resets at dawn)
var equipped: Dictionary = {}      # pid -> {weapon: item_id, armor: item_id}
var doll_label: Label
var doll_back: ColorRect
var doll_sprite: Node2D
var doll_open := false

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
var survivor: DSVillager               # Anna, the first (kept for compat + tutorial)
var villagers: Array[DSVillager] = []  # additional rescued/stranded survivors
var village_stock: Dictionary = {}     # the shared storehouse: item_id -> qty
var village_panel: Label
var village_panel_open := false
var _villager_nid := 100

# what each class does at work: [station ("" = forager), product, qty, to_village_stock?]
const JOBS := {
	"class-brinewife": ["work-smokehouse", "item-smoked-crab", 2, true],
	"class-salvager": ["work-workbench", "item-salt", 3, false],
	"class-smith": ["work-workbench", "item-bronze-salvage", 2, false],
	"class-reef-runner": ["", "item-driftwood", 2, false],
	"class-warden": ["work-yoke-post", "", 0, false],
}
const NAME_POOL := ["Bex", "Corin", "Del", "Enna", "Fisk", "Goro", "Hale", "Isa",
	"Joss", "Kael", "Lorn", "Mira", "Nils", "Orla", "Perr", "Renn", "Sable", "Tovin"]
const CLASS_POOL := ["class-brinewife", "class-salvager", "class-smith", "class-reef-runner", "class-warden"]
const TRAIT_POOL := ["trait-devout", "trait-agnostic", "trait-industrious", "trait-idle",
	"trait-storyteller", "trait-surly", "trait-night-owl", "trait-bitter", "trait-keen-eyes", "trait-forge-sense"]
var chapels: Dictionary = {}          # god_id -> position
var attuned: Dictionary = {}          # pid -> Array[String]
var rites_done_today: Dictionary = {} # god_id -> bool
var petrify: Dictionary = {}           # pid -> frames; petrify_frames mirrors MY pid for display
var petrify_frames := 0
var message := "Something pale stands in the north flats. It looks like it is waiting."
var menu_label: Label
var menu_open := false
var menu_mode := "build"   # "build" | "craft"

# the camp: the first structure plants it; everything after builds within the ring
const CAMP_RADIUS := 320.0
var camp_center := Vector2.INF
var camp_ring: Line2D

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
	var args := OS.get_cmdline_user_args()
	if "--fresh" in args:
		skip_autoload = true
	if "--server" in args:
		net_mode = "server"
	for a: String in args:
		if a.begins_with("--connect="):
			net_mode = "client"
			_net_connect_addr = a.trim_prefix("--connect=")
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
	stats.register(acting_pid, 60.0, 60.0)   # unfed floor — food raises the ceiling
	abilities = AbilitiesSystem.new(registry)
	abilities.earn(acting_pid, 6)            # the flats have already tempered you a little
	abilities.changed.connect(func(p: int) -> void: _recompute_vitals(p))
	devotion.ledger_event.connect(func(p: int, l: String, a: float, n: String) -> void: verdict.record(p, l, a, n, clock.day))
	village.ledger_event.connect(func(l: String, a: float, n: String) -> void: verdict.record(acting_pid, l, a, n, clock.day))

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
	sound = SoundKit.new()
	add_child(sound)
	clock.sim_minute.connect(_on_sim_minute)
	_refresh_hud()

	if not skip_autoload and net_mode != "client" and FileAccess.file_exists(save_path):
		load_game()
	if net_mode == "server":
		_start_server()
	elif net_mode == "client":
		_start_client()
	if "--screenshot-sheet" in OS.get_cmdline_user_args():
		abilities.earn(acting_pid, 6)
		for i in 4:
			abilities.allocate(acting_pid, "virtue-grit")
		for i in 3:
			abilities.allocate(acting_pid, "virtue-hunger")
		_toggle_sheet(true)
		_screenshot_and_quit()
	elif "--screenshot-craft" in OS.get_cmdline_user_args():
		for it: String in ["item-driftwood", "item-rope", "item-bronze-salvage", "item-wreck-timber", "item-salt", "item-crab-meat"]:
			inventory.add(acting_pid, it, 8)
		works.place("work-workbench", acting_pid, player.position + Vector2(40, 0))
		_toggle_menu(true, "craft")
		_screenshot_and_quit()
	elif "--screenshot-build" in OS.get_cmdline_user_args():
		attuned_for(acting_pid).append("god-halor")
		_toggle_menu(true, "build")
		_screenshot_and_quit()
	elif "--screenshot-village" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-wreck-timber", 20)
		inventory.add(acting_pid, "item-salt", 20)
		intent_build("work-workbench")
		intent_build("work-smokehouse")
		survivor.rescue()
		survivor.position = village_heart()
		for v: DSVillager in villagers:
			v.def_class = ["class-salvager", "class-brinewife", "class-smith", "class-reef-runner"][villagers.find(v) % 4]
			v.rescue()
			v.position = village_heart()
		village_stock["item-smoked-crab"] = 4
		village.tribesmen[survivor.tribesman_id].bloomed = true
		_on_sim_day(1)
		_toggle_village(true)
		_screenshot_and_quit()
	elif "--screenshot-doll" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-bronze-knife", 1)
		inventory.add(acting_pid, "item-salt-cloak", 1)
		inventory.add(acting_pid, "item-driftwood-club", 1)
		inventory.add(acting_pid, "item-smoked-crab", 3)
		inventory.add(acting_pid, "item-salt", 12)
		equip_toggle(acting_pid, "item-bronze-knife")
		equip_toggle(acting_pid, "item-salt-cloak")
		_toggle_doll(true)
		_screenshot_and_quit()
	elif "--screenshot-camp" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-wreck-timber", 12)
		inventory.add(acting_pid, "item-rope", 4)
		inventory.add(acting_pid, "item-driftwood", 40)
		intent_build("work-workbench")            # plants the camp ring
		# lay an L of wall: two horizontal, then a rotated vertical turning the corner
		var base := camp_center + Vector2(0, 120)
		for i in 3:
			player.position = base + Vector2(i * 34 - 40, 0)
			intent_build("work-driftwood-wall")
		for j in 3:
			player.position = base + Vector2(28, j * 30 - 40)
			intent_build("work-driftwood-wall")
			var last := works._next_id - 1
			_rotate_work(last)   # turn the side pieces upright
		player.position = base + Vector2(-10, 10)
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
	if net_mode == "client":
		return  # the server owns the world
	var s := SaveSystem.to_save(clock, devotion, village, works, verdict)
	s["game"] = {
		"inventory": inventory.inventories.duplicate(true),
		"player_stats": stats.actors.get(acting_pid, {}).duplicate(true),
		"player_pos": [player.position.x, player.position.y],
		"attuned": attuned.duplicate(true),
		"chapels": _chapels_to_dict(),
		"camp": [camp_center.x, camp_center.y] if camp_center != Vector2.INF else null,
		"rites_done_today": rites_done_today.duplicate(),
		"harvested_indices": harvested_indices.duplicate(),
		"boss_dead": boss_dead,
		"abilities": abilities.state.duplicate(true),
		"consumed_hp": consumed_hp.duplicate(true),
		"equipped": equipped.duplicate(true),
		"net_players": net_players.duplicate(), "next_pid": next_pid,
		"survivor": {"rescued": survivor.rescued if survivor != null else false,
			"tribesman_id": survivor.tribesman_id if survivor != null else -1,
			"pos": [survivor.position.x, survivor.position.y] if survivor != null else [0, 0]},
		"pool": villagers.map(func(v: DSVillager) -> Dictionary:
			return {"nid": int(v.get_meta("nid", 0)), "rescued": v.rescued, "tid": v.tribesman_id,
				"cls": v.def_class, "job": v.job_work_id, "x": v.position.x, "y": v.position.y}),
		"village_stock": village_stock.duplicate(),
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
		stats.actors[acting_pid] = g.player_stats
	var pp: Array = g.get("player_pos", [WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0])
	player.position = Vector2(float(pp[0]), float(pp[1]))
	if g.has("attuned"):
		attuned = SaveSystem._int_keys(g.get("attuned", {}))
	else:
		attuned = {1: g.get("attuned_gods", [])}
	net_players = g.get("net_players", {})
	next_pid = int(g.get("next_pid", 1))
	var camp: Variant = g.get("camp", null)
	if camp != null:
		camp_center = Vector2(float(camp[0]), float(camp[1]))
		_update_camp_ring()
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
		_spawn_work_visual(int(inst_id), str(inst.work_id), Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))), chapel_dict)
	boss_dead = bool(g.get("boss_dead", false))
	if g.has("abilities"):
		abilities.state = SaveSystem._int_keys(g.get("abilities", {}))
	else:
		# pre-Tally save: back-pay everything the flats already owe this player
		var back_pay := 6 + clock.day * 2 + (2 if boss_dead else 0) + (g.get("attuned_gods", []) as Array).size() \
			+ (1 if bool(g.get("survivor", {}).get("rescued", false)) else 0)
		abilities.state[1] = {"earned": back_pay, "alloc": {}}
		message += "\nThe flats have been keeping count: %d TEMPER owed. [T] to spend it." % back_pay
	consumed_hp = SaveSystem._int_keys(g.get("consumed_hp", {})) if g.has("consumed_hp") else {1: float(g.get("consumed_hp_bonus", 0.0))}
	equipped = SaveSystem._int_keys(g.get("equipped", {}))
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
	# restore the rescued pool (bodies were respawned by _spawn_stranded_pool in _ready)
	village_stock = g.get("village_stock", {})
	for pd: Dictionary in g.get("pool", []):
		for v: DSVillager in villagers:
			if int(v.get_meta("nid", -1)) == int(pd.nid):
				v.def_class = str(pd.get("cls", v.def_class))
				v.job_work_id = str(pd.get("job", ""))
				v.position = Vector2(float(pd.x), float(pd.y))
				if bool(pd.rescued):
					v.rescued = true
					v.tribesman_id = int(pd.get("tid", -1))
					var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
					v.set_mood(str(rec.get("expression", "steady")))
				v.set_label_name()
				break
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
	_net_tick(delta)
	if net_mode != "client":
		clock.advance(delta)
		stats.tick(delta)
		for pid: Variant in petrify.keys():
			if int(petrify[pid]) > 0:
				petrify[pid] = int(petrify[pid]) - 1
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
		if player.position.distance_to(s.position) < interact_range() and s.get_meta("god_id") not in attuned_for(my_pid):
			return "[E] Kneel"
	if survivor != null and not survivor.rescued and player.position.distance_to(survivor.position) < interact_range():
		return "[E] Rescue her"
	for god_id: String in chapels:
		if acting_pos().distance_to(chapels[god_id]) < interact_range():
			if _carrying_remnant():
				return "[E] Enshrine the remnant"
			return "[E] Hold the rite" if not rites_done_today.get(god_id, false) else "(rite already held today)"
	var pw := nearest_work(player.position)
	if pw >= 0:
		var winst: Dictionary = works.placed[pw]
		if bool(winst.get("in_use", false)):
			return "(the %s is working)" % str(registry.get_entity(str(winst.work_id)).name).to_lower()
		return "[E] Tend the %s" % str(registry.get_entity(str(winst.work_id)).name).to_lower()
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
	# click-and-drag placed works: grab, ghost, drop (synced in multiplayer)
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and not menu_open and not sheet_open and net_mode != "server":
		if (event as InputEventMouseButton).pressed:
			var mouse := get_global_mouse_position()
			for inst_id: Variant in work_visuals:
				if is_instance_valid(work_visuals[inst_id]) \
						and (work_visuals[inst_id] as Node2D).position.distance_to(mouse) < 30.0:
					drag_work_id = int(inst_id)
					(work_visuals[drag_work_id] as Node2D).modulate.a = 0.55
					break
		elif drag_work_id >= 0:
			var visual := work_visuals[drag_work_id] as Node2D
			visual.modulate.a = 1.0
			var snapped_pos := (get_global_mouse_position() / 16.0).round() * 16.0
			visual.position = snapped_pos
			if net_mode == "client":
				rpc_id(1, "srv_intent", "move_work", [drag_work_id, snapped_pos.x, snapped_pos.y])
			else:
				_move_work(drag_work_id, snapped_pos)
			drag_work_id = -1
		return
	if event is InputEventMouseMotion and drag_work_id >= 0:
		(work_visuals[drag_work_id] as Node2D).position = (get_global_mouse_position() / 16.0).round() * 16.0
		return
	# right-click a placed piece to spin it 90°; SHIFT+right-click to reclaim it
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT \
			and (event as InputEventMouseButton).pressed and not menu_open and not sheet_open and net_mode != "server":
		var mouse := get_global_mouse_position()
		var demolish := (event as InputEventMouseButton).shift_pressed
		for inst_id: Variant in work_visuals:
			if is_instance_valid(work_visuals[inst_id]) \
					and (work_visuals[inst_id] as Node2D).position.distance_to(mouse) < 30.0:
				var act := "demolish_work" if demolish else "rotate_work"
				if net_mode == "client":
					rpc_id(1, "srv_intent", act, [int(inst_id)])
				elif demolish:
					_demolish_work(int(inst_id))
				else:
					_rotate_work(int(inst_id))
				break
		return
	if village_panel_open and event is InputEventKey and event.pressed:
		var vkey := (event as InputEventKey).physical_keycode
		if vkey == KEY_ESCAPE or vkey == KEY_V:
			_toggle_village(false)
			return
		if vkey == KEY_G:
			if net_mode == "client":
				rpc_id(1, "srv_intent", "give_food", [])
			else:
				intent_give_food()
			return
	if doll_open and event is InputEventKey and event.pressed:
		var dkey := (event as InputEventKey).physical_keycode
		if dkey >= KEY_1 and dkey <= KEY_9:
			intent_equip_index(int(dkey - KEY_1))
			return
		if dkey == KEY_ESCAPE or dkey == KEY_I:
			_toggle_doll(false)
			return
	if sheet_open and event is InputEventKey and event.pressed:
		var skey := (event as InputEventKey).physical_keycode
		if skey >= KEY_1 and skey <= KEY_6:
			var virtues := registry.all_of("virtue")
			var virtue_id := str(virtues[int(skey - KEY_1)].id)
			if net_mode == "client":
				rpc_id(1, "srv_intent", "deallocate" if (event as InputEventKey).shift_pressed else "allocate", [virtue_id])
			elif (event as InputEventKey).shift_pressed:
				abilities.deallocate(acting_pid, virtue_id)
			else:
				abilities.allocate(acting_pid, virtue_id)
			_toggle_sheet(true)
			return
		if skey == KEY_ESCAPE or skey == KEY_T:
			_toggle_sheet(false)
			return
	if menu_open and event is InputEventKey and event.pressed:
		var key := (event as InputEventKey).physical_keycode
		if key >= KEY_1 and key <= KEY_9:
			var idx := int(key - KEY_1)
			var options := menu_works() if menu_mode == "build" else craftable_recipes()
			if idx < options.size():
				if menu_mode == "build":
					intent_build(str(options[idx]))
				else:
					intent_craft(str(options[idx]))
			_toggle_menu(false)
			return
		if key == KEY_ESCAPE or (key == KEY_B and menu_mode == "build") or (key == KEY_C and menu_mode == "craft"):
			_toggle_menu(false)
			return
		# the OTHER menu key falls through to switch modes below
	if event.is_action_pressed("interact"):
		intent_interact()
	elif event.is_action_pressed("craft"):
		sfx("ui")
		_toggle_menu(not (menu_open and menu_mode == "craft"), "craft")
	elif event.is_action_pressed("build"):
		sfx("ui")
		_toggle_menu(not (menu_open and menu_mode == "build"), "build")
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
		sfx("ui")
		_toggle_sheet(not sheet_open)
	elif event.is_action_pressed("inventory"):
		sfx("ui")
		_toggle_doll(not doll_open)
	elif event.is_action_pressed("village"):
		sfx("ui")
		_toggle_village(not village_panel_open)
	elif event.is_action_pressed("give_food"):
		if net_mode == "client":
			rpc_id(1, "srv_intent", "give_food", [])
		else:
			intent_give_food()
	elif event.is_action_pressed("save"):
		save_game()
		message = "The flats will remember. (saved)"
		_refresh_hud()

## --- intents (the only door into the sim from presentation) --------------------
## E is contextual: kneel at a shrine, rescue the stranded, hold a rite, else harvest.
func interact_range() -> float:
	return INTERACT_RANGE + abilities.mod_add(acting_pid, "interact-range")

func harvest_range() -> float:
	return HARVEST_RANGE + abilities.mod_add(acting_pid, "interact-range")

func intent_interact() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "interact", [])
		return true
	for s in shrines:
		var god_id: String = s.get_meta("god_id")
		if acting_pos().distance_to(s.position) < interact_range() and god_id not in attuned_for(acting_pid):
			return intent_kneel(god_id)
	# what you're standing ON wins: a chapel's rite before a nearby stranger
	for god_id: String in chapels:
		if acting_pos().distance_to(chapels[god_id]) < interact_range():
			if _carrying_remnant():
				return intent_enshrine(god_id)
			return intent_rite(god_id)
	if survivor != null and not survivor.rescued and acting_pos().distance_to(survivor.position) < interact_range():
		return intent_rescue()
	# a stranded stranger to rescue, or a villager to hear out
	for v: DSVillager in all_villagers():
		if acting_pos().distance_to(v.position) < interact_range():
			if not v.rescued:
				return intent_rescue_villager(v)
			return intent_talk(v)
	var near_work := nearest_work(acting_pos())
	if near_work >= 0:
		return intent_tend(near_work)
	return intent_harvest()

## Rescue a stranded survivor (not Anna — the pool strangers).
func intent_rescue_villager(v: DSVillager) -> bool:
	v.rescue()
	abilities.earn(acting_pid, 1)
	var cls := str(registry.get_entity(v.def_class).get("name", "survivor")).to_lower()
	message = "%s, a %s, follows you home. Give them work and a full belly and they'll keep the flats at bay." % [v.display_name, cls]
	_refresh_hud()
	return true

## Talk to a villager: hear them, and — if their door is a heard grievance —
## opening up IS meeting their Key. They bloom.
func intent_talk(v: DSVillager) -> bool:
	var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
	if rec.is_empty():
		return false
	var key := str(rec.get("key", ""))
	if not bool(rec.get("key_met", false)) and (key == "grievance-heard" or key.begins_with("respect") or key == "confided-in" or key == "audience-kept" or key == "left-alone" or key == "trusted-with-stores"):
		village.meet_key(v.tribesman_id)
		v.set_mood("content")
		sfx("bloom")
		message = "%s talks, and something loosens. They bloom — you'll see it in their work." % v.display_name
	else:
		var m := str(rec.get("expression", "steady"))
		var line := "'The flats are quiet today. That's the most you can ask of them.'"
		if m == "poorFood" or _stock_food_total() == 0:
			line = "'There's not much in the stores. A person works better fed.'"
		elif m in ["slacking", "spreadingDoubt", "pettyTheft"]:
			line = "'I don't know why I stay, some days. ...but I stay.'"
		elif bool(rec.get("bloomed", false)):
			line = "'Good to have somewhere to be. Thank you for that.'"
		message = "%s: %s" % [v.display_name, line]
	_refresh_hud()
	return true

## Where HOME is: the hearth if one burns, else a chapel, else the workbench,
## else the world's center. Anna settles here; so will everyone after her.
## Set / move the camp anchor and redraw its ring. Server broadcasts on change.
func _set_camp(pos: Vector2) -> void:
	camp_center = pos
	_update_camp_ring()

func _update_camp_ring() -> void:
	if net_mode == "server":
		return
	if camp_ring == null:
		camp_ring = Line2D.new()
		camp_ring.width = 3.0
		camp_ring.default_color = Color(0.42, 0.36, 0.26, 0.65)   # a salt-line drawn in the dust
		camp_ring.z_index = -7
		# a dashed ring of stakes reads better than a solid circle in pixel art
		var pts := PackedVector2Array()
		var seg := 64
		for i in range(seg + 1):
			if i % 2 == 0:   # dash: skip every other segment
				if pts.size() > 0:
					camp_ring.points = pts   # (Line2D can't do gaps; use posts instead)
			var a := TAU * i / float(seg)
			pts.append(Vector2(cos(a), sin(a)) * CAMP_RADIUS)
		camp_ring.points = pts
		add_child(camp_ring)
		# little boundary stakes at the compass points
		for k in 8:
			var a := TAU * k / 8.0
			var stake := SpriteKit.sprite("salt_pillar", Vector2(6, 12), Color("cfd8d2"))
			stake.position = Vector2(cos(a), sin(a)) * CAMP_RADIUS
			stake.modulate = Color(1, 1, 1, 0.8)
			stake.scale = Vector2(0.6, 0.6)
			camp_ring.add_child(stake)
	camp_ring.visible = camp_center != Vector2.INF
	if camp_center != Vector2.INF:
		camp_ring.position = camp_center

func village_heart() -> Vector2:
	var hearth := work_pos("work-hearth")
	if hearth != Vector2.INF:
		return hearth
	if camp_center != Vector2.INF:
		return camp_center
	for wid: String in ["work-chapel", "work-workbench"]:
		var pos := work_pos(wid)
		if pos != Vector2.INF:
			return pos
	return Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)

## The nearest placed work in reach that isn't a chapel (chapels have rites).
func nearest_work(from: Vector2) -> int:
	var best := interact_range()
	var found := -1
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		if str(inst.work_id) == "work-chapel":
			continue
		var d := from.distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
		if d < best:
			best = d
			found = int(inst_id)
	return found

## Tend a work: set it WORKING for the day (use is worship — its god gets the
## trickle). Tend again to hear about it instead.
func intent_tend(inst_id: int) -> bool:
	var inst: Dictionary = works.placed[inst_id]
	var work := registry.get_entity(str(inst.work_id))
	var god_id: String = work.get("godId", "neutral")
	var god_line := ""
	if god_id != "neutral":
		god_line = " %s's work — kept in use, it feeds them favor." % str(registry.get_entity(god_id).name)
	var what := str(work.get("purpose", work.get("text", "")))
	if not bool(inst.get("in_use", false)):
		works.set_in_use(inst_id, true)
		sfx("craft")
		message = "You tend the %s — WORKING until dawn.%s\n%s" % [str(work.name).to_lower(), god_line, what]
	else:
		message = "The %s is working.%s\n%s" % [str(work.name).to_lower(), god_line, what]
	_refresh_hud()
	return true

func _carrying_remnant() -> bool:
	for item_id: String in inventory._inv(acting_pid).keys():
		if registry.get_entity(item_id).get("category", "") == "remnant":
			return true
	return false

const KNEEL_HINTS := {
	"god-halor": "[Q] Pillar of Salt, when the pinch comes.",
	"god-maren": "[R] Call the Squall, when they crowd you.",
}

func intent_kneel(god_id: String) -> bool:
	if not devotion.attune(acting_pid, god_id):
		return false
	attuned_for(acting_pid).append(god_id)
	var god := registry.get_entity(god_id)
	message = "You kneel at the fallen shrine. %s: '%s'\n%s is with you — %s Their strength is not endless." % [
		str(god.voice.tone).split(";")[0], str(god.voice.sampleLine),
		str(god.name).to_upper(), str(KNEEL_HINTS.get(god_id, ""))]
	sfx("kneel")
	if god_id == "god-maren":
		inventory.add(acting_pid, "item-harpoon-verse", 1)
		message += "\nTucked in the shrine-stones: a VERSE OF THE HARPOON-SONG. Whalers say there are three."
	abilities.earn(acting_pid, 1)   # kneeling to a god tempers you
	_toggle_menu(false)
	_refresh_hud()
	return true

## Cast an invocation and hand its data-defined effects to the executor.
func intent_cast(invocation_id: String = "inv-pillar-of-salt") -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "cast", [invocation_id])
		return true
	var inv: Dictionary = devotion.cast(acting_pid, invocation_id)
	if inv.is_empty():
		var found := devotion._find_invocation(invocation_id)
		if not found.is_empty() and found.god_id in attuned_for(acting_pid):
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
			relief += 1.0 - abilities.mod_mult(acting_pid, "squall-cost-mult")
		if relief > 0.0:
			devotion._restore(acting_pid, "god-maren",
				float(found2.inv.vigorCost) * devotion.max_vigor("god-maren") * minf(relief, 0.9))
	message = str(inv.text)
	_refresh_hud()
	return true

## The effect executor: data-defined invocation effects become world changes.
func _apply_effect(effect: Dictionary) -> void:
	match str(effect.get("type", "")):
		"petrify-invulnerable":
			sfx("cast_pillar")
			petrify[acting_pid] = int(float(effect.get("duration", 6)) * 60.0 * abilities.mod_mult(acting_pid, "petrify-mult"))
			if acting_pid == my_pid:
				petrify_frames = int(petrify[acting_pid])
				player.modulate = Color("cfd0ce")
		"aoe-knockdown":
			var radius := float(effect.get("radius", 8)) * TILE
			for e in enemies.duplicate():
				if is_instance_valid(e) and acting_pos().distance_to(e.position) <= radius:
					e.stun(2.5)
		"lightning-strikes":
			var strikes := int(effect.get("magnitude", 3))
			var radius := float(effect.get("radius", 8)) * TILE
			var in_range := enemies.filter(func(e: DSEnemy) -> bool:
				return is_instance_valid(e) and acting_pos().distance_to(e.position) <= radius)
			in_range.sort_custom(func(a: DSEnemy, b: DSEnemy) -> bool:
				return acting_pos().distance_to(a.position) < acting_pos().distance_to(b.position))
			for i in mini(strikes, in_range.size()):
				var target: DSEnemy = in_range[i]
				_flash_bolt(target.position)
				sfx("bolt", target.position)
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
	abilities.earn(acting_pid, 1)   # saving someone tempers you differently
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
	sfx("rite")
	devotion.rite_day(acting_pid, god_id, "chapel", 1)
	message = "You lead the rite at %s's chapel. The shrine-light steadies a little." % str(registry.get_entity(god_id).name)
	_refresh_hud()
	return true

func intent_harvest() -> bool:
	var nearest: Area2D = null
	var best := harvest_range()
	for node in resource_nodes:
		if not is_instance_valid(node):
			continue
		var d := acting_pos().distance_to(node.position)
		if d < best:
			best = d
			nearest = node
	if nearest == null:
		return false
	sfx("harvest", nearest.position)
	inventory.add(acting_pid, nearest.get_meta("item_id"),
		int(nearest.get_meta("qty")) + int(abilities.mod_add(acting_pid, "harvest-bonus-qty")))
	if str(nearest.get_meta("item_id")) == "item-storm-glass" and inventory.count(acting_pid, "item-harpoon-verse") == 2:
		inventory.add(acting_pid, "item-harpoon-verse", 1)
		message = "Folded inside the storm-glass, impossibly: the LAST VERSE of the harpoon-song.\nYou know the whole making now. It wants a rite at a chapel — bronze, storm-glass, and good timber."
	harvested_indices.append(int(nearest.get_meta("idx", -1)))
	resource_nodes.erase(nearest)
	nearest.queue_free()
	_refresh_hud()
	return true

## F eats the first food in your pack. Two slots; a full belly refuses.
func intent_eat() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "eat", [])
		return true
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		var fstats: Dictionary = item.get("stats", {})
		if not fstats.has("foodHp"):
			continue
		if not stats.eat(acting_pid, float(fstats.foodHp), float(fstats.foodStamina), float(fstats.get("foodMinutes", 8)) * 60.0):
			message = "You're full. Come back to the rest of it when this wears off."
			_refresh_hud()
			return false
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
		sfx("eat")
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
	visible_sets.append_array(attuned_for(my_pid))
	var out: Array = []
	for god_id: String in order:
		if god_id not in visible_sets:
			continue
		for work: Dictionary in registry.all_of("work"):
			if work.get("godId", "") == god_id and not work.get("grim", false):
				out.append(str(work.id))
	return out

func _toggle_build_menu(open: bool) -> void:
	_toggle_menu(open, "build")

func _cost_str(cost: Array) -> String:
	var bits: Array[String] = []
	for c: Dictionary in cost:
		bits.append("%s×%d" % [str(registry.get_entity(str(c.itemId)).get("name", c.itemId)), int(c.qty)])
	return ", ".join(bits)

## Recipes you can see: tree recipes always; legend recipes only once you hold
## their fragments.
func craftable_recipes() -> Array:
	var out: Array = []
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "legend":
			var frags := int(recipe.get("unlock", {}).get("fragments", 0))
			if frags > 0 and inventory.count(acting_pid, str(recipe.get("fragmentItemId", ""))) < frags:
				continue
		out.append(str(recipe.id))
	return out

func _toggle_menu(open: bool, mode: String = "build") -> void:
	menu_open = open
	menu_mode = mode
	if menu_label == null:
		return
	menu_label.visible = open
	if not open:
		return
	if mode == "build":
		_render_build_menu()
	else:
		_render_craft_menu()

func _render_build_menu() -> void:
	var lines := ["BUILD — number to raise it, [B] to close"]
	var options := menu_works()
	var last_god := ""
	for i in options.size():
		var work := registry.get_entity(str(options[i]))
		var god_id: String = work.get("godId", "neutral")
		if god_id != last_god:
			last_god = god_id
			lines.append("· %s ·" % ("salvage" if god_id == "neutral" else str(registry.get_entity(god_id).name) + "'s works"))
		var afford := inventory.can_afford(acting_pid, work.get("buildCost", []))
		lines.append("%d. %s%s" % [i + 1, str(work.name), "" if afford else "  (can't afford)"])
		lines.append("     %s" % str(work.get("purpose", work.get("text", ""))))
		lines.append("     cost: %s" % _cost_str(work.get("buildCost", [])))
	if attuned_for(my_pid).size() < 2:
		lines.append("· more works open when you kneel at new shrines ·")
	menu_label.text = "\n".join(lines)

func _render_craft_menu() -> void:
	var lines := ["CRAFT — number to make it, [C] to close"]
	var options := craftable_recipes()
	for i in options.size():
		var recipe := registry.get_entity(str(options[i]))
		var item := registry.get_entity(str(recipe.output.itemId))
		var station: String = recipe.get("stationWorkId", "")
		if station == "":
			station = str(recipe.get("ritual", {}).get("atWorkId", ""))
		var afford := inventory.can_afford(acting_pid, recipe.get("inputs", []))
		var have_station := station == "" or works.count_of(station) > 0
		var tag := ""
		if not have_station:
			tag = "  (needs %s)" % str(registry.get_entity(station).name)
		elif not afford:
			tag = "  (can't afford)"
		var where := "  @ %s" % str(registry.get_entity(station).name) if station != "" else "  (by hand)"
		lines.append("%d. %s ×%d%s" % [i + 1, str(item.name), int(recipe.output.qty), tag])
		lines.append("     %s%s" % [_cost_str(recipe.get("inputs", [])), where])
	if options.is_empty():
		lines.append("Nothing to make yet — gather materials, raise a workbench.")
	menu_label.text = "\n".join(lines)

func intent_craft(recipe_id: String) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "craft", [recipe_id])
		return true
	var ok := inventory.craft(acting_pid, recipe_id, works)
	if ok:
		sfx("craft")
		var station: String = registry.get_entity(recipe_id).get("stationWorkId", "")
		if station != "":
			for inst_id: Variant in works.placed:
				if str(works.placed[inst_id].work_id) == station:
					works.set_in_use(int(inst_id), true)   # using it IS use
					break
		var recipe := registry.get_entity(recipe_id)
		if recipe.get("track", "") == "legend":
			var item := registry.get_entity(str(recipe.output.itemId))
			message = "THE RITE IS DONE. %s is yours.\n%s" % [str(item.name).to_upper(), str(item.get("legend", {}).get("history", ""))]
	_refresh_hud()
	return ok

func intent_craft_first() -> void:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "craft_first", [])
		return
	# a known legend always takes precedence — you don't accidentally make rope instead
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "legend" and intent_craft(str(recipe.id)):
			return
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "tree" and intent_craft(str(recipe.id)):
			return

## Swing at the nearest enemy in arc range. Costs stamina — tired arms miss nothing, they just can't.
func intent_attack() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "attack", [])
		return true
	var target: DSEnemy = null
	var best := ATTACK_RANGE
	for e in enemies:
		if not is_instance_valid(e):
			continue
		var d := acting_pos().distance_to(e.position)
		if d < best:
			best = d
			target = e
	if target == null:
		return false
	if not stats.spend_stamina(acting_pid, attack_stamina_cost()):
		message = "Too winded to swing. Breath comes back — or food raises the ceiling."
		_refresh_hud()
		return false
	_flash_swing(target.position)
	sfx("swing")
	sfx("hit", target.position)
	target.on_hit()
	if equipped_item(acting_pid, "weapon") == "item-marens-own-harpoon" \
			or abilities.talent_active(acting_pid, "talent-bolt-marked"):
		_flash_bolt(target.position)   # strike true and the bolt comes down on your mark
		sfx("bolt", target.position)
	if stats.damage(target, attack_damage()):
		_on_enemy_killed(target)
	return true

func equipped_item(pid: int, slot: String) -> String:
	return str(equipped.get(pid, {}).get(slot, ""))

## Equip an item from the pack into its doll slot; any current occupant returns
## to the pack. Toggling an already-equipped item unequips it.
func equip_toggle(pid: int, item_id: String) -> void:
	var item := registry.get_entity(item_id)
	var slot: String = str(item.get("slot", ""))
	if slot == "":
		return
	if not equipped.has(pid):
		equipped[pid] = {}
	var current: String = equipped_item(pid, slot)
	if current == item_id:                       # unequip
		equipped[pid].erase(slot)
		inventory.add(pid, item_id, 1)
	else:
		if inventory.count(pid, item_id) <= 0:
			return
		inventory.pay(pid, [{"itemId": item_id, "qty": 1}])
		if current != "":
			inventory.add(pid, current, 1)       # old piece back to the pack
		equipped[pid][slot] = item_id
	_recompute_vitals(pid)

func attack_damage() -> float:
	# your EQUIPPED weapon decides the swing; bare hands otherwise
	var w := equipped_item(acting_pid, "weapon")
	var dmg := ATTACK_DAMAGE
	if w != "":
		dmg = float(registry.get_entity(w).get("stats", {}).get("damage", ATTACK_DAMAGE))
	dmg = abilities.mod_add(acting_pid, "melee-damage", dmg)
	dmg = abilities.mod_add(acting_pid, "bolt-on-swing", dmg)
	return dmg

func armor_defense(pid: int) -> float:
	var a := equipped_item(pid, "armor")
	return float(registry.get_entity(a).get("stats", {}).get("defense", 0.0)) if a != "" else 0.0

func attack_stamina_cost() -> float:
	return maxf(ATTACK_STAMINA - abilities.mod_add(acting_pid, "attack-cost-reduction"), 5.0)

## Recompute everything the virtues touch on the body. Called on every
## allocation change, load, and remnant consumption.
func _recompute_vitals(pid: int = -1) -> void:
	if pid < 0:
		pid = acting_pid
	var a: Dictionary = stats.actors.get(pid, {})
	if a.is_empty():
		return
	a.base_hp = 60.0 + float(consumed_hp.get(pid, 0.0)) + abilities.mod_add(pid, "base-hp")
	a.food_slots = StatsSystem.FOOD_SLOTS + int(abilities.mod_add(pid, "food-slots"))
	a.regen_mult = abilities.mod_mult(pid, "stamina-regen-mult")
	a.eat_mult = abilities.mod_mult(pid, "eat-restore-mult")
	a.hp = minf(float(a.hp), stats.max_hp(pid))
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

func damage_player(amount: float, pid: int = -1) -> void:
	if pid < 0:
		pid = my_pid
	if int(petrify.get(pid, 0)) > 0:
		return  # the salt holds
	amount = maxf(amount - armor_defense(pid), 1.0)   # worn scale turns the worst of it
	# The Returning: what goes out comes back — once a day, even you
	if abilities.talent_active(pid, "talent-the-returning") and not cheat_death_used.get(pid, false) \
			and stats.hp(pid) - amount <= 0.0:
		cheat_death_used[pid] = true
		stats.actors[pid].hp = 1.0
		if pid == my_pid:
			sfx("rite")
		if pid == my_pid:
			message = "The tide takes you out — and brings you back. Once a day, Neris keeps that promise."
			_refresh_hud()
		_net_push_state(pid)
		_refresh_bars()
		return
	if pid == my_pid:
		sfx("grunt")
	if stats.damage(pid, amount):
		if pid == my_pid:
			sfx("death")
		# Death penalty is an open design question (GAME-SPEC); M1 placeholder:
		# wake at the village center, hurt pride only.
		if net_mode == "server":
			avatars[pid] = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
		elif pid == my_pid:
			player.position = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
		stats.heal_full(pid)
	_net_push_state(pid)
	_refresh_bars()

## Server: push a player's state to their peer (after damage etc. outside intents).
func _net_push_state(pid: int) -> void:
	if net_mode != "server":
		return
	for peer_id: Variant in peers:
		if int(peers[peer_id]) == pid:
			rpc_id(int(peer_id), "cl_player_state", _player_state(pid))
			return

func _on_enemy_killed(enemy: DSEnemy) -> void:
	sfx("kill", enemy.position)
	var creature := registry.get_entity(enemy.creature_id)
	for drop: Dictionary in creature.get("drops", []):
		var qty := int(drop.qty)
		if enemy.creature_id == "creature-scuttle-crab" and str(drop.itemId) == "item-crab-meat":
			qty += int(abilities.mod_add(acting_pid, "crab-bonus-drop"))  # the respectful way
		inventory.add(acting_pid, str(drop.itemId), qty)
	if enemy.is_boss:
		boss_dead = true
		abilities.earn(acting_pid, 2)   # nothing tempers like a king
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
		inventory.add(acting_pid, remnant_id, 1)
		message = "%s falls — the oldest sailor left, out of his depth at last. His wreck-ring is yours to salvage.\nSomething divine remains in him. A warm, reasonable voice: 'They'd ask you to feed it to them. I only ever ask you to eat.'\n[E] at a chapel to ENSHRINE it — or [X] to consume it. Some doors only open once." % str(creature.name)
	stats.unregister(enemy)
	enemies.erase(enemy)
	enemy.queue_free()
	_refresh_hud()

## The Verdict, in your hands: consume a remnant for permanent strength —
## and the god it belonged to dims, for everyone, forever.
func intent_consume_remnant() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "consume", [])
		return true
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		if item.get("category", "") != "remnant":
			continue
		var god_id: String = item.get("remnantOf", "god-halor")
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
		sfx("consume")
		consumed_hp[acting_pid] = float(consumed_hp.get(acting_pid, 0.0)) + 15.0 + abilities.mod_add(acting_pid, "consume-bonus-hp")
		_recompute_vitals()
		verdict.remnant_consume(acting_pid, god_id)
		message = "You eat what was left of a god's strength. You feel MAGNIFICENT.\nSomewhere, %s grows quieter — for everyone, forever. The warm voice sounds pleased." % str(registry.get_entity(god_id).name)
		_refresh_hud()
		return true
	return false

func intent_enshrine(god_id_of_chapel: String) -> bool:
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		if item.get("category", "") != "remnant":
			continue
		var god_id: String = item.get("remnantOf", god_id_of_chapel)
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
		verdict.remnant_enshrine(acting_pid, god_id)
		message = "You set the remnant in the chapel-stone. %s steadies — the whole world's worth of them.\nThe warm voice says nothing at all." % str(registry.get_entity(god_id).name)
		_refresh_hud()
		return true
	return false

func intent_build(work_id: String) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "build", [work_id])
		return true
	var work := registry.get_entity(work_id)
	if work.is_empty():
		return false
	var pos := acting_pos() + Vector2(40, 0)
	# the camp ring: first structure plants it, the rest must fall inside it
	if camp_center != Vector2.INF and pos.distance_to(camp_center) > CAMP_RADIUS:
		message = "Too far from camp. Stand within the ring to build — or drag a piece to found it wider."
		_refresh_hud()
		return false
	if not inventory.pay(acting_pid, work.get("buildCost", [])):
		message = "Not enough to raise the %s." % str(work.name).to_lower()
		_refresh_hud()
		return false
	if camp_center == Vector2.INF:
		_set_camp(pos)
		message = "You plant your camp here. Build within the ring; the flats are kinder inside it."
	var inst_id := works.place(work_id, acting_pid, pos)
	sfx("build", pos)
	if work_id == "work-chapel":
		# dedicate to the first attuned god who lacks one
		for god_id: String in attuned_for(acting_pid):
			if not chapels.has(god_id):
				message = "A chapel to %s, raised from wreck-timber. Hold rites here [E] — their strength returns through worship." % str(registry.get_entity(god_id).name)
				break
	_spawn_work_visual(inst_id, work_id, pos, {})
	_reassign_all_jobs()
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
			abilities.available(acting_pid), abilities.earned(acting_pid)]]
	var virtues := registry.all_of("virtue")
	for i in virtues.size():
		var v: Dictionary = virtues[i]
		var s := abilities.score(acting_pid, str(v.id))
		var pips := ""
		for p in AbilitiesSystem.VIRTUE_CAP:
			pips += "●" if p < s else "·"
		lines.append("%d. %-8s %s %2d   (%s)" % [i + 1, str(v.name), pips, s, str(registry.get_entity(str(v.godId)).name)])
		for talent: Dictionary in v.talents:
			var lit := s >= int(talent.threshold)
			lines.append("    %s %s (%d) — %s" % ["■" if lit else "□", str(talent.name), int(talent.threshold), str(talent.text)])
	sheet_label.text = "\n".join(lines)

## --- the pack & the paper doll ----------------------------------------------
## Equippable things you can act on: currently-equipped first (to unequip),
## then equippable items sitting in the pack.
func equippable_list() -> Array:
	var out: Array = []
	for slot: String in ["weapon", "armor", "trinket"]:
		var cur := equipped_item(acting_pid, slot)
		if cur != "":
			out.append(cur)
	for item_id: String in inventory._inv(acting_pid).keys():
		if str(registry.get_entity(item_id).get("slot", "")) != "" and item_id not in out:
			out.append(item_id)
	return out

func _toggle_doll(open: bool) -> void:
	doll_open = open
	if doll_label == null:
		return
	doll_label.visible = open
	doll_back.visible = open
	doll_sprite.visible = open
	if not open:
		return
	var weapon := equipped_item(acting_pid, "weapon")
	var armor := equipped_item(acting_pid, "armor")
	var lines := ["THE PACK & THE DOLL — number to equip/unequip, [I] to close", ""]
	lines.append("        WEAPON: %s%s" % [
		str(registry.get_entity(weapon).name) if weapon != "" else "— bare hands —",
		"  (%d dmg)" % int(attack_damage()) if true else ""])
	lines.append("        ARMOR:  %s%s" % [
		str(registry.get_entity(armor).name) if armor != "" else "— none —",
		"  (−%d dmg)" % int(armor_defense(acting_pid)) if armor != "" else ""])
	lines.append("        health %d / %d" % [int(stats.hp(acting_pid)), int(stats.max_hp(acting_pid))])
	lines.append("")
	var equippable := equippable_list()
	if equippable.size() > 0:
		lines.append("EQUIP:")
		for i in equippable.size():
			var it := registry.get_entity(str(equippable[i]))
			var slot := str(it.get("slot", ""))
			var worn := equipped_item(acting_pid, slot) == str(equippable[i])
			var stat := ""
			if slot == "weapon":
				stat = "  %d dmg" % int(it.get("stats", {}).get("damage", 0))
			elif slot == "armor":
				stat = "  −%d dmg" % int(it.get("stats", {}).get("defense", 0))
			lines.append("  %d. %s%s%s" % [i + 1, str(it.name), stat, "   ✓ worn — press to remove" if worn else ""])
		lines.append("")
	lines.append("PACK:")
	var any := false
	for item_id: String in inventory._inv(acting_pid).keys():
		lines.append("  %s ×%d" % [str(registry.get_entity(item_id).name), inventory.count(acting_pid, item_id)])
		any = true
	if not any:
		lines.append("  (empty hands)")
	doll_label.text = "\n".join(lines)

func intent_equip_index(i: int) -> void:
	var equippable := equippable_list()
	if i < 0 or i >= equippable.size():
		return
	var item_id := str(equippable[i])
	if net_mode == "client":
		rpc_id(1, "srv_intent", "equip", [item_id])
	else:
		equip_toggle(acting_pid, item_id)
	if doll_open:
		_toggle_doll(true)

## --- the village panel ------------------------------------------------------
func _toggle_village(open: bool) -> void:
	village_panel_open = open
	if village_panel == null:
		return
	village_panel.visible = open
	(village_panel.get_meta("back") as ColorRect).visible = open
	if not open:
		return
	var lines := ["THE VILLAGE — [G] pool your food into the stores, [V] to close", ""]
	var roster := all_villagers().filter(func(v: DSVillager) -> bool: return v.rescued and v.tribesman_id >= 0)
	if roster.is_empty():
		lines.append("No one has joined you yet. Strangers are stranded out on the flats — find them.")
	else:
		lines.append("%-10s %-11s %-13s %s" % ["NAME", "TRADE", "MOOD", "NEEDS"])
		for v: DSVillager in roster:
			var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
			var cls := str(registry.get_entity(v.def_class).get("name", "?"))
			var moodw := "content" if bool(rec.get("bloomed", false)) else v._mood_word()
			var need := _villager_need(v, rec)
			lines.append("%-10s %-11s %-13s %s" % [v.display_name.left(10), cls.left(11), moodw.left(13), need])
	lines.append("")
	var food := _stock_food_total()
	var stores: Array[String] = []
	for item_id: String in village_stock:
		stores.append("%d %s" % [int(village_stock[item_id]), str(registry.get_entity(item_id).name)])
	lines.append("STORES: %s" % (", ".join(stores) if stores.size() > 0 else "empty"))
	lines.append("Your people eat %d food a day; the stores hold %d. Feed them, or they sour." % [roster.size(), food])
	village_panel.text = "\n".join(lines)

func _villager_need(v: DSVillager, rec: Dictionary) -> String:
	if rec.is_empty():
		return ""
	if bool(rec.get("bloomed", false)):
		return "nothing — thriving"
	var key := str(rec.get("key", ""))
	if key == "grievance-heard" or key == "confided-in" or key == "audience-kept":
		return "wants to be heard — talk to them [E]"
	if key.begins_with("shrine-access"):
		return "a chapel to their god"
	if key == "schedule-night":
		return "night work"
	if key == "right-job" or key == "promoted":
		return "the right work"
	if key == "left-alone":
		return "to be left be — don't fuss"
	return "attention — a good day or two"

## Pool the player's food into the shared stores (feed the village).
func intent_give_food() -> void:
	var given := 0
	for item_id: String in inventory._inv(acting_pid).keys():
		if str(registry.get_entity(item_id).get("category", "")) == "food":
			var n := inventory.count(acting_pid, item_id)
			village_stock[item_id] = int(village_stock.get(item_id, 0)) + n
			inventory.pay(acting_pid, [{"itemId": item_id, "qty": n}])
			given += n
	sfx("build")
	message = "You set %d food in the village stores. A fed camp is a loyal one." % given
	if village_panel_open:
		_toggle_village(true)
	_refresh_hud()

## One-shot audio, guarded for the headless server.
func sfx(name: String, at := Vector2.INF, base_db := 0.0) -> void:
	if net_mode != "server" and sound != null:
		sound.play(name, at, player.position if at != Vector2.INF else Vector2.INF, base_db)

## Move a placed work (drag-drop commit). Server/offline authority.
func _move_work(inst_id: int, pos: Vector2) -> void:
	if not works.placed.has(inst_id):
		return
	var inst: Dictionary = works.placed[inst_id]
	var old_pos := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
	# dragging a piece may FOUND or RE-CENTER the camp if it's the only anchor;
	# otherwise it must land inside the ring
	if camp_center != Vector2.INF and works.placed.size() > 1 and pos.distance_to(camp_center) > CAMP_RADIUS:
		if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
			(work_visuals[inst_id] as Node2D).position = old_pos   # snap back
		message = "That's outside the camp ring."
		_refresh_hud()
		return
	inst.x = pos.x
	inst.y = pos.y
	if camp_center == Vector2.INF or works.placed.size() == 1:
		_set_camp(pos)   # a lone structure carries the camp with it
	# a chapel carries its dedication with it
	for god_id: String in chapels.keys():
		if (chapels[god_id] as Vector2).distance_to(old_pos) < 1.0:
			chapels[god_id] = pos
	if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
		(work_visuals[inst_id] as Node2D).position = pos
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Reclaim a placed work: remove it and refund HALF its build cost (rounded down).
## The kindest "sell" the flats offer — there's no merchant, only what you salvage back.
func _demolish_work(inst_id: int) -> void:
	if not works.placed.has(inst_id):
		return
	var inst: Dictionary = works.placed[inst_id]
	var work := registry.get_entity(str(inst.work_id))
	var pos := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
	var refunded: Array[String] = []
	for c: Dictionary in work.get("buildCost", []):
		var back := int(c.qty) / 2
		if back > 0:
			inventory.add(acting_pid, str(c.itemId), back)
			refunded.append("%d %s" % [back, str(registry.get_entity(str(c.itemId)).get("name", c.itemId))])
	# forget chapel dedication if this was one
	for god_id: String in chapels.keys():
		if (chapels[god_id] as Vector2).distance_to(pos) < 4.0:
			chapels.erase(god_id)
	works.placed.erase(inst_id)
	if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
		work_visuals[inst_id].queue_free()
	work_visuals.erase(inst_id)
	# if that was the last structure, the camp un-plants (re-found it anywhere)
	if works.placed.is_empty():
		camp_center = Vector2.INF
		_update_camp_ring()
	sfx("build")
	message = "You reclaim the %s.%s" % [str(work.name).to_lower(),
		"  Salvaged: %s." % ", ".join(refunded) if refunded.size() > 0 else ""]
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Rotate a placed work 90° (walls, fences — everything can turn).
func _rotate_work(inst_id: int) -> void:
	if not works.placed.has(inst_id):
		return
	var inst: Dictionary = works.placed[inst_id]
	inst.rot = (int(inst.get("rot", 0)) + 90) % 360
	if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
		(work_visuals[inst_id] as Node2D).rotation_degrees = float(inst.rot)
	sfx("build")
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Shared by building and loading: the physical body of a placed work.
## chapel_hint maps god_id -> [x, y] from a save; empty when building live.
func _spawn_work_visual(inst_id: int, work_id: String, pos: Vector2, chapel_hint: Dictionary) -> void:
	var work := registry.get_entity(work_id)
	var work_sprites := {
		"work-workbench": "workbench", "work-chapel": "chapel", "work-smokehouse": "smokehouse",
		"work-hearth": "hearth", "work-driftwood-wall": "wall", "work-yoke-post": "yoke_post",
		"work-salt-cellar": "salt_cellar", "work-lightning-rod": "lightning_rod",
		"work-storm-cistern": "storm_cistern",
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
			for g: String in attuned_for(acting_pid):
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
	visual.set_meta("inst_id", inst_id)
	if works.placed.has(inst_id):
		visual.rotation_degrees = float(works.placed[inst_id].get("rot", 0))
	if work.get("blocks", false):
		var body := StaticBody2D.new()
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(30, 14)   # a wall segment's footprint (rotates with the visual)
		shape.shape = rect
		body.add_child(shape)
		visual.add_child(body)
	work_visuals[inst_id] = visual
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
				sfx("bloom")
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
	if net_mode != "client":
		_spawn_stranded_pool()

## Scatter a handful of stranded coast-folk to find and bring home. Deterministic
## (seeded) so the server and every client agree on who is where.
func _spawn_stranded_pool() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var spots := [Vector2(TILE * 44, TILE * 20), Vector2(TILE * 6, TILE * 18),
		Vector2(TILE * 40, TILE * 28), Vector2(TILE * 16, TILE * 27)]
	for i in spots.size():
		var v := DSVillager.new()
		v.host = self
		v.tribesman_id = -1
		_villager_nid += 1
		v.set_meta("nid", _villager_nid)
		v.display_name = NAME_POOL[rng.randi() % NAME_POOL.size()]
		v.def_class = CLASS_POOL[rng.randi() % CLASS_POOL.size()]
		var t1: String = TRAIT_POOL[rng.randi() % TRAIT_POOL.size()]
		var t2: String = TRAIT_POOL[rng.randi() % TRAIT_POOL.size()]
		v.def_traits = [t1] if t1 == t2 else [t1, t2]
		v.def_patron = "god-halor"
		v.position = spots[i]
		add_child(v)
		villagers.append(v)

func all_villagers() -> Array:
	var out: Array = []
	if survivor != null:
		out.append(survivor)
	out.append_array(villagers)
	return out

func _stock_food_total() -> int:
	var n := 0
	for item_id: String in village_stock:
		if str(registry.get_entity(item_id).get("category", "")) == "food":
			n += int(village_stock[item_id])
	return n

func _stock_take_one_food() -> bool:
	for item_id: String in village_stock:
		if str(registry.get_entity(item_id).get("category", "")) == "food" and int(village_stock[item_id]) > 0:
			village_stock[item_id] = int(village_stock[item_id]) - 1
			if village_stock[item_id] <= 0:
				village_stock.erase(item_id)
			return true
	return false

## The village lives once a day: everyone works, eats, and their mood shifts.
func _village_dawn() -> void:
	var rite_led := rites_done_today.values().any(func(v: bool) -> bool: return v)
	rites_done_today.clear()
	# 1. WORK: settled villagers with a job produce — food to the stores, materials to you
	var produced: Array[String] = []
	for v: DSVillager in all_villagers():
		if not v.rescued or v.tribesman_id < 0:
			continue
		if v.position.distance_to(village_heart()) > DSVillager.SETTLE_RADIUS + 80.0:
			continue   # too far out to have worked today
		var job: Array = JOBS.get(v.def_class, [])
		if job.is_empty() or str(job[1]) == "":
			continue
		var station: String = job[0]
		if station != "" and works.count_of(station) == 0:
			continue   # their building isn't built
		if station != "":
			# their labor keeps the station fed to its god
			for inst_id: Variant in works.placed:
				if str(works.placed[inst_id].work_id) == station:
					works.set_in_use(int(inst_id), true)
					break
		var qty := int(round(float(job[2]) * village.output_per_hour(v.tribesman_id)))
		if qty <= 0:
			continue
		var item_id := str(job[1])
		if bool(job[3]):
			village_stock[item_id] = int(village_stock.get(item_id, 0)) + qty
		else:
			inventory.add(acting_pid, item_id, qty)
		produced.append("%s %s" % [qty, str(registry.get_entity(item_id).name)])
	# 2. EAT + MOOD: each villager eats from the stores; hunger and neglect sour them
	var deserters: Array[DSVillager] = []
	for v: DSVillager in all_villagers():
		if not v.rescued or v.tribesman_id < 0:
			continue
		var conditions: Array = ["rested"]
		if rite_led:
			conditions.append("riteAttended")
		if not _stock_take_one_food():
			conditions.append("poorFood")   # hungry
		if str(v.def_patron) != "" and not chapels.has(v.def_patron):
			conditions.append("noShrineAccess")
		village.drift_day(v.tribesman_id, conditions)
		var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
		v.set_mood(str(rec.get("expression", "steady")))
		if str(rec.get("expression", "")) == "desertion":
			deserters.append(v)
	# 3. CONSEQUENCE: the truly neglected walk off into the flats
	for v: DSVillager in deserters:
		message = "%s has left the village. The flats keep what a poor camp cannot." % v.display_name
		village.tribesmen.erase(v.tribesman_id)
		villagers.erase(v)
		if v == survivor:
			survivor.rescued = false
		v.queue_free()
	if produced.size() > 0 and net_mode != "client":
		message = "Dawn. Your people worked: %s." % ", ".join(produced)
	if village_panel_open:
		_toggle_village(true)

## Assign the nearest matching station as this villager's job (or forager/idle).
func assign_job(v: DSVillager) -> void:
	var job: Array = JOBS.get(v.def_class, [])
	if job.is_empty():
		return
	var station: String = job[0]
	if station == "" or works.count_of(station) > 0:
		v.job_work_id = station   # "" = forager (needs no building)

func _reassign_all_jobs() -> void:
	for v: DSVillager in all_villagers():
		if v.rescued and v.job_work_id == "":
			assign_job(v)

func _on_sim_day(_day: int) -> void:
	_village_dawn()
	devotion.villager_trickle_day(acting_pid, "god-halor", village.devout_count("god-halor"))
	for inst_id: Variant in works.placed:
		works.placed[inst_id].in_use = false   # dawn: works rest until tended
	village.end_of_day()
	cheat_death_used.clear()
	for pid: Variant in stats.actors:
		if pid is int:
			abilities.earn(int(pid), 2)   # every survived day tempers everyone
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
	if net_mode == "client":
		return  # the server's beasts arrive as mirrors
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
			sfx("thunder")
	daynight.color = tint
	if net_mode != "server" and sound != null:
		sound.ambience("amb_storm" if is_storm_day() else ("amb_night" if clock.is_night() else "amb_day"))
	if net_mode == "server" and clock.minute_of_day % 5 == 0:
		rpc("cl_world_sync", _world_sync())
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
	# the pack & paper doll
	doll_back = ColorRect.new()
	doll_back.position = Vector2(360, 120)
	doll_back.size = Vector2(560, 470)
	doll_back.color = Color(0.949, 0.937, 0.910, 0.95)
	doll_back.visible = false
	layer.add_child(doll_back)
	doll_sprite = SpriteKit.sprite("survivor", Vector2(22, 30), Color("c8865a"))
	doll_sprite.position = Vector2(790, 400)
	doll_sprite.scale = Vector2(4.0, 4.0)
	doll_sprite.visible = false
	layer.add_child(doll_sprite)
	doll_label = Label.new()
	doll_label.position = Vector2(376, 132)
	doll_label.custom_minimum_size = Vector2(528, 0)
	doll_label.add_theme_color_override("font_color", Color("3b3428"))
	doll_label.add_theme_font_size_override("font_size", 13)
	doll_label.visible = false
	layer.add_child(doll_label)
	var vp_back := ColorRect.new()
	vp_back.position = Vector2(330, 96)
	vp_back.size = Vector2(620, 540)
	vp_back.color = Color(0.949, 0.937, 0.910, 0.95)
	vp_back.visible = false
	vp_back.name = "VillageBack"
	layer.add_child(vp_back)
	village_panel = Label.new()
	village_panel.position = Vector2(346, 108)
	village_panel.custom_minimum_size = Vector2(588, 0)
	village_panel.add_theme_color_override("font_color", Color("3b3428"))
	village_panel.add_theme_font_size_override("font_size", 13)
	village_panel.visible = false
	village_panel.set_meta("back", vp_back)
	layer.add_child(village_panel)

func _refresh_bars() -> void:
	if hp_bar == null:
		return
	hp_bar.size.x = 158.0 * stats.hp(acting_pid) / maxf(stats.max_hp(acting_pid), 1.0)
	stamina_bar.size.x = 158.0 * stats.stamina(acting_pid) / maxf(stats.max_stamina(acting_pid), 1.0)
	if "god-halor" in attuned_for(my_pid):
		var s: Dictionary = devotion.state.get(acting_pid, {}).get("god-halor", {})
		vigor_bar.size.x = 158.0 * float(s.get("vigor", 0)) / devotion.max_vigor("god-halor")
	else:
		vigor_bar.size.x = 0.0
	if maren_bar != null:
		if "god-maren" in attuned_for(my_pid):
			var m: Dictionary = devotion.state.get(acting_pid, {}).get("god-maren", {})
			maren_bar.size.x = 158.0 * float(m.get("vigor", 0)) / devotion.max_vigor("god-maren")
		else:
			maren_bar.size.x = 0.0

func _refresh_hud() -> void:
	if hud == null:
		return
	var inv := ""
	for item_id: String in inventory._inv(acting_pid):
		inv += "%s ×%d   " % [str(registry.get_entity(item_id).get("name", item_id)), inventory.count(acting_pid, item_id)]
	var fed: int = (stats.actors.get(acting_pid, {}).get("foods", []) as Array).size()
	var weather := ""
	if is_storm_day():
		weather = "  — THE GREAT STORM"
	elif "god-maren" in attuned_for(my_pid) and (clock.day + 1) % 4 == 3:
		weather = "  — Maren whispers: storm tomorrow"
	hud.text = "Day %d, %02d:%02d%s%s%s%s\n%s\n[WASD] move  [E] interact  [C] craft  [B] build  [F] eat  [I] pack  [V] village  [T] tally  [SPACE] attack  [drag] move  [R-click] turn  [Shift+R-click] reclaim%s\n%s" % [
		clock.day + 1, clock.minute_of_day / 60, clock.minute_of_day % 60, weather,
		"  — night. NIGHT BELONGS TO THE HOUNDS." if clock.is_night() else "",
		"  |  fed ×%d" % fed if fed > 0 else "", _direction_hints(),
		inv if inv != "" else "(empty hands)",
		("  [Q] Pillar of Salt" if "god-halor" in attuned_for(my_pid) else "") + ("  [R] Call the Squall" if "god-maren" in attuned_for(my_pid) else ""), message]

## Where the unfinished business is: unvisited shrines, the stranded woman.
func _direction_hints() -> String:
	var bits: Array[String] = []
	for s in shrines:
		if s.get_meta("god_id") not in attuned_for(my_pid):
			bits.append("a pale shrine %s" % _bearing(s.position))
	if survivor != null and not survivor.rescued:
		bits.append("someone stranded %s" % _bearing(survivor.position))
	var verses := inventory.count(acting_pid, "item-harpoon-verse")
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
		"save": [KEY_F5], "sheet": [KEY_T], "inventory": [KEY_I], "village": [KEY_V], "give_food": [KEY_G],
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


## ===========================================================================
## NET — host-authoritative co-op (ARCHITECTURE.md §6).
## Server: runs the whole sim headless; clients send INTENTS and positions,
## receive their per-player state + light world syncs. The world layout is
## deterministic (seeded), so sync is deltas, not geometry.
## ===========================================================================
var _net_connect_addr := ""
var _username := ""

func attuned_for(pid: int) -> Array:
	if not attuned.has(pid):
		attuned[pid] = []
	return attuned[pid]

## Where the acting player stands (server: last reported avatar position).
func acting_pos() -> Vector2:
	if net_mode == "server":
		return avatars.get(acting_pid, Vector2.INF)
	return player.position

## Nearest player to a point — what enemies hunt. Returns {pos, pid}.
func nearest_threat(from: Vector2) -> Dictionary:
	if net_mode != "server":
		return {"pos": player.position, "pid": my_pid}
	var best_d := INF
	var best := {"pos": Vector2.INF, "pid": -1}
	for pid: Variant in avatars:
		var d: float = from.distance_to(avatars[pid])
		if d < best_d:
			best_d = d
			best = {"pos": avatars[pid], "pid": int(pid)}
	return best

func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var port := NET_PORT
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	peer.create_server(port, 16)
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_disconnected.connect(_on_peer_left)
	player.visible = false   # the server is nobody
	print("DRIED SEA server v%s on udp/%d - world day %d" % [GAME_VERSION, port, clock.day + 1])

func _start_client() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			_username = a.trim_prefix("--name=")
	if _username == "":
		_username = OS.get_environment("USERNAME")
	if _username == "":
		_username = "drifter"
	var parts := _net_connect_addr.split(":")
	var peer := ENetMultiplayerPeer.new()
	peer.create_client(parts[0], int(parts[1]) if parts.size() > 1 else NET_PORT)
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func() -> void:
		rpc_id(1, "srv_hello", _username, GAME_VERSION))
	multiplayer.connection_failed.connect(func() -> void:
		message = "Could not reach the server at %s. The flats are quiet." % _net_connect_addr
		_refresh_hud())
	multiplayer.server_disconnected.connect(func() -> void:
		message = "The server has gone under. Your deeds are saved there."
		_refresh_hud())
	message = "Crossing the flats to %s ..." % _net_connect_addr
	skip_autoload = true

## --- server-side RPCs -------------------------------------------------------
@rpc("any_peer", "reliable")
func srv_hello(username: String, version: String) -> void:
	if net_mode != "server":
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if version != GAME_VERSION:
		rpc_id(peer_id, "cl_message", "Your build is v%s; the server runs v%s. Grab the new build." % [version, GAME_VERSION])
		return
	var pid: int
	if net_players.has(username):
		pid = int(net_players[username])
	else:
		next_pid += 1
		pid = next_pid
		net_players[username] = pid
		stats.register(pid, 60.0, 60.0)
		abilities.earn(pid, 6 + clock.day * 2)   # late joiners get the days they missed
	if not stats.actors.has(pid):
		stats.register(pid, 60.0, 60.0)
	peers[peer_id] = pid
	avatars[pid] = Vector2(WORLD.x * TILE / 2.0, WORLD.y * TILE / 2.0)
	acting_pid = pid
	_recompute_vitals(pid)
	print("joined: %s (pid %d)" % [username, pid])
	rpc_id(peer_id, "cl_welcome", pid, _player_state(pid), _world_sync())
	rpc("cl_players", _players_snapshot())
	save_game()

@rpc("any_peer", "reliable")
func srv_intent(kind: String, args: Array) -> void:
	if net_mode != "server":
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not peers.has(peer_id):
		return
	acting_pid = peers[peer_id]
	message = ""
	match kind:
		"interact": intent_interact()
		"attack": intent_attack()
		"cast": intent_cast(str(args[0]))
		"eat": intent_eat()
		"craft_first": intent_craft_first()
		"craft": intent_craft(str(args[0]))
		"build": intent_build(str(args[0]))
		"consume": intent_consume_remnant()
		"allocate": abilities.allocate(acting_pid, str(args[0]))
		"deallocate": abilities.deallocate(acting_pid, str(args[0]))
		"equip": equip_toggle(acting_pid, str(args[0]))
		"give_food": intent_give_food()
		"move_work": _move_work(int(args[0]), Vector2(float(args[1]), float(args[2])))
		"rotate_work": _rotate_work(int(args[0]))
		"demolish_work": _demolish_work(int(args[0]))
	rpc_id(peer_id, "cl_player_state", _player_state(acting_pid))
	rpc("cl_world_sync", _world_sync())

@rpc("any_peer", "unreliable_ordered")
func srv_pos(x: float, y: float) -> void:
	if net_mode != "server":
		return
	var pid: int = peers.get(multiplayer.get_remote_sender_id(), -1)
	if pid > 0:
		avatars[pid] = Vector2(x, y)

func _on_peer_left(peer_id: int) -> void:
	var pid: int = peers.get(peer_id, -1)
	peers.erase(peer_id)
	avatars.erase(pid)
	rpc("cl_players", _players_snapshot())
	save_game()

## --- payload builders (server) ----------------------------------------------
func _player_state(pid: int) -> Dictionary:
	return {
		"pid": pid,
		"inventory": inventory.inventories.get(pid, {}),
		"stats": stats.actors.get(pid, {}),
		"abilities": abilities.state.get(pid, {}),
		"devotion": devotion.state.get(pid, {}),
		"attuned": attuned_for(pid),
		"equipped": equipped.get(pid, {}),
		"petrify": int(petrify.get(pid, 0)),
		"message": message,
	}

func _world_sync() -> Dictionary:
	var enemy_list := []
	for e in enemies:
		if is_instance_valid(e):
			enemy_list.append({"nid": _enemy_nid(e), "creature": e.creature_id,
				"x": e.position.x, "y": e.position.y, "hp": stats.hp(e)})
	var specials := []
	var extra_defs := []
	for n in resource_nodes:
		if is_instance_valid(n) and int(n.get_meta("idx", -1)) >= STORM_GLASS_IDX_BASE:
			specials.append({"item": n.get_meta("item_id"), "x": n.position.x, "y": n.position.y, "idx": n.get_meta("idx")})
	for i in range(84, node_defs.size()):
		var d: Dictionary = node_defs[i]
		extra_defs.append({"item_id": d.item_id, "x": (d.pos as Vector2).x, "y": (d.pos as Vector2).y, "idx": d.idx})
	return {
		"day": clock.day, "minute": clock.minute_of_day,
		"harvested": harvested_indices, "extra_defs": extra_defs,
		"works": works.placed, "chapels": _chapels_to_dict(),
		"camp": [camp_center.x, camp_center.y] if camp_center != Vector2.INF else null,
		"boss_dead": boss_dead, "enemies": enemy_list, "specials": specials,
		"villager": {"rescued": survivor.rescued, "x": survivor.position.x, "y": survivor.position.y},
		"pool": villagers.map(func(v: DSVillager) -> Dictionary:
			return {"nid": int(v.get_meta("nid", 0)), "name": v.display_name, "cls": v.def_class,
				"x": v.position.x, "y": v.position.y, "rescued": v.rescued, "mood": v.mood, "job": v.job_work_id}),
		"stock": village_stock,
	}

func _players_snapshot() -> Array:
	var out := []
	for username: String in net_players:
		var pid := int(net_players[username])
		if avatars.has(pid):
			var p: Vector2 = avatars[pid]
			out.append({"pid": pid, "name": username, "x": p.x, "y": p.y})
	return out

func _enemy_nid(e: DSEnemy) -> int:
	if not enemy_net_ids.has(e):
		_next_enemy_net_id += 1
		enemy_net_ids[e] = _next_enemy_net_id
	return enemy_net_ids[e]

## --- client-side RPCs ---------------------------------------------------------
@rpc("authority", "reliable")
func cl_welcome(pid: int, pstate: Dictionary, wsync: Dictionary) -> void:
	my_pid = pid
	acting_pid = pid
	cl_player_state(pstate)
	cl_world_sync(wsync)
	message = "You cross onto the shared flats as %s. Day %d." % [_username, clock.day + 1]
	_refresh_hud()
	if "--probe" in OS.get_cmdline_user_args():
		print("PROBE OK: joined as pid %d, day %d, %d enemies mirrored" % [pid, clock.day + 1, enemies.size()])
		get_tree().quit(0)

@rpc("authority", "reliable")
func cl_player_state(p: Dictionary) -> void:
	inventory.inventories[my_pid] = p.get("inventory", {})
	stats.actors[my_pid] = p.get("stats", {})
	abilities.state[my_pid] = p.get("abilities", {})
	devotion.state[my_pid] = p.get("devotion", {})
	attuned[my_pid] = p.get("attuned", [])
	equipped[my_pid] = p.get("equipped", {})
	petrify_frames = int(p.get("petrify", 0))
	if doll_open:
		_toggle_doll(true)
	if player != null:
		player.modulate = Color("cfd0ce") if petrify_frames > 0 else Color.WHITE
	if str(p.get("message", "")) != "":
		message = str(p.message)
	_refresh_hud()
	_refresh_bars()
	if sheet_open:
		_toggle_sheet(true)

@rpc("authority", "reliable")
func cl_world_sync(w: Dictionary) -> void:
	clock.day = int(w.get("day", 0))
	clock.minute_of_day = int(w.get("minute", 360))
	daynight.color = _tint_for_minute(clock.minute_of_day)
	var wcamp: Variant = w.get("camp", null)
	camp_center = Vector2(float(wcamp[0]), float(wcamp[1])) if wcamp != null else Vector2.INF
	_update_camp_ring()
	# extra node defs the server minted after world-gen (boss hoard etc.)
	for d: Dictionary in w.get("extra_defs", []):
		if int(d.idx) >= node_defs.size():
			var pos := Vector2(float(d.x), float(d.y))
			node_defs.append({"item_id": str(d.item_id), "pos": pos, "idx": int(d.idx)})
			_spawn_one_node(str(d.item_id), pos, int(d.idx))
	# harvested nodes vanish (deterministic layout means that's the whole diff)
	harvested_indices = (w.get("harvested", []) as Array).map(func(v: Variant) -> int: return int(v))
	for node in resource_nodes.duplicate():
		var idx := int(node.get_meta("idx", -1))
		if idx < STORM_GLASS_IDX_BASE and idx in harvested_indices:
			resource_nodes.erase(node)
			node.queue_free()
	# storm-glass and other ephemerals
	var have_specials := {}
	for node in resource_nodes:
		if is_instance_valid(node) and int(node.get_meta("idx", -1)) >= STORM_GLASS_IDX_BASE:
			have_specials[int(node.get_meta("idx"))] = node
	var want_specials := {}
	for sp: Dictionary in w.get("specials", []):
		want_specials[int(sp.idx)] = true
		if not have_specials.has(int(sp.idx)):
			_spawn_one_node(str(sp.item), Vector2(float(sp.x), float(sp.y)), int(sp.idx))
	for idx: int in have_specials:
		if not want_specials.has(idx):
			resource_nodes.erase(have_specials[idx])
			(have_specials[idx] as Node).queue_free()
	# works: spawn visuals for anything new; follow positions (someone may be dragging)
	var placed: Dictionary = SaveSystem._int_keys(w.get("works", {}))
	works.placed = placed
	chapels.clear()
	var chapel_dict: Dictionary = w.get("chapels", {})
	for inst_id: Variant in placed:
		var inst: Dictionary = placed[inst_id]
		var wpos := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
		if not work_visuals.has(int(inst_id)):
			_spawn_work_visual(int(inst_id), str(inst.work_id), wpos, chapel_dict)
		elif int(inst_id) != drag_work_id:
			(work_visuals[int(inst_id)] as Node2D).position = wpos
			(work_visuals[int(inst_id)] as Node2D).rotation_degrees = float(inst.get("rot", 0))
	# a work removed on the server (demolished) must vanish here too
	for vid: int in work_visuals.keys():
		if not placed.has(vid):
			if is_instance_valid(work_visuals[vid]):
				work_visuals[vid].queue_free()
			work_visuals.erase(vid)
	for god_id: Variant in chapel_dict:
		var cp: Array = chapel_dict[god_id]
		chapels[str(god_id)] = Vector2(float(cp[0]), float(cp[1]))
	# enemies: reconcile by net id
	boss_dead = bool(w.get("boss_dead", false))
	for e in enemies.duplicate():
		if not is_instance_valid(e):
			enemies.erase(e)
	var have := {}
	for e in enemies:
		have[int(e.get_meta("nid", -1))] = e
	var want := {}
	for ed: Dictionary in w.get("enemies", []):
		var nid := int(ed.nid)
		want[nid] = true
		if have.has(nid):
			(have[nid] as DSEnemy).position = Vector2(float(ed.x), float(ed.y))
		else:
			var m := DSEnemy.new()
			m.mirror = true
			m.creature_id = str(ed.creature)
			m.position = Vector2(float(ed.x), float(ed.y))
			m.set_meta("nid", nid)
			m.host = self
			add_child(m)
			enemies.append(m)
	for nid: int in have:
		if not want.has(nid):
			var gone: DSEnemy = have[nid]
			enemies.erase(gone)
			gone.queue_free()
	# Anna
	if survivor != null and w.has("villager"):
		survivor.position = Vector2(float(w.villager.x), float(w.villager.y))
		if bool(w.villager.rescued) and not survivor.rescued:
			survivor.rescued = true
			survivor.set_label_name()
	# the rest of the roster (client mirrors, keyed by nid)
	village_stock = w.get("stock", {})
	var seen := {}
	for pd: Dictionary in w.get("pool", []):
		var nid := int(pd.nid)
		seen[nid] = true
		var body: DSVillager = null
		for v: DSVillager in villagers:
			if int(v.get_meta("nid", -1)) == nid:
				body = v
				break
		if body == null:
			body = DSVillager.new()
			body.host = self
			body.set_meta("nid", nid)
			body.display_name = str(pd.name)
			body.def_class = str(pd.cls)
			add_child(body)
			villagers.append(body)
		body.position = body.position.lerp(Vector2(float(pd.x), float(pd.y)), 0.5)
		body.job_work_id = str(pd.get("job", ""))
		if bool(pd.rescued) and not body.rescued:
			body.rescued = true
		if body.rescued:
			body.set_mood(str(pd.get("mood", "steady")))
		body._refresh_label()
	for v: DSVillager in villagers.duplicate():
		if not seen.has(int(v.get_meta("nid", -1))):
			villagers.erase(v)
			v.queue_free()
	if village_panel_open:
		_toggle_village(true)
	_refresh_hud()

@rpc("authority", "unreliable_ordered")
func cl_positions(players: Array, enemy_nids: Array, ex: Array, ey: Array, vx: float, vy: float) -> void:
	if survivor != null:
		survivor.position = survivor.position.lerp(Vector2(vx, vy), 0.5)
	for pd: Dictionary in players:
		var pid := int(pd.pid)
		if pid == my_pid:
			continue
		if not remote_nodes.has(pid):
			var av := Node2D.new()
			av.add_child(SpriteKit.sprite("villager", Vector2(18, 26), Color("c8865a")))
			av.add_child(_world_label(str(pd.get("name", "drifter")), Vector2(0, 16)))
			add_child(av)
			remote_nodes[pid] = av
		var node := remote_nodes[pid] as Node2D
		node.position = node.position.lerp(Vector2(float(pd.x), float(pd.y)), 0.5)
	for i in enemy_nids.size():
		for e in enemies:
			if is_instance_valid(e) and int(e.get_meta("nid", -1)) == int(enemy_nids[i]):
				e.position = e.position.lerp(Vector2(float(ex[i]), float(ey[i])), 0.5)

@rpc("authority", "reliable")
func cl_players(players: Array) -> void:
	var live := {}
	for pd: Dictionary in players:
		live[int(pd.pid)] = true
	for pid: int in remote_nodes.keys():
		if not live.has(pid) or pid == my_pid:
			(remote_nodes[pid] as Node).queue_free()
			remote_nodes.erase(pid)

@rpc("authority", "reliable")
func cl_message(text: String) -> void:
	message = text
	_refresh_hud()

## --- streams ------------------------------------------------------------------
func _net_tick(delta: float) -> void:
	_pos_timer += delta
	if _pos_timer < 0.1:
		return
	_pos_timer = 0.0
	if net_mode == "client" and multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		rpc_id(1, "srv_pos", player.position.x, player.position.y)
	elif net_mode == "server":
		var nids: Array = []
		var ex: Array = []
		var ey: Array = []
		for e in enemies:
			if is_instance_valid(e):
				nids.append(_enemy_nid(e))
				ex.append(e.position.x)
				ey.append(e.position.y)
		rpc("cl_positions", _players_snapshot(), nids, ex, ey, survivor.position.x, survivor.position.y)
