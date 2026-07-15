class_name DSPlayer
extends CharacterBody2D
## The survivor. Placeholder body per STYLE-BIBLE: a warm-toned figure with a
## selective outline — the one warm thing on the flats until you build a hearth.

const SPEED := 140.0

var facing := Vector2.DOWN
var prompt: Label

func _ready() -> void:
	add_child(SpriteKit.sprite("survivor", Vector2(22, 30), Color("c8865a")))
	prompt = Label.new()
	prompt.position = Vector2(-70, -44)
	prompt.custom_minimum_size = Vector2(140, 0)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_color_override("font_color", Color("3b3428"))
	prompt.add_theme_color_override("font_outline_color", Color("f2efe8"))
	prompt.add_theme_constant_override("outline_size", 4)
	prompt.add_theme_font_size_override("font_size", 11)
	add_child(prompt)
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
	var host := get_parent() as GameHost
	if host != null and host.petrify_frames > 0:
		# (host checked again below for speed mods)
		velocity = Vector2.ZERO   # rooted — the pillar does not walk
		return
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if dir != Vector2.ZERO:
		facing = dir.normalized()
	var speed := SPEED
	if host != null:
		speed *= host.abilities.mod_mult(GameHost.LOCAL_PLAYER, "move-speed-mult")
		if host.clock.is_night():
			speed *= host.abilities.mod_mult(GameHost.LOCAL_PLAYER, "night-speed-mult")
	velocity = dir * speed
	move_and_slide()
