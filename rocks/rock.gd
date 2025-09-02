extends Area2D

@export var max_hp: int = 1
@export var debris_scene: PackedScene        # optional: pre-made debris scene
@export var loot_scene: PackedScene          # optional: coins/resources to drop
@export var flash_time: float = 0.08         # hit flash duration (seconds)
@export var respawn_seconds: float = 20.0    # how long before the rock comes back
@export var rock_value: int = 1

# --- VARIANTS / RANDOMIZATION ---
@export var textures: Array[Texture2D] = []  # assign RockA, RockB, ...
@export var rock_values: Array[int] = []
@export var use_random_variant: bool = true
@export var variant_index: int = -1          # -1 = auto/random (if enabled)
@export var repick_on_respawn: bool = true   # pick a new art on respawn

# subtle per-instance variety (all optional)
@export var random_flip_h: bool = true
@export var random_rotation_degrees: float = 0.0   # e.g. 8 means ±8°
@export var random_scale_variation: float = 0.0    # e.g. 0.08 means ±8%

var _hp: int
var _is_broken: bool = false
var _chosen_variant: int = -1
var _rock_value: int = 1

@onready var _sprite: Sprite2D = $Rock1
@onready var _col: CollisionShape2D = $CollisionShape2D
@onready var _particles: GPUParticles2D = $DebrisParticles if has_node("DebrisParticles") else null
@onready var _sfx: AudioStreamPlayer2D = $BreakSFX if has_node("BreakSFX") else null

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	_hp = max_hp

	# Pick/apply initial variant before hooking signals (so visuals are correct if an immediate hit occurs)
	_apply_variant(_pick_variant_index())
	_apply_small_random_variation()

	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not area_entered.is_connected(_on_area_entered):
		area_entered.connect(_on_area_entered)

func take_damage(amount: int = 1, attacker: Node = null) -> void:
	if _is_broken or _hp <= 0:
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
	# optional small hit puff before breaking
	if _particles and not _is_broken:
		_particles.emitting = true

func _break_apart(attacker: Node) -> void:
	if _is_broken:
		return
	_is_broken = true

	# stop collisions/visibility (use deferred inside physics callbacks)
	if _col:
		_col.set_deferred("disabled", true)
	if _sprite:
		_sprite.visible = false

	# particles + sfx
	if _particles:
		_particles.one_shot = true
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

	# your stat hook
	GameState.add_rock_broken(_rock_value)

	# schedule respawn (do NOT queue_free the rock)
	_async_respawn(respawn_seconds)

func _async_respawn(seconds: float) -> void:
	var t := get_tree().create_timer(seconds)
	await t.timeout
	if !is_inside_tree():
		return
	_respawn()

func _respawn() -> void:
	_hp = max_hp
	_is_broken = false

	# (optional) pick a new look on respawn
	if repick_on_respawn:
		_apply_variant(_pick_variant_index())

	# show again
	if _sprite:
		_sprite.visible = true

	# re-enable collision safely
	if _col:
		_col.set_deferred("disabled", false)

	# reset/stop particles so they don't keep emitting
	if _particles:
		_particles.emitting = false

# --- Variant helpers ---

func _pick_variant_index() -> int:
	if textures.is_empty():
		_chosen_variant = -1
		return -1
	if not use_random_variant and variant_index >= 0 and variant_index < textures.size():
		_chosen_variant = variant_index
		return variant_index
	_chosen_variant = _rng.randi_range(0, textures.size() - 1)
	return _chosen_variant

func _apply_variant(i: int) -> void:
	if i >= 0 and i < textures.size() and _sprite:
		_sprite.texture = textures[i]
		
	if i >= 0 and i < rock_values.size() and rock_values[i] != null:
		# duplicate so each instance has its own resource
		_rock_value = rock_values[i]

	# Add the rock value to the max for the level
	var _curr_max_rocks: int = GameState.max_rocks
	var _new_max_rocks: int = _curr_max_rocks + _rock_value
	GameState.reset_for_level(_new_max_rocks)


func _apply_small_random_variation() -> void:
	if random_flip_h and _rng.randf() < 0.5 and _sprite:
		_sprite.flip_h = true
	if random_rotation_degrees > 0.0:
		var half := random_rotation_degrees * 0.5
		rotation_degrees += _rng.randf_range(-half, half)
	if random_scale_variation > 0.0:
		var s := 1.0 + _rng.randf_range(-random_scale_variation, random_scale_variation)
		scale = Vector2(s, s)

# --- Signal handlers ---

func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("damager"):
		if area.has_method("play_on_hit"):
			area.call_deferred("play_on_hit", self)
		var dmg_val := 1
		var maybe_damage = area.get("damage")   # returns null if not present
		if maybe_damage != null:
			dmg_val = int(maybe_damage)
		take_damage(dmg_val, area)

func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("damager"):
		if body.has_method("play_on_hit"):
			body.call_deferred("play_on_hit", self)
		var dmg_val := 1
		var maybe_damage = body.get("damage")
		if maybe_damage != null:
			dmg_val = int(maybe_damage)
		take_damage(dmg_val, body)
