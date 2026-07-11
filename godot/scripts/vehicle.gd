extends VehicleBody3D

# DECISION_PENDIENTE: la especificación pide las ruedas en y=0.1, pero con la carrocería
# (BoxShape3D de 1.2 m de alto centrada en el origen, base en y=-0.6) el raycast de
# suspensión de cada rueda (rest_length 0.15 + radio 0.35 = 0.5 m) solo alcanza y=-0.4,
# por encima de la base de la caja: la caja tocaba el suelo antes que las ruedas y estas
# quedaban en el aire (0/4 en contacto), por lo que engine_force no movía el coche.
# Bajé el origen de las 4 ruedas a y=-0.4 en vehicle.tscn para que el contacto quede bajo
# la caja (4/4 en contacto, coche conducible). Revisar con el arquitecto la geometría
# carrocería/ruedas.

# DECISION_PENDIENTE: la especificación asume que engine_force positivo = avanzar,
# pero se midió que en Godot 4.4 el VehicleBody3D con esta configuración de ruedas avanza
# hacia su +Z con engine_force positivo (es decir, positivo = marcha atrás geométrica).
# Para que "acelerar" lleve el coche hacia su frente (-Z, donde están las ruedas de dirección)
# y se aleje de la cámara, se invierte el signo: ENGINE_FORCE_MAX negativo = avanzar,
# REVERSE_FORCE_MAX positivo = retroceder. Revisar convención con el arquitecto.
const ENGINE_FORCE_MAX := -2500.0
const REVERSE_FORCE_MAX := 1200.0
const BRAKE_FORCE := 40.0
const HANDBRAKE_FORCE := 60.0
const STEER_LERP_SPEED := 6.0
const MAX_STEER_BASE := 0.55
const STEER_SPEED_REF := 40.0
const STEER_MIN_FACTOR := 0.35
const RESET_LIFT := 2.0

## Por debajo de esta velocidad, mantener "brake_reverse" pasa de frenar a dar marcha atrás.
const BRAKE_TO_REVERSE_SPEED := 0.5

## Si es false, se ignora todo input de conducción (menú/pausa/cuenta regresiva).
var input_enabled := true

@onready var _front_wheels: Array[VehicleWheel3D] = [$WheelFrontLeft, $WheelFrontRight]
@onready var _rear_wheels: Array[VehicleWheel3D] = [$WheelRearLeft, $WheelRearRight]


func _physics_process(delta: float) -> void:
	if not input_enabled:
		engine_force = 0.0
		_set_brakes(0.0, 0.0)
		steering = lerp(steering, 0.0, delta * STEER_LERP_SPEED)
		return

	if Input.is_action_just_pressed("reset"):
		_reset()

	var accel := Input.get_action_strength("accelerate")
	var brake_input := Input.get_action_strength("brake_reverse")
	# D (derecha) da +1. En Godot, steering positivo gira a la IZQUIERDA, así que se
	# negará abajo para que D gire a la derecha (coherente con el avance invertido).
	var steer_dir := Input.get_axis("steer_left", "steer_right")
	var handbrake_on := Input.is_action_pressed("handbrake")

	# DECISION_PENDIENTE: el frenado se aplica directamente por rueda (VehicleWheel3D.brake)
	# en vez de usar VehicleBody3D.brake, para poder limitar el freno de mano a las traseras
	# sin depender de cómo distribuye el motor de físicas el valor del body.
	if handbrake_on:
		engine_force = 0.0
		_set_brakes(0.0, HANDBRAKE_FORCE)
	elif accel > 0.0:
		engine_force = accel * ENGINE_FORCE_MAX
		_set_brakes(0.0, 0.0)
	elif brake_input > 0.0:
		if linear_velocity.length() > BRAKE_TO_REVERSE_SPEED:
			engine_force = 0.0
			_set_brakes(BRAKE_FORCE, BRAKE_FORCE)
		else:
			engine_force = brake_input * REVERSE_FORCE_MAX
			_set_brakes(0.0, 0.0)
	else:
		engine_force = 0.0
		_set_brakes(0.0, 0.0)

	var speed := linear_velocity.length()
	var max_steer: float = MAX_STEER_BASE * clamp(1.0 - speed / STEER_SPEED_REF, STEER_MIN_FACTOR, 1.0)
	steering = lerp(steering, -steer_dir * max_steer, delta * STEER_LERP_SPEED)


func _set_brakes(front_force: float, rear_force: float) -> void:
	for wheel in _front_wheels:
		wheel.brake = front_force
	for wheel in _rear_wheels:
		wheel.brake = rear_force


func _reset() -> void:
	var yaw := rotation.y
	global_position += Vector3.UP * RESET_LIFT
	_settle(yaw)
	print("vehículo reiniciado en %s" % global_position)


## Recoloca el vehículo en pos con rotación solo-yaw y velocidades a cero.
## Usado por los modos de juego (contrato GameMode) para posicionar al vehículo.
func teleport(pos: Vector3, yaw: float) -> void:
	global_position = pos
	_settle(yaw)
	print("vehículo teletransportado a %s" % global_position)


func _settle(yaw: float) -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
