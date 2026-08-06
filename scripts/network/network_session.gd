extends Node

## Browser-only two-player session coordinator. Cloudflare is used only to
## exchange WebRTC offers/answers/ICE; gameplay travels over the data channel.

signal state_changed(state: int, status: String)
signal room_created(code: String)
signal lobby_changed(snapshot: Dictionary)
signal connection_error(message: String)
signal friend_disconnected(message: String)

enum SessionState {
	IDLE,
	CREATING,
	WAITING,
	CONNECTING,
	LOBBY,
	LOADING,
	COUNTDOWN,
	PLAYING,
	ENDED,
	ERROR,
}

var state: SessionState = SessionState.IDLE
var status_text: String = ""
var room_code: String = ""
var local_peer_id: int = 0

var _runtime_config: Dictionary = {}
var _base_url: String = ""
var _role_secret: String = ""
var _signal_ticket: String = ""
var _signal_url: String = ""
var _ice_servers: Array = []
var _lobby: Dictionary = {}
var _current_match: Dictionary = {}
var _characters: Dictionary = {}

var _http: HTTPRequest
var _websocket: WebSocketPeer
var _webrtc_connection: WebRTCPeerConnection
var _webrtc_peer: WebRTCMultiplayerPeer
var _websocket_was_open := false
var _offer_started := false

var _server_tick := 0
var _local_input_sequence := 0
var _local_input_history: Array[Dictionary] = []
var _last_received_guest_sequence := -1
var _last_processed_guest_sequence := -1
var _last_guest_input_msec := 0
var _last_data_received_msec := 0
var _host_scene_ready := false
var _guest_scene_ready := false
var _death_announced: Dictionary = {}
var _rematch_votes: Dictionary = {}
var _state_started_msec := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_runtime_config = NetworkProtocol.load_runtime_config()
	_base_url = str(_runtime_config.get("signaling_base_url", "")).strip_edges().trim_suffix("/")
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	EventBus.character_killed.connect(_on_character_killed)
	EventBus.character_died.connect(_on_character_died)
	EventBus.character_respawned.connect(_on_character_respawned)
	EventBus.mode_score_changed.connect(_on_mode_score_changed)
	EventBus.match_ended.connect(_on_match_ended)

func _process(_delta: float) -> void:
	_poll_signaling()
	if state in [SessionState.CREATING, SessionState.CONNECTING, SessionState.LOADING] \
			and Time.get_ticks_msec() - _state_started_msec > NetworkProtocol.HANDSHAKE_TIMEOUT_MSEC:
		if state == SessionState.LOADING:
			_abort_for_disconnect("The other player did not finish loading in time.")
		else:
			_fail("The online connection timed out. Please try again.")
		return
	if state == SessionState.PLAYING and _last_data_received_msec > 0:
		if Time.get_ticks_msec() - _last_data_received_msec > NetworkProtocol.DISCONNECT_TIMEOUT_MSEC:
			_abort_for_disconnect("The connection timed out. Keep the game window active while playing.")

func _physics_process(_delta: float) -> void:
	if state != SessionState.PLAYING or not is_host():
		return
	_server_tick += 1
	var now := Time.get_ticks_msec()
	if now - _last_guest_input_msec > NetworkProtocol.INPUT_STALE_MSEC:
		var guest := get_character(NetworkProtocol.GUEST_PEER_ID)
		if guest:
			guest.set_network_input({"sequence": _last_processed_guest_sequence})
	if _server_tick % NetworkProtocol.SNAPSHOT_INTERVAL_TICKS == 0:
		_send_snapshot()

func is_supported_platform() -> bool:
	return OS.has_feature("web")

func is_configured() -> bool:
	return _base_url.begins_with("http://") or _base_url.begins_with("https://")

func is_host() -> bool:
	return local_peer_id == NetworkProtocol.HOST_PEER_ID

func has_active_session() -> bool:
	return state not in [SessionState.IDLE, SessionState.ERROR]

func is_online_match() -> bool:
	return not _current_match.is_empty() and state in [
		SessionState.LOADING,
		SessionState.COUNTDOWN,
		SessionState.PLAYING,
		SessionState.ENDED,
	]

func lobby_snapshot() -> Dictionary:
	return _lobby.duplicate(true)

