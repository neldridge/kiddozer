extends CharacterBody2D

# ---------------- Movement ----------------
const SPEED: float = 75.0
const JUMP_VELOCITY: float = -150.0

# ---------------- Anim names --------------
@export var damage: int = 1
@export var attack_anim: StringName = &"attack"
@export var run_anim: StringName = &"walk"      # primary run name
@export var run_fallback_anim: StringName = &"hit"  # <- will be used if 'run' doesn't exist
@export var idle_anim: StringName = &"idle"
@export var jump_anim: StringName = &"jump"
@export var fall_anim: StringName = &"fall"

# ------------- Slope physics glue ---------
@export var slope_snap_length: float = 12.0
@export var slope_max_angle_deg: float = 60.0
@export var slope_max_slides: int = 8
@export var slope_constant_speed: bool = true
@export var floor_stop_on_slope_when_idle: bool = true

# ------------- Visual slope tilt ----------
@export var enable_slope_tilt: bool = true
@export_range(0.0, 89.0, 0.1) var slope_tilt_max_deg: float = 45.0
@export_range(0.0, 30.0, 0.1) var slope_tilt_min_deg: float = 3.0

# Keep pivot glued to contact (no hover)
@export var pivot_follow_contact: bool = true
@export_range(0.0, 12.0, 0.1) var pivot_up_bias_px: float = 2.0   # keep ABOVE floor by this much

# Smoothing / jitter control
@export var tilt_deadzone_deg: float = 0.8
@export var quantize_angle_step_deg: float = 0.25  # 0 = off
@export var normal_alpha: float = 14.0             # bigger = snappier
@export var contact_alpha: float = 18.0
@export var rot_alpha: float = 12.0
@export var pivot_alpha: float = 16.0

# Landing snap: fully sync visuals on landing to avoid “snap forward” after long falls
@export var landing_snap_time: float = 0.06  # seconds to hold exact sync right after landing

# Hard penetration guard (ray solve)
@export var penetration_guard_distance: float = 24.0
@export var penetration_guard_extra_down: float = 10.0

# Your ground is on layer 1
@export var floor_collision_mask: int = 1

# Stable source for floor info
@export var slope_raycast_path: NodePath = ^"FloorRay"

# ------------- Nodes ----------------------
@onready var visual_pivot: Node2D = $VisualPivot
@onready var animated_sprite_2d: AnimatedSprite2D = $VisualPivot/AnimatedSprite2D
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var idle_sound: AudioStreamPlayer2D = $IdleSound
@onready var moving_sound: AudioStreamPlayer2D = $MovingSound
@onready var _ray: RayCast2D = get_node_or_null(slope_raycast_path) if slope_raycast_path != ^"" else null
@onready var _attack_timer: Timer = Timer.new()

# Debug
@export var debug_draw: bool = false
@export var debug_len: float = 20.0

var _attack_locked: bool = false

# Smoothed state
var _n_s: Vector2 = Vector2.UP          # smoothed floor normal
var _c_s: Vector2 = Vector2.ZERO        # smoothed contact (GLOBAL)
var _rot_s: float = 0.0                 # smoothed rotation target (radians)
var _pos_s: Vector2 = Vector2.ZERO      # smoothed pivot target (LOCAL)

# Landing detection
var _was_on_floor: bool = false
var _landing_timer: float = 0.0

func _ready() -> void:
	floor_snap_length = slope_snap_length
	floor_max_angle = deg_to_rad(slope_max_angle_deg)
	max_slides = slope_max_slides
	floor_constant_speed = slope_constant_speed
	floor_stop_on_slope = floor_stop_on_slope_when_idle
	if _ray: _ray.enabled = true

	if not is_in_group("damager"):
		add_to_group("damager")
	if animated_sprite_2d and not animated_sprite_2d.is_connected("animation_finished", _on_anim_finished):
		animated_sprite_2d.animation_finished.connect(_on_anim_finished)

	_attack_timer.one_shot = true
	add_child(_attack_timer)
	_attack_timer.timeout.connect(_on_attack_lock_timeout)

	_rot_s = visual_pivot.rotation
	_pos_s = visual_pivot.position
	_c_s = to_global(_pos_s)
	_was_on_floor = is_on_floor()

