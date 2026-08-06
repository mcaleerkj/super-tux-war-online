extends CharacterBody2D
class_name CharacterController

## Orchestrates character components for physics, visuals, and lifecycle.
##
## Uses component-based architecture with CharacterPhysics, CharacterVisuals,
## and CharacterLifecycle for better separation of concerns and maintainability.

# Components
var physics: CharacterPhysics
var visuals: CharacterVisuals
var lifecycle: CharacterLifecycle

enum ControlSource {
	AUTO,
	LOCAL_HUMAN,
	CPU,
	REMOTE_INPUT,
	REPLICA,
}

# Public properties
@export var is_player: bool = false
@export var character_color: Color = Color.WHITE
@export var character_asset_name: String = ""
@export var foot_offset: float = 14.0
@export_enum("Auto", "Local Human", "CPU", "Remote Input", "Replica") var control_source: int = ControlSource.AUTO

# Stable identity for multiplayer. Offline humans use participant 1 and CPUs
# use 0; online humans use their WebRTC peer IDs (host 1, guest 2).
var participant_id: int = 0
var is_human: bool = false
var participant_color_slot: int = 0

var _buffered_input: Dictionary = _neutral_input()
var _replica_snapshots: Array[Dictionary] = []
var _visual_correction: Vector2 = Vector2.ZERO
const REPLICA_DELAY_TICKS := 6
const MAX_REPLICA_SNAPSHOTS := 12
const SMOOTH_CORRECTION_LIMIT := 48.0
const CORRECTION_DECAY := 14.0

# Exposed for backwards compatibility
var is_despawned: bool = false:
	get: return lifecycle.is_despawned if lifecycle else false

var is_eliminated: bool = false:
	get: return lifecycle.is_eliminated if lifecycle else false

## Permanently removes the character from play (no respawn). Used by
## elimination-based game modes.
func eliminate() -> void:
	lifecycle.eliminate()

func _ready():
	# Initialize components
	physics = CharacterPhysics.new(self)
	visuals = CharacterVisuals.new(self)
	lifecycle = CharacterLifecycle.new(self)
	if control_source == ControlSource.AUTO:
		control_source = ControlSource.LOCAL_HUMAN if is_player else ControlSource.CPU
	if participant_id == 0 and control_source == ControlSource.LOCAL_HUMAN:
		participant_id = 1
	is_human = control_source in [ControlSource.LOCAL_HUMAN, ControlSource.REMOTE_INPUT, ControlSource.REPLICA]
	is_player = control_source == ControlSource.LOCAL_HUMAN
	lifecycle.set_authoritative(not _is_online_guest())
	if _is_online_guest():
		# Prediction never resolves human-to-human contact locally. Disable it
		# before the first playable frame, including on the interpolated replica.
		set_collision_layer_value(2, false)
		set_collision_mask_value(2, false)
	
	lifecycle.initialize()
	visuals.initialize()
	
	# Setup groups
	add_to_group("characters")
	if is_locally_controlled():
		add_to_group("players")
	if is_human:
		add_to_group("human_players")
	
	# Register with GameStateManager
	GameStateManager.register_character(self)
	
	# Rendering
	z_index = 10
	
	# Apply character color
	var color_rect := get_node_or_null("ColorRect")
	if color_rect:
		color_rect.color = character_color
	
	# Set initial facing
	visuals.face_towards_screen_center()

## Loads and applies cached sprite frames for the specified character.
func load_character_animations(character_name: String) -> void:
	character_asset_name = character_name
	visuals.load_animations(character_name)

func _physics_process(delta: float) -> void:
	if _is_online_match() and not GameStateManager.is_playing():
		return
	if control_source == ControlSource.REPLICA:
		_update_replica(delta)
		return

	# Update lifecycle (respawn, spawn protection)
	if not lifecycle.update_lifecycle(delta):
		_update_visual_correction(delta)
		return  # Don't process physics while despawned
	if _is_online_guest():
		# Guests predict only static-world collision. The host alone resolves
		# stomps and character-to-character contact.
		set_collision_layer_value(2, false)
		set_collision_mask_value(2, false)
	
	# Update spawn animation
	visuals.update_spawn_animation(delta)
	
	# All control sources feed the same physics input contract.
	var input_frame := _capture_input_frame()
	if is_locally_controlled() and _is_online_match():
		input_frame = NetworkSession.prepare_local_input(input_frame)
	var previous_velocity_y := physics.update_physics(delta, input_frame)
	if is_locally_controlled() and _is_online_match():
		NetworkSession.after_local_simulation(self, input_frame)
	_clear_transient_input()
	
	# Update animations
	visuals.update_animation(
		is_on_floor(),
		velocity,
		physics.get_current_input_direction(),
		physics.get_effective_max_speed(),
		physics.get_previous_horizontal_velocity()
	)
	
	# Check for character collisions (stomps and deaths)
	if not _is_online_match() or NetworkSession.is_host():
		_check_character_collisions(previous_velocity_y)
	_update_visual_correction(delta)

