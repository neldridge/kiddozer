extends CharacterBody2D

# --- Movement constants ---
const SPEED: float = 200.0
const JUMP_VELOCITY: float = -300.0

# --- Combat / animation names ---
@export var damage: int = 1
@export var attack_anim: StringName = &"attack"
@export var run_anim: StringName = &"run"
@export var idle_anim: StringName = &"idle"
@export var jump_anim: StringName = &"jump"   # optional
@export var fall_anim: StringName = &"fall"   # optional

# --- Slope handling (physics) ---
@export var slope_snap_length: float = 8.0
@export var slope_max_angle_deg: float = 60.0
@export var slope_max_slides: int = 8
@export var slope_constant_speed: bool = true
@export var floor_stop_on_slope_when_idle: bool = true

# --- Visual slope tilt (sprite only) ---
@export var enable_slope_tilt: bool = true
@export_range(0.0, 89.0, 0.1) var slope_tilt_max_deg: float = 45.0
@export_range(0.0, 30.0, 0.1) var slope_tilt_min_deg: float = 3.0
@export_range(0.0, 30.0, 0.1) var slope_tilt_smooth: float = 10.0
# Optional RayCast2D (pointing down) for steadier normals on noisy tilemaps.
@export var slope_raycast_path: NodePath = ^""
# --- Keep the pivot glued to the ground contact point ---
@export var pivot_follow_contact: bool = true      # move pivot to the physics contact each frame
@export_range(0.0, 60.0, 0.1) var pivot_follow_lerp: float = 20.0  # how fast it follows (bigger = snappier)
@export_range(-8.0, 16.0, 0.1) var pivot_down_bias_px: float = 2.0 # push slightly into ground to hide 1px gaps


# --- Debug ---
@export var debug_tilt: bool = false
# --- Debug drawing ---
@export var debug_draw: bool = true     # toggle in inspector
@export var debug_len: float = 20.0

# --- Node refs (explicit to match your screenshot) ---
@onready var visual_pivot: Node2D = $VisualPivot
@onready var animated_sprite_2d: AnimatedSprite2D = $VisualPivot/AnimatedSprite2D
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var idle_sound: AudioStreamPlayer2D = $IdleSound
@onready var moving_sound: AudioStreamPlayer2D = $MovingSound
@onready var _attack_timer: Timer = Timer.new()
@onready var _slope_ray: RayCast2D = get_node_or_null(slope_raycast_path) if slope_raycast_path != ^"" else null

var _attack_locked: bool = false

func _ready() -> void:
	# Slope glue
	floor_snap_length = slope_snap_length
	floor_max_angle = deg_to_rad(slope_max_angle_deg)
	max_slides = slope_max_slides
	floor_constant_speed = slope_constant_speed
	floor_stop_on_slope = floor_stop_on_slope_when_idle

	if _slope_ray:
		_slope_ray.enabled = true

	if not is_in_group("damager"):
		add_to_group("damager")

	if animated_sprite_2d and not animated_sprite_2d.is_connected("animation_finished", _on_anim_finished):
		animated_sprite_2d.animation_finished.connect(_on_anim_finished)

	_attack_timer.one_shot = true
	add_child(_attack_timer)
	_attack_timer.timeout.connect(_on_attack_lock_timeout)
	if debug_draw:
		queue_redraw()   # requests a redraw for _draw()

func _physics_process(delta: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Horizontal + flip
	var direction: float = Input.get_axis("ui_left", "ui_right")
	if direction != 0.0:
		velocity.x = direction * SPEED
		# NOTE: sprite is a CHILD of VisualPivot; flipping the sprite is correct.
		animated_sprite_2d.flip_h = direction > 0.0
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)

	# Move
	move_and_slide()

	# Visual tilt
	_apply_slope_tilt(delta)

	# Animations
	if _is_attack_anim_playing():
		_attack_locked = true
	elif not _attack_locked:
		_play_locomotion_anim(direction)

	# Sounds
	var is_intending_move: bool = absf(direction) > 0.0
	if is_on_floor():
		if is_intending_move:
			if not moving_sound.playing: moving_sound.play()
			if idle_sound.playing: idle_sound.stop()
		else:
			if not idle_sound.playing: idle_sound.play()
			if moving_sound.playing: moving_sound.stop()
	else:
		if not moving_sound.playing: moving_sound.play()
		if idle_sound.playing: idle_sound.stop()

# --- Visual slope tilt helper -------------------------------------------------
func _apply_slope_tilt(delta: float) -> void:
	var current: float = visual_pivot.rotation
	var target_rot: float = 0.0

	var have_floor: bool = is_on_floor()
	var floor_normal: Vector2 = Vector2.ZERO
	var contact_pos_global: Vector2 = Vector2.ZERO
	var have_contact: bool = false

	if have_floor:
		# Prefer a raycast normal if provided; otherwise body floor normal
		if _slope_ray and _slope_ray.is_colliding():
			floor_normal = _slope_ray.get_collision_normal()
			contact_pos_global = _slope_ray.get_collision_point()
			have_contact = true
		else:
			floor_normal = get_floor_normal()

		# If we don't have a precise contact point yet, take it from slide collisions
		if not have_contact:
			var n: int = get_slide_collision_count()
			for i in n:
				var col := get_slide_collision(i)
				if col:
					# Treat mostly-upward normals as floor (ignore walls)
					if col.get_normal().dot(Vector2.UP) > 0.1:
						contact_pos_global = col.get_position()
						have_contact = true
						break

		# Compute slope angle from the floor normal
		if floor_normal != Vector2.ZERO:
			var tangent: Vector2 = Vector2(-floor_normal.y, floor_normal.x).normalized()
			var slope_rad: float = atan2(tangent.y, tangent.x)
			var clamped_rad: float = clamp(slope_rad, -PI * 0.5, PI * 0.5)
			var slope_deg: float = absf(rad_to_deg(clamped_rad))
			if slope_deg >= slope_tilt_min_deg:
				var max_rad: float = deg_to_rad(slope_tilt_max_deg)
				target_rot = clamp(clamped_rad, -max_rad, max_rad)

	# 1) Rotate towards target
	visual_pivot.rotation = lerp_angle(current, target_rot, minf(1.0, slope_tilt_smooth * delta))

	# 2) Reposition pivot to the ACTUAL floor contact (optional but fixes “hover on tilt”)
	if pivot_follow_contact and have_floor and have_contact:
		# Bias the pivot slightly into the ground along the normal (visual-only)
		var biased_global: Vector2 = contact_pos_global - floor_normal * pivot_down_bias_px
		var target_local: Vector2 = to_local(biased_global)
		var t: float = minf(1.0, pivot_follow_lerp * delta)
		visual_pivot.position = visual_pivot.position.lerp(target_local, t)


