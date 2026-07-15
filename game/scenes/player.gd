class_name DSPlayer
extends CharacterBody2D
## The survivor. Placeholder body per STYLE-BIBLE: a warm-toned figure with a
## selective outline — the one warm thing on the flats until you build a hearth.

const SPEED := 140.0

func _ready() -> void:
	var outline := ColorRect.new()
	outline.size = Vector2(22, 30)
	outline.position = Vector2(-11, -15)
	outline.color = Color("4a3021")
	add_child(outline)
	var body := ColorRect.new()
	body.size = Vector2(18, 26)
	body.position = Vector2(-9, -13)
	body.color = Color("c8865a")   # the warm survivor on the bleached flats
	add_child(body)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(18, 26)
	shape.shape = rect
	add_child(shape)
	var cam := Camera2D.new()
	cam.zoom = Vector2(2, 2)
	cam.position_smoothing_enabled = true
	add_child(cam)
	cam.make_current()

func _physics_process(_delta: float) -> void:
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = dir * SPEED
	move_and_slide()