## Sets AI input for next physics frame.
func set_ai_inputs(move_direction: float, jump_pressed: bool, jump_released: bool, drop_pressed: bool) -> void:
	_buffered_input = {
		"move_x": clampf(move_direction, -1.0, 1.0),
		"run": false,
		"down": drop_pressed,
		"jump_pressed": jump_pressed,
		"jump_released": jump_released,
	}

func set_network_input(input_frame: Dictionary) -> void:
	if control_source != ControlSource.REMOTE_INPUT:
		return
	var next := _sanitized_input(input_frame)
	# Multiple packets can arrive before the next host physics tick. Preserve
	# one-shot edges until physics consumes them instead of letting a newer
	# continuous-state packet erase a jump.
	next["jump_pressed"] = bool(next.get("jump_pressed", false)) or bool(_buffered_input.get("jump_pressed", false))
	next["jump_released"] = bool(next.get("jump_released", false)) or bool(_buffered_input.get("jump_released", false))
	_buffered_input = next

func configure_participant(peer_id: int, source: int, asset_name: String, color_slot: int) -> void:
	participant_id = peer_id
	control_source = source
	is_human = source != ControlSource.CPU
	is_player = source == ControlSource.LOCAL_HUMAN
	participant_color_slot = color_slot
	character_asset_name = asset_name
	name = "Player_%d" % peer_id

func is_locally_controlled() -> bool:
	return control_source == ControlSource.LOCAL_HUMAN

func is_cpu_controlled() -> bool:
	return control_source == ControlSource.CPU

func participant_label() -> String:
	if not is_human:
		return "CPU"
	return "Player %d" % participant_id

func capture_network_state(server_tick: int, acknowledged_input: int) -> Dictionary:
	return {
		"tick": server_tick,
		"peer_id": participant_id,
		"ack": acknowledged_input,
		"position": global_position,
		"velocity": velocity,
		"physics": physics.capture_prediction_state(),
		"despawned": is_despawned,
		"eliminated": is_eliminated,
		"protection": lifecycle.spawn_protection_timer,
		"visible": visible,
		"on_floor": is_on_floor(),
		"facing_left": _is_facing_left(),
	}

func push_replica_snapshot(state: Dictionary) -> void:
	if control_source != ControlSource.REPLICA:
		return
	_replica_snapshots.append(state.duplicate(true))
	if _replica_snapshots.size() > MAX_REPLICA_SNAPSHOTS:
		_replica_snapshots.pop_front()
	_apply_snapshot_lifecycle(state)

func reconcile_authoritative_state(state: Dictionary, pending_inputs: Array[Dictionary]) -> void:
	if control_source != ControlSource.LOCAL_HUMAN or not _is_online_guest():
		return
	_apply_snapshot_lifecycle(state)
	if bool(state.get("despawned", false)):
		global_position = state.get("position", global_position)
		velocity = state.get("velocity", Vector2.ZERO)
		return

	var previous_display_position := global_position + _visual_correction
	global_position = state.get("position", global_position)
	velocity = state.get("velocity", velocity)
	physics.restore_prediction_state(state.get("physics", {}))
	for frame in pending_inputs:
		physics.update_physics(1.0 / 60.0, frame, false)

	var correction := _wrap_aware_delta(global_position, previous_display_position)
	if correction.length() <= SMOOTH_CORRECTION_LIMIT:
		_visual_correction = correction
	else:
		_visual_correction = Vector2.ZERO

func apply_remote_death(killer: CharacterController) -> void:
	# An unreliable snapshot can arrive before the reliable death event. Replay
	# the transition once here so effects/audio are not lost in that ordering.
	if lifecycle.is_despawned:
		lifecycle.is_despawned = false
	lifecycle.apply_remote_despawn(killer)

func apply_remote_respawn(position: Vector2) -> void:
	lifecycle.apply_remote_respawn(position)
	visuals.start_spawn_animation()
	visuals.face_towards_screen_center()
	_visual_correction = Vector2.ZERO

func _check_character_collisions(previous_velocity_y: float) -> void:
	# Check all character collisions for stomps and deaths
	for i in range(get_slide_collision_count()):
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		
		# Only process character-to-character collisions
		var other_character := collider as CharacterController
		if other_character and other_character != self:
			# Ignore already-despawned targets
			if other_character.is_despawned:
				continue
			
			var normal: Vector2 = collision.get_normal()
			
			# Check if we stomped them (we were falling and hit their top)
			# Upward normal means we hit their top from above
			var hit_their_top: bool = normal.y < -0.6 and previous_velocity_y > 0
			
			# Check if we hit their bottom (we were jumping up and hit their bottom)
			# Downward normal means we hit their bottom from below
			var hit_their_bottom: bool = normal.y > 0.6 and previous_velocity_y < 0
			
			if hit_their_top:
				# Successful stomp - they die, we bounce
				EventBus.character_stomped.emit(self, other_character)
				other_character.despawn(self)
				velocity.y = physics.jump_velocity * 0.5
			elif hit_their_bottom:
				# Hit their bottom from below - we die and credit them
				despawn(other_character)
			# Side collisions (normal.x dominant) are harmless - do nothing

