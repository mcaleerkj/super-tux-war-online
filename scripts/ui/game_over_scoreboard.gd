extends Control

@onready var _score_table: VBoxContainer = $"%ScoreTable"
@onready var _restart_button: Button = $"%RestartButton"
@onready var _menu_button: Button = $"%MenuButton"
@onready var _lobby_button: Button = $"%LobbyButton"
@onready var _title: Label = $"%Title"
@onready var _score_header: Label = $"%ScoreHeader"

var _current_level_path: String = ""

func _ready() -> void:
	_restart_button.pressed.connect(_on_restart_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	_lobby_button.pressed.connect(_on_lobby_pressed)
	# The host's match-ended signal reaches the UI before NetworkSession's
	# listener changes PLAYING to ENDED, so use the active match identity here.
	if NetworkSession.is_online_match():
		_restart_button.text = "Rematch"
		_menu_button.text = "Leave"
		_lobby_button.visible = NetworkSession.is_host()
	_update_title()
	_populate_scoreboard()

func _update_title() -> void:
	var winner := GameStateManager.match_winner
	if winner == null:
		_title.text = "Draw!"
	elif winner.is_locally_controlled():
		_title.text = "You Win!"
	else:
		_title.text = "%s Wins!" % GameSettings.get_character_display_name(winner.character_asset_name)

func set_current_level(level_path: String) -> void:
	_current_level_path = level_path

func _populate_scoreboard() -> void:
	# Mode-specific column title (Kills / Coins / Lives / Points)
	var mode := get_tree().get_first_node_in_group("game_mode")
	if mode is GameMode:
		_score_header.text = mode.score_header()

	# Remove existing rows (keep header)
	for child in _score_table.get_children():
		if child.name != "TableHeader":
			child.queue_free()
	
	# Get all characters and their scores
	var character_scores: Array[Dictionary] = []
	var characters := get_tree().get_nodes_in_group("characters")
	
	for node in characters:
		var character := node as CharacterController
		if character:
			# Get score from score counter
			var score := _get_character_score(character)
			character_scores.append({
				"character": character,
				"score": score,
				"name": GameSettings.get_character_display_name(character.character_asset_name),
				"is_human": character.is_human,
				"is_local": character.is_locally_controlled(),
				"participant_label": character.participant_label(),
				"color": character.character_color
			})
	
	# Sort by score (highest first)
	character_scores.sort_custom(func(a, b): return a.score > b.score)
	
	# Create rows
	for entry in character_scores:
		var row := _create_score_row(entry)
		_score_table.add_child(row)

func _get_character_score(character: CharacterController) -> int:
	# The active game mode owns scores.
	var mode := get_tree().get_first_node_in_group("game_mode")
	if mode is GameMode:
		return mode.get_score(character)
	# Fallback for direct F6 level runs without a mode.
	var score_counter := get_tree().get_first_node_in_group("score_counter")
	if score_counter and score_counter.has_method("get_character_score"):
		return score_counter.get_character_score(character)
	return 0

func _create_score_row(entry: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	# Color swatch to represent character tint (CPU colors, etc.)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(18, 18)
	swatch.color = entry.get("color", Color.WHITE)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(swatch)
	
	# Kills
	var kills_label := Label.new()
	kills_label.custom_minimum_size = Vector2(80, 0)
	kills_label.text = str(entry.score)
	kills_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kills_label.add_theme_font_size_override("font_size", 16)
	row.add_child(kills_label)
	
	# Character name
	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(150, 0)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text = entry.name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", entry.get("color", Color.WHITE))
	row.add_child(name_label)
	
	# Player indicator (Player or CPU text)
	var player_label := Label.new()
	player_label.custom_minimum_size = Vector2(100, 0)
	player_label.text = str(entry.get("participant_label", "CPU"))
	player_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	player_label.add_theme_font_size_override("font_size", 16)
	player_label.add_theme_color_override("font_color", Color.GREEN if entry.get("is_local", false) else Color.CORNFLOWER_BLUE if entry.get("is_human", false) else Color.RED)
	row.add_child(player_label)
	
	return row

func _on_restart_pressed() -> void:
	if NetworkSession.state == NetworkSession.SessionState.ENDED:
		_restart_button.disabled = true
		_restart_button.text = "Waiting..."
		NetworkSession.vote_rematch()
		return
	queue_free()
	GameStateManager.restart_match()

func _on_lobby_pressed() -> void:
	queue_free()
	NetworkSession.return_to_lobby()

func _on_menu_pressed() -> void:
	queue_free()
	if NetworkSession.has_active_session():
		NetworkSession.leave_session(false)
	GameStateManager.return_to_menu()
