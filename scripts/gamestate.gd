# GameState.gd
extends Node

signal rocks_broken_changed(count: int)

var rocks_broken: int = 0

func add_rock_broken(count: int) -> void:
	rocks_broken += count
	rocks_broken_changed.emit(rocks_broken)

func reset_rocks_broken() -> void:
	rocks_broken = 0
	rocks_broken_changed.emit(rocks_broken)
