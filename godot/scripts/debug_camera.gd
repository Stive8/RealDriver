extends Camera3D

const MIN_SPEED := 2.0
const MAX_SPEED := 100.0
const MOUSE_SENSITIVITY := 0.003
const ZOOM_STEP := 1.15

var speed := 15.0
var yaw := 0.0
var pitch := 0.0
var _debug_timer := 0.0


func _ready() -> void:
	yaw = rotation.y
	pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = clamp(speed * ZOOM_STEP, MIN_SPEED, MAX_SPEED)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = clamp(speed / ZOOM_STEP, MIN_SPEED, MAX_SPEED)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch -= event.relative.y * MOUSE_SENSITIVITY
		pitch = clamp(pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(pitch, yaw, 0.0)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		dir += Vector3.DOWN

	if dir.length_squared() > 0.0:
		global_position += dir.normalized() * speed * delta

	# DECISION_PENDIENTE: print de diagnóstico temporal para depurar movimiento;
	# quitar una vez confirmado que la cámara se mueve correctamente.
	_debug_timer += delta
	if _debug_timer >= 1.0:
		_debug_timer = 0.0
		print("cam pos=%s  speed=%.1f m/s" % [global_position, speed])