# ----------------- INPUT HOOK for attack (plays in air too) -------------------
# Call this from your hit/click/weapon event. It will play even while falling.
func play_on_hit(_target: Node) -> void:
	_play_attack()

func _play_attack() -> void:
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
	# Only unlock when the attack actually finishes
	if animated_sprite_2d and animated_sprite_2d.animation == String(attack_anim):
		_attack_locked = false

func _on_attack_lock_timeout() -> void:
	# Safety: if the attack is still playing, extend lock briefly
	if _is_attack_anim_playing():
		_attack_timer.start(0.05)
	else:
		_attack_locked = false

func _is_attack_anim_playing() -> bool:
	return animated_sprite_2d \
		and animated_sprite_2d.animation == String(attack_anim) \
		and animated_sprite_2d.is_playing()

# ------------------------------- PHYSICS --------------------------------------
func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var direction: float = Input.get_axis("ui_left", "ui_right")
	if direction != 0.0:
		velocity.x = direction * SPEED
		animated_sprite_2d.flip_h = direction > 0.0
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)

	move_and_slide()

	# Landing detection & immediate sync
	var now_on_floor: bool = is_on_floor()
	var just_landed: bool = (not _was_on_floor) and now_on_floor
	if just_landed:
		_force_sync_visuals_to_floor()
		_landing_timer = landing_snap_time

	_update_tilt_and_pivot(delta)

	# During the landing snap window, keep visuals locked to the current targets (no lag)
	if _landing_timer > 0.0:
		_landing_timer -= delta
		visual_pivot.rotation = _rot_s
		visual_pivot.position = _pos_s

	_was_on_floor = now_on_floor

	# ---------------- Animation state machine ----------------
	# If an attack is playing (ground or air), don't override it.
	if _is_attack_anim_playing():
		_attack_locked = true
	else:
		# If we previously locked (e.g., cross-frame), keep it until timeout unlocks.
		if not _attack_locked:
			_play_locomotion_anim(direction, now_on_floor)

	# Sounds (unchanged)
	var moving: bool = absf(direction) > 0.0
	if now_on_floor:
		if moving:
			if not moving_sound.playing: moving_sound.play()
			if idle_sound.playing: idle_sound.stop()
		else:
			if not idle_sound.playing: idle_sound.play()
			if moving_sound.playing: moving_sound.stop()
	else:
		if not moving_sound.playing: moving_sound.play()
		if idle_sound.playing: idle_sound.stop()

	if debug_draw:
		queue_redraw()

