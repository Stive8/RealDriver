extends Node3D

const MAP_PATH := "res://data/map.json"
const PERIMETER_HALF := 560.0
const PERIMETER_THICK := 2.0

## Grafo de tráfico ya construido (Fase T-0), metadatos de map.json y medio-extent del
## área jugable (perímetro amurallado, mismo valor para cualquier ciudad), expuestos para
## que GameFlow los pase a los modos vía ModeContext (Fase M-1) y para que el minimapa
## acote su horneado al área realmente alcanzable (Fase M-4: el grafo de calles incluye
## vías del export de OSM más allá del muro, que inflarían el mundo horneado si se usaran
## para acotar en vez de este valor).
var graph: TrafficGraph
var map_meta: Dictionary
var play_area_half_extent: float = PERIMETER_HALF

## Fase R-2: única fuente de verdad para la altura del terreno. Se inicializa en modo
## plano (TerrainSampler.new() sin setup()) para que cualquier lectura antes de _ready()
## devuelva 0.0 en vez de fallar; setup() lo llena en _ready() con la grilla real (o {}
## si map.json es de un esquema anterior a 1.2, dejándolo en modo plano).
var terrain_sampler: TerrainSampler = TerrainSampler.new()

var _vehicle: VehicleBody3D
var _hud_label: Label
var _traffic_debug: Node3D


func _ready() -> void:
	var start_ms := Time.get_ticks_msec()

	var file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if file == null:
		push_error("No se pudo abrir %s" % MAP_PATH)
		return

	var json_text := file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("map.json no es un JSON válido")
		return

	var roads: Array = data.get("roads", [])
	var buildings: Array = data.get("buildings", [])
	# v1.1 retrocompatible: controls ausente = lista vacía (map.json v1.0 carga sin errores).
	var controls: Array = data.get("controls", [])
	map_meta = data.get("meta", {})

	# --- Terreno (Fase R-2): ANTES que calles/edificios. terrain ausente o schema < 1.2
	# -> {} -> TerrainSampler y TerrainBuilder caen a su modo plano (compatibilidad). ---
	var terrain: Dictionary = data.get("terrain", {})
	terrain_sampler.setup(terrain)

	var terrain_start_ms := Time.get_ticks_msec()
	var terrain_node := TerrainBuilder.build(terrain)
	add_child(terrain_node)
	var terrain_ms := Time.get_ticks_msec() - terrain_start_ms
	var terrain_nx: int = int(terrain.get("nx", 2))
	var terrain_nz: int = int(terrain.get("nz", 2))
	var terrain_tris := 2 * (terrain_nx - 1) * (terrain_nz - 1)
	print("terreno %dx%d, %d tris, rango 0..%.1f m, %d ms" % [
		terrain_nx, terrain_nz, terrain_tris, terrain_sampler.max_height, terrain_ms])

	# --- Roads geometry + collision ---
	var roads_mesh := RoadBuilder.build(roads)
	var roads_body := _wrap_trimesh_collision(roads_mesh, "Roads")
	add_child(roads_body)

	# --- Buildings geometry + collision ---
	var buildings_mesh := BuildingBuilder.build(buildings)
	var buildings_body := _wrap_trimesh_collision(buildings_mesh, "Buildings")
	add_child(buildings_body)

	# --- Buildings outline (toon inverted hull) ---
	var outline := BuildingBuilder.build_outline(buildings_mesh.mesh)
	buildings_body.add_child(outline)

	# --- Perimeter walls ---
	_add_perimeter_walls()

	# --- Props (trees + parked cars, decorative, no collision) ---
	var props := PropScatter.scatter(roads, buildings)
	add_child(props)

	# --- Grafo de tráfico (Fase T-0): construcción, clasificación y diagnóstico ---
	graph = TrafficGraph.new()
	graph.build(roads, controls)
	graph.print_diagnostics()
	_traffic_debug = graph.build_debug_overlay()
	_traffic_debug.visible = false  # se muestra/oculta con G (toggle_traffic_debug)
	add_child(_traffic_debug)

	# --- Gestor de tráfico (Fases T-1/T-2): población cinemática sobre el grafo ---
	var traffic_manager := TrafficManager.new()
	traffic_manager.name = "TrafficManager"
	traffic_manager.setup(graph, get_node("../Vehicle") as Node3D, terrain_sampler)
	add_child(traffic_manager)

	# --- Reference to Vehicle for HUD ---
	_vehicle = get_node("../Vehicle") as VehicleBody3D
	if _vehicle == null:
		push_error("MapLoader: no se encontró Vehicle en ../Vehicle")

	# --- HUD se crea en deferred para tree completamente listo ---
	call_deferred("_deferred_setup_ui")

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("%d vías, %d edificios, %d ms" % [roads.size(), buildings.size(), elapsed_ms])
	print("Fase V-3: árboles y autos decorativos vía prop_scatter.gd (MultiMesh)")


