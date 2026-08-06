extends GameMode

## Frag Limit: first character to N kills wins (the original game mode).

func mode_id() -> StringName:
	return &"frag"

func display_name() -> String:
	return "Frag Limit"

func goal_label() -> String:
	return "Kills to Win"

func goal_min() -> int:
	return 3

func goal_max() -> int:
	return 50

func goal_default() -> int:
	return 10

func score_header() -> String:
	return "Kills"

func on_character_killed(killer: CharacterController, _victim: CharacterController) -> void:
	add_score(killer, 1)
	check_goal_reached(killer)