## Despawns character, spawns gravestone, and emits kill event.
func despawn(killer: CharacterController = null) -> void:
	lifecycle.despawn(killer)

## Respawns character at spawn point with protection and visual effects.
func respawn() -> void:
	lifecycle.respawn()
	visuals.start_spawn_animation()
	visuals.face_towards_screen_center()

## Returns character's foot position for spawn point calculations.
func get_foot_position() -> Vector2:
	return lifecycle.get_foot_position()

func _capture_input_frame() -> Dictionary:
	if control_source == ControlSource.LOCAL_HUMAN:
		return InputManager.capture_gameplay_input()
	return _buffered_input.duplicate()

func _clear_transient_input() -> void:
	if control_source in [ControlSource.CPU, ControlSource.REMOTE_INPUT]:
		_buffered_input["jump_pressed"] = false
		_buffered_input["jump_released"] = false

func _update_replica(_delta: float) -> void:
	if _replica_snapshots.is_empty():
		return
	var newest_tick := int(_replica_snapshots[-1].get("tick", 0))
	var target_tick := newest_tick - REPLICA_DELAY_TICKS
	while _replica_snapshots.size() >= 2 and int(_replica_snapshots[1].get("tick", 0)) <= target_tick:
		_replica_snapshots.pop_front()

	var a := _replica_snapshots[0]
	var b := _replica_snapshots[1] if _replica_snapshots.size() >= 2 else a
	var tick_a := int(a.get("tick", target_tick))
	var tick_b := int(b.get("tick", tick_a))
	var weight := 1.0 if tick_a == tick_b else clampf(float(target_tick - tick_a) / float(tick_b - tick_a), 0.0, 1.0)
	var pos_a: Vector2 = a.get("position", global_position)
	var pos_b: Vector2 = b.get("position", pos_a)
	global_position = pos_a + _wrap_aware_delta(pos_a, pos_b) * weight
	velocity = (a.get("velocity", Vector2.ZERO) as Vector2).lerp(b.get("velocity", Vector2.ZERO), weight)
	visuals.update_animation(
		bool(b.get("on_floor", false)),
		velocity,
		signf(velocity.x),
		physics.get_effective_max_speed(),
		physics.get_previous_horizontal_velocity()
	)
	var sprite := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite and absf(velocity.x) < 0.1:
		sprite.flip_h = bool(b.get("facing_left", sprite.flip_h))

func _apply_snapshot_lifecycle(state: Dictionary) -> void:
	lifecycle.apply_network_state(
		bool(state.get("despawned", false)),
		bool(state.get("eliminated", false)),
		float(state.get("protection", 0.0))
	)
	if _is_online_guest():
		set_collision_layer_value(2, false)
		set_collision_mask_value(2, false)
	visible = bool(state.get("visible", not lifecycle.is_despawned))

func _update_visual_correction(delta: float) -> void:
	var sprite := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null:
		return
	_visual_correction = _visual_correction.lerp(Vector2.ZERO, clampf(delta * CORRECTION_DECAY, 0.0, 1.0))
	if _visual_correction.length_squared() < 0.01:
		_visual_correction = Vector2.ZERO
	sprite.position = _visual_correction

func _wrap_aware_delta(from: Vector2, to: Vector2) -> Vector2:
	return NetworkProtocol.wrap_aware_delta(from, to, get_viewport_rect().size)

func _is_facing_left() -> bool:
	var sprite := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	return sprite.flip_h if sprite else false

func _is_online_match() -> bool:
	return has_node("/root/NetworkSession") and NetworkSession.is_online_match()

func _is_online_guest() -> bool:
	return _is_online_match() and not NetworkSession.is_host()

static func _neutral_input() -> Dictionary:
	return {"move_x": 0.0, "run": false, "down": false, "jump_pressed": false, "jump_released": false}

static func _sanitized_input(value: Dictionary) -> Dictionary:
	return {
		"move_x": clampf(float(value.get("move_x", 0.0)), -1.0, 1.0),
		"run": bool(value.get("run", false)),
		"down": bool(value.get("down", false)),
		"jump_pressed": bool(value.get("jump_pressed", false)),
		"jump_released": bool(value.get("jump_released", false)),
		"sequence": int(value.get("sequence", 0)),
		"client_tick": int(value.get("client_tick", 0)),
	}
