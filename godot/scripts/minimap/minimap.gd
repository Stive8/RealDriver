class_name Minimap
extends Control
## Minimapa (Fase M-4): hornea una vez la red vial completa en un SubViewport y
## redibuja SOLO la capa de ruta cuando el modo activo emite route_changed. El shader
## (shaders/minimap.gdshader) traslada+rota la textura horneada para que arriba = rumbo
## del vehículo. GameFlow informa el modo activo vía set_active_mode()/set_active_mode(null).

# [ESTRUCTURAL] — válidas para cualquier ciudad.
const DIAMETER_PX := 220.0
const MARGIN_PX := 16.0
const ROAD_COLOR := Color(0.75, 0.75, 0.75, 1.0)
const ROAD_MIN_PX := 1.0
const ROAD_MAX_PX := 8.0
const ROUTE_COLOR := Color(1.0, 0.65, 0.0, 1.0)
const ROUTE_WIDTH_PX := 4.0
const CHECKPOINT_RADIUS_PX := 6.0
const START_COLOR := Color(1.0, 0.9, 0.15, 1.0)
const CHECKPOINT_COLOR := Color(1.0, 0.65, 0.0, 1.0)
const NEXT_CHECKPOINT_COLOR := Color(0.25, 1.0, 0.35, 1.0)
const NORTH_INSET_PX := 14.0
const PLAYER_ARROW_SIZE_PX := 8.0

# [ESTRUCTURAL] Fase C-3 (contrato 6): MINIMAP_VIEW_RADIUS es fijo para cualquier ciudad;
# MINIMAP_BAKE_RES se deriva de map_meta.stats (ver _compute_bake_res). Legado (sin stats):
# mismo span de Jordán que time_trial_mode.gd usa para su rama de compatibilidad.
const MINIMAP_VIEW_RADIUS := 150.0   ## radio visible del minimapa (m).
const LEGACY_SPAN_X := 1860.0
const LEGACY_SPAN_Z := 1056.0

@export var vehicle_path: NodePath
@export var map_path: NodePath

@onready var _vehicle: VehicleBody3D = get_node(vehicle_path) as VehicleBody3D
@onready var _map: Node3D = get_node(map_path) as Node3D

var _sub_viewport: SubViewport
var _roads_layer: Node2D
var _route_layer: Node2D
var _display: ColorRect
var _shader_material: ShaderMaterial
var _north_label: Label

var _bake_res: int = 1024
var _world_min := Vector2.ZERO
var _world_span := 1.0

var _route_polyline: PackedVector2Array = PackedVector2Array()
var _route_markers: Array = []

var _active_mode: GameMode = null


func _ready() -> void:
	_bake_res = _compute_bake_res()
	print("minimapa: bake_res=%d" % _bake_res)
	_compute_world_bounds()
	_build_display_layout()
	_build_viewport()
	_build_overlay_nodes()
	_bake_roads()


func _compute_bake_res() -> int:
	var stats: Dictionary = _map.map_meta.get("stats", {})
	var span_x: float = stats.get("span_x", LEGACY_SPAN_X)
	var span_z: float = stats.get("span_z", LEGACY_SPAN_Z)
	return 1024 if maxf(span_x, span_z) <= 2000.0 else 2048


## Llamado por GameFlow al arrancar (con el modo) y al parar (con null).
func set_active_mode(mode: GameMode) -> void:
	if _active_mode != null and _active_mode.route_changed.is_connected(_on_route_changed):
		_active_mode.route_changed.disconnect(_on_route_changed)
	_active_mode = mode
	if _active_mode != null:
		_active_mode.route_changed.connect(_on_route_changed)
		_on_route_changed()
	else:
		_route_polyline = PackedVector2Array()
		_route_markers = []
		_redraw_route()


func _process(_delta: float) -> void:
	if _vehicle == null or _shader_material == null:
		return
	var pos: Vector3 = _vehicle.global_position
	var heading: float = _vehicle.rotation.y
	_shader_material.set_shader_parameter("player_uv", _world_to_uv(Vector2(pos.x, pos.z)))
	_shader_material.set_shader_parameter("heading", heading)
	_update_north_label(heading)


# ---------------------------------------------------------------------------
# Mundo <-> UV/px del horneado
# ---------------------------------------------------------------------------
# Se acota al área jugable real (perímetro amurallado, cuadrado centrado en el origen;
# ver map_loader.gd), NO al rectángulo envolvente del grafo completo: el grafo de calles
# incluye vías del export de OSM más allá del muro (en el mapa de Jordán, ~37% de los
# nodos), que inflarían el mundo horneado (~3000 m en vez de ~1120 m) y reducirían la
# resolución efectiva del minimapa sin aportar nada (esas calles no son alcanzables).
func _compute_world_bounds() -> void:
	var half: float = _map.play_area_half_extent
	_world_min = Vector2(-half, -half)
	_world_span = half * 2.0
	if _world_span <= 0.0:
		_world_span = 1.0


func _world_to_uv(world_xz: Vector2) -> Vector2:
	return (world_xz - _world_min) / _world_span


func _world_to_px(world_xz: Vector2) -> Vector2:
	return _world_to_uv(world_xz) * _bake_res