func _deferred_setup_ui() -> void:
	var hud_canvas := _create_hud()
	hud_canvas.layer = 128
	get_tree().root.add_child(hud_canvas)
	_hud_label = hud_canvas.find_child("SpeedLabel", true, false) as Label


# ---------------------------------------------------------------------------
# Colisión trimesh para una malla combinada
# ---------------------------------------------------------------------------
func _wrap_trimesh_collision(mesh_instance: MeshInstance3D, base_name: String) -> StaticBody3D:
	var static_body := StaticBody3D.new()
	static_body.name = base_name + "Collision"

	mesh_instance.name = base_name + "Mesh"
	static_body.add_child(mesh_instance)

	var shape := mesh_instance.mesh.create_trimesh_shape()
	if shape == null:
		push_error("No se pudo crear trimesh shape para %s" % base_name)
	else:
		var col := CollisionShape3D.new()
		col.name = base_name + "Shape"
		col.shape = shape
		static_body.add_child(col)

	return static_body


# ---------------------------------------------------------------------------
# Muros de perímetro (4 cajas en ±560, altura derivada del relieve: Fase R-2)
# ---------------------------------------------------------------------------
func _add_perimeter_walls() -> void:
	var max_h := terrain_sampler.max_height
	# DECISION_PENDIENTE: el ESPEC da centro = (max_height + 20) / 2 − 5, pero esa fórmula
	# no reproduce el rango que el propio ESPEC declara como objetivo ("de y=−5 a
	# max_height + 25"): con la fórmula tal cual, el rango real sale [-10, max_height+20].
	# Se prioriza el rango declarado explícitamente (más inequívoco) y se despeja el
	# centro a partir de él: centro = (max_height + 20) / 2 (sin el −5).
	var wall_height := max_h + 30.0
	var wall_center_y := (max_h + 20.0) / 2.0

	var wall_shape_x := BoxShape3D.new()
	wall_shape_x.size = Vector3(PERIMETER_THICK, wall_height, PERIMETER_HALF * 2.0)

	var wall_shape_z := BoxShape3D.new()
	wall_shape_z.size = Vector3(PERIMETER_HALF * 2.0, wall_height, PERIMETER_THICK)

	var configs := [
		{ "name": "WallEast",  "pos": Vector3( PERIMETER_HALF, wall_center_y, 0.0),               "shape": wall_shape_x },
		{ "name": "WallWest",  "pos": Vector3(-PERIMETER_HALF, wall_center_y, 0.0),               "shape": wall_shape_x },
		{ "name": "WallNorth", "pos": Vector3(0.0, wall_center_y, -PERIMETER_HALF),               "shape": wall_shape_z },
		{ "name": "WallSouth", "pos": Vector3(0.0, wall_center_y,  PERIMETER_HALF),               "shape": wall_shape_z },
	]

	for cfg in configs:
		var body := StaticBody3D.new()
		body.name = cfg["name"]
		body.position = cfg["pos"]
		var col := CollisionShape3D.new()
		col.shape = cfg["shape"]
		body.add_child(col)
		add_child(body)


# ---------------------------------------------------------------------------
# HUD: velocidad en km/h
# ---------------------------------------------------------------------------
func _create_hud() -> CanvasLayer:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"

	var bg := ColorRect.new()
	bg.anchor_left = 0.0
	bg.anchor_top = 1.0
	bg.anchor_right = 0.0
	bg.anchor_bottom = 1.0
	bg.offset_left = 10.0
	bg.offset_top = -50.0
	bg.offset_right = 200.0
	bg.offset_bottom = -10.0
	bg.color = Color(0.0, 0.0, 0.0, 0.5)
	canvas.add_child(bg)

	var label := Label.new()
	label.name = "SpeedLabel"
	label.text = "0 km/h"
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	label.add_theme_constant_override("outline_size", 3)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	bg.add_child(label)

	return canvas


# ---------------------------------------------------------------------------
# Actualizar HUD cada frame
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	# Overlay de tráfico (T-0): tecla G.
	if _traffic_debug != null and Input.is_action_just_pressed("toggle_traffic_debug"):
		_traffic_debug.visible = not _traffic_debug.visible

	if _vehicle == null or _hud_label == null:
		return
	var speed_kmh := _vehicle.linear_velocity.length() * 3.6
	_hud_label.text = "%d km/h" % speed_kmh