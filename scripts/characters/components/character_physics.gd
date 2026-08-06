extends Node
class_name CharacterPhysics

## Handles character physics: gravity, movement, collision, and boundary wrapping.
## Implements SMW-style acceleration/friction for realistic momentum-based movement.

var character: CharacterBody2D

# Physics properties
var jump_velocity: float = GameConstants.JUMP_VELOCITY
var gravity: float = GameConstants.GRAVITY
var max_fall_speed: float = GameConstants.MAX_FALL_SPEED

# Acceleration-based movement (SMW-style)
var acceleration: float = GameConstants.PLAYER_ACCEL
var max_speed: float = GameConstants.PLAYER_MAX_WALK_SPEED
var friction_ground: float = GameConstants.FRICTION_GROUND
var friction_ice: float = GameConstants.FRICTION_ICE
var friction_air: float = GameConstants.FRICTION_AIR
var current_input_direction: float = 0.0
var current_effective_max_speed: float = GameConstants.PLAYER_MAX_WALK_SPEED
var previous_horizontal_velocity: float = 0.0

# Speed modifiers (can be set externally for powerups/effects)
var speed_modifier: float = 1.0  # 1.0 = normal, 1.375 = turbo, 0.55 = slowdown
var is_turbo_active: bool = false  # Set true when turbo key held
var is_slowdown_active: bool = false  # Set true when slowdown effect active

# Surface detection
var is_on_ice: bool = false

# Boundary wrap
var wrap_enabled: bool = true
var wrap_offset: float = 10.0

# Jump assist timers
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var drop_through_timer: float = 0.0
const DROP_THROUGH_DURATION: float = 0.2

func _init(character_body: CharacterBody2D) -> void:
	character = character_body

## Updates physics timers and applies movement. Returns previous velocity Y for collision detection.
func update_physics(delta: float, input_frame: Dictionary, emit_events: bool = true) -> float:
	var was_on_floor := character.is_on_floor()
	
	# Update coyote time
	if was_on_floor:
		coyote_timer = GameConstants.COYOTE_TIME
	else:
		coyote_timer = max(0.0, coyote_timer - delta)
	
	# Update jump buffer
	if jump_buffer_timer > 0.0:
		jump_buffer_timer = max(0.0, jump_buffer_timer - delta)
	
	# Update drop-through timer
	if drop_through_timer > 0.0:
		drop_through_timer = max(0.0, drop_through_timer - delta)
	
	_handle_input(delta, input_frame, emit_events)
	
	# Apply gravity
	_apply_gravity(delta)
	
	# Cap velocity
	character.velocity.y = clamp(character.velocity.y, -max_fall_speed, max_fall_speed)
	character.velocity.x = clamp(character.velocity.x, -GameConstants.PLAYER_MAX_RUN_SPEED, GameConstants.PLAYER_MAX_RUN_SPEED)
	
	# Store previous velocity for collision detection
	var previous_velocity_y := character.velocity.y
	
	# Temporarily disable platform_on_leave for drop-through
	var old_platform_on_leave := character.platform_on_leave
	if drop_through_timer > 0.0:
		character.platform_on_leave = CharacterBody2D.PLATFORM_ON_LEAVE_DO_NOTHING
	
	character.move_and_slide()

	# Restore platform behavior
	if drop_through_timer > 0.0:
		character.platform_on_leave = old_platform_on_leave

	# Detect surface type (ice vs normal) from this frame's actual collision
	_detect_surface_type()

	# Landing transition (also releases any buffered jump)
	if character.is_on_floor() and not was_on_floor:
		if emit_events:
			EventBus.character_landed.emit(character, previous_velocity_y)
		if jump_buffer_timer > 0.0:
			_perform_jump(1.0, emit_events)
			jump_buffer_timer = 0.0
	
	# Boundary wrap after all motion
	_wrap_after_motion()
	
	return previous_velocity_y

