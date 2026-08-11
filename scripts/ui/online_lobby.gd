extends Control

@onready var _setup_view: VBoxContainer = %SetupView
@onready var _lobby_view: VBoxContainer = %LobbyView
@onready var _status_label: Label = %StatusLabel
@onready var _room_code_input: LineEdit = %RoomCodeInput
@onready var _create_button: Button = %CreateButton
@onready var _join_button: Button = %JoinButton
@onready var _back_button: Button = %BackButton
@onready var _room_code_label: Label = %RoomCodeLabel
@onready var _copy_button: Button = %CopyButton
@onready var _connection_label: Label = %ConnectionLabel
@onready var _host_label: Label = %HostLabel
@onready var _guest_label: Label = %GuestLabel
@onready var _level_label: Label = %LevelLabel
@onready var _goal_label: Label = %GoalLabel
@onready var _character_label: Label = %CharacterLabel
@onready var _prev_level: Button = %PrevOnlineLevel
@onready var _next_level: Button = %NextOnlineLevel
@onready var _minus_goal: Button = %MinusOnlineGoal
@onready var _plus_goal: Button = %PlusOnlineGoal
@onready var _prev_character: Button = %PrevOnlineCharacter
@onready var _next_character: Button = %NextOnlineCharacter
@onready var _ready_button: Button = %ReadyButton
@onready var _start_button: Button = %StartOnlineButton
@onready var _leave_button: Button = %LeaveButton

## Shares the palette the spawner tints characters with, so a lobby swatch is
## the colour that player actually appears in.
const SpawnManagerScript := preload("res://scripts/levels/spawn_manager.gd")

var _local_ready := false
var _player_list: VBoxContainer
var _add_bot_button: Button
var _remove_bot_button: Button

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build_player_list_container()
	_build_bot_controls()
	_create_button.pressed.connect(NetworkSession.create_room)
	_join_button.pressed.connect(_on_join_pressed)
	_back_button.pressed.connect(hide)
	_copy_button.pressed.connect(_on_copy_pressed)
	_prev_level.pressed.connect(NetworkSession.cycle_host_level.bind(-1))
	_next_level.pressed.connect(NetworkSession.cycle_host_level.bind(1))
	_minus_goal.pressed.connect(NetworkSession.adjust_host_goal.bind(-1))
	_plus_goal.pressed.connect(NetworkSession.adjust_host_goal.bind(1))
	_prev_character.pressed.connect(_cycle_character.bind(-1))
	_next_character.pressed.connect(_cycle_character.bind(1))
	_ready_button.pressed.connect(_on_ready_pressed)
	_start_button.pressed.connect(NetworkSession.start_online_match)
	_leave_button.pressed.connect(_on_leave_pressed)
	_room_code_input.text_changed.connect(_normalize_code)
	NetworkSession.state_changed.connect(_on_session_state_changed)
	NetworkSession.lobby_changed.connect(_on_lobby_changed)
	NetworkSession.connection_error.connect(_show_error)
	_update_view()

func open() -> void:
	visible = true
	_update_view()
	if NetworkSession.has_active_session():
		_ready_button.grab_focus()
	else:
		_create_button.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("ui_cancel") or event.is_echo():
		return
	get_viewport().set_input_as_handled()
	if NetworkSession.has_active_session():
		_on_leave_pressed()
	else:
		hide()

func _on_join_pressed() -> void:
	NetworkSession.join_room(_room_code_input.text)

func _on_copy_pressed() -> void:
	if NetworkSession.room_code != "":
		DisplayServer.clipboard_set(NetworkSession.room_code)
		_status_label.text = "Room code copied. If the browser blocks the clipboard, select the code above."

func _normalize_code(value: String) -> void:
	var normalized := NetworkProtocol.normalize_room_code(value)
	if normalized.length() > NetworkProtocol.ROOM_CODE_LENGTH:
		normalized = normalized.left(NetworkProtocol.ROOM_CODE_LENGTH)
	if normalized != value:
		_room_code_input.text = normalized
		_room_code_input.caret_column = normalized.length()
	_join_button.disabled = not NetworkProtocol.is_valid_room_code(normalized)

func _cycle_character(direction: int) -> void:
	var characters := GameSettings.AVAILABLE_CHARACTERS
	var current := characters.find(str(_local_player().get("character_id", "tux")))
	NetworkSession.set_local_character(characters[(current + direction + characters.size()) % characters.size()])

func _local_player() -> Dictionary:
	for player in _players():
		if int((player as Dictionary).get("peer_id", 0)) == NetworkSession.local_peer_id:
			return player
	return {}

func _players() -> Array:
	var value: Variant = NetworkSession.lobby_snapshot().get("players", [])
	return value if value is Array else []

