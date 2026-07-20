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
	check(host.player.name_label != null and host.player.name_label.text == "tester", "your join name rides over your own head")
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

	# 6. a road companion over the wire (VILLAGER-AND-GODHEAD-SPEC Part I §4):
	# class the rescued stranger, recruit them, and confirm the client mirror
	# shows on_road — companion AI itself is host-only; this just checks the sync.
	if stranger != null and stranger.tribesman_id >= 0:
		host.rpc_id(1, "srv_intent", "drill_train", [stranger.tribesman_id, "arms-warrior"])
		waited = 0.0
		while host.village.arms_level(stranger.tribesman_id) == 0 and waited < 6.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		check(host.village.arms_level(stranger.tribesman_id) == 1, "trained the stranger Warrior 1 across the wire")
		host.rpc_id(1, "srv_intent", "recruit", [int(stranger.get_meta("nid", 0))])
		waited = 0.0
		while not stranger.on_road and waited < 6.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		check(stranger.on_road, "the client mirror shows on_road after a wire recruit")

	# 7. Godhead (VILLAGER-AND-GODHEAD-SPEC Part II §7) mirrors world-level, not
	# per-player — every srv_intent above already carried a world_sync, so the
	# client's local GodheadSystem should already reflect the fresh server's
	# state: base 10% under a 40% cap (one biome keystone down, set at boot).
	check(absf(host.godhead.godhead("god-halor") - 10.0) < 0.01, "Godhead's base value mirrors to the client (%.1f%%)" % host.godhead.godhead("god-halor"))
	check(absf(host.godhead.cap() - 40.0) < 0.01, "and so does the cap (%.1f%%)" % host.godhead.cap())

	# 8. the Waker (§5): a real, server-authoritative player death over the
	# wire. Real hound combat has no deterministic timing to assert against,
	# so this rides the same test-only "test_die" hook net_smoke needs (see
	# main.gd srv_intent) — it calls the exact damage_player() path an enemy
	# hit does, self-targeted, and the ledger line rides home on the EXISTING
	# player_state/message channel (cl_player_state), same as any other event.
	var death_pos: Vector2 = host.player.position
	host.rpc_id(1, "srv_intent", "test_die", [])
	waited = 0.0
	while not host.message.contains("DARK TAKES YOU") and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.message.contains("DARK TAKES YOU") and host.message.contains("UR-NOTH"), "a client's own death gets the Waker's ledger line over the wire")

	# ...and the client's BODY actually moves to the rest point. Clients own
	# their own position (cl_positions skips my_pid), so before cl_warp the
	# server relocated a remote player only on paper and their next position
	# packet quietly undid it — a remote player never really woke anywhere.
	var died_at := death_pos
	waited = 0.0
	while host.player.position.distance_to(died_at) < 8.0 and waited < 4.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.player.position.distance_to(died_at) >= 8.0,
		"...and the Waker actually MOVES a remote body (was %.0f,%.0f now %.0f,%.0f)" % [died_at.x, died_at.y, host.player.position.x, host.player.position.y])

	# 9. CALLINGS step params over the wire: a client's collect step gates
	# server-side (the authoritative pack is light), then advances once the
	# client has really harvested the goods. Seeded via the test_calling hook;
	# everything after it is the live runtime path.
	host.rpc_id(1, "srv_intent", "test_calling", ["calling-chart-leads-deep", "s2"])
	waited = 0.0
	while (host.callings.get(host.my_pid, []) as Array).is_empty() and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(not (host.callings.get(host.my_pid, []) as Array).is_empty(), "the seeded calling mirrors to the client journal")
	host.rpc_id(1, "srv_intent", "journal", [0])   # press continue, empty-handed
	waited = 0.0
	while not host.message.begins_with("Not yet") and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.message.begins_with("Not yet") and host.message.contains("0/2"), "the server refuses the light-packed continue with a nudge (%s)" % host.message)
	# cut two timber across the wire — worked swing by swing, like any player
	var timber: Area2D = null
	for n in host.resource_nodes:
		if is_instance_valid(n) and str(n.get_meta("item_id")) == "item-wreck-timber":
			timber = n
			break
	check(timber != null, "the deterministic world grew a timber stand here")
	if timber != null:
		host.player.position = timber.position
		await get_tree().create_timer(0.6).timeout   # let the position stream catch up
		waited = 0.0
		while host.inventory.count(host.my_pid, "item-wreck-timber") < 2 and waited < 8.0:
			host.intent_interact()
			await get_tree().create_timer(0.4).timeout
			waited += 0.4
		check(host.inventory.count(host.my_pid, "item-wreck-timber") >= 2, "timber cut over the wire (×%d)" % host.inventory.count(host.my_pid, "item-wreck-timber"))
	host.rpc_id(1, "srv_intent", "journal", [0])   # the same press, goods in hand
	waited = 0.0
	while waited < 6.0:
		var mirror: Array = host.callings.get(host.my_pid, [])
		if not mirror.is_empty() and str((mirror[0] as Dictionary).get("step", "")) == "s3":
			break
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	var adv: Array = host.callings.get(host.my_pid, [])
	check(not adv.is_empty() and str((adv[0] as Dictionary).get("step", "")) == "s3", "goods in hand, the step advances and the new step mirrors home")

	# 10. BEASTS AT HEEL (VILLAGER-AND-GODHEAD-SPEC Part III) over the wire.
	# Taming for real takes several sim-days of feeding — no wire test should
	# sit through that in real time — so a tamed beast is seeded directly
	# (test_seed_beast) and this just proves the thing that's actually novel
	# over the network: it mirrors to the client, with its name, via the same
	# world_sync/cl_world_sync path everything else above already rides.
	host.rpc_id(1, "srv_intent", "test_seed_beast", [])
	waited = 0.0
	while host.beasts.is_empty() and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(not host.beasts.is_empty() and host.beasts[0].display_name == "Wiretest",
		"a beast mirrors to a client with its name")
	check(host.beasts[0].creature_id == "creature-scuttle-crab" and host.beasts[0].at_heel,
		"...and its species + heel state")

	# a client feeds a WILD crab over the wire: allocate WILD 3, grant the
	# craved food (test_grant_item — the client has no real way to harvest its
	# way to a specific item deterministically), then the real feed_wild path.
	for i in 3:
		host.rpc_id(1, "srv_intent", "allocate", ["virtue-wild"])
		await get_tree().create_timer(0.15).timeout
	check(host.abilities.score(host.my_pid, "virtue-wild") == 3, "WILD 3 allocated across the wire")
	host.rpc_id(1, "srv_intent", "test_grant_item", ["item-smoked-crab", 2])
	waited = 0.0
	while host.inventory.count(host.my_pid, "item-smoked-crab") == 0 and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(host.inventory.count(host.my_pid, "item-smoked-crab") > 0, "the craved food arrives in the client's pack")
	var wild_crab: DSEnemy = null
	for e in host.enemies:
		if is_instance_valid(e) and e.creature_id == "creature-scuttle-crab":
			wild_crab = e
			break
	check(wild_crab != null, "an untamed crab is mirrored here too")
	if wild_crab != null:
		host.player.position = wild_crab.position
		await get_tree().create_timer(0.6).timeout   # let the position stream reach the server
		host.intent_feed_wild(wild_crab)              # relays to the server over the wire
		waited = 0.0
		while not host.message.contains("trust") and waited < 6.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		check(host.message.contains("trust 1/2"), "a client feeds a crab over the wire — the trust numbers come home (%s)" % host.message)

	# 11. M3.b (REEF-FOREST-SPEC §5) over the wire: a client casts a NEW
	# invocation (Vessa's Undertow) and the effect mirrors home. Attunement for
	# real is a walk to a fallen shrine — test_attune calls the SAME
	# devotion.attune() a real kneel does, twice, to reach rank 2 without
	# modeling that whole walk over the wire (same "seed state, exercise the
	# real path" shape as test_seed_beast above).
	host.rpc_id(1, "srv_intent", "test_attune", ["god-vessa"])
	await get_tree().create_timer(0.2).timeout
	host.rpc_id(1, "srv_intent", "test_attune", ["god-vessa"])
	waited = 0.0
	while int(host.devotion.state.get(host.my_pid, {}).get("god-vessa", {}).get("rank", 0)) < 2 and waited < 6.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	check(int(host.devotion.state.get(host.my_pid, {}).get("god-vessa", {}).get("rank", 0)) == 2, "attuned to Vessa rank 2 across the wire")
	var pull_prey: DSEnemy = null
	for e in host.enemies:
		if is_instance_valid(e) and not e.peaceful and not e.surrendered:
			pull_prey = e
			break
	check(pull_prey != null, "a hostile is mirrored here to pull")
	if pull_prey != null:
		# outside AGGRO_RADIUS (170px, daytime) but inside Undertow's own pull
		# radius (280px) — so any distance the target closes is the SPELL's
		# doing, not ordinary chase AI catching up on its own.
		host.player.position = pull_prey.position + Vector2(220, 0)
		await get_tree().create_timer(0.6).timeout   # let the position stream reach the server
		var pull_d0 := host.player.position.distance_to(pull_prey.position)
		host.intent_cast("inv-undertow")               # relays to the server
		waited = 0.0
		while host.player.position.distance_to(pull_prey.position) >= pull_d0 and waited < 6.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		check(host.player.position.distance_to(pull_prey.position) < pull_d0,
			"Undertow pulls the target closer — the effect mirrors home over the wire (%.0f -> %.0f)" % [pull_d0, host.player.position.distance_to(pull_prey.position)])

	# 12. M3.b: a client renames a beast — server-authoritative, syncs to the
	# client's own mirror (the fix: cl_world_sync now re-applies `name` on
	# EVERY sync, not just when the mirror node is first created).
	if not host.beasts.is_empty():
		var seeded: DSBeast = host.beasts[0]   # "Wiretest", seeded by test_seed_beast above
		var old_beast_name := seeded.display_name
		check(host.intent_rename_beast(seeded.beast_id, 1), "the rename intent relays to the server")
		waited = 0.0
		while host.beasts[0].display_name == old_beast_name and waited < 6.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2
		check(host.beasts[0].display_name != old_beast_name,
			"the client's own beast mirror shows the new name (%s -> %s)" % [old_beast_name, host.beasts[0].display_name])

	_finish()
