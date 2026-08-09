extends Node

var _failures := 0

func _ready() -> void:
	# Keep the runner alive when GameStateManager replaces the current scene.
	get_tree().current_scene = null
	_run.call_deferred()

func _run() -> void:
	# NetworkProtocol duplicates each online mode's goal bounds so it stays
	# loadable without autoloads. This scene has them, so it is where the copy is
	# held to the mode prototype it was copied from.
	for mode_id: StringName in NetworkProtocol.ONLINE_MODE_GOALS:
		var bounds: Dictionary = NetworkProtocol.ONLINE_MODE_GOALS[mode_id]
		_expect(ModeRegistry.is_valid(mode_id), "online mode %s is a registered mode" % mode_id)
		var prototype := ModeRegistry.get_prototype(mode_id)
		_expect(int(bounds["min"]) == prototype.goal_min(), "%s goal floor matches its prototype" % mode_id)
		_expect(int(bounds["max"]) == prototype.goal_max(), "%s goal ceiling matches its prototype" % mode_id)

	# A full six-player roster, so the spawn, colour, and registration paths are
	# exercised at the maximum rather than at the degenerate two-player case.
	var roster_size := NetworkProtocol.MAX_PLAYERS
	var participants: Array = []
	for index in roster_size:
		participants.append({
			"peer_id": NetworkProtocol.HOST_PEER_ID + index,
			"character_id": NetworkProtocol.CHARACTERS[index % NetworkProtocol.CHARACTERS.size()],
			"color_slot": index,
		})
	var config := {
		"protocol_version": NetworkProtocol.VERSION,
		"mode_id": "frag",
		"level_id": "level01",
		"goal": 3,
		"participants": participants,
	}
	var session := get_tree().root.get_node("NetworkSession")
	var game_state := get_tree().root.get_node("GameStateManager")
	session.set("local_peer_id", NetworkProtocol.HOST_PEER_ID)
	session.set("state", 5) # NetworkSession.SessionState.LOADING
	session.set("_current_match", config.duplicate(true))
	await game_state.call("start_online_match", config)
	await get_tree().process_frame
	await get_tree().process_frame

	var characters := get_tree().get_nodes_in_group("characters")
	_expect(characters.size() == roster_size, "online roster spawns all %d participants" % roster_size)
	_expect(get_tree().get_nodes_in_group("human_players").size() == roster_size, "every online actor is marked human")
	_expect(get_tree().get_nodes_in_group("game_mode").size() == 1, "online match creates one mode")
	var host := session.call("get_character", NetworkProtocol.HOST_PEER_ID) as CharacterController
	var guest := session.call("get_character", NetworkProtocol.FIRST_GUEST_PEER_ID) as CharacterController
	_expect(host != null and host.is_locally_controlled(), "host owns the local character")
	_expect(guest != null and guest.control_source == CharacterController.ControlSource.REMOTE_INPUT, "host simulates guest input")

	# Only three character sprites exist, so colour is the sole way to tell six
	# players apart. Every participant must land on a distinct one.
	var seen_colors: Dictionary = {}
	var seen_positions: Dictionary = {}
	for index in roster_size:
		var participant := session.call("get_character", NetworkProtocol.HOST_PEER_ID + index) as CharacterController
		_expect(participant != null, "participant %d is registered with the session" % index)
		if participant == null:
			continue
		seen_colors[participant.character_color] = true
		seen_positions[participant.global_position] = true
		if index > 0:
			_expect(
				participant.control_source == CharacterController.ControlSource.REMOTE_INPUT,
				"host simulates remote input for participant %d" % index
			)
	_expect(seen_colors.size() == roster_size, "all %d participants get distinct colours" % roster_size)
	_expect(seen_positions.size() == roster_size, "all %d participants get distinct spawn points" % roster_size)
	var replica := CharacterController.new()
	replica.control_source = CharacterController.ControlSource.REPLICA
	get_tree().root.add_child(replica)
	replica.visuals.start_spawn_animation()
	replica._update_replica(CharacterVisuals.SPAWN_FADE_DURATION * 0.5)
	_expect(replica.modulate.a > 0.0, "remote replica advances its respawn fade")
	replica.queue_free()
	await get_tree().process_frame
	# On the host, the game-over UI is constructed while NetworkSession is
	# still PLAYING/LOADING and before its match-ended listener switches to
	# ENDED. It must nevertheless expose the online actions.
	var game_over := load("res://scenes/ui/game_over_scoreboard.tscn").instantiate() as Control
	get_tree().root.add_child(game_over)
	var rematch_button := game_over.get_node("%RestartButton") as Button
	var lobby_button := game_over.get_node("%LobbyButton") as Button
	_expect(rematch_button.text == "Rematch", "host game-over screen offers an online rematch")
	_expect(lobby_button.visible, "host game-over screen offers lobby settings")
	game_over.queue_free()
	await get_tree().process_frame
	if _failures == 0:
		print("[Tests] online match smoke test passed")
	get_tree().quit(_failures)

func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[Tests] FAILED: %s" % description)
