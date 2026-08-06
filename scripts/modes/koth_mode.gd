extends GameMode

## King of the Hill: be the SOLE occupant of the zone to accrue points
## (1 per 0.5 s; contested = nobody scores). The hill relocates every 15 s.
## First to N points wins.

const ZONE_SCENE := preload("res://scenes/objects/koth_zone.tscn")
const MOVE_INTERVAL := 15.0
const POINTS_PER_SECOND := 2.0
const MIN_PLATFORM_NODES := 4
const AI_PUSH_INTERVAL := 0.4

var _zone: Area2D = null
var _move_timer := MOVE_INTERVAL
var _accrual: Dictionary = {}  # CharacterController -> float
var _push_timer := 0.0
var _current_platform_id := -1

func mode_id() -> StringName:
	return &"koth"

func display_name() -> String:
	return "King of the Hill"

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

func on_match_started() -> void:
	_place_zone()

func tick(delta: float) -> void:
	if _zone == null:
		return
	_move_timer -= delta
	if _move_timer <= 0.0:
		_place_zone()
	var occupants: Array = _zone.get_occupants()
	if occupants.size() == 1:
		var king: CharacterController = occupants[0]
		var previous := int(_accrual.get(king, 0.0))
		_accrual[king] = float(_accrual.get(king, 0.0)) + delta * POINTS_PER_SECOND
		if int(_accrual[king]) != previous:
			set_score(king, int(_accrual[king]))
			check_goal_reached(king)
	_push_timer -= delta
	if _push_timer <= 0.0:
		_push_timer = AI_PUSH_INTERVAL
		_push_ai_goals(occupants)

func get_status_text() -> String:
	return "HILL MOVES IN %d" % ceili(maxf(_move_timer, 0.0))

## Random platform with a decent horizontal run (excluding the current one
## on relocation); the zone origin sits on the platform surface.
func _place_zone() -> void:
	_move_timer = MOVE_INTERVAL
	var nav := get_tree().current_scene as LevelNavigation
	if nav == null or nav.platforms.is_empty():
		return
	var options: Array = []
	for platform: LevelNavigation.PlatformEntry in nav.platforms.values():
		if platform.nodes.size() >= MIN_PLATFORM_NODES and platform.id != _current_platform_id:
			options.append(platform)
	if options.is_empty():
		return
	var chosen: LevelNavigation.PlatformEntry = options.pick_random()
	_current_platform_id = chosen.id
	var first: LevelNavigation.NodeEntry = chosen.nodes[0]
	var last: LevelNavigation.NodeEntry = chosen.nodes[chosen.nodes.size() - 1]
	var center := Vector2((first.position.x + last.position.x) * 0.5, first.position.y)
	if _zone == null:
		_zone = ZONE_SCENE.instantiate()
		_zone.position = center
		get_tree().current_scene.add_child(_zone)
	else:
		print("[KOTH] hill moved")
		_zone.relocate(center)
		EventBus.hill_moved.emit()
		EventBus.ui_notification.emit("THE HILL MOVED!", "info")

func _push_ai_goals(occupants: Array) -> void:
	for character in get_characters():
		var cpu := cpu_of(character)
		if cpu == null:
			continue
		var inside := occupants.has(character)
		if inside and occupants.size() > 1:
			cpu.clear_move_goal()  # contested: fight the intruder
		else:
			cpu.set_move_goal(_zone.ground_position, true)