func _handle_input(delta: float, input_frame: Dictionary, emit_events: bool) -> void:
	is_turbo_active = bool(input_frame.get("run", false))
	var input_direction := clampf(float(input_frame.get("move_x", 0.0)), -1.0, 1.0)
	var down_pressed := bool(input_frame.get("down", false))
	var jump_pressed := bool(input_frame.get("jump_pressed", false))
	var jump_released := bool(input_frame.get("jump_released", false))
	
	# Apply acceleration-based movement
	_apply_horizontal_movement(input_direction, delta)
	
	# Drop-through semisolid platforms
	if down_pressed and jump_pressed and character.is_on_floor():
		drop_through_timer = DROP_THROUGH_DURATION
		character.position.y += 1
		return
	
	# Jump with coyote time and buffering
	if jump_pressed and not down_pressed:
		if coyote_timer > 0.0:
			_perform_jump(1.0, emit_events)
			coyote_timer = 0.0
		else:
			jump_buffer_timer = GameConstants.JUMP_BUFFER_TIME
	
	# Variable jump: early release clamp
	if jump_released and character.velocity.y < 0:
		if character.velocity.y < GameConstants.JUMP_EARLY_CLAMP:
			character.velocity.y = GameConstants.JUMP_EARLY_CLAMP

func _apply_gravity(delta: float) -> void:
	if not character.is_on_floor():
		character.velocity.y += gravity * delta

func _perform_jump(jump_modifier: float = 1.0, emit_event: bool = true) -> void:
	var jump_speed := jump_velocity
	var has_directional_input := absf(current_input_direction) > 0.1
	var is_at_turbo_speed := absf(character.velocity.x) >= GameConstants.PLAYER_MAX_WALK_SPEED
	var is_turbo_jump := is_turbo_active and has_directional_input and is_at_turbo_speed
	if is_turbo_jump:
		jump_speed = GameConstants.JUMP_VELOCITY_TURBO
	character.velocity.y = jump_speed * jump_modifier
	if emit_event:
		EventBus.character_jumped.emit(character, is_turbo_jump)

func capture_prediction_state() -> Dictionary:
	return {
		"coyote": coyote_timer,
		"jump_buffer": jump_buffer_timer,
		"drop_timer": drop_through_timer,
		"input_x": current_input_direction,
		"turbo": is_turbo_active,
		"ice": is_on_ice,
	}

func restore_prediction_state(state: Dictionary) -> void:
	coyote_timer = maxf(0.0, float(state.get("coyote", 0.0)))
	jump_buffer_timer = maxf(0.0, float(state.get("jump_buffer", 0.0)))
	drop_through_timer = maxf(0.0, float(state.get("drop_timer", 0.0)))
	current_input_direction = clampf(float(state.get("input_x", 0.0)), -1.0, 1.0)
	is_turbo_active = bool(state.get("turbo", false))
	is_on_ice = bool(state.get("ice", false))

func _wrap_after_motion() -> void:
	if not wrap_enabled:
		return
	
	var rect: Rect2 = character.get_viewport().get_visible_rect()
	var left: float = rect.position.x
	var right: float = rect.position.x + rect.size.x
	var top: float = rect.position.y
	var bottom: float = rect.position.y + rect.size.y
	
	var pos: Vector2 = character.global_position
	
	# Horizontal wrap
	if pos.x > right:
		pos.x = left + wrap_offset
	elif pos.x < left:
		pos.x = right - wrap_offset
	
	# Vertical wrap
	if pos.y > bottom:
		pos.y = top + wrap_offset
	elif pos.y < top:
		pos.y = bottom - wrap_offset
	
	character.global_position = pos