func current_match_config() -> Dictionary:
	return _current_match.duplicate(true)

func get_character(peer_id: int) -> CharacterController:
	var value: Variant = _characters.get(peer_id)
	return value as CharacterController if is_instance_valid(value) else null

func register_match_characters(characters: Dictionary) -> void:
	_characters = characters.duplicate()

func create_room() -> void:
	if not _can_begin_connection():
		return
	_reset_transport(false)
	local_peer_id = NetworkProtocol.HOST_PEER_ID
	_lobby = _default_lobby()
	_set_state(SessionState.CREATING, "Creating a private room...")
	var response := await _request_json(HTTPClient.METHOD_POST, "/v1/rooms", {
		"protocol_version": NetworkProtocol.VERSION,
	})
	if not _accept_room_response(response):
		return
	room_created.emit(room_code)
	_set_state(SessionState.WAITING, "Share the code with your friend")

func join_room(value: String) -> void:
	if not _can_begin_connection():
		return
	var code := NetworkProtocol.normalize_room_code(value)
	if not NetworkProtocol.is_valid_room_code(code):
		_fail("Enter a valid eight-character room code.")
		return
	_reset_transport(false)
	local_peer_id = NetworkProtocol.GUEST_PEER_ID
	room_code = code
	_set_state(SessionState.CONNECTING, "Joining room %s..." % code)
	var response := await _request_json(HTTPClient.METHOD_POST, "/v1/rooms/%s/join" % code, {
		"protocol_version": NetworkProtocol.VERSION,
	})
	if not _accept_room_response(response):
		return

func set_local_character(character_id: String) -> void:
	if character_id not in GameSettings.AVAILABLE_CHARACTERS or state != SessionState.LOBBY:
		return
	if is_host():
		_lobby["host_character"] = character_id
		_lobby["host_ready"] = false
		_lobby["guest_ready"] = false
		_broadcast_lobby()
	else:
		_request_guest_lobby_change.rpc_id(NetworkProtocol.HOST_PEER_ID, {"character_id": character_id})

func cycle_host_level(direction: int) -> void:
	if not is_host() or state != SessionState.LOBBY:
		return
	var ids: Array = NetworkProtocol.LEVELS.keys()
	ids.sort()
	var current := ids.find(str(_lobby.get("level_id", "level01")))
	_lobby["level_id"] = ids[(current + direction + ids.size()) % ids.size()]
	_clear_ready_and_broadcast()

func adjust_host_goal(delta: int) -> void:
	if not is_host() or state != SessionState.LOBBY:
		return
	var proto := ModeRegistry.get_prototype(&"frag")
	_lobby["goal"] = clampi(int(_lobby.get("goal", 10)) + delta, proto.goal_min(), proto.goal_max())
	_clear_ready_and_broadcast()

func set_ready(ready: bool) -> void:
	if state != SessionState.LOBBY:
		return
	if is_host():
		_lobby["host_ready"] = ready
		_broadcast_lobby()
	else:
		_request_guest_lobby_change.rpc_id(NetworkProtocol.HOST_PEER_ID, {"ready": ready})

func can_start_match() -> bool:
	return is_host() and state == SessionState.LOBBY \
		and bool(_lobby.get("host_ready", false)) \
		and bool(_lobby.get("guest_ready", false))

func start_online_match() -> void:
	if not can_start_match():
		return
	_current_match = _build_match_config()
	if not NetworkProtocol.validate_match_config(_current_match):
		_fail("The lobby produced an invalid match configuration.")
		return
	_host_scene_ready = false
	_guest_scene_ready = false
	_set_state(SessionState.LOADING, "Loading match...")
	_receive_load_match.rpc_id(NetworkProtocol.GUEST_PEER_ID, _current_match)
	GameStateManager.start_online_match(_current_match)

func notify_scene_ready() -> void:
	if state != SessionState.LOADING:
		return
	if is_host():
		_host_scene_ready = true
		_maybe_begin_countdown()
	else:
		_notify_guest_scene_ready.rpc_id(NetworkProtocol.HOST_PEER_ID)

