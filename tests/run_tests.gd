extends SceneTree

var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_expect(NetworkProtocol.normalize_room_code(" abcd-1234 ") == "ABCD1234", "normalizes room codes")
	_expect(NetworkProtocol.is_valid_room_code("ABCD1234"), "accepts valid Crockford code")
	_expect(not NetworkProtocol.is_valid_room_code("O0IL1234"), "rejects ambiguous code characters")
	_expect(NetworkProtocol.level_path_from_id("level02").ends_with("level02.tscn"), "maps stable level IDs")

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
		print("[Tests] all network protocol tests passed")
	quit(_failures)

func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[Tests] FAILED: %s" % description)