## Applies SMW-style acceleration and friction to horizontal movement
func _apply_horizontal_movement(input_direction: float, delta: float) -> void:
	current_input_direction = input_direction
	previous_horizontal_velocity = character.velocity.x
	# Calculate effective max speed based on modifiers
	var effective_max_speed := max_speed
	if is_turbo_active:
		effective_max_speed = GameConstants.PLAYER_MAX_RUN_SPEED
	elif is_slowdown_active:
		effective_max_speed = GameConstants.PLAYER_MAX_SLOW_SPEED
	# Applied after the turbo branch so mode effects (e.g. chicken slow)
	# reduce turbo speed too.
	effective_max_speed *= speed_modifier
	current_effective_max_speed = effective_max_speed
	
	# Determine acceleration rate based on surface
	var current_accel := acceleration
	if is_on_ice:
		current_accel = GameConstants.PLAYER_ACCEL_ICE
	
	if input_direction != 0.0:
		# Apply acceleration
		var accel_amount := current_accel * delta
		character.velocity.x += input_direction * accel_amount
		
		# Clamp to max speed
		character.velocity.x = clamp(character.velocity.x, -effective_max_speed, effective_max_speed)
	else:
		# Apply friction when no input
		var friction := _get_current_friction()
		var friction_amount := friction * delta
		
		if absf(character.velocity.x) <= friction_amount:
			# Stop completely if velocity is very small
			character.velocity.x = 0.0
		else:
			# Apply friction in opposite direction of movement
			var friction_dir: float = -sign(character.velocity.x)
			character.velocity.x += friction_dir * friction_amount

## Returns appropriate friction based on current state (ground, ice, air)
func _get_current_friction() -> float:
	if not character.is_on_floor():
		return friction_air
	elif is_on_ice:
		return friction_ice
	else:
		return friction_ground

## Detects if character is standing on ice tiles
func _detect_surface_type() -> void:
	is_on_ice = false

	if not character.is_on_floor():
		return

	var probe_pos := _get_ground_probe_position()

	# Check every ground layer at the probe position for the "ice" custom data flag
	for tilemap in _find_ground_tilemaps():
		var tile_coords := tilemap.local_to_map(tilemap.to_local(probe_pos))
		var tile_data := tilemap.get_cell_tile_data(tile_coords)
		if tile_data != null and tile_data.get_custom_data("ice"):
			is_on_ice = true
			return

## Returns a point a few pixels below the character's collision bottom edge,
## safely inside the tile it's resting on. Sampling exactly at the collision
## boundary is unreliable: floor-snap leaves a sub-pixel gap that can round
## the sample into the (empty) tile above instead of the one underfoot.
const GROUND_PROBE_DEPTH: float = 4.0

func _get_ground_probe_position() -> Vector2:
	var shape_node := character.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node and shape_node.shape is RectangleShape2D:
		var rect := shape_node.shape as RectangleShape2D
		var half_height: float = rect.size.y * shape_node.scale.y / 2.0
		var bottom_offset: float = shape_node.position.y + half_height
		return character.global_position + Vector2(0, bottom_offset + GROUND_PROBE_DEPTH)
	return character.get_foot_position()

## Finds the TileMapLayer nodes that carry walkable ground collision
func _find_ground_tilemaps() -> Array[TileMapLayer]:
	var scene_root := character.get_tree().current_scene
	if scene_root == null:
		return []

	var layers: Array[TileMapLayer] = []
	for layer_name in ["GroundTileMap", "SemisolidTileMap"]:
		var node := scene_root.find_child(layer_name, true, false)
		if node is TileMapLayer:
			layers.append(node)
	return layers

## Calculates distance needed to stop from current velocity (useful for AI)
func get_stopping_distance() -> float:
	var friction := _get_current_friction()
	if friction <= 0.0:
		return INF
	
	var current_speed := absf(character.velocity.x)
	# Using kinematic equation: v² = u² + 2as
	# Solving for s (distance): s = v² / (2 * a)
	return (current_speed * current_speed) / (2.0 * friction)

## Calculates time needed to stop from current velocity (useful for AI)
func get_stopping_time() -> float:
	var friction := _get_current_friction()
	if friction <= 0.0:
		return INF
	
	var current_speed := absf(character.velocity.x)
	# Using equation: v = u - at
	# Solving for t: t = v / a
	return current_speed / friction

func get_current_input_direction() -> float:
	return current_input_direction

func get_effective_max_speed() -> float:
	return current_effective_max_speed

func get_previous_horizontal_velocity() -> float:
	return previous_horizontal_velocity
