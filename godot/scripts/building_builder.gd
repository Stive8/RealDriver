class_name BuildingBuilder
extends RefCounted

const BUILDING_MATERIAL_PATH := "res://materials/building.tres"
const PALETTE: Array[Color] = [
	Color("c9b8a8"),
	Color("b8c4cc"),
	Color("cfc7b2"),
	Color("a8b0a0"),
]


static func build(buildings: Array) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# generate_normals() promedia la normal de vértices que comparten posición
	# (p.ej. la esquina donde una pared se junta con el techo), lo que da
	# normales inclinadas ahí y hace que pared y techo se vean como una sola
	# superficie doblada en vez de dos caras planas. -1 desactiva ese
	# suavizado para toda la malla.
	st.set_smooth_group(-1)

	var built_count := 0
	var discarded_count := 0

	for building in buildings:
		var points := _clean_footprint(building["footprint"])
		if points.size() < 3:
			discarded_count += 1
			continue

		var height: float = float(building["height"])
		var color: Color = PALETTE[int(building["id"]) % PALETTE.size()]

		if _add_building(st, points, height, color):
			built_count += 1
		else:
			discarded_count += 1

	st.generate_normals()
	st.set_material(load(BUILDING_MATERIAL_PATH))
	var mesh := st.commit()

	print("BuildingBuilder: %d edificios, %d descartados" % [built_count, discarded_count])

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Buildings"
	mesh_instance.mesh = mesh
	return mesh_instance


static func _clean_footprint(footprint: Array) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for p in footprint:
		points.append(Vector2(p[0], p[1]))

	if points.size() > 1 and points[0].is_equal_approx(points[points.size() - 1]):
		points.remove_at(points.size() - 1)

	# Solo importa que TODOS los edificios queden en una orientación
	# consistente entre sí (los datos de OSM no garantizan un sentido fijo);
	# cuál de las dos se elija aquí es arbitrario siempre que _add_building
	# use la fórmula de devanado acorde (comprobada por render en
	# aislamiento, ver comentario en _add_building).
	if _signed_area_xz(points) > 0.0:
		points.reverse()

	return points


static func _signed_area_xz(points: Array[Vector2]) -> float:
	var area := 0.0
	var n := points.size()
	for i in range(n):
		var a := points[i]
		var b := points[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	return area


static func _add_building(st: SurfaceTool, points: Array[Vector2], height: float, color: Color) -> bool:
	var polygon := PackedVector2Array(points)
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return false

	st.set_color(color)

	for i in range(0, triangles.size(), 3):
		st.add_vertex(_to_world(points[triangles[i]], height))
		st.add_vertex(_to_world(points[triangles[i + 1]], height))
		st.add_vertex(_to_world(points[triangles[i + 2]], height))

	# El orden (bottom0, top1, bottom1) / (bottom0, top0, top1) -no
	# (bottom0, bottom1, top1)- es el que deja la cara visible mirando hacia
	# afuera del edificio. Comprobado renderizando en aislamiento un solo
	# muro real (con un fondo de color puro y sin luz ambigua) desde ambos
	# lados: con el orden "obvio" (bottom0, bottom1, top1) el muro se veía
	# desde ADENTRO y se culleaba desde afuera.
	var n := points.size()
	for i in range(n):
		var p0 := points[i]
		var p1 := points[(i + 1) % n]
		var bottom0 := _to_world(p0, 0.0)
		var bottom1 := _to_world(p1, 0.0)
		var top0 := _to_world(p0, height)
		var top1 := _to_world(p1, height)

		st.add_vertex(bottom0)
		st.add_vertex(top1)
		st.add_vertex(bottom1)

		st.add_vertex(bottom0)
		st.add_vertex(top0)
		st.add_vertex(top1)

	return true


static func _to_world(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)
