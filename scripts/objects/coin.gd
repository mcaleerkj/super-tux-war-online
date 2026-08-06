extends Area2D

## Collectible coin for Coin Collection mode. Code-drawn (no textures),
## bobs gently, collects on first character contact.

signal collected(character: CharacterController)

var _taken := false
var _base_y := 0.0
var _time := 0.0

func _ready() -> void:
	_base_y = position.y
	body_entered.connect(_on_body_entered)

func _process(delta: float) -> void:
	_time += delta
	position.y = _base_y + 3.0 * sin(_time * 5.0)

func _on_body_entered(body: Node2D) -> void:
	var character := body as CharacterController
	# The _taken guard makes same-frame double-entry first-wins-safe.
	if character == null or character.is_despawned or _taken:
		return
	_taken = true
	set_deferred("monitoring", false)
	collected.emit(character)
	queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 10.0, Color(1.0, 0.84, 0.0))
	draw_arc(Vector2.ZERO, 10.0, 0.0, TAU, 24, Color(0.72, 0.5, 0.05), 2.0)
	draw_circle(Vector2(-3.0, -3.0), 3.0, Color(1.0, 0.95, 0.6))
