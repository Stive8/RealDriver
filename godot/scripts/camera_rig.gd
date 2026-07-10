extends Node3D

const POSITION_LERP_SPEED := 8.0
const YAW_LERP_SPEED := 4.0

@export var target_path: NodePath

var _target: Node3D


func _ready() -> void:
	_target = get_node_or_null(target_path)
	if _target == null:
		push_error("CameraRig: target_path no resuelve a ningún nodo (%s)" % target_path)
		return
	global_position = _target.global_position
	rotation.y = _target.rotation.y


func _physics_process(delta: float) -> void:
	if _target == null:
		return
	global_position = global_position.lerp(_target.global_position, delta * POSITION_LERP_SPEED)
	rotation.y = lerp_angle(rotation.y, _target.rotation.y, delta * YAW_LERP_SPEED)