func notify_match_started() -> void:
	_set_state(SessionState.PLAYING, "")
	_server_tick = 0
	_local_input_sequence = 0
	_local_input_history.clear()
	_last_received_guest_sequence = -1
	_last_processed_guest_sequence = -1
	_last_guest_input_msec = Time.get_ticks_msec()
	_last_data_received_msec = Time.get_ticks_msec()

func prepare_local_input(raw_input: Dictionary) -> Dictionary:
	var frame := raw_input.duplicate()
	if not is_host() and state == SessionState.PLAYING:
		_local_input_sequence += 1
		frame["sequence"] = _local_input_sequence
		frame["client_tick"] = _local_input_sequence
	return frame

func after_local_simulation(_character: CharacterController, input_frame: Dictionary) -> void:
	if is_host() or state != SessionState.PLAYING:
		return
	var sanitized := NetworkProtocol.sanitize_input(input_frame)
	if sanitized.is_empty():
		return
	_local_input_history.append(sanitized)
	var start := maxi(0, _local_input_history.size() - NetworkProtocol.INPUT_HISTORY_SIZE)
	var batch: Array = _local_input_history.slice(start)
	_submit_input_batch.rpc_id(NetworkProtocol.HOST_PEER_ID, batch)

func vote_rematch() -> void:
	if state != SessionState.ENDED:
		return
	_rematch_votes[local_peer_id] = true
	if is_host():
		_maybe_start_rematch()
	else:
		_submit_rematch_vote.rpc_id(NetworkProtocol.HOST_PEER_ID)
	lobby_changed.emit(_lobby_with_rematch())

func return_to_lobby() -> void:
	if not is_host() or state != SessionState.ENDED:
		return
	_receive_return_to_lobby.rpc_id(NetworkProtocol.GUEST_PEER_ID)
	_apply_return_to_lobby()

func leave_session(return_to_menu: bool = true) -> void:
	if multiplayer.has_multiplayer_peer() and local_peer_id != 0:
		_remote_leave.rpc()
	_reset_transport(true)
	if return_to_menu and not GameStateManager.is_in_menu():
		GameStateManager.return_to_menu()

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_guest_lobby_change(change: Dictionary) -> void:
	if not is_host() or multiplayer.get_remote_sender_id() != NetworkProtocol.GUEST_PEER_ID or state != SessionState.LOBBY:
		return
	if change.has("character_id"):
		var character_id := str(change.character_id)
		if character_id in GameSettings.AVAILABLE_CHARACTERS:
			_lobby["guest_character"] = character_id
			_lobby["host_ready"] = false
			_lobby["guest_ready"] = false
	if change.has("ready"):
		_lobby["guest_ready"] = bool(change.ready)
	_broadcast_lobby()

@rpc("authority", "call_remote", "reliable", 0)
func _receive_lobby(snapshot: Dictionary) -> void:
	if is_host():
		return
	_lobby = snapshot.duplicate(true)
	_set_state(SessionState.LOBBY, "Connected")
	lobby_changed.emit(lobby_snapshot())

@rpc("authority", "call_remote", "reliable", 0)
func _receive_load_match(config: Dictionary) -> void:
	if is_host() or not NetworkProtocol.validate_match_config(config):
		_fail("The host sent an incompatible match configuration.")
		return
	_current_match = config.duplicate(true)
	_host_scene_ready = false
	_guest_scene_ready = false
	_set_state(SessionState.LOADING, "Loading match...")
	GameStateManager.start_online_match(_current_match)

@rpc("any_peer", "call_remote", "reliable", 0)
func _notify_guest_scene_ready() -> void:
	if is_host() and multiplayer.get_remote_sender_id() == NetworkProtocol.GUEST_PEER_ID and state == SessionState.LOADING:
		_guest_scene_ready = true
		_maybe_begin_countdown()

