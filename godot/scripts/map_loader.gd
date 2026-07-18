extends Node3D

## Fase C-3: la ruta ya no es fija -- viene de CityLibrary (biblioteca local o
## res://data/map.json si no hay seleccion / el archivo esta corrupto).
const FALLBACK_MAP_PATH := "res://data/map.json"
const PERIMETER_MARGIN := 30.0
const PERIMETER_THICK := 2.0
## Contrato 6: JSON 1.1/1.2 sin `stats` -> extent/span legado de Jordán (nunca alcanzado
## por el Jordán empaquetado hoy, que ya trae stats desde Fase C-1).
const LEGACY_EXTENT := [-560.0, -530.0, 560.0, 530.0]
## [ESTRUCTURAL] Fase R-4: paso de remuestreo para detectar la pendiente máxima al cargar
## (espejo de SLOPE_SAMPLE_STEP en generate_map.py).
const SLOPE_SAMPLE_STEP := 10.0

## Grafo de tráfico ya construido (Fase T-0), metadatos de map.json y medio-extent del
## área jugable (perímetro amurallado, mismo valor para cualquier ciudad), expuestos para
## que GameFlow los pase a los modos vía ModeContext (Fase M-1) y para que el minimapa
## acote su horneado al área realmente alcanzable (Fase M-4: el grafo de calles incluye
## vías del export de OSM más allá del muro, que inflarían el mundo horneado si se usaran
## para acotar en vez de este valor).
var graph: TrafficGraph
var map_meta: Dictionary
var play_area_half_extent: float = 0.0

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

	var map_path := CityLibrary.get_selected_map_path()
	var data = _load_map_data(map_path)
	if data == null:
		push_warning("MapLoader: %s invalido/corrupto; usando Jordán empaquetado" % map_path)
		map_path = FALLBACK_MAP_PATH
		data = _load_map_data(map_path)
	if data == null:
		push_error("MapLoader: no se pudo cargar ni siquiera %s" % FALLBACK_MAP_PATH)
		return

	var roads: Array = data.get("roads", [])
	var buildings: Array = data.get("buildings", [])
	# v1.1 retrocompatible: controls ausente = lista vacía (map.json v1.0 carga sin errores).
	var controls: Array = data.get("controls", [])
	map_meta = data.get("meta", {})

	_vehicle = get_node("../Vehicle") as VehicleBody3D
	if _vehicle == null:
		push_error("MapLoader: no se encontró Vehicle en ../Vehicle")

	var stats: Dictionary = map_meta.get("stats", {})
	var extent: Array = stats.get("extent_m", LEGACY_EXTENT) if not stats.is_empty() else LEGACY_EXTENT
	print("mapa cargado: %s (zone_id=%s)" % [map_path, str(map_meta.get("zone_id", "n/a"))])
	print("span: %.1f x %.1f m" % [stats.get("span_x", 0.0), stats.get("span_z", 0.0)])

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

	# --- Agua (Fase W-2, ESPEC_SESION_RETROFIT_AGUA_V2, contrato 5): ANTES que calles
	# (jerarquía visual: agua +0.05 < calzada +0.10). Ausente en JSON < 1.4 -> listas
	# vacías -> WaterBuilder construye una malla vacía sin error (compatibilidad). ---
	var water_areas: Array = data.get("water_areas", [])
	var water_ways: Array = data.get("water_ways", [])
	var water_mesh := WaterBuilder.build(water_areas, water_ways, terrain_sampler)
	add_child(water_mesh)

	# --- Roads geometry + collision ---
	var roads_mesh := RoadBuilder.build(roads, terrain_sampler)
	var roads_body := _wrap_trimesh_collision(roads_mesh, "Roads")
	add_child(roads_body)

	# --- Buildings visual (MultiMesh from .glb assets) ---
	var buildings_visual := BuildingBuilder.build_with_assets(buildings, terrain_sampler)
	add_child(buildings_visual)

	# --- Buildings collision (single merged trimesh via procedural build) ---
	var proc_buildings := BuildingBuilder.build(buildings, terrain_sampler)
	var buildings_body := StaticBody3D.new()
	buildings_body.name = "BuildingsCollision"
	var shape := proc_buildings.mesh.create_trimesh_shape()
	if shape != null:
		var col := CollisionShape3D.new()
		col.shape = shape
		buildings_body.add_child(col)
	proc_buildings.queue_free()
	add_child(buildings_body)

	# --- Perimeter walls ---
	_add_perimeter_walls(extent)

	# --- Props (trees + parked cars, decorative, no collision) ---
	var props := PropScatter.scatter(roads, buildings, terrain_sampler)
	add_child(props)

	# --- Grafo de tráfico (Fase T-0): construcción, clasificación y diagnóstico ---
	graph = TrafficGraph.new()
	graph.build(roads, controls, terrain_sampler)
	graph.print_diagnostics()
	_traffic_debug = graph.build_debug_overlay(terrain_sampler)
	_traffic_debug.visible = false  # se muestra/oculta con G (toggle_traffic_debug)
	add_child(_traffic_debug)

	# --- Gestor de tráfico (Fases T-1/T-2): población cinemática sobre el grafo ---
	var traffic_manager := TrafficManager.new()
	traffic_manager.name = "TrafficManager"
	traffic_manager.setup(graph, get_node("../Vehicle") as Node3D, terrain_sampler)
	add_child(traffic_manager)

	# --- Spawn del vehículo (Fase C-3): derivado del grafo, no fijo en la escena.
	# Diferido: vehicle.gd tiene su propio _ready() que reinterpreta la y actual como
	# margen sobre el terreno; si Map lo teletransporta ANTES de que corra, ese _ready()
	# vuelve a sumar el terreno sobre una y ya absoluta (doble altura). call_deferred
	# garantiza que esto corre después de todos los _ready() del frame actual. ---
	var spawn := RouteGenerator.pick_start_node(graph)
	if spawn.is_empty():
		push_warning("MapLoader: grafo sin nodos validos para spawn; el vehiculo queda en su posicion de escena")
	else:
		call_deferred("_deferred_position_vehicle", spawn)

	# --- HUD se crea en deferred para tree completamente listo ---
	call_deferred("_deferred_setup_ui")

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("%d vías, %d edificios, %d ms" % [roads.size(), buildings.size(), elapsed_ms])
	print("Fase V-3: árboles y autos decorativos vía prop_scatter.gd (MultiMesh)")

	# --- Fase R-4: pendiente máxima detectada AL CARGAR, recorriendo las vías con el
	# TerrainSampler real de Godot (espejo en vivo del --stats de generate_map.py). ---
	var slope_info := _max_road_slope(roads)
	print("pendiente máxima detectada al cargar: %.1f%% (vía id %d)" % [slope_info["slope"], slope_info["road_id"]])


