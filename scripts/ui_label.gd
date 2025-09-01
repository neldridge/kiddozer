# RockCounterLabel.gd (on a Label node)
extends Label

func _ready() -> void:
	# initialize text immediately
	text = "Rocks: %d" % GameState.rocks_broken
	# update whenever the count changes
	GameState.rocks_broken_changed.connect(_on_rocks_broken_changed)

func _on_rocks_broken_changed(count: int) -> void:
	text = "Rocks: %d" % count
