extends Node

## Central audio system: SFX pooling, music crossfade, bus volume control.
##
## Subscribes to EventBus for all gameplay cues so gameplay code stays
## audio-agnostic. Runs with PROCESS_MODE_ALWAYS (and pause-immune tweens)
## because the scene tree is paused during both the pause menu and game over.
## Missing audio files are warn-once no-ops so the game runs without assets.

const SFX_POOL_SIZE := 12
const CROSSFADE_TIME := 1.0
const STINGER_FADE_TIME := 0.3
const PAUSE_DUCK_DB := -12.0
const DUCK_TWEEN_TIME := 0.2
const LAND_MIN_IMPACT := 300.0
const SKID_VOLUME_DB := -10.0
const MUSIC_SILENT_DB := -60.0

const BUS_MASTER := 0
const BUS_MUSIC_NAME := &"Music"
const BUS_SFX_NAME := &"SFX"

# Per-event playback config. cooldown_ms stops same-frame stacking (up to 8
# characters act at once), max_voices caps overlap, pitch_var adds variety.
const SFX_EVENTS := {
	&"jump": {"cooldown_ms": 70, "max_voices": 3, "volume_db": -6.0, "pitch_var": 0.06},
	&"jump_turbo": {"cooldown_ms": 70, "max_voices": 2, "volume_db": -6.0, "pitch_var": 0.06},
	&"land": {"cooldown_ms": 90, "max_voices": 2, "volume_db": -12.0, "pitch_var": 0.05},
	&"stomp": {"cooldown_ms": 60, "max_voices": 3, "volume_db": 0.0, "pitch_var": 0.04},
	&"die": {"cooldown_ms": 60, "max_voices": 3, "volume_db": -4.0, "pitch_var": 0.03},
	&"respawn": {"cooldown_ms": 100, "max_voices": 2, "volume_db": -6.0, "pitch_var": 0.0},
	&"score": {"cooldown_ms": 100, "max_voices": 2, "volume_db": -3.0, "pitch_var": 0.0},
	&"match_start": {"cooldown_ms": 500, "max_voices": 1, "volume_db": -2.0, "pitch_var": 0.0},
	&"pause": {"cooldown_ms": 100, "max_voices": 1, "volume_db": -6.0, "pitch_var": 0.0},
	&"unpause": {"cooldown_ms": 100, "max_voices": 1, "volume_db": -6.0, "pitch_var": 0.0},
	&"ui_select": {"cooldown_ms": 40, "max_voices": 2, "volume_db": -6.0, "pitch_var": 0.0},
	&"ui_open": {"cooldown_ms": 80, "max_voices": 1, "volume_db": -6.0, "pitch_var": 0.0},
	&"coin": {"cooldown_ms": 60, "max_voices": 2, "volume_db": -4.0, "pitch_var": 0.0},
	&"tick": {"cooldown_ms": 400, "max_voices": 1, "volume_db": -6.0, "pitch_var": 0.0},
	&"horn": {"cooldown_ms": 500, "max_voices": 1, "volume_db": -2.0, "pitch_var": 0.0},
	&"whistle": {"cooldown_ms": 300, "max_voices": 1, "volume_db": -4.0, "pitch_var": 0.0},
	&"cluck": {"cooldown_ms": 200, "max_voices": 2, "volume_db": -4.0, "pitch_var": 0.05},
}

# Track name -> should loop. Level tracks are keyed by level scene basename.
const MUSIC_TRACKS := {
	&"menu": true,
	&"level01": true,
	&"level02": true,
	&"level03": true,
	&"victory": false,
	&"defeat": false,
}

var _sfx_streams: Dictionary = {}  # StringName -> AudioStream
var _music_streams: Dictionary = {}
var _sfx_pool: Array[AudioStreamPlayer] = []
var _last_play_ms: Dictionary = {}  # StringName -> int

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _active_music: AudioStreamPlayer
var _music_tween: Tween
var _duck_tween: Tween
var _current_track: StringName = &""
var _duck_db: float = 0.0

var _skid_player: AudioStreamPlayer
var _skidding_ids: Dictionary = {}  # instance_id -> true