func _deferred_setup_ui() -> void:
	var hud_canvas := _create_hud()
	hud_canvas.layer = 128
	get_tree().root.add_child(hud_canvas)
	_hud_label = hud_canvas.find_child("SpeedLabel", true, false) as Label


func _deferred_position_vehicle(spawn: Dictionary) -> void:
	if _vehicle == null:
		return
	var pos: Vector2 = spawn["pos"]
	_vehicle.teleport(Vector3(pos.x, 1.0, pos.y), spawn["yaw"])
	print("spawn elegido: nodo en (%.2f, %.2f), yaw=%.2f" % [pos.x, pos.y, spawn["yaw"]])


func _load_map_data(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var json_text := file.get_as_text()
	file.close()
	var data = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		return null
	return data


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
# Muros de perímetro (Fase C-3: rectángulo en stats.extent_m ± 30 m, cualquier ciudad;
# altura derivada del relieve, Fase R-2, intacta)
# ---------------------------------------------------------------------------
func _add_perimeter_walls(extent: Array) -> void:
	var xmin: float = float(extent[0]) - PERIMETER_MARGIN
	var zmin: float = float(extent[1]) - PERIMETER_MARGIN
	var xmax: float = float(extent[2]) + PERIMETER_MARGIN
	var zmax: float = float(extent[3]) + PERIMETER_MARGIN
	# Cuadrado que SIEMPRE contiene el rectángulo real: usado solo por minimap.gd
	# (play_area_half_extent), que asume un área cuadrada centrada en el origen.
	play_area_half_extent = maxf(maxf(absf(xmin), absf(xmax)), maxf(absf(zmin), absf(zmax)))

	var width := xmax - xmin
	var depth := zmax - zmin
	var cx := (xmin + xmax) * 0.5
	var cz := (zmin + zmax) * 0.5

	var max_h := terrain_sampler.max_height
	# DECISION_PENDIENTE: el ESPEC da centro = (max_height + 20) / 2 − 5, pero esa fórmula
	# no reproduce el rango que el propio ESPEC declara como objetivo ("de y=−5 a
	# max_height + 25"): con la fórmula tal cual, el rango real sale [-10, max_height+20].
	# Se prioriza el rango declarado explícitamente (más inequívoco) y se despeja el
	# centro a partir de él: centro = (max_height + 20) / 2 (sin el −5).
	var wall_height := max_h + 30.0
	var wall_center_y := (max_h + 20.0) / 2.0

	var wall_shape_x := BoxShape3D.new()  # muros este/oeste: delgado en X, largo en Z
	wall_shape_x.size = Vector3(PERIMETER_THICK, wall_height, depth)

	var wall_shape_z := BoxShape3D.new()  # muros norte/sur: largo en X, delgado en Z
	wall_shape_z.size = Vector3(width, wall_height, PERIMETER_THICK)

	var configs := [
		{ "name": "WallEast",  "pos": Vector3(xmax, wall_center_y, cz),   "shape": wall_shape_x },
		{ "name": "WallWest",  "pos": Vector3(xmin, wall_center_y, cz),   "shape": wall_shape_x },
		{ "name": "WallNorth", "pos": Vector3(cx, wall_center_y, zmin),   "shape": wall_shape_z },
		{ "name": "WallSouth", "pos": Vector3(cx, wall_center_y, zmax),   "shape": wall_shape_z },
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
# Pendiente máxima de vía (Fase R-4): remuestrea cada vía cada SLOPE_SAMPLE_STEP m y
# compara alturas vía terrain_sampler. Espejo en vivo de road_slope_stats() en
# generate_map.py, pero contra el sampler real de Godot (no el que generó el JSON).
# ---------------------------------------------------------------------------
func _max_road_slope(roads: Array) -> Dictionary:
	var max_slope := 0.0
	var max_road_id := -1
	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		for i in range(points.size() - 1):
			var a := Vector2(points[i][0], points[i][1])
			var b := Vector2(points[i + 1][0], points[i + 1][1])
			var seg_len := a.distance_to(b)
			if seg_len < 0.01:
				continue
			var steps := maxi(1, int(ceil(seg_len / SLOPE_SAMPLE_STEP)))
			var prev_h := terrain_sampler.height_at(a.x, a.y)
			for s in range(1, steps + 1):
				var p := a.lerp(b, float(s) / float(steps))
				var h := terrain_sampler.height_at(p.x, p.y)
				var d := seg_len / steps
				if d > 0.01:
					var slope := absf(h - prev_h) / d * 100.0
					if slope > max_slope:
						max_slope = slope
						max_road_id = int(road.get("id", -1))
				prev_h = h
	return {"slope": max_slope, "road_id": max_road_id}


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
