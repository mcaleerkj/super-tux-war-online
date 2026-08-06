extends Node

# Simple game settings singleton
# Stores settings that persist between menu and gameplay

var cpu_count: int = 1  # Number of CPU opponents (1-7)
var player_character: String = "tux"  # Player's selected character
var cpu_character: String = "beasty"  # CPU's selected character
var selected_level_index: int = 0  # Currently selected level in main menu

# Game mode selection (session-only, like the rest of the match settings)
var selected_mode: StringName = &"frag"
var mode_goals: Dictionary = {}  # StringName -> int; remembers each mode's goal

# Audio settings (persisted to user://settings.cfg; applied by AudioManager)
var master_volume: float = 1.0
var music_volume: float = 0.8
var sfx_volume: float = 1.0
var audio_muted: bool = false

const MIN_CPU_COUNT: int = 1
const MAX_CPU_COUNT: int = 7

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION_AUDIO := "audio"

# Available characters
const AVAILABLE_CHARACTERS: Array[String] = ["tux", "beasty", "gopher"]

func _ready() -> void:
	load_audio_settings()

func set_cpu_count(count: int) -> void:
	cpu_count = clampi(count, MIN_CPU_COUNT, MAX_CPU_COUNT)

func get_cpu_count() -> int:
	return cpu_count

func increase_cpu_count() -> void:
	set_cpu_count(cpu_count + 1)

func decrease_cpu_count() -> void:
	set_cpu_count(cpu_count - 1)

func set_player_character(character_name: String) -> void:
	if character_name in AVAILABLE_CHARACTERS:
		player_character = character_name

func get_player_character() -> String:
	return player_character

func set_cpu_character(character_name: String) -> void:
	if character_name in AVAILABLE_CHARACTERS:
		cpu_character = character_name

func get_cpu_character() -> String:
	return cpu_character

func get_character_display_name(character_name: String) -> String:
	match character_name:
		"tux":
			return "Tux"
		"beasty":
			return "Beasty"
		"gopher":
			return "Gopher"
		_:
			return character_name.capitalize()

func set_selected_mode(id: StringName) -> void:
	if ModeRegistry.is_valid(id):
		selected_mode = id

func get_selected_mode() -> StringName:
	return selected_mode

func get_goal_for_mode(id: StringName) -> int:
	var proto := ModeRegistry.get_prototype(id)
	return int(mode_goals.get(id, proto.goal_default()))

func set_goal_for_mode(id: StringName, value: int) -> void:
	var proto := ModeRegistry.get_prototype(id)
	mode_goals[id] = clampi(value, proto.goal_min(), proto.goal_max())

func adjust_goal_for_mode(id: StringName, delta: int) -> void:
	set_goal_for_mode(id, get_goal_for_mode(id) + delta)

func set_selected_level_index(index: int) -> void:
	selected_level_index = max(0, index)

func get_selected_level_index() -> int:
	return selected_level_index

# Audio setters are dumb storage: clamp and assign only. AudioManager owns
# all AudioServer calls; the options popup decides when to save.

func set_master_volume(value: float) -> void:
	master_volume = clampf(value, 0.0, 1.0)

func set_music_volume(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)

func set_sfx_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)

func set_audio_muted(muted: bool) -> void:
	audio_muted = muted

func save_audio_settings() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)  # keep other sections if the file exists
	config.set_value(SETTINGS_SECTION_AUDIO, "master_volume", master_volume)
	config.set_value(SETTINGS_SECTION_AUDIO, "music_volume", music_volume)
	config.set_value(SETTINGS_SECTION_AUDIO, "sfx_volume", sfx_volume)
	config.set_value(SETTINGS_SECTION_AUDIO, "muted", audio_muted)
	var err := config.save(SETTINGS_PATH)
	if err != OK:
		push_warning("GameSettings: failed to save settings (%s)" % error_string(err))

func load_audio_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return  # first launch: keep defaults
	set_master_volume(config.get_value(SETTINGS_SECTION_AUDIO, "master_volume", master_volume))
	set_music_volume(config.get_value(SETTINGS_SECTION_AUDIO, "music_volume", music_volume))
	set_sfx_volume(config.get_value(SETTINGS_SECTION_AUDIO, "sfx_volume", sfx_volume))
	set_audio_muted(config.get_value(SETTINGS_SECTION_AUDIO, "muted", audio_muted))

