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
	check(host.inventory.count(1, "item-ship-cloth") == 2, "cloth in hand")

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

	# station crafting now unlocked
	host.inventory.add(1, "item-driftwood", 1)
	check(host.intent_craft("recipe-salt-harvest"), "workbench enables salt harvest")

	# day/night: run the clock to 22:00, the world darkens
	host.clock.minute_of_day = 22 * 60
	host.clock.advance(1.0)  # tick one minute to apply
	await get_tree().physics_frame
	check(host.clock.is_night(), "22:00 is night")
	check(host.daynight.color != Color(1, 1, 1), "and the flats go cold")

	print("\nsmoke: %d checks, %d failure(s)" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

func _node_of(host: GameHost, item_id: String) -> Area2D:
	for n in host.resource_nodes:
		if is_instance_valid(n) and str(n.get_meta("item_id")) == item_id:
			return n
	return null
