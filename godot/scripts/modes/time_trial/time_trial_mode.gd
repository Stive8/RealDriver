class_name TimeTrialMode
extends GameMode
## Contrarreloj (Fase M-3): genera una ruta en bucle (RouteGenerator), cuenta
## regresiva 3-2-1-GO, cobra checkpoints en orden (solo el siguiente, distancia XZ),
## cronometra y guarda el mejor tiempo por ciudad+ruta (BestTimes).

# [ESTRUCTURAL] — válidas para cualquier ciudad.
const COUNTDOWN_SECONDS := 3
const GO_FLASH_SECONDS := 0.4         ## cuánto se muestra "GO" antes de ocultar el label;
                                       ## puramente cosmético, input y reloj ya arrancaron.
const ROUTE_SEED := 0                 ## determinista: mismo mapa -> misma ruta.
const MARKER_DIM_ALPHA := 0.12        ## alfa del checkpoint ya cobrado.
const MARKER_DEFAULT_ALPHA := 0.35    ## alfa de un checkpoint futuro (aún no es el siguiente).
const MARKER_PENDING_ALPHA := 0.85    ## alfa del siguiente checkpoint pendiente (más brillante).
# DECISION_PENDIENTE: el resaltado del siguiente checkpoint se hace SOLO con alfa (brillo),
# nunca con escala: escalar la malla agranda el círculo visible por encima del radio real de
# detección (cp["radius"]), haciendo creer que el checkpoint se cobra en un área más grande
# de la que realmente dispara _check_next_checkpoint() (reportado por el humano: "pasaba por
# los checkpoints y no pasaba nada" al conducir por el borde del círculo agrandado).
const VEHICLE_TELEPORT_Y := 1.0       ## altura de asiento del chasis (ver Vehicle en main.tscn).
const _EPS := 1e-4

var _ctx: ModeContext
var _route: RouteGenerator.RouteData = null
var _city_id: String = ""

var _checkpoint_root: Node3D = null
var _checkpoint_meshes: Array = []  # MeshInstance3D, mismo orden que _route.checkpoints
var _next_checkpoint_index := 0

var _hud_root: Control = null
var _time_label: Label
var _cp_label: Label
var _best_label: Label
var _countdown_label: Label

var _elapsed_ms := 0.0
var _running := false        # true entre GO y meta
var _paused := false
var _countdown_active := false
var _countdown_remaining := 0.0
var _go_flash_remaining := 0.0

var _best_ms_at_start := -1


func get_mode_id() -> String:
	return "time_trial"


func get_display_name() -> String:
	return "Contrarreloj"


func configure(ctx: ModeContext) -> void:
	_ctx = ctx


func start_mode() -> void:
	_cleanup_visuals()

	_city_id = BestTimes.compute_city_id(_ctx.map_meta)
	_route = RouteGenerator.generate(_ctx.graph, RouteGenerator.TARGET_LOOP_LENGTH, RouteGenerator.CHECKPOINT_SPACING, ROUTE_SEED)
	if _route == null:
		print("[tt] no se pudo generar ruta: grafo insuficiente para el circuito")
		aborted.emit()
		return

	_next_checkpoint_index = 0
	_elapsed_ms = 0.0
	_running = false
	_paused = false
	_best_ms_at_start = BestTimes.get_best(_city_id, _route.route_id)

	_build_checkpoint_markers()
	_build_hud()
	_position_vehicle_at_start()
	_start_countdown()
	route_changed.emit()


func stop_mode() -> void:
	_cleanup_visuals()
	_ctx.vehicle.input_enabled = false
	_running = false
	_paused = false
	_countdown_active = false
	print("[tt] detenido")


func set_paused(p: bool) -> void:
	_paused = p


func get_route_overlay() -> Dictionary:
	if _route == null:
		return {}
	var markers: Array = []
	# El último checkpoint es S de nuevo (meta = salida, ver RouteGenerator): es el único
	# marcador "start" — misma convención que el color dorado de _build_checkpoint_cylinder.
	var last_index := _route.checkpoints.size() - 1
	# Solo los pendientes: los ya cobrados desaparecen del minimapa (se re-emite
	# route_changed en cada cobro, ver _on_checkpoint_reached).
	for i in range(_next_checkpoint_index, _route.checkpoints.size()):
		markers.append({"pos": _route.checkpoints[i]["pos"], "kind": "start" if i == last_index else "checkpoint"})
	return {"polyline": _route.polyline, "markers": markers}


