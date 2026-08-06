extends Node

var _failures := 0

func _ready() -> void:
	get_tree().current_scene = null
	_run.call_deferred()

func _run() -> void:
	var game_state := get_tree().root.get_node("GameStateManager")
	var settings := get_tree().root.get_node("GameSettings")
	settings.call("set_cpu_count", 1)
	for mode_id in [&"frag", &"time", &"classic", &"coin", &"koth", &"chicken"]:
		settings.call("set_selected_mode", mode_id)
		var prototype := ModeRegistry.get_prototype(mode_id)
		settings.call("set_goal_for_mode", mode_id, prototype.goal_default())
		await game_state.call("start_match", "res://scenes/levels/level01.tscn")
		for frame in 4:
			await get_tree().process_frame
		for frame in 8:
			await get_tree().physics_frame
		var characters := get_tree().get_nodes_in_group("characters")
		_expect(characters.size() == 2, "%s spawns one player and one CPU" % mode_id)
		var mode := get_tree().get_first_node_in_group("game_mode") as GameMode
		_expect(mode != null and mode.mode_id() == mode_id, "%s creates the selected mode" % mode_id)
		if mode_id == &"coin":
			_expect(get_tree().get_nodes_in_group("coins").size() <= 1, "coin mode initializes without duplicate objectives")
		await game_state.call("return_to_menu")
	if _failures == 0:
		print("[Tests] all offline modes booted successfully")
	get_tree().quit(_failures)

func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[Tests] FAILED: %s" % description)