@rpc("authority", "call_remote", "reliable", 0)
func _receive_begin_countdown() -> void:
	if not is_host() and state == SessionState.LOADING:
		_set_state(SessionState.COUNTDOWN, "Match starting...")
		GameStateManager.begin_online_countdown()

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _submit_input_batch(batch: Array) -> void:
	if not is_host() or state != SessionState.PLAYING \
		or multiplayer.get_remote_sender_id() != NetworkProtocol.GUEST_PEER_ID \
		or batch.size() > NetworkProtocol.INPUT_HISTORY_SIZE:
		return
	var latest: Dictionary = {}
	var jump_pressed := false
	var jump_released := false
	for value in batch:
		var frame := NetworkProtocol.sanitize_input(value)
		if frame.is_empty():
			continue
		var sequence := int(frame.sequence)
		if sequence <= _last_received_guest_sequence:
			continue
		_last_received_guest_sequence = sequence
		jump_pressed = jump_pressed or bool(frame.jump_pressed)
		jump_released = jump_released or bool(frame.jump_released)
		latest = frame
	if latest.is_empty():
		return
	latest["jump_pressed"] = jump_pressed
	latest["jump_released"] = jump_released
	_last_processed_guest_sequence = int(latest.sequence)
	_last_guest_input_msec = Time.get_ticks_msec()
	_last_data_received_msec = _last_guest_input_msec
	var guest := get_character(NetworkProtocol.GUEST_PEER_ID)
	if guest:
		guest.set_network_input(latest)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _receive_snapshot(states: Array) -> void:
	if is_host() or state != SessionState.PLAYING or states.size() > 2:
		return
	_last_data_received_msec = Time.get_ticks_msec()
	for value in states:
		if not value is Dictionary:
			continue
		var snapshot := value as Dictionary
		var peer_id := int(snapshot.get("peer_id", 0))
		if peer_id not in [NetworkProtocol.HOST_PEER_ID, NetworkProtocol.GUEST_PEER_ID]:
			continue
		if not snapshot.get("position") is Vector2 or not snapshot.get("velocity") is Vector2:
			continue
		var character := get_character(peer_id)
		if character == null:
			continue
		if peer_id == local_peer_id:
			var acknowledged := int(snapshot.get("ack", -1))
			var pending := NetworkProtocol.pending_inputs_after_ack(_local_input_history, acknowledged)
			_local_input_history = pending
			character.reconcile_authoritative_state(snapshot, pending)
		else:
			character.push_replica_snapshot(snapshot)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_lifecycle(event_type: String, victim_id: int, killer_id: int, position: Vector2) -> void:
	if is_host() or state != SessionState.PLAYING:
		return
	var victim := get_character(victim_id)
	if victim == null:
		return
	if event_type == "death":
		victim.global_position = position
		victim.apply_remote_death(get_character(killer_id))
	elif event_type == "respawn":
		victim.apply_remote_respawn(position)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_score(peer_id: int, value: int) -> void:
	if is_host() or state != SessionState.PLAYING:
		return
	var mode := get_tree().get_first_node_in_group("game_mode") as GameMode
	var character := get_character(peer_id)
	if mode and character:
		mode.apply_authoritative_score(character, value)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_match_end(winner_peer_id: int) -> void:
	if is_host() or state != SessionState.PLAYING:
		return
	_set_state(SessionState.ENDED, "Match complete")
	_rematch_votes.clear()
	GameStateManager.end_online_match(winner_peer_id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _submit_rematch_vote() -> void:
	if is_host() and state == SessionState.ENDED and multiplayer.get_remote_sender_id() == NetworkProtocol.GUEST_PEER_ID:
		_rematch_votes[NetworkProtocol.GUEST_PEER_ID] = true
		_maybe_start_rematch()

@rpc("authority", "call_remote", "reliable", 0)
func _receive_return_to_lobby() -> void:
	if not is_host():
		_apply_return_to_lobby()

@rpc("any_peer", "call_remote", "reliable", 0)
func _remote_leave() -> void:
	_abort_for_disconnect("Your friend left the room.")

func _can_begin_connection() -> bool:
	if not is_supported_platform():
		_fail("Online play is available in the browser build.")
		return false
	if not is_configured():
		_fail("The signaling service URL is not configured.")
		return false
	return true

func _request_json(method: HTTPClient.Method, path: String, payload: Dictionary) -> Dictionary:
	var body := JSON.stringify(payload)
	var err := _http.request(
		_base_url + path,
		PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
		method,
		body
	)
	if err != OK:
		return {"ok": false, "error": error_string(err)}
	var completed: Array = await _http.request_completed
	var response_code := int(completed[1])
	var response_body: PackedByteArray = completed[3]
	var parsed: Variant = JSON.parse_string(response_body.get_string_from_utf8())
	if response_code < 200 or response_code >= 300:
		var message := "Room service error (%d)." % response_code
		if parsed is Dictionary:
			message = str(parsed.get("error", message))
		return {"ok": false, "error": message}
	if not parsed is Dictionary:
		return {"ok": false, "error": "The room service returned invalid data."}
	var result := parsed as Dictionary
	result["ok"] = true
	return result

func _accept_room_response(response: Dictionary) -> bool:
	if not bool(response.get("ok", false)):
		_fail(str(response.get("error", "Could not connect to the room service.")))
		return false
	room_code = NetworkProtocol.normalize_room_code(str(response.get("room_code", room_code)))
	_role_secret = str(response.get("role_secret", ""))
	_signal_ticket = str(response.get("signal_ticket", ""))
	_signal_url = str(response.get("signaling_url", ""))
	var ice: Variant = response.get("ice_servers", [])
	_ice_servers = ice if ice is Array else []
	if not NetworkProtocol.is_valid_room_code(room_code) or _signal_ticket == "" or _signal_url == "":
		_fail("The room service returned incomplete connection data.")
		return false
	if not _start_webrtc():
		return false
	return true

func _start_webrtc() -> bool:
	_webrtc_peer = WebRTCMultiplayerPeer.new()
	var channels := [MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED]
	var err := _webrtc_peer.create_server(channels) if is_host() else _webrtc_peer.create_client(local_peer_id, channels)
	if err != OK:
		_fail("Could not initialize WebRTC multiplayer: %s" % error_string(err))
		return false
	_webrtc_connection = WebRTCPeerConnection.new()
	err = _webrtc_connection.initialize({"iceServers": _ice_servers})
	if err != OK:
		_fail("Could not initialize the browser peer connection: %s" % error_string(err))
		return false
	_webrtc_connection.session_description_created.connect(_on_session_description_created)
	_webrtc_connection.ice_candidate_created.connect(_on_ice_candidate_created)
	err = _webrtc_peer.add_peer(
		_webrtc_connection,
		NetworkProtocol.GUEST_PEER_ID if is_host() else NetworkProtocol.HOST_PEER_ID,
		100
	)
	if err != OK:
		_fail("Could not attach the WebRTC peer: %s" % error_string(err))
		return false
	multiplayer.multiplayer_peer = _webrtc_peer
	_websocket = WebSocketPeer.new()
	var separator := "&" if "?" in _signal_url else "?"
	err = _websocket.connect_to_url(_signal_url + separator + "ticket=" + _signal_ticket.uri_encode())
	if err != OK:
		_fail("Could not open the signaling connection: %s" % error_string(err))
		return false
	_websocket_was_open = false
	_offer_started = false
	return true

func _poll_signaling() -> void:
	if _websocket == null:
		return
	_websocket.poll()
	var socket_state := _websocket.get_ready_state()
	if socket_state == WebSocketPeer.STATE_OPEN:
		_websocket_was_open = true
		while _websocket.get_available_packet_count() > 0:
			var packet := _websocket.get_packet()
			if packet.size() > NetworkProtocol.MAX_SIGNAL_MESSAGE_BYTES:
				continue
			var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if parsed is Dictionary:
				_handle_signal_message(parsed)
	elif socket_state == WebSocketPeer.STATE_CLOSED and _websocket_was_open \
			and state in [SessionState.WAITING, SessionState.CONNECTING]:
		_fail("The signaling connection closed before WebRTC was ready.")

func _handle_signal_message(message: Dictionary) -> void:
	var type := str(message.get("type", ""))
	if type == "peer_joined":
		if is_host() and not _offer_started:
			_offer_started = true
			var err := _webrtc_connection.create_offer()
			if err != OK:
				_fail("Could not create a WebRTC offer: %s" % error_string(err))
	elif type in ["offer", "answer"]:
		var sdp := str(message.get("sdp", ""))
		if sdp.length() <= NetworkProtocol.MAX_SIGNAL_MESSAGE_BYTES:
			_webrtc_connection.set_remote_description(type, sdp)
	elif type == "ice":
		_webrtc_connection.add_ice_candidate(
			str(message.get("media", "")),
			int(message.get("index", 0)),
			str(message.get("candidate", ""))
		)
	elif type == "peer_left":
		if state in [SessionState.WAITING, SessionState.CONNECTING]:
			_abort_for_disconnect("Your friend left the room.")
	elif type == "error":
		_fail(str(message.get("message", "Signaling failed.")))

func _on_session_description_created(type: String, sdp: String) -> void:
	if _webrtc_connection.set_local_description(type, sdp) == OK:
		_send_signal({"type": type, "sdp": sdp})

func _on_ice_candidate_created(media: String, index: int, candidate: String) -> void:
	_send_signal({"type": "ice", "media": media, "index": index, "candidate": candidate})

func _send_signal(message: Dictionary) -> void:
	if _websocket and _websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_websocket.send_text(JSON.stringify(message))

func _on_peer_connected(peer_id: int) -> void:
	if peer_id not in [NetworkProtocol.HOST_PEER_ID, NetworkProtocol.GUEST_PEER_ID] or peer_id == local_peer_id:
		return
	_last_data_received_msec = Time.get_ticks_msec()
	_set_state(SessionState.LOBBY, "Connected")
	if is_host():
		_broadcast_lobby()

func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id in [NetworkProtocol.HOST_PEER_ID, NetworkProtocol.GUEST_PEER_ID] and has_active_session():
		_abort_for_disconnect("Your friend disconnected.")

func _default_lobby() -> Dictionary:
	var selected_path := NetworkProtocol.level_path_from_id("level01")
	var level_id := NetworkProtocol.level_id_from_path(selected_path)
	var selected_index := GameSettings.get_selected_level_index()
	var level_ids: Array = NetworkProtocol.LEVELS.keys()
	level_ids.sort()
	if selected_index >= 0 and selected_index < level_ids.size():
		level_id = str(level_ids[selected_index])
	return {
		"protocol_version": NetworkProtocol.VERSION,
		"room_code": room_code,
		"host_character": GameSettings.get_player_character(),
		"guest_character": "beasty",
		"level_id": level_id,
		"goal": GameSettings.get_goal_for_mode(&"frag"),
		"host_ready": false,
		"guest_ready": false,
	}

func _build_match_config() -> Dictionary:
	return {
		"protocol_version": NetworkProtocol.VERSION,
		"mode_id": "frag",
		"level_id": str(_lobby.get("level_id", "level01")),
		"goal": int(_lobby.get("goal", 10)),
		"participants": [
			{"peer_id": NetworkProtocol.HOST_PEER_ID, "character_id": str(_lobby.get("host_character", "tux")), "color_slot": 0},
			{"peer_id": NetworkProtocol.GUEST_PEER_ID, "character_id": str(_lobby.get("guest_character", "beasty")), "color_slot": 1},
		],
	}

func _clear_ready_and_broadcast() -> void:
	_lobby["host_ready"] = false
	_lobby["guest_ready"] = false
	_broadcast_lobby()

func _broadcast_lobby() -> void:
	if not is_host():
		return
	_lobby["room_code"] = room_code
	if multiplayer.has_multiplayer_peer() and state == SessionState.LOBBY:
		_receive_lobby.rpc_id(NetworkProtocol.GUEST_PEER_ID, _lobby)
	lobby_changed.emit(lobby_snapshot())

func _maybe_begin_countdown() -> void:
	if not is_host() or not _host_scene_ready or not _guest_scene_ready:
		return
	_set_state(SessionState.COUNTDOWN, "Match starting...")
	_receive_begin_countdown.rpc_id(NetworkProtocol.GUEST_PEER_ID)
	GameStateManager.begin_online_countdown()

func _send_snapshot() -> void:
	var states: Array = []
	for peer_id in [NetworkProtocol.HOST_PEER_ID, NetworkProtocol.GUEST_PEER_ID]:
		var character := get_character(peer_id)
		if character:
			states.append(character.capture_network_state(
				_server_tick,
				_last_processed_guest_sequence if peer_id == NetworkProtocol.GUEST_PEER_ID else -1
			))
	if states.size() == 2:
		_receive_snapshot.rpc_id(NetworkProtocol.GUEST_PEER_ID, states)

func _on_character_killed(killer: CharacterController, victim: CharacterController) -> void:
	if not is_host() or state != SessionState.PLAYING or not victim.is_human:
		return
	_death_announced[victim.get_instance_id()] = true
	_receive_lifecycle.rpc_id(
		NetworkProtocol.GUEST_PEER_ID,
		"death",
		victim.participant_id,
		killer.participant_id if killer else 0,
		victim.global_position
	)

func _on_character_died(character: CharacterController) -> void:
	if not is_host() or state != SessionState.PLAYING or not character.is_human:
		return
	var instance_id := character.get_instance_id()
	if _death_announced.erase(instance_id):
		return
	_receive_lifecycle.rpc_id(NetworkProtocol.GUEST_PEER_ID, "death", character.participant_id, 0, character.global_position)

func _on_character_respawned(character: CharacterController) -> void:
	if is_host() and state == SessionState.PLAYING and character.is_human:
		_receive_lifecycle.rpc_id(NetworkProtocol.GUEST_PEER_ID, "respawn", character.participant_id, 0, character.global_position)

func _on_mode_score_changed(character: CharacterController, value: int) -> void:
	if is_host() and state == SessionState.PLAYING and character.is_human:
		_receive_score.rpc_id(NetworkProtocol.GUEST_PEER_ID, character.participant_id, value)

func _on_match_ended(winner: CharacterController) -> void:
	if not is_online_match():
		return
	var winner_id := winner.participant_id if winner else 0
	if is_host():
		_receive_match_end.rpc_id(NetworkProtocol.GUEST_PEER_ID, winner_id)
	_set_state(SessionState.ENDED, "Match complete")
	_rematch_votes.clear()

func _maybe_start_rematch() -> void:
	if not is_host() or not _rematch_votes.has(NetworkProtocol.HOST_PEER_ID) \
		or not _rematch_votes.has(NetworkProtocol.GUEST_PEER_ID):
		return
	_lobby["host_ready"] = true
	_lobby["guest_ready"] = true
	_set_state(SessionState.LOBBY, "Starting rematch...")
	start_online_match()

func _lobby_with_rematch() -> Dictionary:
	var snapshot := lobby_snapshot()
	snapshot["host_rematch"] = _rematch_votes.has(NetworkProtocol.HOST_PEER_ID)
	snapshot["guest_rematch"] = _rematch_votes.has(NetworkProtocol.GUEST_PEER_ID)
	return snapshot

func _apply_return_to_lobby() -> void:
	_current_match.clear()
	_characters.clear()
	_rematch_votes.clear()
	_lobby["host_ready"] = false
	_lobby["guest_ready"] = false
	_set_state(SessionState.LOBBY, "Connected")
	GameStateManager.return_to_menu(true)

func _abort_for_disconnect(message: String) -> void:
	if state == SessionState.IDLE:
		return
	friend_disconnected.emit(message)
	var was_in_match := is_online_match()
	_reset_transport(true)
	if was_in_match:
		GameStateManager.abort_online_match(message)

func _reset_transport(reset_identity: bool) -> void:
	if _websocket:
		_websocket.close(1000, "Session ended")
	if _webrtc_connection:
		_webrtc_connection.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_websocket = null
	_webrtc_connection = null
	_webrtc_peer = null
	_websocket_was_open = false
	_offer_started = false
	_characters.clear()
	_current_match.clear()
	_local_input_history.clear()
	_death_announced.clear()
	_rematch_votes.clear()
	if reset_identity:
		room_code = ""
		local_peer_id = 0
		_role_secret = ""
		_signal_ticket = ""
		_signal_url = ""
		_ice_servers.clear()
		_lobby.clear()
		_set_state(SessionState.IDLE, "")

func _set_state(value: SessionState, status: String) -> void:
	state = value
	status_text = status
	_state_started_msec = Time.get_ticks_msec()
	state_changed.emit(state, status_text)

func _fail(message: String) -> void:
	push_warning("NetworkSession: %s" % message)
	_set_state(SessionState.ERROR, message)
	_reset_transport(false)
	# _reset_transport(false) deliberately preserves the ERROR state and the
	# human-readable message so the lobby can offer a clean retry.
	connection_error.emit(message)
