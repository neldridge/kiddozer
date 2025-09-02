# Level.gd (on your level root, e.g., Node2D)
extends Node2D

@export var max_rocks: int = 16
@export var auto_sum_from_group: bool = false
@export var rock_group_name: StringName = &"rocks"

func _ready() -> void:
	var target := max_rocks
	if auto_sum_from_group:
		target = 0
		for r in get_tree().get_nodes_in_group(rock_group_name):
			if r.has_variable("rock_value"):
				target += int(r.rock_value)
			else:
				target += 1
	GameState.reset_for_level(target)
