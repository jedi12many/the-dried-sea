class_name DSBeast
extends CharacterBody2D
## A tamed beast at heel (VILLAGER-AND-GODHEAD-SPEC Part III). The body that
## walks and fights/carries; beast_system.gd owns the roster truth (xp, mood,
## trust). Modeled on villager.gd's shape: host-driven physics server-side,
## client mirrors just watch (net rule: no AI on a mirror).

const FOLLOW_SPEED := 130.0
const WANDER_SPEED := 32.0
const STRIKE_RANGE := 34.0
const FOLLOW_MAX := 70.0
const SHELL_RADIUS := 170.0          # a crab shells when a hostile is this close
const PORTER_PICKUP_RADIUS := 80.0
const GROWL_BASE_RADIUS := 300.0
const GROWL_VISIBLE_CLOSE := 140.0   # already-obvious hostiles don't need a growl line
const GROWL_COOLDOWN := 6.0

const CREATURE_SPRITES := {"creature-salt-hound": "hound", "creature-scuttle-crab": "crab"}
const TAME_TINT := Color(1.18, 1.04, 0.78)     # a modest warm tint — tame reads at a glance
const DOWNED_TINT := Color(0.55, 0.5, 0.48)
const SHELL_TINT := Color(0.72, 0.82, 0.92)

var host: GameHost
var beast_id := -1
var creature_id := ""
var display_name := "Beast"
var owner_pid := -1
var at_heel := false
var kenneled := false
var mood := "keen"
var downed := false
var downed_until := 0.0
# client-mirror fallback fields (a client's local BeastSystem is never fed —
# host-authoritative sim state rides world_sync instead; see [V] panel notes)
var level := 0
var instincts_lit := 0

var _porter_bag: Dictionary = {}   # item_id -> qty, the crab's own carry
var _carried_since_dawn := false   # did the bag see anything today? (porterDay XP at dawn)
var _shelled := false
var _tide_shell_used_today := false
var _tide_shell_pose := false
var _strike_cd := 0.0
var _growl_cd := 0.0
var _porter_cd := 0.0
var _wander_target := Vector2.ZERO
var _rng := RandomNumberGenerator.new()
var _label: Label
var _body: Node2D

func _ready() -> void:
	_rng.seed = 401 + beast_id
	collision_layer = 0
	collision_mask = 0
	_body = SpriteKit.sprite(CREATURE_SPRITES.get(creature_id, "hound"), Vector2(20, 16), Color("cfc9ba"))
	_body.modulate = TAME_TINT
	add_child(_body)
	_label = Label.new()
	_label.position = Vector2(-70, 14)
	_label.custom_minimum_size = Vector2(140, 0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color("8a7a5c"))
	_label.add_theme_font_size_override("font_size", 10)
	add_child(_label)
	_refresh_label()

func _refresh_label() -> void:
	if _label == null:
		return
	if downed:
		_label.text = "%s (DOWN — [E] to revive)" % display_name
		return
	var where := "at heel" if at_heel else ("kenneled" if kenneled else "waiting")
	_label.text = "%s (%s%s)" % [display_name, where, ", %s" % mood if mood != "keen" else ""]

func flash_tide_shell() -> void:
	_tide_shell_pose = true
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		if is_instance_valid(self):
			_tide_shell_pose = false)

func bag_total() -> int:
	var n := 0
	for item_id: String in _porter_bag:
		n += int(_porter_bag[item_id])
	return n

func _physics_process(delta: float) -> void:
	if host == null:
		return
	if host.net_mode == "client":
		return   # the server walks/fights them; we just watch
	if downed:
		if downed_until <= Time.get_unix_time_from_system():
			host.beast_die(self)
			return
		velocity = Vector2.ZERO
		move_and_slide()
		return
	var role := host.beast_role(creature_id)
	if role == "porter":
		_physics_porter(delta)
	elif role == "fighter":
		if at_heel:
			_physics_hound(delta)
		else:
			_physics_idle()
	else:
		_physics_idle()
	_update_tint()

func _update_tint() -> void:
	if _body == null:
		return
	if downed:
		_body.modulate = DOWNED_TINT
	elif _shelled or _tide_shell_pose:
		_body.modulate = SHELL_TINT
	else:
		_body.modulate = TAME_TINT