func _physics_process(delta: float) -> void:
	if _ctx == null or _route == null:
		return
	if _paused:
		return

	if _countdown_active:
		_process_countdown(delta)
		return

	if _go_flash_remaining > 0.0:
		_go_flash_remaining -= delta
		if _go_flash_remaining <= 0.0 and _countdown_label != null:
			_countdown_label.visible = false

	if not _running:
		return

	_elapsed_ms += delta * 1000.0
	_update_time_label()
	_check_next_checkpoint()


# ---------------------------------------------------------------------------
# Cuenta regresiva
# ---------------------------------------------------------------------------
func _start_countdown() -> void:
	_ctx.vehicle.input_enabled = false
	_countdown_active = true
	_countdown_remaining = float(COUNTDOWN_SECONDS)
	_go_flash_remaining = 0.0
	_countdown_label.visible = true
	_countdown_label.text = str(COUNTDOWN_SECONDS)


func _process_countdown(delta: float) -> void:
	_countdown_remaining -= delta
	if _countdown_remaining > 0.0:
		_countdown_label.text = str(clampi(ceili(_countdown_remaining), 1, COUNTDOWN_SECONDS))
		return
	_countdown_active = false
	_countdown_label.text = "GO"
	_go_flash_remaining = GO_FLASH_SECONDS
	_ctx.vehicle.input_enabled = true
	_running = true
	_elapsed_ms = 0.0
	print("[tt] GO")


# ---------------------------------------------------------------------------
# Checkpoints: detección, cobro, marcadores
# ---------------------------------------------------------------------------
func _check_next_checkpoint() -> void:
	if _next_checkpoint_index >= _route.checkpoints.size():
		return
	var cp: Dictionary = _route.checkpoints[_next_checkpoint_index]
	var cp_pos: Vector2 = cp["pos"]
	var radius: float = cp["radius"]
	var vpos: Vector3 = _ctx.vehicle.global_position
	if Vector2(vpos.x, vpos.z).distance_to(cp_pos) < radius:
		_on_checkpoint_reached()


func _on_checkpoint_reached() -> void:
	_dim_checkpoint_marker(_next_checkpoint_index)
	_next_checkpoint_index += 1
	print("[tt] CP %d/%d t=%s" % [_next_checkpoint_index, _route.checkpoints.size(), _format_time(_elapsed_ms)])
	_update_cp_label()
	_highlight_next_marker()
	route_changed.emit()  # el minimapa quita el checkpoint recién cobrado de su capa de ruta
	if _next_checkpoint_index >= _route.checkpoints.size():
		_finish_race()


func _finish_race() -> void:
	_running = false
	var final_ms := _elapsed_ms
	var previous_best := _best_ms_at_start
	var is_record := BestTimes.try_save(_city_id, _route.route_id, int(round(final_ms)))
	var best_ms := BestTimes.get_best(_city_id, _route.route_id)
	print("[tt] meta: tiempo=%s récord_previo=%s récord_nuevo=%s" % [
		_format_time(final_ms),
		(_format_time(previous_best) if previous_best >= 0 else "ninguno"),
		is_record])
	finished.emit({
		"success": true,
		"stats": [["Tiempo", _format_time(final_ms)], ["Mejor", _format_time(best_ms)], ["Ruta", _route.route_id]],
		"record": is_record,
	})


func _dim_checkpoint_marker(index: int) -> void:
	if index < 0 or index >= _checkpoint_meshes.size():
		return
	var mi := _checkpoint_meshes[index] as MeshInstance3D
	var mat := mi.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color.a = MARKER_DIM_ALPHA


func _highlight_next_marker() -> void:
	for i in range(_checkpoint_meshes.size()):
		if i < _next_checkpoint_index:
			continue  # ya atenuado por _dim_checkpoint_marker; no lo pisamos
		var mi := _checkpoint_meshes[i] as MeshInstance3D
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color.a = MARKER_PENDING_ALPHA if i == _next_checkpoint_index else MARKER_DEFAULT_ALPHA