# --- Attack / animation guardrails -------------------------------------------
func play_on_hit(_target: Node) -> void:
	if not animated_sprite_2d or not animated_sprite_2d.sprite_frames:
		return
	if not animated_sprite_2d.sprite_frames.has_animation(attack_anim):
		return

	_attack_locked = true
	animated_sprite_2d.play(attack_anim)
	animated_sprite_2d.frame = 0
	animated_sprite_2d.frame_progress = 0.0
	_attack_timer.start(_attack_duration())

func _on_anim_finished() -> void:
	if animated_sprite_2d and animated_sprite_2d.animation == String(attack_anim):
		_attack_locked = false

func _on_attack_lock_timeout() -> void:
	if _is_attack_anim_playing():
		_attack_timer.start(0.05)
	else:
		_attack_locked = false

func _is_attack_anim_playing() -> bool:
	return animated_sprite_2d \
		and animated_sprite_2d.animation == String(attack_anim) \
		and animated_sprite_2d.is_playing()

func _attack_duration() -> float:
	if not animated_sprite_2d or not animated_sprite_2d.sprite_frames:
		return 0.1
	var frames: int = animated_sprite_2d.sprite_frames.get_frame_count(attack_anim)
	var fps: float = animated_sprite_2d.sprite_frames.get_animation_speed(attack_anim)
	if fps <= 0.0:
		fps = 10.0
	return max(0.05, float(frames) / fps)

func _play_locomotion_anim(direction: float) -> void:
	if not animated_sprite_2d or not animated_sprite_2d.sprite_frames:
		return

	if not is_on_floor():
		if velocity.y < 0.0 and animated_sprite_2d.sprite_frames.has_animation(jump_anim):
			_safe_play(jump_anim); return
		if velocity.y >= 0.0 and animated_sprite_2d.sprite_frames.has_animation(fall_anim):
			_safe_play(fall_anim); return

	if absf(direction) > 0.0 and animated_sprite_2d.sprite_frames.has_animation(run_anim):
		_safe_play(run_anim)
	elif animated_sprite_2d.sprite_frames.has_animation(idle_anim):
		_safe_play(idle_anim)

func _safe_play(anim: StringName) -> void:
	if _is_attack_anim_playing():
		return
	if animated_sprite_2d.animation != String(anim) or not animated_sprite_2d.is_playing():
		animated_sprite_2d.play(anim)

func _draw() -> void:
	if not debug_draw:
		return

	# 1) Pivot gizmo (RED): where rotation is applied
	if has_node(^"VisualPivot"):
		var pivot: Node2D = $VisualPivot
		var p: Vector2 = pivot.position     # local to this CharacterBody2D
		draw_circle(p, 3.0, Color(1,0,0))
		# show the pivot's "right" direction (tangent)
		var dir: Vector2 = Vector2.RIGHT.rotated(pivot.rotation)
		draw_line(p, p + dir * debug_len, Color(1,0,0), 2.0)

	# 2) Collider feet point (GREEN): where the collider bottom is
	if has_node(^"CollisionShape2D") and $CollisionShape2D.shape:
		var feet_local: Vector2 = _feet_offset_from_collision($CollisionShape2D)
		draw_circle(feet_local, 3.0, Color(0,1,0))
		draw_line(feet_local - Vector2(0, debug_len*0.5), feet_local + Vector2(0, debug_len*0.5), Color(0,1,0,0.4), 1.0)

	# 3) Actual slide contact points (BLUE): what physics says we hit this frame
	var n: int = get_slide_collision_count()
	for i in n:
		var col := get_slide_collision(i)
		if col:
			var gp: Vector2 = col.get_position()
			var lp: Vector2 = to_local(gp)
			draw_circle(lp, 3.0, Color(0.2,0.6,1.0))
			
			
func _feet_offset_from_collision(c: CollisionShape2D) -> Vector2:
	if not c or not c.shape:
		return Vector2.ZERO
	var bottom: float = 0.0
	match c.shape:
		RectangleShape2D:
			bottom = c.shape.size.y * 0.5
		CapsuleShape2D:
			bottom = (c.shape.height * 0.5) + c.shape.radius
		CircleShape2D:
			bottom = c.shape.radius
		_:
			if "get_rect" in c.shape:
				var r = c.shape.get_rect()
				bottom = r.size.y * 0.5
	return c.position + Vector2(0.0, bottom * c.scale.y)
