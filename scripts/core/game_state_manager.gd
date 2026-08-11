extends Node

## Single source of truth for game state management.
##
## Manages state transitions, pause/resume, match lifecycle, and character registry.
## All state changes emit events through EventBus for other systems to react.

enum GameState {
	MENU,
	LOADING,
	COUNTDOWN,
	PLAYING,
	PAUSED,
	GAME_OVER,
	TRANSITIONING
}

var current_state: GameState = GameState.MENU
var previous_state: GameState = GameState.MENU

# Match data
var match_in_progress: bool = false
var match_winner: CharacterController = null
var current_level_path: String = ""
var _online_overlay_open := false

# Character registry
var registered_characters: Dictionary = {}  # CharacterController -> CharacterInfo

class CharacterInfo:
	var controller: CharacterController
	var spawn_point: Vector2

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	InputManager.pause_toggled.connect(_on_pause_toggled)

	EventBus.win_condition_met.connect(_on_win_condition_met)

## Main state transitions

## Starts a new match by loading the specified level.
func start_match(level_path: String) -> void:
	if current_state != GameState.MENU and current_state != GameState.GAME_OVER:
		push_warning("Cannot start match from state: %s" % GameState.keys()[current_state])
		return
	
	match_in_progress = true
	match_winner = null
	current_level_path = level_path
	registered_characters.clear()
	
	_change_state(GameState.LOADING)
	EventBus.scene_changing.emit(get_tree().current_scene.scene_file_path if get_tree().current_scene else "", level_path)
	
	var tree := get_tree()
	var err := tree.change_scene_to_file(level_path)
	if err != OK:
		push_error("Failed to load match scene '%s': %s" % [level_path, error_string(err)])
		match_in_progress = false
		_change_state(GameState.MENU)
		return
	await tree.scene_changed

	if not _spawn_game_mode(GameSettings.get_selected_mode(), GameSettings.get_goal_for_mode(GameSettings.get_selected_mode()), true):
		match_in_progress = false
		return_to_menu()
		return
	_change_state(GameState.PLAYING)
	EventBus.level_loaded.emit(level_path)
	EventBus.match_started.emit()

## Instantiates the selected game mode under the level scene, so it pauses
## with the tree and is freed automatically on scene change. Must run before
## level_loaded/match_started are emitted.
func _spawn_game_mode(id: StringName, goal: int, authority: bool) -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		push_error("Cannot spawn game mode: no current level scene is available")
		return false
	var mode := ModeRegistry.create(id)
	mode.setup(goal, authority)
	mode.name = "GameMode"
	scene.add_child(mode)
	return true

## Pauses the game and shows pause menu via UIManager.
func pause_game() -> void:
	if current_state != GameState.PLAYING:
		return
	if NetworkSession.is_online_match():
		if not _online_overlay_open:
			_online_overlay_open = true
			EventBus.game_paused.emit()
		return
	
	_change_state(GameState.PAUSED)
	get_tree().paused = true
	EventBus.game_paused.emit()

## Resumes the game and hides pause menu.
func resume_game() -> void:
	if NetworkSession.is_online_match():
		if _online_overlay_open:
			_online_overlay_open = false
			EventBus.game_resumed.emit()
		return
	if current_state != GameState.PAUSED:
		return
	
	_change_state(GameState.PLAYING)
	get_tree().paused = false
	EventBus.game_resumed.emit()

## Ends the match, removes characters, and shows game over screen.
func end_match(winner: CharacterController) -> void:
	if current_state != GameState.PLAYING:
		return
	
	match_in_progress = false
	match_winner = winner
	_change_state(GameState.GAME_OVER)
	
	# Remove all characters from the scene
	_remove_all_characters()
	
	if not NetworkSession.is_online_match():
		get_tree().paused = true
	print("[Match] ended - winner: %s" % (winner.name if winner else "draw"))
	EventBus.match_ended.emit(winner)

func return_to_menu(preserve_online_session: bool = false) -> void:
	if not preserve_online_session and NetworkSession.has_active_session():
		NetworkSession.leave_session(false)
	match_in_progress = false
	match_winner = null
	registered_characters.clear()
	get_tree().paused = false
	
	_change_state(GameState.TRANSITIONING)
	EventBus.scene_changing.emit(current_level_path, "res://scenes/ui/start_menu.tscn")
	
	var tree := get_tree()
	var menu_path := "res://scenes/ui/start_menu.tscn"
	var err := tree.change_scene_to_file(menu_path)
	if err != OK:
		push_error("Failed to return to menu '%s': %s" % [menu_path, error_string(err)])
		return
	await tree.scene_changed
	
	current_level_path = ""
	_change_state(GameState.MENU)

func restart_match() -> void:
	if current_level_path == "":
		push_warning("Cannot restart: no level path stored")
		return_to_menu()
		return
	
	var level_path := current_level_path
	_change_state(GameState.TRANSITIONING)
	get_tree().paused = false
	
	var tree := get_tree()
	var err := tree.change_scene_to_file(level_path)
	if err != OK:
		push_error("Failed to restart match scene '%s': %s" % [level_path, error_string(err)])
		return_to_menu()
		return
	await tree.scene_changed

	match_in_progress = true
	match_winner = null
	registered_characters.clear()
	if not _spawn_game_mode(GameSettings.get_selected_mode(), GameSettings.get_goal_for_mode(GameSettings.get_selected_mode()), true):
		return_to_menu()
		return
	_change_state(GameState.PLAYING)
	EventBus.level_loaded.emit(level_path)
	EventBus.match_started.emit()

