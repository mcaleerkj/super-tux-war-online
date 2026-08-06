extends Control

const OPTIONS_POPUP_SCENE := preload("res://scenes/ui/options_popup.tscn")

@onready var _resume_button: Button = $CenterContainer/PanelContainer/VBox/Buttons/ResumeButton
@onready var _options_button: Button = $CenterContainer/PanelContainer/VBox/Buttons/OptionsButton
@onready var _new_game_button: Button = $CenterContainer/PanelContainer/VBox/Buttons/NewGameButton

var _options_popup: AcceptDialog = null

func _ready() -> void:
	# Ensure the pause menu covers the screen and still processes while paused
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	if NetworkSession.is_online_match():
		$CenterContainer/PanelContainer/VBox/Title.text = "Online Menu"

	# Child of the pause menu so it inherits PROCESS_MODE_ALWAYS and works
	# while the tree is paused.
	_options_popup = OPTIONS_POPUP_SCENE.instantiate()
	add_child(_options_popup)

	_resume_button.pressed.connect(_on_resume_pressed)
	_options_button.pressed.connect(_on_options_pressed)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	visibility_changed.connect(_on_visibility_changed)


func _unhandled_input(event: InputEvent) -> void:
	# Allow ESC to resume while the pause menu is visible
	if not visible:
		return
	if event.is_pressed() and not event.is_echo():
		# Only handle ui_cancel if it's NOT the same key as pause
		# (InputManager handles 'pause' globally)
		if event.is_action_pressed("ui_cancel") and not event.is_action_pressed("pause"):
			_on_resume_pressed()


func _on_resume_pressed() -> void:
	GameStateManager.resume_game()


func _on_options_pressed() -> void:
	_options_popup.open()


func _on_new_game_pressed() -> void:
	GameStateManager.return_to_menu()


func _on_visibility_changed() -> void:
	if visible:
		_resume_button.grab_focus()
