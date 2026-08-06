extends Area2D

## King of the Hill zone: a 4x3-tile region above a platform surface.
## The node origin sits ON the surface (ground_position); the collision rect
## extends upward plus a few px below for reliable grounded overlap.
## Code-drawn translucent rect with a pulsing border.

var _bodies: Array = []
var _time := 0.0

## The platform-surface point CPUs should path to.
var ground_position: Vector2:
	get: return global_position

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _process(delta: float) -> void:
	_time += delta
	queue_redraw()

func _on_body_entered(body: Node2D) -> void:
	if body is CharacterController and not _bodies.has(body):
		_bodies.append(body)

func _on_body_exited(body: Node2D) -> void:
	_bodies.erase(body)

## Living characters currently in the zone. (Despawn drops the character
## collision layer, so body_exited fires on death anyway -- the filter here
## is belt and suspenders.)
func get_occupants() -> Array:
	return _bodies.filter(
		func(b: Node) -> bool:
			return is_instance_valid(b) and not (b as CharacterController).is_despawned
	)

func relocate(pos: Vector2) -> void:
	global_position = pos
	_bodies.clear()  # physics re-enters overlaps next frame

func _draw() -> void:
	var pulse := 0.75 + 0.25 * sin(_time * 3.0)
	var rect := Rect2(-64.0, -96.0, 128.0, 96.0)
	draw_rect(rect, Color(0.4, 0.8, 1.0, 0.18 * pulse), true)
	draw_rect(rect, Color(0.5, 0.9, 1.0, 0.6 * pulse), false, 2.0)
