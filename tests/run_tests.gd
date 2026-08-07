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

	_expect(NetworkProtocol.validate_match_config(_roster_config(6)), "accepts a full six-player roster")
	_expect(not NetworkProtocol.validate_match_config(_roster_config(7)), "rejects a roster above MAX_PLAYERS")
	_expect(not NetworkProtocol.validate_match_config(_roster_config(1)), "rejects a solo roster")

	var duplicated := _roster_config(3)
	duplicated["participants"][2]["peer_id"] = NetworkProtocol.HOST_PEER_ID
	_expect(not NetworkProtocol.validate_match_config(duplicated), "rejects duplicate participant ids")

	var hostless := _roster_config(3)
	hostless["participants"][0]["peer_id"] = 4
	_expect(not NetworkProtocol.validate_match_config(hostless), "rejects a roster with no host")

	# Bots share the roster with humans but occupy a disjoint id range, so a bot
	# id can never satisfy the "is this RPC sender a real peer" check.
	var with_bot := _roster_config(2)
	with_bot["participants"].append({
		"peer_id": NetworkProtocol.bot_id_for_slot(0),
		"character_id": "gopher",
		"color_slot": 2,
		"is_bot": true,
	})
	_expect(NetworkProtocol.validate_match_config(with_bot), "accepts a roster containing a bot")
	_expect(NetworkProtocol.is_bot_id(NetworkProtocol.bot_id_for_slot(0)), "bot ids are bot ids")
	_expect(not NetworkProtocol.is_peer_id(NetworkProtocol.bot_id_for_slot(0)), "bot ids are not peer ids")
	_expect(not NetworkProtocol.is_peer_id(NetworkProtocol.MAX_PLAYERS + 1), "rejects peer ids above MAX_PLAYERS")

	var bot_as_human := _roster_config(2)
	bot_as_human["participants"].append({
		"peer_id": NetworkProtocol.bot_id_for_slot(1),
		"character_id": "tux",
		"color_slot": 3,
	})
	_expect(not NetworkProtocol.validate_match_config(bot_as_human), "rejects a bot id claiming to be human")

	var wide_slot := _roster_config(2)
	wide_slot["participants"][1]["color_slot"] = NetworkProtocol.MAX_PLAYERS
	_expect(not NetworkProtocol.validate_match_config(wide_slot), "rejects a color slot outside the palette")

	# Goal bounds are per online mode rather than a single frag-only constant.
	# This runs without autoloads, so it must not touch ModeRegistry — the
	# table-vs-prototype drift check lives in online_match_smoke.gd instead.
	for mode_id: StringName in NetworkProtocol.ONLINE_MODE_GOALS:
		var bounds: Dictionary = NetworkProtocol.ONLINE_MODE_GOALS[mode_id]
		var mode_config := _roster_config(2)
		mode_config["mode_id"] = String(mode_id)
		mode_config["goal"] = int(bounds["min"])
		_expect(NetworkProtocol.validate_match_config(mode_config), "accepts online mode %s at its floor" % mode_id)
		mode_config["goal"] = int(bounds["max"])
		_expect(NetworkProtocol.validate_match_config(mode_config), "accepts online mode %s at its ceiling" % mode_id)
		mode_config["goal"] = int(bounds["max"]) + 1
		_expect(not NetworkProtocol.validate_match_config(mode_config), "rejects %s above its goal range" % mode_id)
		mode_config["goal"] = int(bounds["min"]) - 1
		_expect(not NetworkProtocol.validate_match_config(mode_config), "rejects %s below its goal range" % mode_id)

	# A mode that exists offline but has no host->guest sync yet must be refused,
	# so a half-finished mode can never reach a real match.
	_expect(not NetworkProtocol.is_online_mode(&"chicken"), "chicken is not online yet")
	var offline_only := _roster_config(2)
	offline_only["mode_id"] = "chicken"
	_expect(not NetworkProtocol.validate_match_config(offline_only), "rejects a not-yet-online mode")

	var unknown_mode := _roster_config(2)
	unknown_mode["mode_id"] = "not_a_mode"
	_expect(not NetworkProtocol.validate_match_config(unknown_mode), "rejects an unregistered mode")

	if _failures == 0:
		print("[Tests] all tests passed")
	quit(_failures)

func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[Tests] FAILED: %s" % description)

## A valid frag config with `count` human participants, peer ids 1..count.
func _roster_config(count: int) -> Dictionary:
	var participants: Array = []
	for index in count:
		participants.append({
			"peer_id": NetworkProtocol.HOST_PEER_ID + index,
			"character_id": NetworkProtocol.CHARACTERS[index % NetworkProtocol.CHARACTERS.size()],
			"color_slot": index,
		})
	return {
		"protocol_version": NetworkProtocol.VERSION,
		"mode_id": "frag",
		"level_id": "level01",
		"goal": 10,
		"participants": participants,
	}

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
