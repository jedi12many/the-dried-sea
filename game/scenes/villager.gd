class_name DSVillager
extends CharacterBody2D
## A stranded survivor -> a villager. Found in the world; E to rescue; follows
## you until near the village center, then settles and lives there. Her sim
## life (disposition, worship, drift) runs in VillageSystem — this node is only
## her body.

const FOLLOW_SPEED := 120.0
const SETTLE_RADIUS := 180.0
const WANDER_SPEED := 30.0

var host: GameHost
var display_name := "Anna"
var rescued := false
var tribesman_id := -1
var _wander_target := Vector2.ZERO
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = 31
	var outline := ColorRect.new()
	outline.size = Vector2(18, 26)
	outline.position = Vector2(-9, -13)
	outline.color = Color("4a3021")
	add_child(outline)
	var body := ColorRect.new()
	body.size = Vector2(14, 22)
	body.position = Vector2(-7, -11)
	body.color = Color("b0765a")
	add_child(body)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(14, 22)
	shape.shape = rect
	add_child(shape)

func rescue() -> void:
	rescued = true
	tribesman_id = host.village.add_tribesman(display_name, "class-brinewife", "rescued",
		["trait-devout", "trait-storyteller"], "god-halor")

func _physics_process(_delta: float) -> void:
	if host == null or not rescued:
		return
	var center := Vector2(GameHost.WORLD.x * GameHost.TILE / 2.0, GameHost.WORLD.y * GameHost.TILE / 2.0)
	if position.distance_to(center) > SETTLE_RADIUS:
		# follow whoever saved you, toward home
		var target := host.player.position if host.player.position.distance_to(center) > SETTLE_RADIUS else center
		velocity = (target - position).normalized() * FOLLOW_SPEED
	else:
		# settled: small unhurried life around the village heart
		if _wander_target == Vector2.ZERO or position.distance_to(_wander_target) < 8.0:
			_wander_target = center + Vector2(_rng.randf_range(-120, 120), _rng.randf_range(-120, 120))
		velocity = (_wander_target - position).normalized() * WANDER_SPEED
	move_and_slide()