## Loads an authoritative two-human roster. SpawnManager deliberately does not
## auto-spawn its offline player/CPU set while this configuration is active.
func start_online_match(config: Dictionary) -> void:
	if not NetworkProtocol.validate_match_config(config):
		push_error("GameStateManager: invalid online match configuration")
		NetworkSession.leave_session(false)
		return_to_menu()
		return
	match_in_progress = true
	match_winner = null
	registered_characters.clear()
	_online_overlay_open = false
	var level_path := NetworkProtocol.level_path_from_id(str(config.get("level_id", "")))
	current_level_path = level_path
	_change_state(GameState.LOADING)
	EventBus.scene_changing.emit(get_tree().current_scene.scene_file_path if get_tree().current_scene else "", level_path)
	var tree := get_tree()
	var err := tree.change_scene_to_file(level_path)
	if err != OK:
		push_error("Failed to load online match scene '%s': %s" % [level_path, error_string(err)])
		NetworkSession.leave_session(false)
		return_to_menu()
		return
	await tree.scene_changed
	if not NetworkSession.is_online_match():
		return
	if not _spawn_game_mode(&"frag", int(config.get("goal", 10)), NetworkSession.is_host()):
		NetworkSession.leave_session(false)
		return_to_menu()
		return
	var spawn_manager := tree.get_first_node_in_group("spawn_manager")
	if spawn_manager == null or not spawn_manager.has_method("spawn_online_roster"):
		push_error("Online level has no compatible SpawnManager")
		NetworkSession.leave_session(false)
		return_to_menu()
		return
	var characters: Dictionary = spawn_manager.spawn_online_roster(config)
	var expected: int = (config.get("participants", []) as Array).size()
	if characters.size() != expected:
		push_error("Online roster spawned %d of %d participants" % [characters.size(), expected])
		NetworkSession.leave_session(false)
		return_to_menu()
		return
	NetworkSession.register_match_characters(characters)
	EventBus.level_loaded.emit(level_path)
	NetworkSession.notify_scene_ready()

func begin_online_countdown() -> void:
	if current_state != GameState.LOADING or not NetworkSession.is_online_match():
		return
	_change_state(GameState.COUNTDOWN)
	for value in [3, 2, 1]:
		EventBus.online_countdown_changed.emit(value)
		await get_tree().create_timer(1.0, true).timeout
		if current_state != GameState.COUNTDOWN or not NetworkSession.is_online_match():
			return
	EventBus.online_countdown_changed.emit(0)
	_change_state(GameState.PLAYING)
	EventBus.match_started.emit()
	NetworkSession.notify_match_started()

func end_online_match(winner_peer_id: int) -> void:
	if current_state != GameState.PLAYING or NetworkSession.is_host():
		return
	end_match(NetworkSession.get_character(winner_peer_id))

func abort_online_match(message: String) -> void:
	match_in_progress = false
	match_winner = null
	registered_characters.clear()
	get_tree().paused = false
	EventBus.ui_notification.emit(message, "error")
	return_to_menu(true)

## Character registration

func register_character(character: CharacterController) -> void:
	if registered_characters.has(character):
		return
	
	var info := CharacterInfo.new()
	info.controller = character
	info.spawn_point = character.global_position

	registered_characters[character] = info

func unregister_character(character: CharacterController) -> void:
	registered_characters.erase(character)

func get_character_info(character: CharacterController) -> CharacterInfo:
	return registered_characters.get(character, null)

## State queries

func is_playing() -> bool:
	return current_state == GameState.PLAYING

func is_paused() -> bool:
	return current_state == GameState.PAUSED

func is_in_menu() -> bool:
	return current_state == GameState.MENU

func is_game_over() -> bool:
	return current_state == GameState.GAME_OVER

func can_pause() -> bool:
	return current_state == GameState.PLAYING

func can_show_dev_menu() -> bool:
	return current_state in [GameState.PLAYING, GameState.PAUSED]

## Internal

func _change_state(new_state: GameState) -> void:
	if current_state == new_state:
		return
	
	previous_state = current_state
	current_state = new_state
	
	EventBus.game_state_changed.emit(
		GameState.keys()[previous_state],
		GameState.keys()[current_state]
	)

func _on_pause_toggled() -> void:
	if NetworkSession.is_online_match() and current_state == GameState.PLAYING:
		if _online_overlay_open:
			resume_game()
		else:
			pause_game()
		return
	# Don't allow pause in certain states
	if not can_pause() and current_state != GameState.PAUSED:
		return
	
	if current_state == GameState.PAUSED:
		resume_game()
	elif current_state == GameState.PLAYING:
		pause_game()

func _on_win_condition_met(winner: CharacterController) -> void:
	end_match(winner)

func _remove_all_characters() -> void:
	# Get all characters and remove them
	var characters := get_tree().get_nodes_in_group("characters")
	for node in characters:
		if is_instance_valid(node):
			node.queue_free()
