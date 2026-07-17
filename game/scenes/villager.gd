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
var is_captive := false     # a bound raider (origin "taken") — held, not free
var days_held := 0
var task := ""              # dynamically assigned: wood/food/salt/bronze
var needs_help := false     # fled danger — waiting at home for the flats to clear
var warden_weapon := ""     # item_id claimed from the village stores (wardens arm at dawn)
var warden_armor := ""      # claimed armor — worn against the day villager wounds arrive
var housed := false         # tucked into a cot-hut for the night — hidden, safe
var _strike_cd := 0.0
const DANGER_RADIUS := 150.0
const SAFE_RADIUS := 260.0
const WARDEN_SPEED := 150.0
const WARDEN_STRIKE_RANGE := 34.0
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
	if is_captive:
		_label.text = "%s (bound · day %d)" % [display_name, days_held]
		return
	if needs_help:
		_label.text = "%s — NEEDS HELP!" % display_name
		return
	var job := ""
	if task != "":
		job = " · " + {"wood": "gathering wood", "food": "cooking", "salt": "boiling salt",
			"bronze": "salvaging bronze"}.get(task, task)
	if def_class == "class-warden" and warden_weapon != "":
		job += " · armed"
	var moodword := "" if mood == "steady" else " (%s)" % _mood_word()
	_label.text = "%s%s%s" % [display_name, job, moodword]

func _mood_word() -> String:
	match mood:
		"content": return "content"
		"slacking": return "restless"
		"pettyTheft", "spreadingDoubt": return "unhappy"
		"desertion": return "ready to leave"
		_: return mood

func _physics_process(delta: float) -> void:
	if host == null or not rescued:
		return
	if host.net_mode == "client":
		return   # the server walks them; we just watch
	var center := host.village_heart()
	# WARDENS answer the horn: they run at threats and fight, never flee —
	# a night alarm pulls them straight out of bed
	if def_class == "class-warden" and not is_captive:
		_strike_cd = maxf(_strike_cd - delta, 0.0)
		var duty: Vector2 = host.warden_duty(self)
		if duty != Vector2.INF:
			if housed:
				_leave_house()
			if position.distance_to(duty) > WARDEN_STRIKE_RANGE:
				velocity = (duty - position).normalized() * WARDEN_SPEED
			else:
				velocity = Vector2.ZERO
				if _strike_cd == 0.0:
					_strike_cd = 0.9
					host.warden_strike(self)
			move_and_slide()
			return
	# HOUSED: the night is someone else's problem — rest until the morning hour
	if housed:
		if not _is_night() or host.house_slot_for(self) == Vector2.INF:
			_leave_house()   # morning — or the roof was reclaimed out from over them
		else:
			velocity = Vector2.ZERO
			return
	# DANGER: a working villager caught near a beast drops everything and runs home
	if rescued and not is_captive and def_class != "class-warden":
		var edist := host.enemy_near_dist(position)
		if not needs_help and edist < DANGER_RADIUS and not host.warden_covers(position):
			needs_help = true
			_refresh_label()
			if host.net_mode != "client":
				host.on_villager_needs_help(self)
		elif needs_help and edist > SAFE_RADIUS and position.distance_to(center) < SETTLE_RADIUS:
			needs_help = false   # safe and home — back to work
			_refresh_label()
	if needs_help:
		# at night a cot-hut is the better refuge — drop the huddle and go in
		if _is_night() and not is_captive and host.house_slot_for(self) != Vector2.INF:
			needs_help = false
			_refresh_label()
		else:
			# run for the village heart and huddle there — each at their own slot, not in a pile
			var huddle := center + _slot_offset()
			if position.distance_to(huddle) > 6.0:
				velocity = (huddle - position).normalized() * FOLLOW_SPEED
			else:
				velocity = Vector2.ZERO
			move_and_slide()
			return
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
				# bedtime: arriving at the hut door, they go inside
				if _bound_for_house and _is_night():
					_enter_house()
					return
		else:
			if _wander_target == Vector2.ZERO or position.distance_to(_wander_target) < 8.0:
				_wander_target = center + Vector2(_rng.randf_range(-110, 110), _rng.randf_range(-110, 110))
			velocity = (_wander_target - position).normalized() * WANDER_SPEED
	move_and_slide()

## --- housing: dinner, then in for the night; out again for breakfast ----------
func _is_night() -> bool:
	var hour := host.clock.minute_of_day / 60
	return hour >= 21 or hour < 6

func _enter_house() -> void:
	housed = true
	visible = false          # the hut holds them; the flats can't
	velocity = Vector2.ZERO
	needs_help = false
	_refresh_label()

func _leave_house() -> void:
	housed = false
	visible = true
	# step out the door, each to their own spot — breakfast is at the hearth
	position += Vector2(0, 14) + _slot_offset() * 0.3
	_refresh_label()

## A small, STABLE per-villager offset so folk who share a spot (the same work
## zone, the same chapel, the night hearth) fan into a little cluster instead of
## standing stacked in one pixel. Villager bodies don't collide, so without this
## they pile up perfectly on any shared target.
func _slot_offset() -> Vector2:
	var k: int = tribesman_id if tribesman_id >= 0 else int(get_meta("nid", 0))
	var ang := float(k) * 2.3999632   # golden angle → an even spread, no clumps
	var rad := 22.0 + float(k % 4) * 9.0
	return Vector2(cos(ang), sin(ang)) * rad

## Where their day wants them: breakfast at the hearth, their job by day, their
## god's chapel at dusk, dinner at the hearth, then INTO a cot-hut for the night
## (safety and rest; no room → the old hearth-huddle). Each target is nudged by
## their slot so a crowd fans out.
var _bound_for_house := false

func _daily_target(center: Vector2) -> Vector2:
	_bound_for_house = false
	if is_captive:
		var yoke := host.work_pos("work-yoke-post")
		return yoke if yoke != Vector2.INF else center   # bound to the post, or milling
	var hour := host.clock.minute_of_day / 60
	if hour >= 6 and hour < 7:
		return center + Vector2(0, 44) + _slot_offset()   # breakfast at the hearth
	if hour >= 7 and hour < 17 and task != "":
		var z: Vector2 = host.task_work_zone(task)   # their assigned work: a station or a forage spot
		return z + _slot_offset() if z != Vector2.INF else Vector2.INF
	if hour >= 17 and hour < 19 and def_patron != "":
		var c: Vector2 = host.chapels.get(def_patron, Vector2.INF)
		return c + _slot_offset() if c != Vector2.INF else Vector2.INF
	if hour >= 19 and hour < 21:
		return center + Vector2(0, 44) + _slot_offset()   # dinner at the hearth
	if hour >= 21 or hour < 6:
		var bunk: Vector2 = host.house_slot_for(self)
		if bunk != Vector2.INF:
			_bound_for_house = true
			return bunk   # no slot offset — walk to the door itself
		return center + Vector2(0, 44) + _slot_offset()   # no room at any inn
	return Vector2.INF
