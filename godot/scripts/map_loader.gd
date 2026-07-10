extends Node3D

const MAP_PATH := "res://data/map.json"
const PERIMETER_HALF := 560.0
const PERIMETER_HEIGHT := 20.0
const PERIMETER_THICK := 2.0

var _vehicle: VehicleBody3D
var _hud_label: Label
var _splash_canvas: CanvasLayer


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

	# --- Reference to Vehicle for HUD ---
	_vehicle = get_node("../Vehicle") as VehicleBody3D
	if _vehicle == null:
		push_error("MapLoader: no se encontró Vehicle en ../Vehicle")

	# --- Splash y HUD se crean en deferred para tree completamente listo ---
	call_deferred("_deferred_setup_ui")

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("%d vías, %d edificios, %d ms" % [roads.size(), buildings.size(), elapsed_ms])
	print("Fase V-3: árboles y autos decorativos vía prop_scatter.gd (MultiMesh)")


func _deferred_setup_ui() -> void:
	_splash_canvas = _create_splash()
	_splash_canvas.layer = 128
	get_tree().root.add_child(_splash_canvas)

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
# Muros de perímetro (4 cajas en ±560)
# ---------------------------------------------------------------------------
func _add_perimeter_walls() -> void:
	var wall_shape_x := BoxShape3D.new()
	wall_shape_x.size = Vector3(PERIMETER_THICK, PERIMETER_HEIGHT, PERIMETER_HALF * 2.0)

	var wall_shape_z := BoxShape3D.new()
	wall_shape_z.size = Vector3(PERIMETER_HALF * 2.0, PERIMETER_HEIGHT, PERIMETER_THICK)

	var configs := [
		{ "name": "WallEast",  "pos": Vector3( PERIMETER_HALF, PERIMETER_HEIGHT / 2.0, 0.0),               "shape": wall_shape_x },
		{ "name": "WallWest",  "pos": Vector3(-PERIMETER_HALF, PERIMETER_HEIGHT / 2.0, 0.0),               "shape": wall_shape_x },
		{ "name": "WallNorth", "pos": Vector3(0.0, PERIMETER_HEIGHT / 2.0, -PERIMETER_HALF),               "shape": wall_shape_z },
		{ "name": "WallSouth", "pos": Vector3(0.0, PERIMETER_HEIGHT / 2.0,  PERIMETER_HALF),               "shape": wall_shape_z },
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
# Pantalla inicial con atribución OSM
# ---------------------------------------------------------------------------
func _create_splash() -> CanvasLayer:
	var canvas := CanvasLayer.new()
	canvas.name = "SplashScreen"

	var bg := ColorRect.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.color = Color(0.0, 0.0, 0.0, 0.65)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(bg)

	var title := Label.new()
	title.text = "Ciudad Conducible"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.position = Vector2(0, 280)
	title.size = Vector2(1280, 80)
	bg.add_child(title)

	var attr := Label.new()
	attr.text = "Datos del mapa © OpenStreetMap contributors (ODbL)"
	attr.add_theme_font_size_override("font_size", 16)
	attr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	attr.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	attr.position = Vector2(0, 370)
	attr.size = Vector2(1280, 40)
	bg.add_child(attr)

	var hint := Label.new()
	hint.text = "Presiona cualquier tecla para comenzar"
	hint.add_theme_font_size_override("font_size", 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.position = Vector2(0, 430)
	hint.size = Vector2(1280, 30)
	bg.add_child(hint)

	return canvas


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
# Cerrar splash con cualquier tecla
# ---------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if _splash_canvas != null and _splash_canvas.visible:
		if event is InputEventKey:
			_splash_canvas.visible = false


# ---------------------------------------------------------------------------
# Actualizar HUD cada frame
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	if _vehicle == null or _hud_label == null:
		return
	var speed_kmh := _vehicle.linear_velocity.length() * 3.6
	_hud_label.text = "%d km/h" % speed_kmh