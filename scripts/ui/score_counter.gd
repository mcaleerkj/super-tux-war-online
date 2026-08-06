extends Control
class_name ScoreCounter

## Tracks and displays kill scores for all characters.
##
## Creates UI entries for each character with portrait and score, listens to
## character_killed events via EventBus, scales UI based on character count,
## and triggers win condition when a character reaches the target score.

const SCORE_ENTRY_SCENE := preload("res://scenes/ui/score_entry.tscn")
const GAME_OVER_SCENE := preload("res://scenes/ui/game_over_scoreboard.tscn")
const SCORE_FORMAT := "%d"
const MAX_SCORE := 999
const PORTRAIT_TARGET_SIZE := 28.0

# Scaling thresholds based on character count
const SCALE_NORMAL := 1.0      # 1-2 characters
const SCALE_SMALL := 0.85      # 3-4 characters
const SCALE_SMALLER := 0.70    # 5-6 characters
const SCALE_TINY := 0.60       # 7+ characters

@onready var _entries_container: HBoxContainer = $"Entries"

var _entries_by_character: Dictionary = {}
var _portrait_cache: Dictionary = {}

func _ready() -> void:
	add_to_group("score_counter")
	call_deferred("_scan_existing_characters")
	get_tree().node_added.connect(_on_node_added)

	# Display-only: the active GameMode owns scoring and broadcasts values.
	EventBus.mode_score_changed.connect(_on_mode_score_changed)

func _scan_existing_characters() -> void:
	var characters: Array = []
	for node in get_tree().get_nodes_in_group("characters"):
		if node is CharacterController:
			characters.append(node)
	characters.sort_custom(Callable(self, "_character_sort"))
	for character in characters:
		_register_character(character)

func _character_sort(a: CharacterController, b: CharacterController) -> bool:
	if a.is_human != b.is_human:
		return a.is_human and not b.is_human
	if a.participant_id != b.participant_id:
		return a.participant_id < b.participant_id
	return a.name < b.name

func _on_node_added(node: Node) -> void:
	if node is CharacterController:
		_register_character(node)

func _register_character(character: CharacterController) -> void:
	if _entries_by_character.has(character):
		return
	var entry := _create_entry_ui()
	_entries_container.add_child(entry.node)
	_entries_by_character[character] = entry
	_update_entry_portrait(character, entry)
	# Seed the initial value from the mode (e.g. Classic shows full lives).
	var mode := get_tree().get_first_node_in_group("game_mode")
	entry["score"] = mode.get_score(character) if mode is GameMode else 0
	_update_entry_label(entry)
	character.tree_exiting.connect(_on_character_tree_exiting.bind(character))
	
	# Update scale based on total character count
	_update_scale()

func _create_entry_ui() -> Dictionary:
	var node := SCORE_ENTRY_SCENE.instantiate() as Control
	var portrait := node.get_node("HBoxContainer/Portrait") as TextureRect
	var score_label := node.get_node("HBoxContainer/ScoreLabel") as Label
	return {
		"node": node,
		"portrait": portrait,
		"label": score_label,
		"score": 0
	}

func _update_entry_portrait(character: CharacterController, entry: Dictionary) -> void:
	var portrait: TextureRect = entry.get("portrait")
	if portrait == null or character == null:
		return
	var texture: Texture2D = _get_idle_frame_texture(character)
	if texture == null:
		texture = _get_sprite_frame_texture(character)
	if texture:
		portrait.texture = texture
	
	# Apply character's color tint to the portrait
	portrait.modulate = character.character_color

func _get_idle_frame_texture(character: CharacterController) -> Texture2D:
	if character == null:
		return null
	var asset_name := character.character_asset_name if character.character_asset_name else ""
	if asset_name.is_empty():
		asset_name = ""

	# Prefer loading from the character's idle spritesheet to avoid stale in-tree frames
	if asset_name != "":
		var paths := [
			ResourcePaths.get_character_spritesheet_path(asset_name) + ResourcePaths.CHARACTER_IDLE_SPRITE,
			ResourcePaths.get_character_spritesheet_alt_path(asset_name) + ResourcePaths.CHARACTER_IDLE_SPRITE
		]
		for path in paths:
			if _portrait_cache.has(path):
				return _portrait_cache[path]
			if ResourceLoader.exists(path):
				var full_texture := load(path) as Texture2D
				if full_texture:
					var atlas := AtlasTexture.new()
					atlas.atlas = full_texture
					atlas.region = Rect2(0, 0, 32, 32)
					_portrait_cache[path] = atlas
					return atlas
			_portrait_cache[path] = null
	
	# Fallback to the live AnimatedSprite2D idle frame (if already swapped)
	var sprite := character.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("idle"):
		if sprite.sprite_frames.get_frame_count("idle") > 0:
			return sprite.sprite_frames.get_frame_texture("idle", 0)
	
	return null

func _get_sprite_frame_texture(character: CharacterController) -> Texture2D:
	var sprite := character.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if sprite == null:
		return null
	var frames := sprite.sprite_frames
	if frames == null:
		return null
	if frames.has_animation("idle") and frames.get_frame_count("idle") > 0:
		return frames.get_frame_texture("idle", 0)
	var animation_names := frames.get_animation_names()
	if animation_names.size() == 0:
		return null
	var first_animation := animation_names[0]
	if frames.get_frame_count(first_animation) == 0:
		return null
	return frames.get_frame_texture(first_animation, 0)

func _on_mode_score_changed(character: CharacterController, value: int) -> void:
	if not _entries_by_character.has(character):
		return
	var entry: Dictionary = _entries_by_character[character]
	entry["score"] = clampi(value, 0, MAX_SCORE)
	_update_entry_label(entry)

func _update_entry_label(entry: Dictionary) -> void:
	var label: Label = entry.get("label")
	if label == null:
		return
	var score_value := int(entry.get("score", 0))
	var formatted := SCORE_FORMAT % score_value
	label.text = formatted

func _on_character_tree_exiting(character: CharacterController) -> void:
	if not _entries_by_character.has(character):
		return
	var entry: Dictionary = _entries_by_character[character]
	_entries_by_character.erase(character)
	var node: Control = entry.get("node")
	if node:
		node.queue_free()
	
	# Update scale after removing a character
	_update_scale()


func _update_scale() -> void:
	# Scale down the score counter based on number of entries
	var count := _entries_by_character.size()
	var target_scale: float
	
	if count <= 2:
		target_scale = SCALE_NORMAL
	elif count <= 4:
		target_scale = SCALE_SMALL
	elif count <= 6:
		target_scale = SCALE_SMALLER
	else:
		target_scale = SCALE_TINY
	
	# Apply scale to the entire score counter
	scale = Vector2(target_scale, target_scale)

func get_character_score(character: CharacterController) -> int:
	if _entries_by_character.has(character):
		var entry: Dictionary = _entries_by_character[character]
		return entry.get("score", 0)
	return 0
