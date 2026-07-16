extends Node
## NET smoke: spawns a REAL headless server process, connects a REAL client
## over localhost UDP, and plays: join, mirror the world, harvest, spend Temper.
##   godot --headless --path game res://tests/net_smoke.tscn

var failures := 0
var checks := 0
var server_os_pid := -1

func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("NET FAIL: " + msg)

func _finish() -> void:
	if server_os_pid > 0:
		OS.kill(server_os_pid)
	print("\nnet_smoke: %d checks, %d failure(s)" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

func _ready() -> void:
	# 1. the server: a separate OS process, fresh world, test port
	var proj := ProjectSettings.globalize_path("res://")
	server_os_pid = OS.create_process(OS.get_executable_path(),
		["--headless", "--path", proj, "--", "--server", "--port=7877", "--fresh"])
	check(server_os_pid > 0, "server process launched (pid %d)" % server_os_pid)
	await get_tree().create_timer(3.0).timeout

	# 2. the client: a GameHost in client mode
	var host: GameHost = load("res://scenes/main.tscn").instantiate()
	host.skip_autoload = true
	host.net_mode = "client"
	host._net_connect_addr = "127.0.0.1:7877"
	host._username = "tester"
	host.name = "Main"                    # RPC paths must match the server's /root/Main
	get_tree().root.add_child.call_deferred(host)
	await get_tree().process_frame
	await get_tree().process_frame

	# 3. join: wait for the server to hand us a pid
	var waited := 0.0
	while host.my_pid == 1 and waited < 10.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.my_pid >= 2, "the server knows us: pid %d" % host.my_pid)
	check(host.stats.actors.has(host.my_pid), "our vitals arrived")
	check(host.abilities.earned(host.my_pid) >= 6, "Temper arrived (%d)" % host.abilities.earned(host.my_pid))
	check(host.enemies.size() > 0, "the server's beasts are mirrored here (%d)" % host.enemies.size())
	check(host.enemies.all(func(e: DSEnemy) -> bool: return e.mirror), "and every one is a mirror, not a brain")

	# 4. harvest over the wire: stand on a node (deterministic layout = same spot
	# both sides), let the position stream report us, then send the intent
	var cloth: Area2D = null
	for n in host.resource_nodes:
		if is_instance_valid(n) and str(n.get_meta("item_id")) == "item-ship-cloth":
			cloth = n
			break
	check(cloth != null, "the deterministic world grew the same cloth here")
	var cloth_idx := int(cloth.get_meta("idx"))   # the node won't survive the harvest
	host.player.position = cloth.position
	await get_tree().create_timer(0.5).timeout   # position stream catches up
	host.intent_interact()                        # relays to the server
	waited = 0.0
	while host.inventory.count(host.my_pid, "item-ship-cloth") == 0 and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.inventory.count(host.my_pid, "item-ship-cloth") >= 3, "harvested across the wire (cloth ×%d)" % host.inventory.count(host.my_pid, "item-ship-cloth"))
	waited = 0.0
	while not (cloth_idx in host.harvested_indices) and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(cloth_idx in host.harvested_indices, "the world sync erased the node everywhere")

	# 4.5 rescue a stranded villager over the wire — the roster MUST register them.
	#     Regression: the pool sync dropped tribesman_id, so client mirrors failed
	#     the modal's `rescued and tribesman_id >= 0` filter — villagers stood in
	#     camp while the modal insisted "no one has joined you yet."
	var stranger: DSVillager = null
	for v in host.villagers:
		if is_instance_valid(v) and not v.rescued and not v.is_captive:
			stranger = v
			break
	check(stranger != null, "a stranded villager is mirrored to the client (%d in pool)" % host.villagers.size())
	if stranger != null:
		# Pool positions only ride the event-driven world_sync (lerp 0.5), so a fresh
		# mirror is still far from the server truth. Pump a few syncs to converge it.
		for _i in 8:
			host.rpc_id(1, "srv_intent", "give_food", [])   # harmless; each reply is a world_sync
			await get_tree().create_timer(0.15).timeout
		host.player.position = stranger.position
		await get_tree().create_timer(0.6).timeout   # let the position stream reach the server
		host.intent_interact()                        # relays "interact" -> the server rescues
		var registered := func() -> bool:
			return not host.all_villagers().filter(func(v: DSVillager) -> bool:
				return v.rescued and v.tribesman_id >= 0).is_empty()
		waited = 0.0
		while waited < 6.0 and not registered.call():
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		check(registered.call(), "the rescued villager registers in the client roster (tribesman_id synced)")

	# 5. the Tally over the wire
	host.rpc_id(1, "srv_intent", "allocate", ["virtue-grit"])
	waited = 0.0
	while host.abilities.score(host.my_pid, "virtue-grit") == 0 and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.abilities.score(host.my_pid, "virtue-grit") == 1, "Temper spent across the wire")

	_finish()
