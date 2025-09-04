extends CharacterBody2D

# ---------------- Movement ----------------
const SPEED: float = 75.0
const JUMP_VELOCITY: float = -150.0
const FLOOR_SNAP := 6.0

# ---------------- Anim names --------------
@export var run_anim: StringName = &"walk"
@export var idle_anim: StringName = &"idle"
@export var jump_anim: StringName = &"jump"
@export var fall_anim: StringName = &"fall"

# ------------- Slope physics glue ---------
@export var slope_snap_length: float = 12.0
@export var slope_max_angle_deg: float = 60.0
@export var slope_max_slides: int = 8
@export var slope_constant_speed: bool = true
@export var floor_stop_on_slope_when_idle: bool = true

# ------------- Tilt (rotation) ------------
@export var enable_slope_tilt: bool = true
@export_range(0.0, 89.0, 0.1) var slope_tilt_max_deg: float = 45.0
@export_range(0.0, 30.0, 0.1) var slope_tilt_min_deg: float = 3.0
@export var normal_alpha: float = 14.0
@export var rot_alpha: float = 12.0
@export var tilt_deadzone_deg: float = 0.8
@export var quantize_angle_step_deg: float = 0.25

# ---------- Visuals (bottom-pivot) --------
@export var pivot_follow_contact_x: bool = false
@export_range(0.0, 4.0, 0.1) var pivot_up_bias_px: float = 0.0
@export var follow_ground_y: bool = true
@export_range(16.0, 256.0, 1.0) var ray_up: float = 64.0
@export_range(64.0, 512.0, 1.0) var ray_down: float = 256.0
@export var sprite_bottom_to_tire_px: float = 31.0

# --- New: when to follow ground (visuals) ---
@export var follow_ground_when_falling: bool = true     # follow while descending
@export var follow_ground_only_when_close_px: float = 12.0  # only snap if ground is near

# ---------- Ground mask for raycasts -------
@export var floor_collision_mask: int = 1

# ---------- Probes (for tilt) --------------
@export var slope_raycast_front_path: NodePath = ^"RayFront"
@export var slope_raycast_mid_path:   NodePath = ^"FloorRay"
@export var slope_raycast_back_path:  NodePath = ^"RayBack"

# ------------- Nodes -----------------------
@onready var visual_pivot: Node2D = $VisualPivot
@onready var animated_sprite_2d: AnimatedSprite2D = $VisualPivot/AnimatedSprite2D
@onready var collider: CollisionShape2D = $CollisionShape2D
@onready var _ray_front: RayCast2D = get_node_or_null(slope_raycast_front_path)
@onready var _ray_mid:   RayCast2D = get_node_or_null(slope_raycast_mid_path)
@onready var _ray_back:  RayCast2D = get_node_or_null(slope_raycast_back_path)
@onready var idle_sound: AudioStreamPlayer2D = $IdleSound
@onready var moving_sound: AudioStreamPlayer2D = $MovingSound

# ------------- Debug -----------------------
@export var debug_draw: bool = true
@export var debug_len: float = 24.0

# ------------- Smoothed rotation -----------
var _n_s: Vector2 = Vector2.UP
var _rot_s: float = 0.0

# -------------------------------------------
func _ready() -> void:
	# Physics slope params
	floor_snap_length = slope_snap_length
	floor_max_angle = deg_to_rad(slope_max_angle_deg)
	max_slides = slope_max_slides
	floor_constant_speed = slope_constant_speed
	floor_stop_on_slope = floor_stop_on_slope_when_idle
	# Enable snapping by default
	floor_snap_length = FLOOR_SNAP

	# Visuals: pivot at origin; art bottom aligned to tire line (y=0)
	visual_pivot.position = Vector2.ZERO
	visual_pivot.rotation = 0.0

	if animated_sprite_2d:
		animated_sprite_2d.centered = false
		var frames: SpriteFrames = animated_sprite_2d.sprite_frames
		if frames and frames.get_animation_names().size() > 0:
			var anim: StringName = frames.get_animation_names()[0]
			var tex: Texture2D = frames.get_frame_texture(anim, 0)
			if tex:
				var sz: Vector2 = tex.get_size()
				animated_sprite_2d.offset = Vector2(-sz.x * 0.5, -sz.y + sprite_bottom_to_tire_px)

	_snap_collider_bottom_to_y0()

	if _ray_front: _ray_front.enabled = true; _ray_front.position.y = 0.0
	if _ray_mid:   _ray_mid.enabled = true;   _ray_mid.position.y = 0.0
	if _ray_back:  _ray_back.enabled = true;  _ray_back.position.y = 0.0

	if idle_sound: idle_sound.stream_paused = false
	if moving_sound: moving_sound.stream_paused = false

