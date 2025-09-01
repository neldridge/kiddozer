extends CharacterBody2D

const SPEED = 200.0
const JUMP_VELOCITY = -300.0

@onready var animated_sprite_2d: AnimatedSprite2D = $AnimatedSprite2D
@onready var idle_sound: AudioStreamPlayer2D = $IdleSound
@onready var moving_sound: AudioStreamPlayer2D = $MovingSound

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var direction := Input.get_axis("ui_left", "ui_right")
	if direction:
		velocity.x = direction * SPEED
		animated_sprite_2d.flip_h = direction > 0
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)

	move_and_slide()

	# ---- Sound logic ----
	var is_intending_move: bool = abs(direction) > 0.0

	if is_on_floor():
		if is_intending_move:
			# Moving (including pushing against walls)
			if not moving_sound.playing:
				moving_sound.play()
			if idle_sound.playing:
				idle_sound.stop()
		else:
			# Idle
			if not idle_sound.playing:
				idle_sound.play()
			if moving_sound.playing:
				moving_sound.stop()
	else:
		# In air: always moving sound
		if not moving_sound.playing:
			moving_sound.play()
		if idle_sound.playing:
			idle_sound.stop()