# Browsers block audio until a user gesture; park the first track until then.
var _unlocked: bool = false
var _pending_track: StringName = &""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_unlocked = not OS.has_feature("web")
	_load_streams()
	_build_players()
	_apply_bus_volumes()
	set_muted(GameSettings.audio_muted)

	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.level_loaded.connect(_on_level_loaded)
	EventBus.match_started.connect(func() -> void: play_sfx(&"match_start"))
	EventBus.match_ended.connect(_on_match_ended)
	EventBus.game_paused.connect(_on_game_paused)
	EventBus.game_resumed.connect(_on_game_resumed)
	EventBus.character_jumped.connect(_on_character_jumped)
	EventBus.character_landed.connect(_on_character_landed)
	EventBus.character_stomped.connect(func(_a: CharacterController, _v: CharacterController) -> void: play_sfx(&"stomp"))
	EventBus.character_killed.connect(_on_character_killed)
	EventBus.character_died.connect(_on_character_died)
	EventBus.character_respawned.connect(func(_c: CharacterController) -> void: play_sfx(&"respawn"))
	EventBus.skid_started.connect(_on_skid_started)
	EventBus.skid_ended.connect(_on_skid_ended)
	EventBus.coin_collected.connect(func(_c: CharacterController) -> void: play_sfx(&"coin"))
	EventBus.match_timer_warning.connect(func(_s: int) -> void: play_sfx(&"tick"))
	EventBus.time_expired.connect(func() -> void: play_sfx(&"horn"))
	EventBus.hill_moved.connect(func() -> void: play_sfx(&"whistle"))
	EventBus.chicken_changed.connect(func(_c: CharacterController) -> void: play_sfx(&"cluck"))
	EventBus.character_eliminated.connect(func(_c: CharacterController) -> void: play_sfx(&"horn"))
	EventBus.scene_changing.connect(_on_scene_changing)
	get_tree().node_added.connect(_on_node_added)
	if InputManager.has_signal("mute_toggled"):
		InputManager.mute_toggled.connect(toggle_mute)

	set_process_input(not _unlocked)
	play_music(&"menu")  # boot state is MENU; parked until unlock on web

func _input(event: InputEvent) -> void:
	# First user gesture unlocks web audio. Disabled entirely on desktop.
	var is_gesture := (event is InputEventKey or event is InputEventMouseButton \
		or event is InputEventScreenTouch or event is InputEventJoypadButton) \
		and event.is_pressed()
	if is_gesture:
		_unlocked = true
		set_process_input(false)
		if _pending_track != &"":
			var track := _pending_track
			_pending_track = &""
			play_music(track)

## Public API

func play_sfx(event: StringName) -> void:
	if not _unlocked or not _sfx_streams.has(event):
		return
	var cfg: Dictionary = SFX_EVENTS[event]
	var now := Time.get_ticks_msec()
	if now - int(_last_play_ms.get(event, -100000)) < int(cfg["cooldown_ms"]):
		return
	var voices := 0
	var free_player: AudioStreamPlayer = null
	for player in _sfx_pool:
		if player.playing:
			if player.get_meta("event", &"") == event:
				voices += 1
		elif free_player == null:
			free_player = player
	# Drop when capped or exhausted -- never steal a voice (stealing pops).
	if voices >= int(cfg["max_voices"]) or free_player == null:
		return
	_last_play_ms[event] = now
	free_player.stream = _sfx_streams[event]
	free_player.volume_db = float(cfg["volume_db"])
	var pitch_var := float(cfg["pitch_var"])
	free_player.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	free_player.set_meta("event", event)
	free_player.play()

func play_music(track: StringName, crossfade: float = CROSSFADE_TIME) -> void:
	if track == _current_track:
		return
	if not _unlocked:
		_pending_track = track
		return
	if not _music_streams.has(track):
		push_warning("AudioManager: no music track '%s'" % track)
		stop_music()
		return
	_current_track = track
	var incoming := _music_b if _active_music == _music_a else _music_a
	var outgoing := _active_music
	_active_music = incoming
	incoming.stream = _music_streams[track]
	incoming.volume_db = MUSIC_SILENT_DB
	incoming.play()
	if _music_tween and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_music_tween.set_parallel(true)
	_music_tween.tween_property(incoming, "volume_db", _duck_db, crossfade)
	if outgoing and outgoing.playing:
		_music_tween.tween_property(outgoing, "volume_db", MUSIC_SILENT_DB, crossfade)
		_music_tween.chain().tween_callback(outgoing.stop)

func stop_music(fade_out: float = 0.5) -> void:
	_current_track = &""
	_pending_track = &""
	if not _active_music or not _active_music.playing:
		return
	if _music_tween and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_music_tween.tween_property(_active_music, "volume_db", MUSIC_SILENT_DB, fade_out)
	_music_tween.tween_callback(_active_music.stop)

func set_master_volume(value: float) -> void:
	GameSettings.set_master_volume(value)
	_apply_bus_volumes()

func set_music_volume(value: float) -> void:
	GameSettings.set_music_volume(value)
	_apply_bus_volumes()

func set_sfx_volume(value: float) -> void:
	GameSettings.set_sfx_volume(value)
	_apply_bus_volumes()

func set_muted(muted: bool) -> void:
	GameSettings.set_audio_muted(muted)
	AudioServer.set_bus_mute(BUS_MASTER, muted)

func toggle_mute() -> void:
	set_muted(not GameSettings.audio_muted)

## Event handlers

func _on_game_state_changed(_from_state: String, to_state: String) -> void:
	if to_state == "MENU":
		play_music(&"menu")

func _on_level_loaded(level_path: String) -> void:
	play_music(StringName(level_path.get_file().get_basename()))

