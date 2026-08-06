extends GameMode

## Classic: everyone has N lives; run out and you're eliminated for good.
## Last character standing wins. If the human is eliminated early, the match
## continues among the CPUs while they spectate.

func mode_id() -> StringName:
	return &"classic"

func display_name() -> String:
	return "Classic"

func goal_label() -> String:
	return "Lives"

func goal_min() -> int:
	return 1

func goal_max() -> int:
	return 10

func goal_default() -> int:
	return 3

func score_header() -> String:
	return "Lives"

func initial_score() -> int:
	return goal  # chips show full lives before any event

func on_character_died(character: CharacterController) -> void:
	if character.is_eliminated:
		return
	var lives := get_score(character) - 1
	set_score(character, lives)
	if lives <= 0:
		print("[Classic] %s eliminated" % character.name)
		character.eliminate()
		_check_last_standing()

func _check_last_standing() -> void:
	var alive: Array[CharacterController] = []
	for character in get_characters():
		if not character.is_eliminated:
			alive.append(character)
	if alive.size() <= 1:
		declare_winner(alive[0] if alive.size() == 1 else null)

func get_status_text() -> String:
	var player := _find_player()
	if player and player.is_eliminated:
		return "ELIMINATED - SPECTATING"
	return ""

func _find_player() -> CharacterController:
	for character in get_characters():
		if character.is_locally_controlled():
			return character
	return null
