class_name ModeRegistry

## Static registry of game modes: ordered ids -> scripts. Not an autoload.
##
## Prototypes are metadata-only instances for menu queries (display names,
## goal ranges) -- they must NEVER be added to the tree.

const MODE_IDS: Array[StringName] = [&"frag", &"time", &"classic", &"coin", &"koth", &"chicken"]

const _SCRIPTS := {
	&"frag": "res://scripts/modes/frag_mode.gd",
	&"time": "res://scripts/modes/time_mode.gd",
	&"classic": "res://scripts/modes/classic_mode.gd",
	&"coin": "res://scripts/modes/coin_mode.gd",
	&"koth": "res://scripts/modes/koth_mode.gd",
	&"chicken": "res://scripts/modes/chicken_mode.gd",
}

static var _prototypes: Dictionary = {}

static func is_valid(id: StringName) -> bool:
	return _SCRIPTS.has(id)

static func create(id: StringName) -> GameMode:
	var path: String = _SCRIPTS.get(id, _SCRIPTS[&"frag"])
	return (load(path) as GDScript).new()

static func get_prototype(id: StringName) -> GameMode:
	if not _prototypes.has(id):
		_prototypes[id] = create(id)
	return _prototypes[id]