## The scene ships two fixed player labels, which cannot show a six-player
## roster. Swap them for a vertical list built from the roster at runtime.
func _build_player_list_container() -> void:
	var row := _host_label.get_parent() as Control
	if row == null:
		return
	_host_label.queue_free()
	_guest_label.queue_free()
	_player_list = VBoxContainer.new()
	_player_list.name = "PlayerList"
	_player_list.add_theme_constant_override("separation", 4)
	_player_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_player_list)

## Host-only controls for filling spare slots with CPUs, added next to the
## roster so the count and the buttons that change it sit together.
func _build_bot_controls() -> void:
	if _player_list == null:
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_add_bot_button = Button.new()
	_add_bot_button.text = "+ CPU"
	_add_bot_button.pressed.connect(NetworkSession.add_bot)
	_remove_bot_button = Button.new()
	_remove_bot_button.text = "− CPU"
	_remove_bot_button.pressed.connect(NetworkSession.remove_bot)
	row.add_child(_add_bot_button)
	row.add_child(_remove_bot_button)
	_player_list.get_parent().add_child(row)

func _rebuild_player_list() -> void:
	if _player_list == null:
		return
	for child in _player_list.get_children():
		child.queue_free()
	for player in _players():
		_player_list.add_child(_build_player_row(player as Dictionary))

func _build_player_row(player: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(18, 18)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var palette: Array = SpawnManagerScript.CPU_COLORS
	swatch.color = palette[int(player.get("color_slot", 0)) % palette.size()]
	row.add_child(swatch)

	var peer_id := int(player.get("peer_id", 0))
	var who := "CPU"
	if not bool(player.get("is_bot", false)):
		if peer_id == NetworkSession.local_peer_id:
			who = "You"
		elif peer_id == NetworkProtocol.HOST_PEER_ID:
			who = "Host"
		else:
			who = "Player %d" % peer_id
	var label := Label.new()
	label.custom_minimum_size = Vector2(300, 24)
	label.text = "%s — %s%s" % [
		who,
		GameSettings.get_character_display_name(str(player.get("character_id", "tux"))),
		"  READY" if bool(player.get("ready", false)) else "",
	]
	row.add_child(label)
	return row

func _on_ready_pressed() -> void:
	_local_ready = not _local_ready
	NetworkSession.set_ready(_local_ready)

func _on_leave_pressed() -> void:
	NetworkSession.leave_session(false)
	visible = false

func _on_session_state_changed(_state: int, _status: String) -> void:
	_update_view()
	if NetworkSession.state in [NetworkSession.SessionState.LOADING, NetworkSession.SessionState.COUNTDOWN, NetworkSession.SessionState.PLAYING]:
		visible = false

func _on_lobby_changed(_snapshot: Dictionary) -> void:
	_update_view()

func _show_error(message: String) -> void:
	visible = true
	_setup_view.visible = true
	_lobby_view.visible = false
	_status_label.text = message

func _update_view() -> void:
	var has_room := NetworkSession.has_active_session()
	_setup_view.visible = not has_room
	_lobby_view.visible = has_room
	_status_label.text = NetworkSession.status_text
	if not has_room:
		return
	var snapshot := NetworkSession.lobby_snapshot()
	_room_code_label.text = NetworkSession.room_code
	_connection_label.text = NetworkSession.status_text
	_rebuild_player_list()
	_level_label.text = str(snapshot.get("level_id", "level01")).capitalize()
	_goal_label.text = str(snapshot.get("goal", 10))
	var local_player := _local_player()
	_character_label.text = GameSettings.get_character_display_name(str(local_player.get("character_id", "tux")))
	_local_ready = bool(local_player.get("ready", false))
	_ready_button.text = "Ready ✓" if _local_ready else "Ready"
	var in_lobby := NetworkSession.state == NetworkSession.SessionState.LOBBY
	_ready_button.disabled = not in_lobby
	_prev_character.disabled = not in_lobby
	_next_character.disabled = not in_lobby
	var host_controls := NetworkSession.is_host() and in_lobby
	if _add_bot_button:
		var roster := _players()
		_add_bot_button.visible = NetworkSession.is_host()
		_remove_bot_button.visible = NetworkSession.is_host()
		_add_bot_button.disabled = not host_controls or roster.size() >= NetworkProtocol.MAX_PLAYERS
		_remove_bot_button.disabled = not host_controls or NetworkSession.bot_count() == 0
	_prev_level.disabled = not host_controls
	_next_level.disabled = not host_controls
	_minus_goal.disabled = not host_controls
	_plus_goal.disabled = not host_controls
	_start_button.visible = NetworkSession.is_host()
	_start_button.disabled = not NetworkSession.can_start_match()
