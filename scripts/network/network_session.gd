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
var _offer_started := false
## Bumped on every teardown so a coroutine that resumes after an awaited HTTP
## round trip can tell whether the session it started for is still the current
## one. Without it, leaving the lobby mid-request lets the response reconfigure
## a session the player already abandoned.
var _session_epoch := 0
var _signal_reconnect_attempts := 0
var _signal_reconnecting := false
var _local_description: Dictionary = {}
var _local_ice_candidates: Array[Dictionary] = []
var _remote_description_sdp := ""

var _server_tick := 0
var _local_input_sequence := 0
var _local_input_history: Array[Dictionary] = []
## peer_id -> {received, processed, input_msec, data_msec}. Per remote peer
## rather than a single set of counters: with several guests, one chatty peer
## must not refresh the liveness clock for another that has gone silent, and
## each guest needs its own input sequence acknowledged.
var _remote_tracks: Dictionary = {}
## peer_id -> bool, including the local peer. Replaces the host/guest pair so
## the countdown can wait on however many peers are actually in the match.
var _scene_ready: Dictionary = {}
var _death_announced: Dictionary = {}
var _rematch_votes: Dictionary = {}
var _state_started_msec := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_runtime_config = NetworkProtocol.load_runtime_config()
	_base_url = NetworkProtocol.resolve_signaling_base_url(_runtime_config)
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
	if state == SessionState.PLAYING:
		# Still fatal for any silent peer, matching today's behaviour. Splitting
		# this into "drop that guest, keep playing" is the next step.
		for peer_id: int in _remote_tracks.keys():
			var track: Dictionary = _remote_tracks[peer_id]
			var since := int(track.get("data_msec", 0))
			if since > 0 and Time.get_ticks_msec() - since > NetworkProtocol.DISCONNECT_TIMEOUT_MSEC:
				_abort_for_disconnect("The connection timed out. Keep the game window active while playing.")
				return

func _physics_process(_delta: float) -> void:
	if state != SessionState.PLAYING or not is_host():
		return
	_server_tick += 1
	var now := Time.get_ticks_msec()
	# A peer whose packets have stopped arriving keeps its last input applied
	# rather than drifting, so re-assert the acknowledged sequence for each.
	for peer_id: int in _remote_tracks.keys():
		var track: Dictionary = _remote_tracks[peer_id]
		if now - int(track.get("input_msec", 0)) <= NetworkProtocol.INPUT_STALE_MSEC:
			continue
		var character := get_character(peer_id)
		if character:
			character.set_network_input({"sequence": int(track.get("processed", -1))})
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

## True when `peer_id` is a connected remote peer this session recognises. Used
## in place of the old "is it peer 2" checks: with several guests, the question
## an RPC handler needs answered is membership, not identity. Bots never pass,
## because nothing ever arrives from them over the wire.
func _is_remote_participant(peer_id: int) -> bool:
	if peer_id == 0 or peer_id == local_peer_id or not NetworkProtocol.is_peer_id(peer_id):
		return false
	return peer_id in multiplayer.get_peers()

## Peer ids of everyone in the lobby roster, humans only, host first.
func _lobby_peer_ids() -> Array:
	var ids: Array = []
	for player in _lobby_players():
		if not bool((player as Dictionary).get("is_bot", false)):
			ids.append(int((player as Dictionary).get("peer_id", 0)))
	return ids

func _lobby_players() -> Array:
	var players: Variant = _lobby.get("players", [])
	return players if players is Array else []

func _lobby_player(peer_id: int) -> Dictionary:
	for player in _lobby_players():
		if int((player as Dictionary).get("peer_id", 0)) == peer_id:
			return player
	return {}

func create_room() -> void:
	if not _can_begin_connection():
		return
	_reset_transport(false)
	var epoch := _session_epoch
	local_peer_id = NetworkProtocol.HOST_PEER_ID
	_lobby = _default_lobby()
	_set_state(SessionState.CREATING, "Creating a private room...")
	var response := await _request_json(HTTPClient.METHOD_POST, "/v1/rooms", {
		"protocol_version": NetworkProtocol.VERSION,
	})
	if epoch != _session_epoch:
		return
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
	var epoch := _session_epoch
	local_peer_id = NetworkProtocol.GUEST_PEER_ID
	room_code = code
	_set_state(SessionState.CONNECTING, "Joining room %s..." % code)
	var response := await _request_json(HTTPClient.METHOD_POST, "/v1/rooms/%s/join" % code, {
		"protocol_version": NetworkProtocol.VERSION,
	})
	if epoch != _session_epoch:
		return
	if not _accept_room_response(response):
		return

