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

	# 5. the Tally over the wire
	host.rpc_id(1, "srv_intent", "allocate", ["virtue-grit"])
	waited = 0.0
	while host.abilities.score(host.my_pid, "virtue-grit") == 0 and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.abilities.score(host.my_pid, "virtue-grit") == 1, "Temper spent across the wire")

	_finish()
