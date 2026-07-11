class_name FreeDriveMode
extends GameMode
## Conducción libre (Fase M-1): el vehículo queda donde esté con input habilitado.
## No emite `finished` nunca; se sale por ESC -> Abandonar (GameFlow).

var _ctx: ModeContext


func get_mode_id() -> String:
	return "free_drive"


func get_display_name() -> String:
	return "Conducción libre"


func configure(ctx: ModeContext) -> void:
	_ctx = ctx


func start_mode() -> void:
	_ctx.vehicle.input_enabled = true
	print("[free_drive] iniciado")


func stop_mode() -> void:
	_ctx.vehicle.input_enabled = false
	print("[free_drive] detenido")