func set_local_character(character_id: String) -> void:
	if character_id not in GameSettings.AVAILABLE_CHARACTERS or state != SessionState.LOBBY:
		return
	if is_host():
		_apply_player_change(local_peer_id, {"character_id": character_id})
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
		_apply_player_change(local_peer_id, {"ready": ready})
		_broadcast_lobby()
	else:
		_request_guest_lobby_change.rpc_id(NetworkProtocol.HOST_PEER_ID, {"ready": ready})

## Applies one player's lobby change in place. Changing a character re-arms the
## whole roster, so nobody starts a match with a line-up they did not agree to.
func _apply_player_change(peer_id: int, change: Dictionary) -> void:
	var player := _lobby_player(peer_id)
	if player.is_empty():
		return
	if change.has("character_id"):
		var character_id := str(change["character_id"])
		if character_id in GameSettings.AVAILABLE_CHARACTERS:
			player["character_id"] = character_id
			for other in _lobby_players():
				(other as Dictionary)["ready"] = bool((other as Dictionary).get("is_bot", false))
	if change.has("ready"):
		player["ready"] = bool(change["ready"])

func can_start_match() -> bool:
	if not is_host() or state != SessionState.LOBBY:
		return false
	var players := _lobby_players()
	if players.size() < 2 or players.size() > NetworkProtocol.MAX_PLAYERS:
		return false
	for player in players:
		if not bool((player as Dictionary).get("ready", false)):
			return false
	return true

func start_online_match() -> void:
	if not can_start_match():
		return
	_current_match = _build_match_config()
	if not NetworkProtocol.validate_match_config(_current_match):
		_fail("The lobby produced an invalid match configuration.")
		return
	_scene_ready.clear()
	_set_state(SessionState.LOADING, "Loading match...")
	_receive_load_match.rpc(_current_match)
	GameStateManager.start_online_match(_current_match)

func notify_scene_ready() -> void:
	if state != SessionState.LOADING:
		return
	if is_host():
		_scene_ready[local_peer_id] = true
		_maybe_begin_countdown()
	else:
		_notify_guest_scene_ready.rpc_id(NetworkProtocol.HOST_PEER_ID)

func notify_match_started() -> void:
	_set_state(SessionState.PLAYING, "")
	_server_tick = 0
	_local_input_sequence = 0
	_local_input_history.clear()
	var now := Time.get_ticks_msec()
	_remote_tracks.clear()
	for peer_id in multiplayer.get_peers():
		_reset_track(int(peer_id), now)

## Per-remote-peer counters. Created on demand so a peer that connects mid-lobby
## is tracked without a separate registration step.
func _reset_track(peer_id: int, now: int) -> void:
	_remote_tracks[peer_id] = {"received": -1, "processed": -1, "input_msec": now, "data_msec": now}

func _track(peer_id: int) -> Dictionary:
	if not _remote_tracks.has(peer_id):
		_reset_track(peer_id, Time.get_ticks_msec())
	return _remote_tracks[peer_id]

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
	_receive_return_to_lobby.rpc()
	_apply_return_to_lobby()