# ---------------- Tilt + Pivot follow + Hard clamp ----------------
func _update_tilt_and_pivot(delta: float) -> void:
	if not enable_slope_tilt:
		_rot_s = lerp_angle(_rot_s, 0.0, clamp(rot_alpha * delta, 0.0, 1.0))
		return

	var have_floor: bool = is_on_floor()
	var normal_new: Vector2 = Vector2.ZERO
	var contact_new_global: Vector2 = Vector2.ZERO
	var have_contact: bool = false

	if have_floor and _ray and _ray.is_colliding():
		normal_new = _ray.get_collision_normal()
		contact_new_global = _ray.get_collision_point()
		have_contact = true
	elif have_floor:
		normal_new = get_floor_normal()
		var count: int = get_slide_collision_count()
		for i in count:
			var col := get_slide_collision(i)
			if col and col.get_normal().dot(Vector2.UP) > 0.1:
				contact_new_global = col.get_position()
				have_contact = true
				break

	# Smooth normal
	if normal_new != Vector2.ZERO:
		var t_n: float = clamp(normal_alpha * delta, 0.0, 1.0)
		_n_s = (_n_s * (1.0 - t_n) + normal_new * t_n).normalized()

	# Desired rotation
	var desired_rot: float = 0.0
	if have_floor and _n_s != Vector2.ZERO:
		var tangent: Vector2 = Vector2(-_n_s.y, _n_s.x).normalized()
		var slope_rad: float = atan2(tangent.y, tangent.x)
		var clamped_rad: float = clamp(slope_rad, -PI * 0.5, PI * 0.5)
		var slope_deg: float = absf(rad_to_deg(clamped_rad))
		if slope_deg >= slope_tilt_min_deg:
			var max_rad: float = deg_to_rad(slope_tilt_max_deg)
			desired_rot = clamp(clamped_rad, -max_rad, max_rad)

	# Deadzone / quantize
	var dz: float = deg_to_rad(tilt_deadzone_deg)
	if _angle_dist(_rot_s, desired_rot) < dz:
		desired_rot = _rot_s
	if quantize_angle_step_deg > 0.0:
		var step: float = deg_to_rad(quantize_angle_step_deg)
		desired_rot = round(desired_rot / step) * step

	# Smooth rotation target
	var t_rot: float = clamp(rot_alpha * delta, 0.0, 1.0)
	_rot_s = lerp_angle(_rot_s, desired_rot, t_rot)

	# ----- Pivot follow -----
	if pivot_follow_contact and have_floor and have_contact:
		# Smooth contact (GLOBAL)
		var t_c: float = clamp(contact_alpha * delta, 0.0, 1.0)
		_c_s = _c_s.lerp(contact_new_global, t_c)

		# Target ABOVE floor along normal
		var bias_px: float = max(0.0, pivot_up_bias_px)
		var desired_global: Vector2 = _c_s + _n_s * bias_px
		desired_global = _resolve_pivot_against_world(desired_global, _n_s, penetration_guard_distance, penetration_guard_extra_down)

		# Smooth pivot target in LOCAL space
		var desired_local: Vector2 = to_local(desired_global)
		var t_pos: float = clamp(pivot_alpha * delta, 0.0, 1.0)
		_pos_s = _pos_s.lerp(desired_local, t_pos)

	# Apply smoothed targets (landing snap may overwrite right after)
	visual_pivot.rotation = _rot_s
	visual_pivot.position = _pos_s

# ---- LANDING SNAP: hard-sync visuals & state on first contact ----------------
func _force_sync_visuals_to_floor() -> void:
	var normal: Vector2 = Vector2.UP
	var contact_g: Vector2 = to_global(visual_pivot.position)
	if _ray and _ray.is_colliding():
		normal = _ray.get_collision_normal()
		contact_g = _ray.get_collision_point()
	else:
		if get_floor_normal() != Vector2.ZERO:
			normal = get_floor_normal()
		var count: int = get_slide_collision_count()
		for i in count:
			var col := get_slide_collision(i)
			if col and col.get_normal().dot(Vector2.UP) > 0.1:
				contact_g = col.get_position()
				break

	var desired_rot: float = 0.0
	if normal != Vector2.ZERO:
		var tang: Vector2 = Vector2(-normal.y, normal.x).normalized()
		var sr: float = atan2(tang.y, tang.x)
		var cr: float = clamp(sr, -PI * 0.5, PI * 0.5)
		var maxr: float = deg_to_rad(slope_tilt_max_deg)
		desired_rot = clamp(cr, -maxr, maxr)

	var desired_global: Vector2 = contact_g + normal.normalized() * max(0.0, pivot_up_bias_px)
	desired_global = _resolve_pivot_against_world(desired_global, normal, penetration_guard_distance, penetration_guard_extra_down)
	var desired_local: Vector2 = to_local(desired_global)

	visual_pivot.rotation = desired_rot
	visual_pivot.position = desired_local

	_n_s = normal
	_c_s = contact_g
	_rot_s = desired_rot
	_pos_s = desired_local

