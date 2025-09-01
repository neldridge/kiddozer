extends Area2D

@export var max_hp: int = 1
@export var debris_scene: PackedScene        # optional: pre-made debris scene
@export var loot_scene: PackedScene          # optional: coins/resources to drop
@export var flash_time: float = 0.08         # hit flash duration (seconds)

var _hp: int

@onready var _sprite: Sprite2D = $Rock1
@onready var _col: CollisionShape2D = $CollisionShape2D
@onready var _particles: GPUParticles2D = $DebrisParticles if has_node("DebrisParticles") else null
@onready var _sfx: AudioStreamPlayer2D = $BreakSFX if has_node("BreakSFX") else null

func _ready() -> void:
	_hp = max_hp
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not area_entered.is_connected(_on_area_entered):
		area_entered.connect(_on_area_entered)

func take_damage(amount: int = 1, attacker: Node = null) -> void:
	if _hp <= 0:
		return
	_hp -= max(1, amount)
	_hit_flash()

	if _hp <= 0:
		_break_apart(attacker)

func _hit_flash() -> void:
	if _sprite:
		_sprite.modulate = Color(1.0, 0.7, 0.7)
		await get_tree().create_timer(flash_time).timeout
		if is_instance_valid(_sprite):
			_sprite.modulate = Color.WHITE
	if _particles:
		_particles.emitting = true

func _break_apart(attacker: Node) -> void:
	# stop collisions/visibility
	if _col:
		_col.set_deferred("disabled", true)
	if _sprite:
		_sprite.visible = false

	# particles + sfx
	if _particles:
		_particles.emitting = true
	if _sfx:
		_sfx.play()

	# optional: spawn debris chunks
	if debris_scene:
		var debris := debris_scene.instantiate()
		debris.global_position = global_position
		get_tree().current_scene.add_child(debris)

	# optional: spawn loot
	if loot_scene:
		var loot := loot_scene.instantiate()
		loot.global_position = global_position
		get_tree().current_scene.add_child(loot)

	GameState.add_rock_broken()
	GameState.add_rock_broken()
	GameState.add_rock_broken()
	# let particles/sfx play a moment, then remove
	await get_tree().create_timer(0.7).timeout
	queue_free()

# --- Signal handlers ---

func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("damager"):
		var dmg_val := 1
		var maybe_damage = area.get("damage")   # returns null if not present
		if maybe_damage != null:
			dmg_val = int(maybe_damage)
		take_damage(dmg_val, area)

func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("damager"):
		var dmg_val := 1
		var maybe_damage = body.get("damage")
		if maybe_damage != null:
			dmg_val = int(maybe_damage)
		take_damage(dmg_val, body)
