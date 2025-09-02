# GameState.gd
extends Node

signal rocks_broken_changed(count: int)   # you already use this
signal goal_changed(max_rocks: int)       # UI can listen for the target
signal level_won                          # fire once when we reach/exceed target

var rocks_broken: int = 0
var max_rocks: int = 0
var actual_max_rocks: int = 0
var won: bool = false
var winning_percentage: float = 0.8

func add_rock_broken(count: int = 1) -> void:
	if won:
		return
	rocks_broken += count
	rocks_broken_changed.emit(rocks_broken)
	if max_rocks > 0 and rocks_broken >= max_rocks:
		won = true
		level_won.emit()
		
func add_max_rocks(more_rocks: int) -> void:
	if won:
		return
	actual_max_rocks = actual_max_rocks + more_rocks
	max_rocks = actual_max_rocks
	reset_for_level(max_rocks)

func reset_for_level(target_max_rocks: int) -> void:
	if won:
		return
	max_rocks = max(0, target_max_rocks) 
	actual_max_rocks = max_rocks
	max_rocks = floor(max_rocks * winning_percentage)
	rocks_broken = 0
	won = false
	goal_changed.emit(max_rocks)
	rocks_broken_changed.emit(rocks_broken)

# Optional: manual setter if you want to change the goal without resetting progress
func set_goal(target_max_rocks: int) -> void:
	max_rocks = max(0, target_max_rocks)
	goal_changed.emit(max_rocks)
