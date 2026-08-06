extends GameMode

## Chicken: the first killer becomes the chicken -- tinted, slowed, and worth
## hunting. The chicken earns 1 point/sec alive and +5 per kill it makes;
## killing the chicken transfers the role. First to N points wins.

const CHICKEN_TINT := Color(1.0, 0.95, 0.35)
const CHICKEN_SPEED := 0.75
const CHICKEN_KILL_BONUS := 5.0
const AI_PUSH_INTERVAL := 0.3
const FLEE_SAMPLE_MAX := 200
const SCREEN := Vector2(1280.0, 704.0)  # matches project viewport; arena wraps

var _chicken: CharacterController = null
var _accrual: Dictionary = {}  # CharacterController -> float
var _push_timer := 0.0

func mode_id() -> StringName:
	return &"chicken"

func display_name() -> String:
	return "Chicken"

func goal_label() -> String:
	return "Points to Win"

func goal_min() -> int:
	return 10

func goal_max() -> int:
	return 99

func goal_default() -> int:
	return 30

func score_header() -> String:
	return "Points"

func on_character_killed(killer: CharacterController, victim: CharacterController) -> void:
	if not _is_chicken_valid():
		_set_chicken(killer)
	elif victim == _chicken:
		_set_chicken(killer)
	elif killer == _chicken:
		_accrual[killer] = float(_accrual.get(killer, 0.0)) + CHICKEN_KILL_BONUS
		_publish_score(killer)

func tick(delta: float) -> void:
	if _is_chicken_valid() and not _chicken.is_despawned:
		_accrual[_chicken] = float(_accrual.get(_chicken, 0.0)) + delta
		_publish_score(_chicken)
	_push_timer -= delta
	if _push_timer <= 0.0:
		_push_timer = AI_PUSH_INTERVAL
		_push_ai_policies()

func get_status_text() -> String:
	if not _is_chicken_valid():
		return "FIRST STOMP BECOMES THE CHICKEN"
	if _chicken.is_locally_controlled():
		return "YOU ARE THE CHICKEN"
	return "KILL THE CHICKEN"

func _publish_score(character: CharacterController) -> void:
	var value := int(_accrual.get(character, 0.0))
	if value != get_score(character):
		set_score(character, value)
		check_goal_reached(character)

func _is_chicken_valid() -> bool:
	return _chicken != null and is_instance_valid(_chicken)

func _set_chicken(character: CharacterController) -> void:
	if _is_chicken_valid():
		_chicken.visuals.clear_tint_overlay()
		_chicken.physics.speed_modifier = 1.0
	_chicken = character
	if _is_chicken_valid():
		print("[Chicken] -> %s" % character.name)
		_chicken.visuals.set_tint_overlay(CHICKEN_TINT)
		_chicken.physics.speed_modifier = CHICKEN_SPEED
		EventBus.chicken_changed.emit(character)
		var who := "YOU ARE" if character.is_locally_controlled() else "%s IS" % \
			GameSettings.get_character_display_name(character.character_asset_name).to_upper()
		EventBus.ui_notification.emit("%s THE CHICKEN!" % who, "info")
	_push_ai_policies()

func _push_ai_policies() -> void:
	var chicken_active := _is_chicken_valid()
	for character in get_characters():
		var cpu := cpu_of(character)
		if cpu == null:
			continue
		if not chicken_active:
			cpu.clear_priority_target()
			cpu.clear_move_goal()
		elif character == _chicken:
			cpu.clear_priority_target()
			_push_flee_goal(cpu, character)
		else:
			cpu.set_priority_target(_chicken)
			cpu.clear_move_goal()

## The chicken CPU flees to the nav node maximizing min wrap-aware distance
## from all living hunters (the arena wraps at the edges, so plain distance
## would flee "into" a pursuer through the seam).
func _push_flee_goal(cpu: CPUController, chicken: CharacterController) -> void:
	var nav := get_tree().current_scene as LevelNavigation
	if nav == null or nav.nodes.is_empty():
		return
	var hunters := get_characters().filter(
		func(c: CharacterController) -> bool: return c != chicken and not c.is_despawned
	)
	if hunters.is_empty():
		cpu.clear_move_goal()
		return
	var stride := maxi(1, nav.nodes.size() / FLEE_SAMPLE_MAX)
	var best: LevelNavigation.NodeEntry = null
	var best_dist := -1.0
	var i := 0
	while i < nav.nodes.size():
		var node: LevelNavigation.NodeEntry = nav.nodes[i]
		var min_dist := INF
		for hunter: CharacterController in hunters:
			min_dist = minf(min_dist, _wrap_distance(node.position, hunter.global_position))
		if min_dist > best_dist:
			best_dist = min_dist
			best = node
		i += stride
	if best:
		cpu.set_move_goal(best.position)

func _wrap_distance(a: Vector2, b: Vector2) -> float:
	var dx := absf(a.x - b.x)
	dx = minf(dx, SCREEN.x - dx)
	var dy := absf(a.y - b.y)
	dy = minf(dy, SCREEN.y - dy)
	return Vector2(dx, dy).length()
