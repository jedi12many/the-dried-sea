class_name DSVillager
extends CharacterBody2D
## A stranded survivor -> a villager. Found in the world; E to rescue; follows
## you until near the village center, then settles and lives there. Her sim
## life (disposition, worship, drift) runs in VillageSystem — this node is only
## her body.

const FOLLOW_SPEED := 120.0
const SETTLE_RADIUS := 180.0
const WANDER_SPEED := 30.0
const FOLLOW_STOP := 44.0   # she keeps a respectful distance; never body-blocks

var host: GameHost
var display_name := "Anna"
var rescued := false
var tribesman_id := -1
var _wander_target := Vector2.ZERO
var _rng := RandomNumberGenerator.new()
var _label: Label

func _ready() -> void:
	_rng.seed = 31
	# Friendly bodies don't block: she walks THROUGH the player and the world.
	# (Pinning your rescuer against a salt pillar is not the fantasy.)
	collision_layer = 0
	collision_mask = 0
	add_child(SpriteKit.sprite("villager", Vector2(18, 26), Color("b0765a")))
	_label = Label.new()
	_label.text = "someone, stranded"
	_label.position = Vector2(-70, 16)
	_label.custom_minimum_size = Vector2(140, 0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color("8a7a5c"))
	_label.add_theme_font_size_override("font_size", 10)
	add_child(_label)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(14, 22)
	shape.shape = rect
	add_child(shape)

func rescue() -> void:
	rescued = true
	tribesman_id = host.village.add_tribesman(display_name, "class-brinewife", "rescued",
		["trait-devout", "trait-storyteller"], "god-halor")
	if _label != null:
		_label.text = display_name

## Restore the nameplate after a save-load (rescue() would double-register her).
func set_label_name() -> void:
	if _label != null:
		_label.text = display_name

func _physics_process(_delta: float) -> void:
	if host == null or not rescued:
		return
	if host.net_mode == "client":
		return   # the server walks her; we just watch
	var center := host.village_heart()
	if position.distance_to(center) > SETTLE_RADIUS:
		# follow the nearest living soul toward home — at heel, not underfoot
		var guide: Vector2 = host.nearest_threat(position).pos
		if guide == Vector2.INF:
			guide = center
		var target := guide if guide.distance_to(center) > SETTLE_RADIUS else center
		if position.distance_to(target) <= FOLLOW_STOP:
			velocity = Vector2.ZERO
			move_and_slide()
			return
		velocity = (target - position).normalized() * FOLLOW_SPEED
	else:
		# settled: a real day — work in the morning, rites in the evening, home at night
		var duty := _daily_target(center)
		if duty != Vector2.INF:
			if position.distance_to(duty) > 20.0:
				velocity = (duty - position).normalized() * WANDER_SPEED * 2.2
			else:
				velocity = Vector2.ZERO   # at her post
		else:
			# midday: small unhurried life around the village heart
			if _wander_target == Vector2.ZERO or position.distance_to(_wander_target) < 8.0:
				_wander_target = center + Vector2(_rng.randf_range(-120, 120), _rng.randf_range(-120, 120))
			velocity = (_wander_target - position).normalized() * WANDER_SPEED
	move_and_slide()

## Where her day wants her. INF = free time (wander).
func _daily_target(center: Vector2) -> Vector2:
	var hour := host.clock.minute_of_day / 60
	if hour >= 6 and hour < 11:
		var post := host.work_pos("work-smokehouse")
		return post if post != Vector2.INF else host.work_pos("work-hearth")
	if hour >= 17 and hour < 21:
		return host.chapels.get("god-halor", Vector2.INF)
	if hour >= 21 or hour < 6:
		return center + Vector2(0, 40)   # home is near the heart, for now
	return Vector2.INF
