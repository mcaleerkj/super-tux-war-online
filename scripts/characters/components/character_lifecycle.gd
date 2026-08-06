extends Node
class_name CharacterLifecycle

## Handles character spawn, death, and respawn logic.

const GRAVESTONE_SCENE = preload("res://scenes/objects/gravestone.tscn")

var character: CharacterBody2D
var shape_alive: CollisionShape2D

# Lifecycle state
var is_despawned: bool = false
var is_eliminated: bool = false
var spawn_position: Vector2
var respawn_timer: float = 0.0
var spawn_protection_timer: float = 0.0
var authoritative: bool = true

const RESPAWN_TIME: float = 2.0
const SPAWN_PROTECTION_DURATION: float = 1.0

func _init(character_body: CharacterBody2D) -> void:
	character = character_body

func initialize() -> void:
	spawn_position = character.global_position
	shape_alive = character.get_node_or_null("CollisionShape2D")
	
	if shape_alive:
		shape_alive.disabled = false

func set_authoritative(value: bool) -> void:
	authoritative = value

## Updates respawn timer and spawn protection.
func update_lifecycle(delta: float) -> bool:
	# Handle respawn timer
	if is_despawned:
		if is_eliminated:
			return false  # Stay dead permanently; never accrue respawn time
		if not authoritative:
			return false  # A guest waits for the host's reliable respawn event.
		respawn_timer += delta
		if respawn_timer >= RESPAWN_TIME:
			respawn()
		return false  # Don't process physics while despawned
	
	# Update spawn protection
	if spawn_protection_timer > 0.0:
		spawn_protection_timer = max(0.0, spawn_protection_timer - delta)
		# Disable character collision during protection
		character.set_collision_layer_value(2, false)
		character.set_collision_mask_value(2, false)
	else:
		# Restore normal collision
		character.set_collision_layer_value(2, true)
		character.set_collision_mask_value(2, true)
	
	return true  # Continue processing

## Despawns character, spawns gravestone, and emits kill event.
func despawn(killer: CharacterController = null) -> void:
	if is_despawned:
		return
	
	is_despawned = true
	respawn_timer = 0.0
	character.velocity = Vector2.ZERO
	
	if killer and killer != character:
		EventBus.character_killed.emit(killer, character)

	# Unconditional (unlike character_killed): suicides also sound/react.
	EventBus.character_died.emit(character)

	_spawn_gravestone()
	
	# Hide and disable collisions
	character.visible = false
	character.set_collision_layer_value(2, false)
	character.set_collision_mask_value(1, false)
	character.set_collision_mask_value(2, false)
	
	if shape_alive:
		shape_alive.disabled = true

## Respawns character at spawn point with protection and visual effects.
func respawn() -> void:
	# Get spawn position from manager
	var spawn_manager := character.get_tree().get_first_node_in_group("spawn_manager")
	if spawn_manager and spawn_manager.has_method("get_spawn_position_for"):
		spawn_position = spawn_manager.get_spawn_position_for(character)
	_respawn_at(spawn_position, true)

## Applies a host-authoritative death on a guest. Mode rule hooks are passive
## on guests, but local audio, gravestones, and HUD reactions still run.
func apply_remote_despawn(killer: CharacterController = null) -> void:
	despawn(killer)

## Applies the exact spawn chosen by the host rather than selecting a local
## random point.
func apply_remote_respawn(position: Vector2) -> void:
	spawn_position = position
	_respawn_at(position, true)

func _respawn_at(position: Vector2, emit_event: bool) -> void:
	is_despawned = false
	is_eliminated = false
	respawn_timer = 0.0
	spawn_protection_timer = SPAWN_PROTECTION_DURATION
	character.global_position = position
	character.velocity = Vector2.ZERO
	
	# Restore collision shape
	if shape_alive:
		shape_alive.disabled = false
	
	# Show character
	character.visible = true
	
	# Enable world collision (character collision handled by protection timer)
	character.set_collision_mask_value(1, true)
	character.set_collision_layer_value(2, false)
	character.set_collision_mask_value(2, false)

	if emit_event:
		EventBus.character_respawned.emit(character)

## Snapshot fallback used if a reliable lifecycle message was delayed. This
## intentionally does not create effects or emit gameplay events.
func apply_network_state(despawned: bool, eliminated: bool, protection: float) -> void:
	is_despawned = despawned
	is_eliminated = eliminated
	spawn_protection_timer = maxf(0.0, protection)
	character.visible = not despawned
	if shape_alive:
		shape_alive.set_deferred("disabled", despawned)
	character.set_collision_mask_value(1, not despawned)
	character.set_collision_layer_value(2, false if despawned or protection > 0.0 else true)
	character.set_collision_mask_value(2, false if despawned or protection > 0.0 else true)

## Permanently removes the character from play (no respawn).
func eliminate() -> void:
	if is_eliminated:
		return
	is_eliminated = true
	if not is_despawned:
		despawn()
	EventBus.character_eliminated.emit(character)

func _spawn_gravestone() -> void:
	var gravestone := GRAVESTONE_SCENE.instantiate()
	gravestone.global_position = character.global_position
	
	var level := character.get_tree().current_scene
	if level:
		level.add_child(gravestone)

## Returns character's foot position for spawn point calculations.
func get_foot_position() -> Vector2:
	var foot_offset: float = character.get("foot_offset")
	if foot_offset == null:
		foot_offset = 14.0
	return character.global_position + Vector2(0, foot_offset)