## Idle: live near the kennel (or the village heart, if none stands) — a
## gentle wander, same shape as a villager off-duty.
func _physics_idle() -> void:
	var center := host.village_heart()
	if _wander_target == Vector2.ZERO or position.distance_to(_wander_target) < 8.0:
		_wander_target = center + Vector2(_rng.randf_range(-70, 70), _rng.randf_range(-70, 70))
	_move_toward(_wander_target, WANDER_SPEED)

## Crabs: never fight, never die. Threatened -> shell (stopped, invulnerable,
## enemies read it as gone). At heel, a live crab hoovers nearby drops into
## its own bag. Off heel, it just idles near home.
func _physics_porter(delta: float) -> void:
	_shelled = host.enemy_near_dist(position) < SHELL_RADIUS
	if _shelled:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	if at_heel:
		var leader := host.companion_leader_pos(owner_pid)
		if leader == Vector2.INF:
			velocity = Vector2.ZERO
			move_and_slide()
			return
		_porter_tick(delta)
		_follow_leader(leader)
	else:
		_physics_idle()

func _porter_tick(delta: float) -> void:
	_porter_cd = maxf(_porter_cd - delta, 0.0)
	if _porter_cd > 0.0:
		return
	var cap := host.beast_carry_capacity(beast_id)
	if bag_total() >= cap:
		return
	for n: Area2D in host.resource_nodes:
		if not is_instance_valid(n):
			continue
		if position.distance_to(n.position) > PORTER_PICKUP_RADIUS:
			continue
		var item_id := str(n.get_meta("item_id"))
		var qty := 1
		if int(n.get_meta("hits", 1)) > 1:
			host._deplete_node(n, 1)
		else:
			qty = int(n.get_meta("qty", 1))
			host.harvested_indices.append(int(n.get_meta("idx", -1)))
			host.resource_nodes.erase(n)
			n.queue_free()
		_porter_bag[item_id] = int(_porter_bag.get(item_id, 0)) + qty
		_carried_since_dawn = true
		_porter_cd = 0.4   # one item per beat — a slow vacuum, not an instant strip
		break

## Hounds: warrior-kit melee off THEIR OWN level, the living-radar growl, and
## a break-off at low HP (same shape as a companion's arms_behavior).
func _physics_hound(delta: float) -> void:
	_strike_cd = maxf(_strike_cd - delta, 0.0)
	_growl_cd = maxf(_growl_cd - delta, 0.0)
	var leader := host.companion_leader_pos(owner_pid)
	if leader == Vector2.INF:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	var behavior := host.beast_behavior(creature_id)
	var engage_range: float = float(behavior.get("engageRange", 6)) * host.TILE
	var break_pct: float = float(behavior.get("breakHpPct", 0.15))
	var max_hp := host.beast.beast_max_hp(beast_id)
	var hp_pct := (host.stats.hp(self) / max_hp) if max_hp > 0.0 else 1.0
	_tick_growl()
	if hp_pct <= break_pct:
		_follow_leader(leader)
		return
	var enemy := host._nearest_hostile(position, engage_range)
	if enemy == null:
		if position.distance_to(leader) > FOLLOW_MAX:
			_follow_leader(leader)
		else:
			velocity = Vector2.ZERO
			move_and_slide()
		return
	var dist := position.distance_to(enemy.position)
	if dist > STRIKE_RANGE:
		_move_toward(enemy.position, FOLLOW_SPEED)
	else:
		velocity = Vector2.ZERO
		move_and_slide()
		if _strike_cd == 0.0:
			_strike_cd = 0.9
			host.beast_strike(self, enemy)

## Blood-Scent lite: a hostile within growl range, not already obvious, gets a
## bearing line for the OWNER alone — throttled, not spammy.
func _tick_growl() -> void:
	if _growl_cd > 0.0:
		return
	host.beast_growl_tick(self)

func _follow_leader(leader: Vector2) -> void:
	_move_toward(leader + _heel_offset(), FOLLOW_SPEED)

## A small per-beast offset — the same "fan out, don't stack" idea as
## villager._slot_offset(), phase-shifted so a road companion and a beast at
## heel don't land on the same pixel behind the player.
func _heel_offset() -> Vector2:
	var k := beast_id if beast_id >= 0 else 0
	var ang := float(k) * 2.3999632 + PI
	var rad := 30.0 + float(k % 3) * 8.0
	return Vector2(cos(ang), sin(ang)) * rad

func _move_toward(target: Vector2, speed: float) -> void:
	if position.distance_to(target) > 6.0:
		velocity = (target - position).normalized() * speed
	else:
		velocity = Vector2.ZERO
	move_and_slide()
