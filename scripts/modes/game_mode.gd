extends Node
class_name GameMode

## Base class for match rule-sets.
##
## Instantiated by GameStateManager and parented under the level scene, so it
## pauses with the tree and is freed automatically on any scene change.
## Subclasses override the metadata and rule hooks; scoring goes through the
## helpers below so the HUD stays in sync via EventBus.mode_score_changed.

var goal: int = 0
var _scores: Dictionary = {}  # CharacterController -> int
var is_authority: bool = true

## Metadata (override all in subclasses)

func mode_id() -> StringName:
	return &"base"

func display_name() -> String:
	return "Base"

func goal_label() -> String:
	return "Goal"

func goal_min() -> int:
	return 1

func goal_max() -> int:
	return 99

func goal_default() -> int:
	return 10

func score_header() -> String:
	return "Score"

func uses_timer() -> bool:
	return false

## Rule hooks (override as needed)

func on_match_started() -> void:
	pass

func tick(_delta: float) -> void:
	pass

func on_character_killed(_killer: CharacterController, _victim: CharacterController) -> void:
	pass

func on_character_died(_character: CharacterController) -> void:
	pass

func on_character_respawned(_character: CharacterController) -> void:
	pass

func get_status_text() -> String:
	return ""  # center-top HUD; "" hides the label

## Framework plumbing (do not override)

func setup(goal_value: int, authority: bool = true) -> void:
	goal = clampi(goal_value, goal_min(), goal_max())
	is_authority = authority

func _ready() -> void:
	add_to_group("game_mode")
	EventBus.match_started.connect(on_match_started)
	EventBus.character_killed.connect(_on_killed)
	EventBus.character_died.connect(_on_died)
	EventBus.character_respawned.connect(_on_respawned)

func _process(delta: float) -> void:
	if is_authority and GameStateManager.is_playing():
		tick(delta)

# Guards: ignore events once the match has ended (e.g. a same-frame double
# kill after the winning stomp).
func _on_killed(killer: CharacterController, victim: CharacterController) -> void:
	if is_authority and GameStateManager.is_playing():
		on_character_killed(killer, victim)

func _on_died(character: CharacterController) -> void:
	if is_authority and GameStateManager.is_playing():
		on_character_died(character)

func _on_respawned(character: CharacterController) -> void:
	if is_authority and GameStateManager.is_playing():
		on_character_respawned(character)

## Score helpers for subclasses

func initial_score() -> int:
	return 0  # ClassicMode overrides -> goal (lives)

func get_score(character: CharacterController) -> int:
	return _scores.get(character, initial_score())

func set_score(character: CharacterController, value: int) -> void:
	_scores[character] = value
	EventBus.mode_score_changed.emit(character, value)

func add_score(character: CharacterController, amount: int) -> void:
	set_score(character, get_score(character) + amount)

func apply_authoritative_score(character: CharacterController, value: int) -> void:
	if character != null:
		set_score(character, value)

func check_goal_reached(character: CharacterController) -> void:
	if get_score(character) >= goal:
		declare_winner(character)

func declare_winner(winner: CharacterController) -> void:  # null = draw
	if is_authority:
		EventBus.win_condition_met.emit(winner)

## Shared utilities for subclasses

func get_characters() -> Array[CharacterController]:
	var result: Array[CharacterController] = []
	for node in get_tree().get_nodes_in_group("characters"):
		if node is CharacterController:
			result.append(node)
	return result

static func cpu_of(character: CharacterController) -> CPUController:
	return character.get_node_or_null("CPUController") as CPUController
