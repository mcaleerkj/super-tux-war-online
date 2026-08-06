extends GameMode

## Time Limit: most kills when the clock runs out. Ties end in a draw.

const WARNING_WINDOW := 10

var _remaining: float = 0.0
var _last_warned: int = -1
var _finished: bool = false

func mode_id() -> StringName:
	return &"time"

func display_name() -> String:
	return "Time Limit"

func goal_label() -> String:
	return "Minutes"

func goal_min() -> int:
	return 1

func goal_max() -> int:
	return 5

func goal_default() -> int:
	return 2

func score_header() -> String:
	return "Kills"

func uses_timer() -> bool:
	return true

func on_match_started() -> void:
	_remaining = goal * 60.0
	_finished = false
	_last_warned = -1

func on_character_killed(killer: CharacterController, _victim: CharacterController) -> void:
	add_score(killer, 1)

func tick(delta: float) -> void:
	if _finished:
		return
	_remaining = maxf(0.0, _remaining - delta)
	var secs := ceili(_remaining)
	if secs <= WARNING_WINDOW and secs > 0 and secs != _last_warned:
		_last_warned = secs
		EventBus.match_timer_warning.emit(secs)
	if _remaining <= 0.0:
		_finished = true
		EventBus.time_expired.emit()
		_declare_time_up_result()

func _declare_time_up_result() -> void:
	var best := -1
	var leader: CharacterController = null
	var tied := false
	for character in get_characters():
		var score := get_score(character)
		if score > best:
			best = score
			leader = character
			tied = false
		elif score == best:
			tied = true
	declare_winner(null if tied else leader)

func get_status_text() -> String:
	var secs := ceili(_remaining)
	@warning_ignore("integer_division")
	return "%d:%02d" % [secs / 60, secs % 60]
