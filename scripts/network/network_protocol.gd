extends RefCounted
class_name NetworkProtocol

const VERSION := 2
const HOST_PEER_ID := 1
const FIRST_GUEST_PEER_ID := 2
const MAX_PLAYERS := 6
## Deprecated alias for the first guest slot. Retained while the session layer
## still addresses a single guest; remove once every send is roster-driven.
const GUEST_PEER_ID := FIRST_GUEST_PEER_ID
## Bots fill roster slots but never hold a network peer id. Keeping their ids in
## a disjoint range means a bot can never be mistaken for a connected peer when
## validating an RPC sender.
const BOT_ID_BASE := 101
const ROOM_CODE_LENGTH := 8
const MAX_SIGNAL_MESSAGE_BYTES := 65_536
const INPUT_HISTORY_SIZE := 3
const SNAPSHOT_INTERVAL_TICKS := 3
const INPUT_STALE_MSEC := 250
const DISCONNECT_TIMEOUT_MSEC := 10_000
const HANDSHAKE_TIMEOUT_MSEC := 20_000
const MAX_SIGNAL_RECONNECT_ATTEMPTS := 3
const MAX_CACHED_ICE_CANDIDATES := 64
const CHARACTERS := ["tux", "beasty", "gopher"]

## Modes whose host->guest state sync actually exists, with the goal bounds the
## wire will accept. Grows one entry at a time as each mode lands, and is
## deliberately separate from ModeRegistry.MODE_IDS so the lobby can never offer
## a mode the wire cannot yet carry.
##
## The bounds are duplicated from the mode prototypes rather than read from them:
## this validator must stay loadable without the autoloads (ModeRegistry pulls in
## GameMode, which references EventBus, which does not exist in a `--script`
## test run). `online_match_smoke.gd` asserts the two never drift apart.
const ONLINE_MODE_GOALS := {
	&"frag": {"min": 3, "max": 50},
}

static func is_online_mode(id: StringName) -> bool:
	return ONLINE_MODE_GOALS.has(id)

const LEVELS := {
	"level01": "res://scenes/levels/level01.tscn",
	"level02": "res://scenes/levels/level02.tscn",
	"level03": "res://scenes/levels/level03.tscn",
}

static func normalize_room_code(value: String) -> String:
	var result := value.strip_edges().to_upper().replace("-", "").replace(" ", "")
	return result

static func is_valid_room_code(value: String) -> bool:
	var code := normalize_room_code(value)
	if code.length() != ROOM_CODE_LENGTH:
		return false
	for character in code:
		if character not in "0123456789ABCDEFGHJKMNPQRSTVWXYZ":
			return false
	return true

static func level_id_from_path(path: String) -> String:
	for id: String in LEVELS:
		if LEVELS[id] == path:
			return id
	return ""

static func level_path_from_id(id: String) -> String:
	return str(LEVELS.get(id, ""))

## True for a network peer slot (host plus up to MAX_PLAYERS-1 guests).
static func is_peer_id(value: int) -> bool:
	return value >= HOST_PEER_ID and value <= MAX_PLAYERS

## True for a bot roster slot. Disjoint from the peer id range by construction.
static func is_bot_id(value: int) -> bool:
	return value >= BOT_ID_BASE and value < BOT_ID_BASE + MAX_PLAYERS

static func bot_id_for_slot(slot: int) -> int:
	return BOT_ID_BASE + slot

static func validate_participant(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var participant := value as Dictionary
	var participant_id := int(participant.get("peer_id", 0))
	var character_id := str(participant.get("character_id", ""))
	var color_slot := int(participant.get("color_slot", -1))
	if character_id not in CHARACTERS:
		return false
	if color_slot < 0 or color_slot >= MAX_PLAYERS:
		return false
	# A bot must carry a bot id and a human must carry a peer id, so the roster
	# alone is enough to decide whether an RPC sender is a real participant.
	if bool(participant.get("is_bot", false)):
		return is_bot_id(participant_id)
	return is_peer_id(participant_id)

static func validate_match_config(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var config := value as Dictionary
	if int(config.get("protocol_version", 0)) != VERSION:
		return false
	var mode_id := StringName(str(config.get("mode_id", "")))
	if not is_online_mode(mode_id):
		return false
	if level_path_from_id(str(config.get("level_id", ""))) == "":
		return false
	var bounds: Dictionary = ONLINE_MODE_GOALS[mode_id]
	var goal := int(config.get("goal", 0))
	if goal < int(bounds["min"]) or goal > int(bounds["max"]):
		return false
	var participants: Variant = config.get("participants", [])
	if not participants is Array:
		return false
	var roster := participants as Array
	if roster.size() < 2 or roster.size() > MAX_PLAYERS:
		return false
	var seen: Dictionary = {}
	for participant in roster:
		if not validate_participant(participant):
			return false
		var participant_id := int((participant as Dictionary).get("peer_id", 0))
		if seen.has(participant_id):
			return false
		seen[participant_id] = true
	return seen.has(HOST_PEER_ID)

static func sanitize_input(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var frame := value as Dictionary
	var sequence := int(frame.get("sequence", -1))
	var client_tick := int(frame.get("client_tick", -1))
	if sequence < 0 or client_tick < 0:
		return {}
	return {
		"sequence": sequence,
		"client_tick": client_tick,
		"move_x": clampf(float(frame.get("move_x", 0.0)), -1.0, 1.0),
		"run": bool(frame.get("run", false)),
		"down": bool(frame.get("down", false)),
		"jump_pressed": bool(frame.get("jump_pressed", false)),
		"jump_released": bool(frame.get("jump_released", false)),
	}

static func pending_inputs_after_ack(history: Array[Dictionary], acknowledged_sequence: int) -> Array[Dictionary]:
	var pending: Array[Dictionary] = []
	for frame in history:
		if int(frame.get("sequence", -1)) > acknowledged_sequence:
			pending.append(frame)
	return pending

static func wrap_aware_delta(from: Vector2, to: Vector2, world_size: Vector2) -> Vector2:
	var result := to - from
	if world_size.x > 0.0 and absf(result.x) > world_size.x * 0.5:
		result.x -= signf(result.x) * world_size.x
	if world_size.y > 0.0 and absf(result.y) > world_size.y * 0.5:
		result.y -= signf(result.y) * world_size.y
	return result

static func load_runtime_config() -> Dictionary:
	var file := FileAccess.open("res://network_config.json", FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}

## Picks the signaling service for the page the build is served from. The
## committed config carries the deployed URL so every export is playable by
## default; a build served from a development host transparently switches to
## the local Worker instead of needing the file rewritten before export.
static func resolve_signaling_base_url(config: Dictionary) -> String:
	var deployed := _clean_base_url(config.get("signaling_base_url", ""))
	var local := _clean_base_url(config.get("local_signaling_base_url", ""))
	if local == "" or not OS.has_feature("web"):
		return deployed
	var hosts: Variant = config.get("local_hosts", [])
	if not hosts is Array or (hosts as Array).is_empty():
		return deployed
	var hostname: Variant = JavaScriptBridge.eval("window.location.hostname", true)
	return local if str(hostname) in hosts else deployed

static func _clean_base_url(value: Variant) -> String:
	return str(value).strip_edges().trim_suffix("/")
