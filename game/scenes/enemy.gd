class_name DSEnemy
extends CharacterBody2D
## A creature, stats-driven from data. M1 brain: idle -> chase -> bite.
## The salt-hound teaches the player that the flats are not empty.

const AGGRO_RADIUS := 170.0
const ATTACK_RANGE := 30.0
const ATTACK_COOLDOWN := 1.1

const CREATURE_SPRITES := {"creature-salt-hound": "hound", "creature-scuttle-crab": "crab", "creature-old-shellback": "shellback",
	"creature-eel-wolf": "eel_wolf", "creature-urchin-back": "urchin_back",
	# M3.c (REEF-FOREST-SPEC §2/§4): target sprite names for the art pass —
	# SpriteKit falls back to a tinted ColorRect for any of these until the
	# real PNGs land, same as every other creature above did at first.
	"creature-the-drowned": "drowned", "creature-angler-stalker": "angler_stalker",
	"creature-anglermother": "anglermother"}

var host: GameHost
var creature_id: String
var speed := 60.0
var attack_damage := 8.0
var peaceful := false   # ambient archetypes never chase or bite
var ambient_armored := false   # M3.a: urchin-back — peaceful until struck, then a slow pursuit (never on its own)
var provoked := false          # ambient_armored only: set true the first time on_hit() lands
var mirror := false     # NET client: a visual echo — the server owns the brain
var is_boss := false
var subduable := false  # raiders: at low HP they surrender instead of dying
var tameable_tier := 0  # a tame-blocked, non-peaceful creature (a hound): mercy-kneel gate (Part III)
var surrendered := false
# M3.c (REEF-FOREST-SPEC §2/§4): data-driven off creature.nightOnly. Non-boss
# nightOnly creatures (the Drowned, angler-stalkers) are spawned/despawned
# wholesale by main.gd's clock tick (_sync_night_creatures) — they simply
# don't exist by day, so this flag never needs to gate their own behavior.
# A BOSS with nightOnly (the Anglermother) can't be despawned that cleanly
# (her ring/keystone anchor wants a stable world position) — Q17 decided
# DORMANT-and-unattackable by day instead (see _physics_process/is_attackable
# below), reads better than a boss winking in and out of existence.
var night_only := false
var is_lure := false    # archetype "lure" (angler-stalker): main.gd spawns a false-glow decoy near it (_spawn_angler_lure)
var spawn_pos := Vector2.ZERO   # bosses guard their ground and leash back to it
var _cooldown := 0.0
var _stun := 0.0
var _chasing := false
var _visual: Node2D
var _hp_bar: ColorRect
# Ghal's Shepherd's Voice (M3.b, REEF-FOREST-SPEC §5): a TEMPORARY deaggro,
# unlike `surrendered` (permanent, mercy-kneel/raider-subdue only). Reuses the
# same dimmed tint language as surrender() but reverts on its own timer.
var _pacify_seconds := 0.0

func pacify(seconds: float) -> void:
	_pacify_seconds = maxf(_pacify_seconds, seconds)
	if _visual != null:
		_visual.modulate = Color(0.7, 0.66, 0.6)   # calmed, same dim tint as a kneeling surrender

func is_pacified() -> bool:
	return _pacify_seconds > 0.0

func stun(seconds: float) -> void:
	_stun = maxf(_stun, seconds)

## Hit feedback: white flash + a health sliver that appears once blooded.
func on_hit() -> void:
	if ambient_armored:
		provoked = true   # harmless until struck (REEF-FOREST-SPEC §4) — this is the strike
	if _visual != null:
		_visual.modulate = Color(3, 3, 3)
		get_tree().create_timer(0.1).timeout.connect(func() -> void:
			if is_instance_valid(self) and _visual != null:
				_visual.modulate = Color.WHITE)
	if _hp_bar == null:
		var back := ColorRect.new()
		back.size = Vector2(18, 3)
		back.position = Vector2(-9, -14)
		back.color = Color("4a3021")
		add_child(back)
		_hp_bar = ColorRect.new()
		_hp_bar.size = Vector2(16, 1)
		_hp_bar.position = Vector2(-8, -13)
		_hp_bar.color = Color("b0483c")
		add_child(_hp_bar)
	var creature := host.registry.get_entity(creature_id)
	var max_hp := float(creature.get("stats", {}).get("hp", 20))
	_hp_bar.size.x = 16.0 * clampf(host.stats.hp(self) / max_hp, 0.0, 1.0)

func setup(game_host: GameHost, id: String) -> void:
	host = game_host
	creature_id = id
	var creature := host.registry.get_entity(id)
	var stats: Dictionary = creature.get("stats", {})
	speed = float(stats.get("speed", 1.0)) * 70.0
	attack_damage = float(stats.get("damage", 5))
	peaceful = creature.get("archetype", "") == "ambient"
	ambient_armored = creature.get("archetype", "") == "ambient-armored"
	is_boss = creature.get("archetype", "") == "boss"
	subduable = creature.get("archetype", "") == "raider-human"
	night_only = bool(creature.get("nightOnly", false))
	is_lure = creature.get("archetype", "") == "lure"
	# a beast with a tame block that ISN'T peaceful (a hound, not a crab —
	# crabs are fed straight, never beaten down) can be mercy-kneeled (Part III §2)
	var tm: Dictionary = creature.get("tame", {})
	tameable_tier = int(tm.get("tier", 0)) if not tm.is_empty() and not peaceful else 0
	spawn_pos = position
	host.stats.register(self, float(stats.get("hp", 20)))

