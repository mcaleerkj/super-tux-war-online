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

var _local_ready := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
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
	var snapshot := NetworkSession.lobby_snapshot()
	var key := "host_character" if NetworkSession.is_host() else "guest_character"
	var current := characters.find(str(snapshot.get(key, "tux")))
	NetworkSession.set_local_character(characters[(current + direction + characters.size()) % characters.size()])

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
	_host_label.text = "Host: %s%s" % [
		GameSettings.get_character_display_name(str(snapshot.get("host_character", "tux"))),
		"  READY" if bool(snapshot.get("host_ready", false)) else "",
	]
	_guest_label.text = "Friend: %s%s" % [
		GameSettings.get_character_display_name(str(snapshot.get("guest_character", "beasty"))),
		"  READY" if bool(snapshot.get("guest_ready", false)) else "",
	]
	_level_label.text = str(snapshot.get("level_id", "level01")).capitalize()
	_goal_label.text = str(snapshot.get("goal", 10))
	var local_key := "host_character" if NetworkSession.is_host() else "guest_character"
	_character_label.text = GameSettings.get_character_display_name(str(snapshot.get(local_key, "tux")))
	_local_ready = bool(snapshot.get("host_ready" if NetworkSession.is_host() else "guest_ready", false))
	_ready_button.text = "Ready ✓" if _local_ready else "Ready"
	var in_lobby := NetworkSession.state == NetworkSession.SessionState.LOBBY
	_ready_button.disabled = not in_lobby
	_prev_character.disabled = not in_lobby
	_next_character.disabled = not in_lobby
	var host_controls := NetworkSession.is_host() and in_lobby
	_prev_level.disabled = not host_controls
	_next_level.disabled = not host_controls
	_minus_goal.disabled = not host_controls
	_plus_goal.disabled = not host_controls
	_start_button.visible = NetworkSession.is_host()
	_start_button.disabled = not NetworkSession.can_start_match()