func _build_checkpoint_markers() -> void:
	_checkpoint_root = RouteGenerator.build_checkpoint_markers(_route.checkpoints, _terrain_sampler())
	add_child(_checkpoint_root)
	_checkpoint_meshes = _checkpoint_root.get_children()
	_highlight_next_marker()


## Fase R-3: los cilindros de checkpoint se apoyan en el terreno real. ModeContext no
## carga el sampler (no está en su contrato, ver mode_context.gd), así que se llega a él
## por el Vehicle -que sí trae ctx- y su hermano Map, igual que hace vehicle.gd consigo
## mismo en R-2. Nunca null en la práctica: un modo solo arranca tras pasar por el menú,
## mucho después de que Map._ready() haya corrido.
func _terrain_sampler() -> TerrainSampler:
	var map_node := _ctx.vehicle.get_node_or_null("../Map")
	if map_node == null:
		return null
	return map_node.get("terrain_sampler")


# ---------------------------------------------------------------------------
# Vehículo
# ---------------------------------------------------------------------------
func _position_vehicle_at_start() -> void:
	var p0: Vector2 = _route.polyline[0]
	var p1: Vector2 = _route.polyline[1] if _route.polyline.size() > 1 else p0 + Vector2(0.0, 1.0)
	var dir := p1 - p0
	# Misma convención que TrafficManager (yaw = atan2(dx, dz), dz = componente Y del Vector2 mundo).
	var yaw := atan2(dir.x, dir.y) if dir.length() > _EPS else 0.0
	_ctx.vehicle.teleport(Vector3(p0.x, VEHICLE_TELEPORT_Y, p0.y), yaw)


# ---------------------------------------------------------------------------
# HUD propio (placeholder; Control simples sobre ctx.hud_layer)
# ---------------------------------------------------------------------------
func _build_hud() -> void:
	_hud_root = Control.new()
	_hud_root.name = "TimeTrialHud"
	_hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ctx.hud_layer.add_child(_hud_root)

	_time_label = _make_label(48)
	_time_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_time_label.position = Vector2(-150.0, 16.0)
	_time_label.size = Vector2(300.0, 60.0)
	_hud_root.add_child(_time_label)

	_cp_label = _make_label(22)
	_cp_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_cp_label.position = Vector2(-150.0, 76.0)
	_cp_label.size = Vector2(300.0, 30.0)
	_hud_root.add_child(_cp_label)

	_best_label = _make_label(18)
	_best_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_best_label.position = Vector2(-150.0, 108.0)
	_best_label.size = Vector2(300.0, 26.0)
	_hud_root.add_child(_best_label)

	_countdown_label = _make_label(96)
	_countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	_countdown_label.position = Vector2(-100.0, -80.0)
	_countdown_label.size = Vector2(200.0, 160.0)
	_hud_root.add_child(_countdown_label)

	_update_time_label()
	_update_cp_label()
	_update_best_label()


func _make_label(font_size: int) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _update_time_label() -> void:
	_time_label.text = _format_time(_elapsed_ms)


func _update_cp_label() -> void:
	_cp_label.text = "CP %d/%d" % [_next_checkpoint_index, _route.checkpoints.size()]


func _update_best_label() -> void:
	_best_label.visible = _best_ms_at_start >= 0
	if _best_ms_at_start >= 0:
		_best_label.text = "Mejor: %s" % _format_time(_best_ms_at_start)


func _cleanup_visuals() -> void:
	if _checkpoint_root != null:
		_checkpoint_root.queue_free()
		_checkpoint_root = null
	_checkpoint_meshes.clear()
	if _hud_root != null:
		_hud_root.queue_free()
		_hud_root = null


static func _format_time(ms: float) -> String:
	var total_ms := int(round(ms))
	var minutes := total_ms / 60000
	var seconds := (total_ms / 1000) % 60
	var millis := total_ms % 1000
	return "%d:%02d.%03d" % [minutes, seconds, millis]