# -------------------------------------------
func _physics_process(delta: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Jump: turn off snapping right away
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		floor_snap_length = 0.0
		velocity.y = JUMP_VELOCITY

	# Horizontal
	var dir: float = Input.get_axis("ui_left", "ui_right")
	if dir != 0.0:
		velocity.x = dir * SPEED
		if animated_sprite_2d:
			animated_sprite_2d.flip_h = dir > 0.0
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)

	# Restore snapping when falling or grounded
	if is_on_floor() or velocity.y > 0.0:
		floor_snap_length = FLOOR_SNAP

	move_and_slide()

	# Tilt: only while grounded/falling; not while rising
	if _should_follow_ground() and enable_slope_tilt:
		_update_tilt(delta)
	else:
		# relax to flat in air / rising
		_rot_s = lerp_angle(_rot_s, 0.0, clamp(rot_alpha * delta, 0.0, 1.0))
	visual_pivot.rotation = _rot_s

	# ---- Visual ground-follow (the previous "glue to ground") ----
	var local_x: float = (visual_pivot.position.x if pivot_follow_contact_x else 0.0)
	if follow_ground_y and _should_follow_ground():
		var gp: Vector2 = to_global(visual_pivot.position)
		var start_y := gp.y - ray_up
		var end_y := gp.y + ray_down
		var hit: Dictionary = _raycast_vertical(gp.x, start_y, end_y)
		if not hit.is_empty():
			var ground_y: float = (hit["position"] as Vector2).y
			var desired_global: Vector2 = Vector2(gp.x, ground_y + pivot_up_bias_px)
			var desired_local: Vector2 = to_local(desired_global)
			desired_local.x = local_x
			# Only snap if the ground is close (prevents yanking down during jumps)
			if absf(desired_local.y - visual_pivot.position.y) <= follow_ground_only_when_close_px:
				visual_pivot.position.y = lerp(visual_pivot.position.y, desired_local.y, 0.35)
	# Always lock X
	visual_pivot.position.x = local_x

	# ---- Anim state ----
	if animated_sprite_2d and animated_sprite_2d.sprite_frames:
		if not is_on_floor():
			if velocity.y < 0.0 and animated_sprite_2d.sprite_frames.has_animation(jump_anim):
				animated_sprite_2d.play(jump_anim)
			elif animated_sprite_2d.sprite_frames.has_animation(fall_anim):
				animated_sprite_2d.play(fall_anim)
		else:
			if absf(dir) > 0.0 and animated_sprite_2d.sprite_frames.has_animation(run_anim):
				animated_sprite_2d.play(run_anim)
			elif animated_sprite_2d.sprite_frames.has_animation(idle_anim):
				animated_sprite_2d.play(idle_anim)

	# ---- Sounds ----
	var moving := absf(dir) > 0.0
	if is_on_floor():
		if moving:
			if moving_sound and not moving_sound.playing: moving_sound.play()
			if idle_sound and idle_sound.playing: idle_sound.stop()
		else:
			if idle_sound and not idle_sound.playing: idle_sound.play()
			if moving_sound and moving_sound.playing: moving_sound.stop()
	else:
		if moving_sound and not moving_sound.playing: moving_sound.play()
		if idle_sound and idle_sound.playing: idle_sound.stop()

	if debug_draw:
		queue_redraw()

# --------- Should visuals/tilt follow ground? ----------
func _should_follow_ground() -> bool:
	# True when on floor, or (optionally) while descending.
	return is_on_floor() or (follow_ground_when_falling and velocity.y > 0.0)