func _on_match_ended(winner: CharacterController) -> void:
	var won := winner != null and winner.is_locally_controlled()
	play_music(&"victory" if won else &"defeat", STINGER_FADE_TIME)

func _on_game_paused() -> void:
	play_sfx(&"pause")
	_duck_music(PAUSE_DUCK_DB)

func _on_game_resumed() -> void:
	play_sfx(&"unpause")
	_duck_music(0.0)

func _on_character_jumped(_character: CharacterController, turbo: bool) -> void:
	play_sfx(&"jump_turbo" if turbo else &"jump")

func _on_character_landed(_character: CharacterController, impact_speed: float) -> void:
	if impact_speed > LAND_MIN_IMPACT:
		play_sfx(&"land")

func _on_character_killed(killer: CharacterController, _victim: CharacterController) -> void:
	# Reward only the player's own kills; CPU kills are covered by stomp/die.
	if killer and killer.is_locally_controlled():
		play_sfx(&"score")

func _on_character_died(character: CharacterController) -> void:
	play_sfx(&"die")
	# A character that dies mid-skid never emits skid_ended (its update loop
	# stops), so clean up the loop refcount here too.
	_remove_skidder(character.get_instance_id())

func _on_skid_started(character: CharacterController) -> void:
	_skidding_ids[character.get_instance_id()] = true
	if _unlocked and _skid_player.stream and not _skid_player.playing:
		_skid_player.play()

func _on_skid_ended(character: CharacterController) -> void:
	_remove_skidder(character.get_instance_id())

func _on_scene_changing(_from_path: String, _to_path: String) -> void:
	_skidding_ids.clear()
	_skid_player.stop()

func _on_node_added(node: Node) -> void:
	# Global UI click sound: every button everywhere, current and future.
	if node is BaseButton and not node.pressed.is_connected(_on_ui_button_pressed):
		node.pressed.connect(_on_ui_button_pressed)

func _on_ui_button_pressed() -> void:
	play_sfx(&"ui_select")

## Internals

func _remove_skidder(id: int) -> void:
	_skidding_ids.erase(id)
	if _skidding_ids.is_empty():
		_skid_player.stop()

func _duck_music(target_db: float) -> void:
	_duck_db = target_db
	if _duck_tween and _duck_tween.is_valid():
		_duck_tween.kill()
	if not _active_music:
		return
	_duck_tween = create_tween()
	_duck_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_duck_tween.tween_property(_active_music, "volume_db", target_db, DUCK_TWEEN_TIME)

func _load_streams() -> void:
	for event: StringName in SFX_EVENTS:
		var stream := _load_stream(ResourcePaths.get_sfx_path(event), false)
		if stream:
			_sfx_streams[event] = stream
	for track: StringName in MUSIC_TRACKS:
		var stream := _load_stream(ResourcePaths.get_music_path(track), MUSIC_TRACKS[track])
		if stream:
			_music_streams[track] = stream

func _load_stream(path: String, loop: bool) -> AudioStream:
	if not ResourceLoader.exists(path):
		push_warning("AudioManager: missing audio file %s" % path)
		return null
	var stream: AudioStream = load(path)
	if stream is AudioStreamOggVorbis:
		stream.loop = loop
	elif stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	return stream

func _build_players() -> void:
	var sfx_bus := _bus_or_master(BUS_SFX_NAME)
	var music_bus := _bus_or_master(BUS_MUSIC_NAME)
	for i in SFX_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = sfx_bus
		add_child(player)
		_sfx_pool.append(player)
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	for player in [_music_a, _music_b]:
		player.bus = music_bus
		add_child(player)
	_active_music = _music_a
	_skid_player = AudioStreamPlayer.new()
	_skid_player.bus = sfx_bus
	_skid_player.volume_db = SKID_VOLUME_DB
	var skid_stream := _load_stream(ResourcePaths.get_sfx_path("skid"), true)
	if skid_stream:
		_skid_player.stream = skid_stream
	add_child(_skid_player)

func _bus_or_master(bus_name: StringName) -> StringName:
	if AudioServer.get_bus_index(bus_name) == -1:
		push_warning("AudioManager: bus '%s' missing; routing to Master" % bus_name)
		return &"Master"
	return bus_name

func _apply_bus_volumes() -> void:
	_set_bus_volume(BUS_MASTER, GameSettings.master_volume)
	var music_idx := AudioServer.get_bus_index(BUS_MUSIC_NAME)
	if music_idx != -1:
		_set_bus_volume(music_idx, GameSettings.music_volume)
	var sfx_idx := AudioServer.get_bus_index(BUS_SFX_NAME)
	if sfx_idx != -1:
		_set_bus_volume(sfx_idx, GameSettings.sfx_volume)

func _set_bus_volume(bus_idx: int, linear: float) -> void:
	AudioServer.set_bus_volume_db(bus_idx, linear_to_db(maxf(linear, 0.0001)))
