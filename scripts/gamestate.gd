# GameState.gd
extends Node

signal rocks_broken_changed(count: int)   # you already use this
signal goal_changed(max_rocks: int)       # UI can listen for the target
signal level_won                          # fire once when we reach/exceed target

var rocks_broken: int = 0
var max_rocks: int = 0
var won: bool = false

func add_rock_broken(count: int = 1) -> void:
	if won:
		return
	rocks_broken += count
	rocks_broken_changed.emit(rocks_broken)
	if max_rocks > 0 and rocks_broken >= max_rocks:
		won = true
		level_won.emit()

func reset_for_level(target_max_rocks: int) -> void:
	max_rocks = max(0, target_max_rocks)
	rocks_broken = 0
	won = false
	goal_changed.emit(max_rocks)
	rocks_broken_changed.emit(rocks_broken)

# Optional: manual setter if you want to change the goal without resetting progress
func set_goal(target_max_rocks: int) -> void:
	max_rocks = max(0, target_max_rocks)
	goal_changed.emit(max_rocks)