# --------- Tilt helpers ----------
func _update_tilt(delta: float) -> void:
	var chosen: RayCast2D = _best_ray()
	var normal_new: Vector2 = Vector2.ZERO
	if chosen and chosen.is_colliding():
		normal_new = chosen.get_collision_normal()
	else:
		normal_new = get_floor_normal()
	if normal_new != Vector2.ZERO:
		_n_s = (_n_s.lerp(normal_new, clamp(normal_alpha * delta, 0.0, 1.0))).normalized()

	var desired_rot: float = 0.0
	if _n_s != Vector2.ZERO:
		var tangent: Vector2 = Vector2(-_n_s.y, _n_s.x).normalized()
		var slope_rad: float = atan2(tangent.y, tangent.x)
		if absf(rad_to_deg(slope_rad)) >= slope_tilt_min_deg:
			desired_rot = clamp(slope_rad, -deg_to_rad(slope_tilt_max_deg), deg_to_rad(slope_tilt_max_deg))
	var dz: float = deg_to_rad(tilt_deadzone_deg)
	if _angle_dist(_rot_s, desired_rot) < dz:
		desired_rot = _rot_s
	if quantize_angle_step_deg > 0.0:
		var step: float = deg_to_rad(quantize_angle_step_deg)
		desired_rot = round(desired_rot / step) * step
	_rot_s = lerp_angle(_rot_s, desired_rot, clamp(rot_alpha * delta, 0.0, 1.0))

func _best_ray() -> RayCast2D:
	if velocity.x > 0.0 and _ray_front and _ray_front.is_colliding(): return _ray_front
	if velocity.x < 0.0 and _ray_back  and _ray_back.is_colliding():  return _ray_back
	if _ray_mid and _ray_mid.is_colliding(): return _ray_mid
	if _ray_front and _ray_front.is_colliding(): return _ray_front
	if _ray_back  and _ray_back.is_colliding():  return _ray_back
	return _ray_mid

func _angle_dist(a: float, b: float) -> float:
	return absf(atan2(sin(b - a), cos(b - a)))

# --------- Ground Y probe ----------
func _raycast_vertical(global_x: float, start_y: float, end_y: float) -> Dictionary:
	var space := get_world_2d().direct_space_state
	var p := PhysicsRayQueryParameters2D.create(Vector2(global_x, start_y), Vector2(global_x, end_y))
	p.collision_mask = floor_collision_mask
	p.exclude = _gather_exclude_rids()
	return space.intersect_ray(p)

func _gather_exclude_rids() -> Array:
	var arr: Array = [get_rid()]
	for c in get_children():
		if c is CollisionObject2D: arr.append((c as CollisionObject2D).get_rid())
		if c is Node:
			for cc in (c as Node).get_children():
				if cc is CollisionObject2D: arr.append((cc as CollisionObject2D).get_rid())
	return arr

# --------- Collider bottom = y0 ----------
func _snap_collider_bottom_to_y0() -> void:
	if not (is_instance_valid(collider) and is_instance_valid(collider.shape)):
		return
	if collider.shape is RectangleShape2D:
		var r := collider.shape as RectangleShape2D
		collider.position.y = -r.size.y * 0.5
	elif collider.shape is CircleShape2D:
		var c := collider.shape as CircleShape2D
		collider.position.y = -c.radius
	elif collider.shape is CapsuleShape2D:
		var cap := collider.shape as CapsuleShape2D
		collider.position.y = -(cap.height * 0.5 + cap.radius)

# ------------- Debug draw -----------------
func _draw() -> void:
	if not debug_draw: return
	draw_line(Vector2(-800, 0), Vector2(800, 0), Color(1,0,0), 2.0) # tire line
	if collider and collider.shape:
		var y_bottom := 0.0
		if collider.shape is RectangleShape2D:
			var r := collider.shape as RectangleShape2D
			y_bottom = collider.position.y + r.size.y * 0.5
		elif collider.shape is CircleShape2D:
			var c := collider.shape as CircleShape2D
			y_bottom = collider.position.y + c.radius
		elif collider.shape is CapsuleShape2D:
			var cap := collider.shape as CapsuleShape2D
			y_bottom = collider.position.y + (cap.height * 0.5 + cap.radius)
		draw_line(Vector2(-800, y_bottom), Vector2(800, y_bottom), Color(0,1,0), 2.0)
	draw_circle(visual_pivot.position, 3.0, Color(0.2,0.6,1.0)) # visual pivot
