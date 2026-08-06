extends Node

## Manages UI lifecycle across scenes.
##
## Ensures HUD (score counter) and dev menu exist in gameplay scenes,
## responds to game state events to show/hide pause menu and game over screen.

const SCORE_COUNTER_SCENE := preload("res://scenes/ui/score_counter.tscn")
const MODE_HUD_SCENE := preload("res://scenes/ui/mode_hud.tscn")
const DEV_MENU_SCENE := preload("res://scenes/ui/dev_menu.tscn")
const PAUSE_MENU_SCENE := preload("res://scenes/ui/pause_menu.tscn")
const GAME_OVER_SCENE := preload("res://scenes/ui/game_over_scoreboard.tscn")

var _last_scene: Node = null
var _pause_menu: Control = null
var _game_over_screen: Control = null
var _countdown_label: Label = null
var _network_dialog: AcceptDialog = null

func _ready() -> void:
	# Ensure we run even when paused and across scenes
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Listen to game state events
	EventBus.game_paused.connect(_on_game_paused)
	EventBus.game_resumed.connect(_on_game_resumed)
	EventBus.match_ended.connect(_on_match_ended)
	EventBus.online_countdown_changed.connect(_on_online_countdown_changed)
	NetworkSession.friend_disconnected.connect(_on_friend_disconnected)
	NetworkSession.state_changed.connect(_on_network_state_changed)


func _process(_delta: float) -> void:
	var cs := get_tree().current_scene
	if cs != _last_scene:
		_last_scene = cs
		_ensure_hud(cs)
		_ensure_dev_menu(cs)


func _on_game_paused() -> void:
	if not is_instance_valid(_pause_menu):
		_pause_menu = PAUSE_MENU_SCENE.instantiate()
		var root := get_tree().current_scene
		var hud := root.get_node_or_null("HUD") if root else null
		if hud:
			hud.add_child(_pause_menu)
		else:
			root.add_child(_pause_menu)
	
	_pause_menu.visible = true

func _on_game_resumed() -> void:
	if is_instance_valid(_pause_menu):
		_pause_menu.visible = false

func _on_match_ended(_winner: CharacterController) -> void:
	# Clean up old game over screen if it exists
	if is_instance_valid(_game_over_screen):
		_game_over_screen.queue_free()
	
	_game_over_screen = GAME_OVER_SCENE.instantiate()
	_game_over_screen.set_current_level(GameStateManager.current_level_path)
	get_tree().root.add_child(_game_over_screen)

func _on_online_countdown_changed(value: int) -> void:
	if not is_instance_valid(_countdown_label):
		_countdown_label = Label.new()
		_countdown_label.name = "OnlineCountdown"
		_countdown_label.process_mode = Node.PROCESS_MODE_ALWAYS
		_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_countdown_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_countdown_label.add_theme_font_size_override("font_size", 96)
		get_tree().current_scene.add_child(_countdown_label)
	_countdown_label.visible = value > 0
	_countdown_label.text = str(value) if value > 0 else ""

func _on_friend_disconnected(message: String) -> void:
	if is_instance_valid(_network_dialog):
		_network_dialog.queue_free()
	_network_dialog = AcceptDialog.new()
	_network_dialog.title = "Connection Lost"
	_network_dialog.dialog_text = message
	_network_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_network_dialog)
	_network_dialog.popup_centered(Vector2i(520, 180))

func _on_network_state_changed(state: int, _status: String) -> void:
	if state in [NetworkSession.SessionState.LOADING, NetworkSession.SessionState.LOBBY] \
			and is_instance_valid(_game_over_screen):
		_game_over_screen.queue_free()
		_game_over_screen = null

func _ensure_hud(root: Node) -> void:
	if root == null:
		return
	var hud := root.get_node_or_null("HUD")
	if hud == null:
		hud = CanvasLayer.new()
		hud.name = "HUD"
		root.add_child(hud)
	# Ensure ScoreCounter exists
	if hud.get_node_or_null("ScoreCounter") == null:
		var sc := SCORE_COUNTER_SCENE.instantiate()
		hud.add_child(sc)
	# Ensure ModeHUD (status/timer/toasts) exists
	if hud.get_node_or_null("ModeHUD") == null:
		var mh := MODE_HUD_SCENE.instantiate()
		mh.name = "ModeHUD"
		hud.add_child(mh)


func _ensure_dev_menu(root: Node) -> void:
	if root == null:
		return
	# Only in debug builds and only in level scenes (not menus)
	if not OS.is_debug_build():
		# Clean up if present from editor
		var existing_release := root.get_node_or_null("DevMenu")
		if existing_release:
			existing_release.queue_free()
		return
	
	# Don't show dev menu in menu state
	if GameStateManager.is_in_menu():
		var existing := root.get_node_or_null("DevMenu")
		if existing:
			existing.queue_free()
		return
	
	if root.get_node_or_null("DevMenu") != null:
		return
	var dev := DEV_MENU_SCENE.instantiate()
	dev.name = "DevMenu"
	root.add_child(dev)
