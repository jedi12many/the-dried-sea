class_name DSEnemy
extends CharacterBody2D
## A creature, stats-driven from data. M1 brain: idle -> chase -> bite.
## The salt-hound teaches the player that the flats are not empty.

const AGGRO_RADIUS := 170.0
const ATTACK_RANGE := 30.0
const ATTACK_COOLDOWN := 1.1

const CREATURE_SPRITES := {"creature-salt-hound": "hound", "creature-scuttle-crab": "crab"}

var host: GameHost
var creature_id: String
var speed := 60.0
var attack_damage := 8.0
var peaceful := false   # ambient archetypes never chase or bite
var _cooldown := 0.0
var _stun := 0.0

func stun(seconds: float) -> void:
	_stun = maxf(_stun, seconds)

func setup(game_host: GameHost, id: String) -> void:
	host = game_host
	creature_id = id
	var creature := host.registry.get_entity(id)
	var stats: Dictionary = creature.get("stats", {})
	speed = float(stats.get("speed", 1.0)) * 70.0
	attack_damage = float(stats.get("damage", 5))
	peaceful = creature.get("archetype", "") == "ambient"
	host.stats.register(self, float(stats.get("hp", 20)))

func _ready() -> void:
	add_child(SpriteKit.sprite(CREATURE_SPRITES.get(creature_id, "hound"), Vector2(20, 16), Color("cfc9ba")))
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
	# night belongs to the hounds: they smell farther and run harder
	var night := host.clock.is_night()
	var aggro := AGGRO_RADIUS * (2.4 if night else 1.0)
	var run_speed := speed * (1.35 if night else 1.0)
	var to_player := host.player.position - position
	var dist := to_player.length()
	if dist <= ATTACK_RANGE:
		velocity = Vector2.ZERO
		if _cooldown == 0.0:
			_cooldown = ATTACK_COOLDOWN
			host.damage_player(attack_damage)
	elif dist <= aggro:
		velocity = to_player.normalized() * run_speed
	else:
		velocity = Vector2.ZERO
	move_and_slide()