# ---------------------------------------------------------------------------
# Layout del círculo (abajo-izquierda, margen fijo) y widget con el shader
# ---------------------------------------------------------------------------
func _build_display_layout() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = MARGIN_PX
	offset_bottom = -MARGIN_PX
	offset_right = MARGIN_PX + DIAMETER_PX
	offset_top = -MARGIN_PX - DIAMETER_PX
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_display = ColorRect.new()
	_display.name = "Display"
	_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = load("res://shaders/minimap.gdshader") as Shader
	_shader_material.set_shader_parameter("view_uv_radius", MINIMAP_VIEW_RADIUS / _world_span)
	_display.material = _shader_material
	add_child(_display)


func _build_viewport() -> void:
	_sub_viewport = SubViewport.new()
	_sub_viewport.name = "Bake"
	_sub_viewport.size = Vector2i(_bake_res, _bake_res)
	_sub_viewport.transparent_bg = true
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_sub_viewport)

	_roads_layer = Node2D.new()
	_roads_layer.name = "RoadsLayer"
	_roads_layer.draw.connect(_draw_roads)
	_sub_viewport.add_child(_roads_layer)

	_route_layer = Node2D.new()
	_route_layer.name = "RouteLayer"
	_route_layer.draw.connect(_draw_route)
	_sub_viewport.add_child(_route_layer)

	_shader_material.set_shader_parameter("map_tex", _sub_viewport.get_texture())


func _build_overlay_nodes() -> void:
	var arrow := Polygon2D.new()
	arrow.name = "PlayerArrow"
	var s := PLAYER_ARROW_SIZE_PX
	arrow.polygon = PackedVector2Array([Vector2(0.0, -s), Vector2(s * 0.6, s * 0.6), Vector2(-s * 0.6, s * 0.6)])
	arrow.color = Color(0.95, 0.15, 0.15, 1.0)
	arrow.position = Vector2(DIAMETER_PX * 0.5, DIAMETER_PX * 0.5)
	add_child(arrow)

	_north_label = Label.new()
	_north_label.name = "NorthLabel"
	_north_label.text = "N"
	_north_label.add_theme_font_size_override("font_size", 14)
	_north_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	_north_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	_north_label.add_theme_constant_override("outline_size", 3)
	_north_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_north_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_north_label.size = Vector2(20.0, 20.0)
	add_child(_north_label)
	_update_north_label(0.0)


## Norte = dirección mundo (0,-1) en la convención (dx,dz) del proyecto (+Z=sur, ver
## TrafficManager._right). Misma rotación que aplica el shader (ver shaders/minimap.gdshader)
## para que el indicador de norte concuerde con la textura.
func _update_north_label(heading: float) -> void:
	var center := Vector2(DIAMETER_PX * 0.5, DIAMETER_PX * 0.5)
	var radius := DIAMETER_PX * 0.5 - NORTH_INSET_PX
	var offset := Vector2(sin(heading), -cos(heading)) * radius
	_north_label.position = center + offset - _north_label.size * 0.5


# ---------------------------------------------------------------------------
# Horneado de vías (una vez)
# ---------------------------------------------------------------------------
func _bake_roads() -> void:
	_roads_layer.queue_redraw()
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _draw_roads() -> void:
	var t0 := Time.get_ticks_msec()
	var graph: TrafficGraph = _map.graph
	var px_per_meter := _bake_res / _world_span
	for e in range(graph.edge_from.size()):
		var a := _world_to_px(graph.node_pos[graph.edge_from[e]])
		var b := _world_to_px(graph.node_pos[graph.edge_to[e]])
		var w := clampf(graph.edge_width[e] * px_per_meter, ROAD_MIN_PX, ROAD_MAX_PX)
		_roads_layer.draw_line(a, b, ROAD_COLOR, w)
	print("[minimapa] horneado mapa %d ms (res %d)" % [Time.get_ticks_msec() - t0, _bake_res])


# ---------------------------------------------------------------------------
# Capa de ruta (solo al recibir route_changed del modo activo)
# ---------------------------------------------------------------------------
func _on_route_changed() -> void:
	if _active_mode == null:
		return
	var overlay := _active_mode.get_route_overlay()
	_route_polyline = overlay.get("polyline", PackedVector2Array())
	_route_markers = overlay.get("markers", [])
	_redraw_route()


func _redraw_route() -> void:
	_route_layer.queue_redraw()
	_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _draw_route() -> void:
	var t0 := Time.get_ticks_msec()
	if _route_polyline.size() >= 2:
		var px_points := PackedVector2Array()
		px_points.resize(_route_polyline.size())
		for i in range(_route_polyline.size()):
			px_points[i] = _world_to_px(_route_polyline[i])
		_route_layer.draw_polyline(px_points, ROUTE_COLOR, ROUTE_WIDTH_PX)
	# _route_markers viene en orden de recorrido y ya excluye los cobrados (ver
	# TimeTrialMode.get_route_overlay): el índice 0 es siempre el siguiente pendiente.
	for i in range(_route_markers.size()):
		var marker: Dictionary = _route_markers[i]
		var pos: Vector2 = marker["pos"]
		var kind: String = marker["kind"]
		var px := _world_to_px(pos)
		var col: Color
		if kind == "start":
			col = START_COLOR
		elif i == 0:
			col = NEXT_CHECKPOINT_COLOR
		else:
			col = CHECKPOINT_COLOR
		_route_layer.draw_circle(px, CHECKPOINT_RADIUS_PX, col)
	print("[minimapa] horneado ruta %d ms" % (Time.get_ticks_msec() - t0))
