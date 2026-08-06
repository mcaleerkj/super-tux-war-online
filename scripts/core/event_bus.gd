extends Node

## Central event bus for decoupled communication across systems.
##
## All game events are emitted through this singleton to avoid tight coupling
## between systems. Systems can subscribe to events without knowing about each other.

## Game state events
@warning_ignore("unused_signal")
signal game_paused
@warning_ignore("unused_signal")
signal game_resumed
@warning_ignore("unused_signal")
signal game_state_changed(from_state: String, to_state: String)
@warning_ignore("unused_signal")
signal online_countdown_changed(value: int)

## Match events
@warning_ignore("unused_signal")
signal match_started
@warning_ignore("unused_signal")
signal match_ended(winner: CharacterController)
@warning_ignore("unused_signal")
signal win_condition_met(winner: CharacterController)
@warning_ignore("unused_signal")
signal character_killed(killer: CharacterController, victim: CharacterController)

## Character lifecycle/audio events
@warning_ignore("unused_signal")
signal character_jumped(character: CharacterController, turbo: bool)
@warning_ignore("unused_signal")
signal character_landed(character: CharacterController, impact_speed: float)
@warning_ignore("unused_signal")
signal character_stomped(attacker: CharacterController, victim: CharacterController)
@warning_ignore("unused_signal")
signal character_died(character: CharacterController)
@warning_ignore("unused_signal")
signal character_respawned(character: CharacterController)
@warning_ignore("unused_signal")
signal skid_started(character: CharacterController)
@warning_ignore("unused_signal")
signal skid_ended(character: CharacterController)

## Scene events
@warning_ignore("unused_signal")
signal scene_changing(from_path: String, to_path: String)
@warning_ignore("unused_signal")
signal scene_changed(scene_path: String)
@warning_ignore("unused_signal")
signal level_loaded(level_path: String)

## Mode events
@warning_ignore("unused_signal")
signal mode_score_changed(character: CharacterController, value: int)
@warning_ignore("unused_signal")
signal character_eliminated(character: CharacterController)
@warning_ignore("unused_signal")
signal match_timer_warning(seconds_left: int)
@warning_ignore("unused_signal")
signal time_expired
@warning_ignore("unused_signal")
signal coin_collected(character: CharacterController)
@warning_ignore("unused_signal")
signal hill_moved
@warning_ignore("unused_signal")
signal chicken_changed(character: CharacterController)

## UI events
@warning_ignore("unused_signal")
signal ui_notification(message: String, type: String)
