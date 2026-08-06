extends RefCounted
class_name NetworkProtocol

const VERSION := 1
const HOST_PEER_ID := 1
const GUEST_PEER_ID := 2
const ROOM_CODE_LENGTH := 8
const MAX_SIGNAL_MESSAGE_BYTES := 65_536
const INPUT_HISTORY_SIZE := 3
const SNAPSHOT_INTERVAL_TICKS := 3
const INPUT_STALE_MSEC := 250
const DISCONNECT_TIMEOUT_MSEC := 10_000
const HANDSHAKE_TIMEOUT_MSEC := 20_000
const CHARACTERS := ["tux", "beasty", "gopher"]
const FRAG_GOAL_MIN := 3
const FRAG_GOAL_MAX := 50

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

static func validate_participant(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var participant := value as Dictionary
	var peer_id := int(participant.get("peer_id", 0))
	var character_id := str(participant.get("character_id", ""))
	var color_slot := int(participant.get("color_slot", -1))
	return peer_id in [HOST_PEER_ID, GUEST_PEER_ID] \
		and character_id in CHARACTERS \
		and color_slot in [0, 1]

static func validate_match_config(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var config := value as Dictionary
	if int(config.get("protocol_version", 0)) != VERSION:
		return false
	if str(config.get("mode_id", "")) != "frag":
		return false
	if level_path_from_id(str(config.get("level_id", ""))) == "":
		return false
	var goal := int(config.get("goal", 0))
	if goal < FRAG_GOAL_MIN or goal > FRAG_GOAL_MAX:
		return false
	var participants: Variant = config.get("participants", [])
	if not participants is Array or participants.size() != 2:
		return false
	var seen: Dictionary = {}
	for participant in participants:
		if not validate_participant(participant):
			return false
		seen[int(participant.get("peer_id", 0))] = true
	return seen.has(HOST_PEER_ID) and seen.has(GUEST_PEER_ID)

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