# World resolve with mask + excludes
func _resolve_pivot_against_world(target_global: Vector2, floor_normal: Vector2, depth: float, extra_down: float) -> Vector2:
	var space := get_world_2d().direct_space_state
	var excludes: Array = _gather_exclude_rids()

	var p1 := PhysicsRayQueryParameters2D.create(target_global, target_global - floor_normal.normalized() * depth)
	p1.exclude = excludes
	p1.collision_mask = floor_collision_mask
	var hit1 := space.intersect_ray(p1)
	if hit1:
		return hit1.position + hit1.normal * pivot_up_bias_px

	var p2 := PhysicsRayQueryParameters2D.create(target_global, target_global + Vector2.DOWN * extra_down)
	p2.exclude = excludes
	p2.collision_mask = floor_collision_mask
	var hit2 := space.intersect_ray(p2)
	if hit2:
		return hit2.position + hit2.normal * pivot_up_bias_px

	return target_global

func _gather_exclude_rids() -> Array:
	var arr: Array = [get_rid()]
	for c in get_children():
		if c is CollisionObject2D: arr.append((c as CollisionObject2D).get_rid())
		if c is Node:
			for cc in (c as Node).get_children():
				if cc is CollisionObject2D: arr.append((cc as CollisionObject2D).get_rid())
	return arr

func _angle_dist(a: float, b: float) -> float:
	return absf(atan2(sin(b - a), cos(b - a)))

# ---------------- Attack / anim helpers ---------------
func _attack_duration() -> float:
	if not animated_sprite_2d or not animated_sprite_2d.sprite_frames: return 0.1
	var frames: int = animated_sprite_2d.sprite_frames.get_frame_count(attack_anim)
	var fps: float = animated_sprite_2d.sprite_frames.get_animation_speed(attack_anim)
	if fps <= 0.0: fps = 10.0
	return max(0.05, float(frames) / fps)

func _play_locomotion_anim(direction: float, on_floor: bool) -> void:
	if not animated_sprite_2d or not animated_sprite_2d.sprite_frames:
		return

	# Air states
	if not on_floor:
		if velocity.y < 0.0 and animated_sprite_2d.sprite_frames.has_animation(jump_anim):
			_safe_play(jump_anim); return
		if velocity.y >= 0.0 and animated_sprite_2d.sprite_frames.has_animation(fall_anim):
			_safe_play(fall_anim); return
		# If you prefer to keep "moving" in air when running horizontally, uncomment:
		# if absf(direction) > 0.0: _safe_play(_pick_run_anim()); return

	# Grounded states
	if absf(direction) > 0.0:
		_safe_play(_pick_run_anim())
	else:
		if animated_sprite_2d.sprite_frames.has_animation(idle_anim):
			_safe_play(idle_anim)

func _pick_run_anim() -> StringName:
	# Use 'run' if present, otherwise fall back to 'moving'
	if animated_sprite_2d.sprite_frames.has_animation(run_anim):
		return run_anim
	if run_fallback_anim != StringName() and animated_sprite_2d.sprite_frames.has_animation(run_fallback_anim):
		return run_fallback_anim
	# If neither exists, stick with idle to avoid errors
	return idle_anim

func _safe_play(anim: StringName) -> void:
	# Do NOT override if an attack is actively playing
	if _is_attack_anim_playing():
		return
	if animated_sprite_2d.animation != String(anim) or not animated_sprite_2d.is_playing():
		animated_sprite_2d.play(anim)

# ---------------- Debug gizmos (optional) ---------------
func _draw() -> void:
	if not debug_draw: return
	var p: Vector2 = visual_pivot.position
	draw_circle(p, 3.0, Color(1, 0, 0))
	draw_line(p, p + Vector2.RIGHT.rotated(visual_pivot.rotation) * debug_len, Color(1, 0, 0), 2.0)
	if _ray and _ray.is_colliding():
		var gp: Vector2 = _ray.get_collision_point()
		var lp: Vector2 = to_local(gp)
		draw_circle(lp, 3.0, Color(0.2, 0.6, 1.0))
		var n: Vector2 = _ray.get_collision_normal()
		draw_line(lp, lp + n * debug_len, Color(0.2, 0.6, 1.0), 1.0)