func leave_session(return_to_menu: bool = true) -> void:
	if multiplayer.has_multiplayer_peer() and local_peer_id != 0:
		_remote_leave.rpc()
	_reset_transport(true)
	if return_to_menu and not GameStateManager.is_in_menu():
		GameStateManager.return_to_menu()

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_guest_lobby_change(change: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not is_host() or not _is_remote_participant(sender) or state != SessionState.LOBBY:
		return
	_apply_player_change(sender, change)
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
	_scene_ready.clear()
	_set_state(SessionState.LOADING, "Loading match...")
	GameStateManager.start_online_match(_current_match)

@rpc("any_peer", "call_remote", "reliable", 0)
func _notify_guest_scene_ready() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if is_host() and _is_remote_participant(sender) and state == SessionState.LOADING:
		_scene_ready[sender] = true
		_maybe_begin_countdown()

@rpc("authority", "call_remote", "reliable", 0)
func _receive_begin_countdown() -> void:
	if not is_host() and state == SessionState.LOADING:
		_set_state(SessionState.COUNTDOWN, "Match starting...")
		GameStateManager.begin_online_countdown()

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _submit_input_batch(batch: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not is_host() or state != SessionState.PLAYING \
		or not _is_remote_participant(sender) \
		or batch.size() > NetworkProtocol.INPUT_HISTORY_SIZE:
		return
	var track := _track(sender)
	# Liveness is refreshed before the "nothing new here" return below: a peer
	# that is despawned, or whose frames are all replays, is still demonstrably
	# connected, and treating that as silence would time it out mid-match.
	track["data_msec"] = Time.get_ticks_msec()
	var latest: Dictionary = {}
	var jump_pressed := false
	var jump_released := false
	for value in batch:
		var frame := NetworkProtocol.sanitize_input(value)
		if frame.is_empty():
			continue
		var sequence := int(frame.sequence)
		if sequence <= int(track.get("received", -1)):
			continue
		track["received"] = sequence
		jump_pressed = jump_pressed or bool(frame.jump_pressed)
		jump_released = jump_released or bool(frame.jump_released)
		latest = frame
	if latest.is_empty():
		return
	latest["jump_pressed"] = jump_pressed
	latest["jump_released"] = jump_released
	track["processed"] = int(latest.sequence)
	track["input_msec"] = Time.get_ticks_msec()
	var character := get_character(sender)
	if character:
		character.set_network_input(latest)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _receive_snapshot(states: Array) -> void:
	if is_host() or state != SessionState.PLAYING or states.size() > NetworkProtocol.MAX_PLAYERS:
		return
	_track(NetworkProtocol.HOST_PEER_ID)["data_msec"] = Time.get_ticks_msec()
	for value in states:
		if not value is Dictionary:
			continue
		var snapshot := value as Dictionary
		var peer_id := int(snapshot.get("peer_id", 0))
		if not _characters.has(peer_id):
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
	var sender := multiplayer.get_remote_sender_id()
	if is_host() and state == SessionState.ENDED and _is_remote_participant(sender):
		_rematch_votes[sender] = true
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

func _request_json(
	method: HTTPClient.Method,
	path: String,
	payload: Dictionary,
	extra_headers: PackedStringArray = PackedStringArray()
) -> Dictionary:
	var body := JSON.stringify(payload)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	headers.append_array(extra_headers)
	var err := _http.request(_base_url + path, headers, method, body)
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
	_offer_started = false
	return _open_signaling_socket()

func _open_signaling_socket() -> bool:
	_websocket = WebSocketPeer.new()
	var separator := "&" if "?" in _signal_url else "?"
	var err := _websocket.connect_to_url(_signal_url + separator + "ticket=" + _signal_ticket.uri_encode())
	if err != OK:
		_websocket = null
		_fail("Could not open the signaling connection: %s" % error_string(err))
		return false
	return true

func _poll_signaling() -> void:
	if _websocket == null:
		return
	_websocket.poll()
	var socket_state := _websocket.get_ready_state()
	if socket_state == WebSocketPeer.STATE_OPEN:
		while _websocket.get_available_packet_count() > 0:
			var packet := _websocket.get_packet()
			if packet.size() > NetworkProtocol.MAX_SIGNAL_MESSAGE_BYTES:
				continue
			var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if parsed is Dictionary:
				_handle_signal_message(parsed)
	elif socket_state == WebSocketPeer.STATE_CLOSED \
			and state in [SessionState.WAITING, SessionState.CONNECTING]:
		# Covers both a dropped socket and one that never opened. A host sitting
		# in WAITING has no handshake timeout, so the retry cap is what stops
		# this from spinning silently forever.
		_begin_signaling_reconnect()

## Signaling tickets are single-use, so a socket that drops before WebRTC is
## established cannot simply redial. Trade the role secret for a fresh ticket
## and resume the exchange rather than forcing both players onto a new room.
func _begin_signaling_reconnect() -> void:
	if _signal_reconnecting:
		return
	_websocket = null
	if _role_secret == "" or _signal_reconnect_attempts >= NetworkProtocol.MAX_SIGNAL_RECONNECT_ATTEMPTS:
		_fail("The signaling connection closed before WebRTC was ready.")
		return
	_signal_reconnecting = true
	_signal_reconnect_attempts += 1
	_resume_signaling.call_deferred()

func _resume_signaling() -> void:
	var epoch := _session_epoch
	var response := await _request_json(
		HTTPClient.METHOD_POST,
		"/v1/rooms/%s/signal-ticket" % room_code,
		{"protocol_version": NetworkProtocol.VERSION},
		PackedStringArray(["Authorization: Bearer " + _role_secret])
	)
	if epoch != _session_epoch:
		return
	_signal_reconnecting = false
	# WebRTC may have completed while the ticket was in flight, in which case
	# signaling is no longer needed at all.
	if state not in [SessionState.WAITING, SessionState.CONNECTING]:
		return
	var ticket := str(response.get("signal_ticket", ""))
	if not bool(response.get("ok", false)) or ticket == "":
		_fail(str(response.get("error", "Lost the signaling connection and could not resume.")))
		return
	_signal_ticket = ticket
	_open_signaling_socket()

func _handle_signal_message(message: Dictionary) -> void:
	var type := str(message.get("type", ""))
	if type == "peer_joined":
		if is_host() and not _offer_started:
			_offer_started = true
			var err := _webrtc_connection.create_offer()
			if err != OK:
				_fail("Could not create a WebRTC offer: %s" % error_string(err))
		else:
			# Reaching here a second time means signaling was re-established. The
			# peer may have missed whatever we produced while the socket was
			# down, so replay it instead of renegotiating the connection.
			_replay_local_signals()
	elif type in ["offer", "answer"]:
		var sdp := str(message.get("sdp", ""))
		if sdp.length() > NetworkProtocol.MAX_SIGNAL_MESSAGE_BYTES or sdp == _remote_description_sdp:
			return  # Oversized, or a replay of the description already applied.
		# Only the host offers and only the guest answers. Anything else is a
		# confused or hostile peer trying to push us into SDP glare.
		if (type == "offer") == is_host():
			return
		_remote_description_sdp = sdp
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
		_local_description = {"type": type, "sdp": sdp}
		_send_signal(_local_description)

func _on_ice_candidate_created(media: String, index: int, candidate: String) -> void:
	var message := {"type": "ice", "media": media, "index": index, "candidate": candidate}
	if _local_ice_candidates.size() < NetworkProtocol.MAX_CACHED_ICE_CANDIDATES:
		_local_ice_candidates.append(message)
	_send_signal(message)

## Re-sends everything this peer has produced so far. Duplicate descriptions are
## dropped on receipt and duplicate ICE candidates are harmless to WebRTC.
func _replay_local_signals() -> void:
	if _local_description.is_empty():
		return
	_send_signal(_local_description)
	for candidate in _local_ice_candidates:
		_send_signal(candidate)

func _send_signal(message: Dictionary) -> void:
	if _websocket and _websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_websocket.send_text(JSON.stringify(message))

func _on_peer_connected(peer_id: int) -> void:
	if not NetworkProtocol.is_peer_id(peer_id) or peer_id == local_peer_id:
		return
	_reset_track(peer_id, Time.get_ticks_msec())
	_set_state(SessionState.LOBBY, "Connected")
	if is_host():
		_add_lobby_player(peer_id)
		_broadcast_lobby()

func _on_peer_disconnected(peer_id: int) -> void:
	if NetworkProtocol.is_peer_id(peer_id) and has_active_session():
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
		"mode_id": "frag",
		"level_id": level_id,
		"goal": GameSettings.get_goal_for_mode(&"frag"),
		"players": [_new_player(NetworkProtocol.HOST_PEER_ID, GameSettings.get_player_character(), false)],
	}

## Roster entries are ordered by join, and colour slot is assigned by position,
## which is what keeps six players visually distinct given only three sprites.
func _new_player(peer_id: int, character_id: String, is_bot: bool) -> Dictionary:
	return {
		"peer_id": peer_id,
		"character_id": character_id,
		"color_slot": _next_free_color_slot(),
		"ready": is_bot,
		"is_bot": is_bot,
	}

func _next_free_color_slot() -> int:
	var taken: Dictionary = {}
	for player in _lobby_players():
		taken[int((player as Dictionary).get("color_slot", -1))] = true
	for slot in NetworkProtocol.MAX_PLAYERS:
		if not taken.has(slot):
			return slot
	return 0

func _add_lobby_player(peer_id: int) -> void:
	if not _lobby_player(peer_id).is_empty():
		return
	var players := _lobby_players()
	if players.size() >= NetworkProtocol.MAX_PLAYERS:
		return
	players.append(_new_player(peer_id, "beasty", false))
	_lobby["players"] = players

func _remove_lobby_player(peer_id: int) -> void:
	var players := _lobby_players()
	for index in range(players.size() - 1, -1, -1):
		if int((players[index] as Dictionary).get("peer_id", 0)) == peer_id:
			players.remove_at(index)
	_lobby["players"] = players

func _build_match_config() -> Dictionary:
	var participants: Array = []
	for player in _lobby_players():
		var entry := player as Dictionary
		participants.append({
			"peer_id": int(entry.get("peer_id", 0)),
			"character_id": str(entry.get("character_id", "tux")),
			"color_slot": int(entry.get("color_slot", 0)),
			"is_bot": bool(entry.get("is_bot", false)),
		})
	return {
		"protocol_version": NetworkProtocol.VERSION,
		"mode_id": str(_lobby.get("mode_id", "frag")),
		"level_id": str(_lobby.get("level_id", "level01")),
		"goal": int(_lobby.get("goal", 10)),
		"participants": participants,
	}

## Bots are always ready; only humans have to re-confirm after a settings change.
func _set_all_ready(ready: bool) -> void:
	for player in _lobby_players():
		var entry := player as Dictionary
		entry["ready"] = ready or bool(entry.get("is_bot", false))

func _clear_ready_and_broadcast() -> void:
	_set_all_ready(false)
	_broadcast_lobby()

func _broadcast_lobby() -> void:
	if not is_host():
		return
	_lobby["room_code"] = room_code
	if multiplayer.has_multiplayer_peer() and state == SessionState.LOBBY:
		_receive_lobby.rpc(_lobby)
	lobby_changed.emit(lobby_snapshot())

func _maybe_begin_countdown() -> void:
	if not is_host() or state != SessionState.LOADING:
		return
	if not bool(_scene_ready.get(local_peer_id, false)):
		return
	for peer_id in multiplayer.get_peers():
		if not bool(_scene_ready.get(int(peer_id), false)):
			return
	_set_state(SessionState.COUNTDOWN, "Match starting...")
	_receive_begin_countdown.rpc()
	GameStateManager.begin_online_countdown()

func _send_snapshot() -> void:
	var states: Array = []
	for peer_id: int in _characters:
		var character := get_character(peer_id)
		if character == null:
			continue
		# Each entry carries that peer's own acknowledged input sequence, which
		# is what lets one broadcast serve every guest: a guest reconciles
		# against its own entry and treats the rest as replicas. The host and
		# bots acknowledge nothing, so they carry -1.
		var track: Dictionary = _remote_tracks.get(peer_id, {})
		states.append(character.capture_network_state(_server_tick, int(track.get("processed", -1))))
	if states.size() >= 2:
		_receive_snapshot.rpc(states)

func _on_character_killed(killer: CharacterController, victim: CharacterController) -> void:
	if not is_host() or state != SessionState.PLAYING or not victim.is_human:
		return
	_death_announced[victim.get_instance_id()] = true
	_receive_lifecycle.rpc(
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
	_receive_lifecycle.rpc("death", character.participant_id, 0, character.global_position)

func _on_character_respawned(character: CharacterController) -> void:
	if is_host() and state == SessionState.PLAYING and character.is_human:
		_receive_lifecycle.rpc("respawn", character.participant_id, 0, character.global_position)

func _on_mode_score_changed(character: CharacterController, value: int) -> void:
	if is_host() and state == SessionState.PLAYING and character.is_human:
		_receive_score.rpc(character.participant_id, value)

func _on_match_ended(winner: CharacterController) -> void:
	if not is_online_match():
		return
	var winner_id := winner.participant_id if winner else 0
	if is_host():
		_receive_match_end.rpc(winner_id)
	_set_state(SessionState.ENDED, "Match complete")
	_rematch_votes.clear()

func _maybe_start_rematch() -> void:
	if not is_host():
		return
	# Every human still in the room has to want it. A peer that left is no
	# longer in the roster and so cannot hold the rematch hostage.
	for peer_id in _lobby_peer_ids():
		if not _rematch_votes.has(peer_id):
			return
	_set_all_ready(true)
	_set_state(SessionState.LOBBY, "Starting rematch...")
	start_online_match()

func _lobby_with_rematch() -> Dictionary:
	var snapshot := lobby_snapshot()
	snapshot["rematch_votes"] = _rematch_votes.keys()
	return snapshot

func _apply_return_to_lobby() -> void:
	_current_match.clear()
	_characters.clear()
	_rematch_votes.clear()
	_set_all_ready(false)
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
	# Invalidates any awaited request still in flight for the previous session.
	_session_epoch += 1
	if _websocket:
		_websocket.close(1000, "Session ended")
	if _webrtc_connection:
		_webrtc_connection.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_websocket = null
	_webrtc_connection = null
	_webrtc_peer = null
	_offer_started = false
	_signal_reconnecting = false
	_signal_reconnect_attempts = 0
	_local_description.clear()
	_local_ice_candidates.clear()
	_remote_description_sdp = ""
	_characters.clear()
	_current_match.clear()
	_local_input_history.clear()
	_death_announced.clear()
	_rematch_votes.clear()
	_remote_tracks.clear()
	_scene_ready.clear()
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
