extends AcceptDialog

## Volume options popup, shared by the start menu and pause menu.
##
## Sliders apply live through AudioManager; settings are saved once on close
## (not per tick -- user:// is IndexedDB-backed on web).

@onready var _master_slider: HSlider = %MasterSlider
@onready var _music_slider: HSlider = %MusicSlider
@onready var _sfx_slider: HSlider = %SfxSlider
@onready var _mute_check: CheckButton = %MuteCheck

func _ready() -> void:
	_master_slider.value_changed.connect(AudioManager.set_master_volume)
	_music_slider.value_changed.connect(AudioManager.set_music_volume)
	_sfx_slider.value_changed.connect(AudioManager.set_sfx_volume)
	# Blip on release so the user hears the SFX level they just set.
	_sfx_slider.drag_ended.connect(func(_changed: bool) -> void: AudioManager.play_sfx(&"ui_select"))
	_mute_check.toggled.connect(AudioManager.set_muted)
	visibility_changed.connect(_on_visibility_changed)

func open() -> void:
	_refresh_from_settings()
	AudioManager.play_sfx(&"ui_open")
	popup_centered()

func _refresh_from_settings() -> void:
	_master_slider.set_value_no_signal(GameSettings.master_volume)
	_music_slider.set_value_no_signal(GameSettings.music_volume)
	_sfx_slider.set_value_no_signal(GameSettings.sfx_volume)
	_mute_check.set_pressed_no_signal(GameSettings.audio_muted)

func _on_visibility_changed() -> void:
	if not visible:
		GameSettings.save_audio_settings()
