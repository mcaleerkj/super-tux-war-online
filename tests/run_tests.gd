extends SceneTree

var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var input_manager: Node = load("res://scripts/core/input_manager.gd").new()
	input_manager.call("_ensure_default_actions")
	_expect(_has_joy_button("jump", JOY_BUTTON_A), "maps controller A to jump")
	_expect(_has_joy_button("run", JOY_BUTTON_X), "maps controller X to sprint")
	_expect(_has_joy_button("run", JOY_BUTTON_B), "maps controller B to sprint")
	_expect(_has_joy_button("pause", JOY_BUTTON_START), "maps controller Menu/Start to pause")
	_expect(_has_joy_axis("move_left", JOY_AXIS_LEFT_X, -1.0), "maps the left stick to movement")
	_expect(_has_joy_axis("run", JOY_AXIS_TRIGGER_RIGHT, 1.0), "maps the right trigger to sprint")
	input_manager.free()

	_expect(NetworkProtocol.normalize_room_code(" abcd-1234 ") == "ABCD1234", "normalizes room codes")
	_expect(NetworkProtocol.is_valid_room_code("ABCD1234"), "accepts valid Crockford code")
	_expect(not NetworkProtocol.is_valid_room_code("O0IL1234"), "rejects ambiguous code characters")
	_expect(NetworkProtocol.level_path_from_id("level02").ends_with("level02.tscn"), "maps stable level IDs")

	# The committed config must be playable as exported. Only a build served from
	# a development host may fall back to the local Worker, so off-web callers
	# always resolve to the deployed URL.
	var shipped_config := NetworkProtocol.load_runtime_config()
	var resolved := NetworkProtocol.resolve_signaling_base_url(shipped_config)
	_expect(resolved.begins_with("https://"), "ships a deployed signaling URL, not localhost")
	_expect(not resolved.ends_with("/"), "normalizes the signaling base URL")
	_expect(
		str(shipped_config.get("local_signaling_base_url", "")) != "",
		"keeps a local signaling override for development"
	)
	_expect(
		NetworkProtocol.resolve_signaling_base_url({"local_signaling_base_url": "http://127.0.0.1:8787"}) == "",
		"reports no signaling service when none is configured"
	)

	var input := NetworkProtocol.sanitize_input({
		"sequence": 9,
		"client_tick": 9,
		"move_x": 7.0,
		"run": true,
		"jump_pressed": true,
	})
	_expect(float(input.get("move_x", 0.0)) == 1.0, "clamps remote movement")
	_expect(bool(input.get("jump_pressed", false)), "preserves jump edges")
	_expect(NetworkProtocol.sanitize_input({"sequence": -1}).is_empty(), "rejects invalid input sequence")
	var history: Array[Dictionary] = [
		{"sequence": 7}, {"sequence": 8}, {"sequence": 9},
	]
	var pending := NetworkProtocol.pending_inputs_after_ack(history, 8)
	_expect(pending.size() == 1 and int(pending[0].sequence) == 9, "keeps only unacknowledged prediction inputs")
	var wrap_delta := NetworkProtocol.wrap_aware_delta(Vector2(1270, 200), Vector2(10, 200), Vector2(1280, 704))
	_expect(wrap_delta == Vector2(20, 0), "interpolates across the nearest wrap boundary")

	var config := {
		"protocol_version": NetworkProtocol.VERSION,
		"mode_id": "frag",
		"level_id": "level01",
		"goal": 10,
		"participants": [
			{"peer_id": 1, "character_id": "tux", "color_slot": 0},
			{"peer_id": 2, "character_id": "beasty", "color_slot": 1},
		],
	}
	_expect(NetworkProtocol.validate_match_config(config), "accepts an allowlisted match")
	config["level_id"] = "res://untrusted.tscn"
	_expect(not NetworkProtocol.validate_match_config(config), "rejects arbitrary resource paths")

	if _failures == 0:
		print("[Tests] all tests passed")
	quit(_failures)

func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[Tests] FAILED: %s" % description)

func _has_joy_button(action: StringName, button: JoyButton) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton and event.button_index == button:
			return true
	return false

func _has_joy_axis(action: StringName, axis: JoyAxis, direction: float) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadMotion \
				and event.axis == axis \
				and signf(event.axis_value) == signf(direction):
			return true
	return false
