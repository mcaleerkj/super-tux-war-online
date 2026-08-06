extends GameMode

## Coin Collection: one coin at a time spawns at a random reachable spot;
## first to collect N coins wins. Kills score nothing but clear the field.

const COIN_SCENE := preload("res://scenes/objects/coin.tscn")
const MIN_SPAWN_DISTANCE := 160.0
const RESPAWN_DELAY := 0.7
const COIN_HOVER := 20.0
const AI_PUSH_INTERVAL := 0.4
const COIN_TIMEOUT := 20.0  # uncollected coins relocate (keeps matches moving)

var _coin: Area2D = null
var _respawn_timer := 0.0
var _push_timer := 0.0
var _coin_age := 0.0

func mode_id() -> StringName:
	return &"coin"

func display_name() -> String:
	return "Coin Collection"

func goal_label() -> String:
	return "Coins to Win"

func goal_min() -> int:
	return 5

func goal_max() -> int:
	return 50

func goal_default() -> int:
	return 20

func score_header() -> String:
	return "Coins"

func on_match_started() -> void:
	_spawn_coin()

func tick(delta: float) -> void:
	if _coin == null and _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_spawn_coin()
	elif is_instance_valid(_coin):
		_coin_age += delta
		if _coin_age >= COIN_TIMEOUT:
			_coin.queue_free()
			_coin = null
			_spawn_coin()
	_push_timer -= delta
	if _push_timer <= 0.0:
		_push_timer = AI_PUSH_INTERVAL
		_push_ai_goals()

func get_status_text() -> String:
	return "FIRST TO %d COINS" % goal

func _on_coin_collected(character: CharacterController) -> void:
	print("[Coins] collected by %s" % character.name)
	_coin = null
	add_score(character, 1)
	EventBus.coin_collected.emit(character)
	if get_score(character) >= goal:
		declare_winner(character)
		return
	_respawn_timer = RESPAWN_DELAY

## Spawn at a nav node >= MIN_SPAWN_DISTANCE from every living character
## (fallback: the node farthest from everyone). Nav nodes are exactly the
## reachable standing spots, so the AI can always path to the coin.
func _spawn_coin() -> void:
	var nav := get_tree().current_scene as LevelNavigation
	if nav == null or nav.nodes.is_empty():
		return
	var living := get_characters().filter(
		func(c: CharacterController) -> bool: return not c.is_despawned
	)
	var candidates: Array = []
	var fallback: LevelNavigation.NodeEntry = null
	var fallback_dist := -1.0
	for node: LevelNavigation.NodeEntry in nav.nodes:
		var min_dist := INF
		for character: CharacterController in living:
			min_dist = minf(min_dist, node.position.distance_to(character.global_position))
		if min_dist >= MIN_SPAWN_DISTANCE:
			candidates.append(node)
		if min_dist > fallback_dist:
			fallback_dist = min_dist
			fallback = node
	var chosen: LevelNavigation.NodeEntry = candidates.pick_random() if not candidates.is_empty() else fallback
	if chosen == null:
		return
	_coin = COIN_SCENE.instantiate()
	_coin.position = chosen.position + Vector2(0, -COIN_HOVER)
	_coin.collected.connect(_on_coin_collected)
	get_tree().current_scene.add_child(_coin)
	_coin_age = 0.0

func _push_ai_goals() -> void:
	var coin_alive := is_instance_valid(_coin)
	for character in get_characters():
		var cpu := cpu_of(character)
		if cpu == null:
			continue
		if coin_alive:
			cpu.set_move_goal(_coin.global_position)
		else:
			cpu.clear_move_goal()
