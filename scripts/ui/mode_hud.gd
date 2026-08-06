extends Control

## Top-center mode status display (match clock, role banners) plus transient
## toasts fed by EventBus.ui_notification. Injected into each level's HUD by
## UIManager next to the score counter. Pausable, so it freezes with the tree.

const TOAST_HOLD := 1.5
const TOAST_FADE := 0.6

var _mode: GameMode = null

@onready var _status: Label = %StatusLabel
@onready var _toast: Label = %ToastLabel

func _ready() -> void:
	add_to_group("mode_hud")
	EventBus.ui_notification.connect(_on_notification)

func _process(_delta: float) -> void:
	if not is_instance_valid(_mode):
		_mode = get_tree().get_first_node_in_group("game_mode") as GameMode
	var text := _mode.get_status_text() if _mode else ""
	_status.visible = text != ""
	_status.text = text

func _on_notification(message: String, _type: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(TOAST_HOLD)
	tween.tween_property(_toast, "modulate:a", 0.0, TOAST_FADE)
