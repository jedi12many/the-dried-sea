class_name DSVillager
extends CharacterBody2D
## A coast survivor -> a villager. Found stranded; [E] to rescue; then they
## follow you home, take the nearest job, and LIVE — working, eating, souring
## or blooming. Their inner life (disposition, traits, Keys) runs in
## VillageSystem; this node is the body that walks and wears the mood.

const FOLLOW_SPEED := 120.0
const SETTLE_RADIUS := 200.0
const WANDER_SPEED := 30.0
const FOLLOW_STOP := 44.0   # at heel, never body-blocking

var host: GameHost
var display_name := "Anna"
var rescued := false
var tribesman_id := -1
# generated identity (set before rescue; used by rescue())
var def_class := "class-brinewife"
var def_traits: Array = ["trait-devout", "trait-storyteller"]
var def_patron := "god-halor"
var job_work_id := ""       # the station this villager tends
var mood := "steady"
var _wander_target := Vector2.ZERO
var _rng := RandomNumberGenerator.new()
var _label: Label
var _body: Node2D

const MOOD_TINT := {
	"content": Color(1.12, 1.08, 0.96), "steady": Color.WHITE,
	"slacking": Color(0.9, 0.86, 0.82), "pettyTheft": Color(0.86, 0.8, 0.78),
	"spreadingDoubt": Color(0.82, 0.74, 0.74), "desertion": Color(0.72, 0.66, 0.68),
}

func _ready() -> void:
	_rng.seed = 31 + tribesman_id
	collision_layer = 0
	collision_mask = 0
	_body = SpriteKit.sprite("villager", Vector2(18, 26), Color("b0765a"))
	add_child(_body)
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
	tribesman_id = host.village.add_tribesman(display_name, def_class, "rescued",
		def_traits, def_patron)
	_refresh_label()
	host.assign_job(self)

func set_label_name() -> void:
	_refresh_label()

func set_mood(m: String) -> void:
	mood = m
	if _body != null:
		_body.modulate = MOOD_TINT.get(m, Color.WHITE)
	_refresh_label()

func _refresh_label() -> void:
	if _label == null:
		return
	if not rescued:
		_label.text = "%s, stranded" % display_name
		return
	var job := ""
	if job_work_id != "" and host != null:
		job = " · " + str(host.registry.get_entity(job_work_id).get("name", "")).to_lower()
	var moodword := "" if mood == "steady" else " (%s)" % _mood_word()
	_label.text = "%s%s%s" % [display_name, job, moodword]

func _mood_word() -> String:
	match mood:
		"content": return "content"
		"slacking": return "restless"
		"pettyTheft", "spreadingDoubt": return "unhappy"
		"desertion": return "ready to leave"
		_: return mood

func _physics_process(_delta: float) -> void:
	if host == null or not rescued:
		return
	if host.net_mode == "client":
		return   # the server walks them; we just watch
	var center := host.village_heart()
	if position.distance_to(center) > SETTLE_RADIUS:
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
		var duty := _daily_target(center)
		if duty != Vector2.INF:
			if position.distance_to(duty) > 20.0:
				velocity = (duty - position).normalized() * WANDER_SPEED * 2.2
			else:
				velocity = Vector2.ZERO   # at post
		else:
			if _wander_target == Vector2.ZERO or position.distance_to(_wander_target) < 8.0:
				_wander_target = center + Vector2(_rng.randf_range(-110, 110), _rng.randf_range(-110, 110))
			velocity = (_wander_target - position).normalized() * WANDER_SPEED
	move_and_slide()

## Where their day wants them: at their job by day, their god's chapel at dusk,
## home at night.
func _daily_target(center: Vector2) -> Vector2:
	var hour := host.clock.minute_of_day / 60
	if hour >= 6 and hour < 17:
		if job_work_id != "":
			var post := host.work_pos(job_work_id)
			if post != Vector2.INF:
				return post
		return Vector2.INF
	if hour >= 17 and hour < 21 and def_patron != "":
		return host.chapels.get(def_patron, Vector2.INF)
	if hour >= 21 or hour < 6:
		return center + Vector2(0, 44)
	return Vector2.INF