func _ready() -> void:
	var size := Vector2(20, 16)
	if creature_id == "creature-old-shellback":
		size = Vector2(44, 32)
	elif creature_id == "creature-anglermother":
		size = Vector2(50, 38)   # the reef's other great beast — first guess, smaller than Shellback's hull but still huge
	_visual = SpriteKit.sprite(CREATURE_SPRITES.get(creature_id, "hound"), size, Color("cfc9ba"))
	add_child(_visual)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(16, 12)
	shape.shape = rect
	add_child(shape)

func surrender() -> void:
	surrendered = true
	if _visual != null:
		_visual.modulate = Color(0.7, 0.66, 0.6)   # beaten, kneeling

## REEF-FOREST-SPEC §4/Q17: a nightOnly BOSS (the Anglermother) by day — no
## aggro, no leash-walk, no combat. Not despawned (her ring is a fixed world
## anchor other systems name: the keystone kneel-spot, the arena-darkness
## override) — just dormant. main.gd's intent_attack skips her via this too.
func is_attackable() -> bool:
	return not (night_only and is_boss and host != null and not host.clock.is_night())

func _physics_process(delta: float) -> void:
	if host == null or host.player == null or mirror:
		return   # mirrors move by the server's word alone
	if night_only and is_boss and not host.clock.is_night():
		velocity = Vector2.ZERO
		move_and_slide()
		return   # dormant by day — her lure is the arena's only light; that IS the fight
	if peaceful or surrendered:
		return   # crabs have nowhere to be; a surrendered raider waits
	if _pacify_seconds > 0.0:
		_pacify_seconds = maxf(_pacify_seconds - delta, 0.0)
		velocity = Vector2.ZERO
		move_and_slide()
		if _pacify_seconds == 0.0 and _visual != null:
			_visual.modulate = Color.WHITE   # the calm passes; back to itself
		return   # Ghal's Shepherd's Voice: calmed, not chasing, for its duration
	if ambient_armored and not provoked:
		return   # the urchin-back: harmless until struck (REEF-FOREST-SPEC §4)
	if _stun > 0.0:
		_stun -= delta
		velocity = Vector2.ZERO
		return   # knocked flat by the squall
	_cooldown = maxf(_cooldown - delta, 0.0)
	# night belongs to the hounds — and the storm belongs to no one
	var threat := host.nearest_threat(position)
	var target_pid := int(threat.pid)
	var companion: DSVillager = threat.get("companion", null)   # a road companion can out-draw the player's own threat
	var beast_target: DSBeast = threat.get("beast", null)       # a fighter beast at heel can too
	if (threat.pos as Vector2) == Vector2.INF:
		velocity = Vector2.ZERO
		return   # an empty world (server with no players yet)
	var bold := host.clock.is_night() or host.is_storm_day()
	var aggro := AGGRO_RADIUS * (2.4 if bold else 1.0)
	var run_speed := speed * (1.35 if bold else 1.0)
	if creature_id == "creature-salt-hound" and target_pid > 0:
		aggro *= host.abilities.mod_mult(target_pid, "hound-aggro-mult")  # Soft-Step
		aggro *= host.equipped_mod_mult(target_pid, "hound-aggro-mult")   # the Lighthouse-Keeper's Lantern
	if creature_id == "creature-salt-hound":
		aggro *= host.old_barnacle_mult(position)   # a Barnacle-lit crab nearby: walking calm
	if is_boss:
		aggro = 240.0   # he guards his hoard; he does not hunt
		run_speed = speed
	var to_player: Vector2 = (threat.pos as Vector2) - position
	var dist := to_player.length()
	var attack_range := ATTACK_RANGE * (1.6 if is_boss else 1.0)
	if is_boss and (position.distance_to(spawn_pos) > 380.0 or dist > 480.0):
		# leash: walk home; an unbothered boss knits himself back together
		if position.distance_to(spawn_pos) > 8.0:
			velocity = (spawn_pos - position).normalized() * speed
		else:
			velocity = Vector2.ZERO
			host.stats.heal_full(self)
		move_and_slide()
		return
	if dist <= attack_range:
		velocity = Vector2.ZERO
		if _cooldown == 0.0:
			_cooldown = ATTACK_COOLDOWN * (1.6 if is_boss else 1.0)
			if creature_id == "creature-salt-hound" and target_pid > 0:
				_cooldown *= host.abilities.mod_mult(target_pid, "hound-cooldown-mult")  # Herd-Sense
			if companion != null:
				host.damage_villager(companion, attack_damage)
			elif beast_target != null:
				host.damage_beast(beast_target, attack_damage)
			else:
				host.damage_player(attack_damage, target_pid)
	elif dist <= aggro:
		if not _chasing and creature_id == "creature-salt-hound":
			host.sfx("growl", position)   # you have been noticed
		_chasing = true
		velocity = to_player.normalized() * run_speed
	else:
		_chasing = false
		velocity = Vector2.ZERO
	move_and_slide()
