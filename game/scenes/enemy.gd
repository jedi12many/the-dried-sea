class_name DSEnemy
extends CharacterBody2D
## A creature, stats-driven from data. M1 brain: idle -> chase -> bite.
## The salt-hound teaches the player that the flats are not empty.

const AGGRO_RADIUS := 170.0
const ATTACK_RANGE := 30.0
const ATTACK_COOLDOWN := 1.1

const CREATURE_SPRITES := {"creature-salt-hound": "hound", "creature-scuttle-crab": "crab", "creature-old-shellback": "shellback"}

var host: GameHost
var creature_id: String
var speed := 60.0
var attack_damage := 8.0
var peaceful := false   # ambient archetypes never chase or bite
var is_boss := false
var spawn_pos := Vector2.ZERO   # bosses guard their ground and leash back to it
var _cooldown := 0.0
var _stun := 0.0
var _visual: Node2D
var _hp_bar: ColorRect

func stun(seconds: float) -> void:
	_stun = maxf(_stun, seconds)

## Hit feedback: white flash + a health sliver that appears once blooded.
func on_hit() -> void:
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
	is_boss = creature.get("archetype", "") == "boss"
	spawn_pos = position
	host.stats.register(self, float(stats.get("hp", 20)))

func _ready() -> void:
	_visual = SpriteKit.sprite(CREATURE_SPRITES.get(creature_id, "hound"), Vector2(20, 16), Color("cfc9ba"))
	add_child(_visual)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(16, 12)
	shape.shape = rect
	add_child(shape)

func _physics_process(delta: float) -> void:
	if host == null or host.player == null:
		return
	if peaceful:
		return   # crabs have nowhere to be
	if _stun > 0.0:
		_stun -= delta
		velocity = Vector2.ZERO
		return   # knocked flat by the squall
	_cooldown = maxf(_cooldown - delta, 0.0)
	# night belongs to the hounds — and the storm belongs to no one
	var bold := host.clock.is_night() or host.is_storm_day()
	var aggro := AGGRO_RADIUS * (2.4 if bold else 1.0)
	var run_speed := speed * (1.35 if bold else 1.0)
	if creature_id == "creature-salt-hound":
		aggro *= host.abilities.mod_mult(GameHost.LOCAL_PLAYER, "hound-aggro-mult")  # Soft-Step
	if is_boss:
		aggro = 240.0   # he guards his hoard; he does not hunt
		run_speed = speed
	var to_player := host.player.position - position
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
			if creature_id == "creature-salt-hound":
				_cooldown *= host.abilities.mod_mult(GameHost.LOCAL_PLAYER, "hound-cooldown-mult")  # Herd-Sense
			host.damage_player(attack_damage)
	elif dist <= aggro:
		velocity = to_player.normalized() * run_speed
	else:
		velocity = Vector2.ZERO
	move_and_slide()
