# RocksLabel.gd
extends Label

func _ready() -> void:
	GameState.rocks_broken_changed.connect(_on_progress)
	GameState.goal_changed.connect(_on_goal)
	GameState.level_won.connect(_on_won)
	# initialize immediately
	_on_progress(GameState.rocks_broken)
	_on_goal()

func _on_progress(current: int) -> void:
	if GameState.won:
		text = "You Won!"
	else:
		text = "Rocks: %d / %d" % [current, GameState.max_rocks] if \
			GameState.max_rocks > 0 else \
			"%d" % current

func _on_goal() -> void:
	_on_progress(GameState.rocks_broken)

func _on_won() -> void:
	text = "You Won!"
	# Optional: pause, open a win screen, or change scene
	# get_tree().paused = true
