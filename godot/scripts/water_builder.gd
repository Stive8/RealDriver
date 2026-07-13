class_name WaterBuilder
extends RefCounted
## Malla de agua (Fase W-2, ESPEC_SESION_RETROFIT_AGUA_V2, contrato 5): polígonos
## (water_areas) triangulados + cintas de eje (water_ways) de sección plana. Una sola
## malla, sin colisión propia (vadear un cruce sin puente es válido por diseño).

const WATER_LIFT := 0.05
const WATER_MATERIAL_PATH := "res://materials/water.tres"
## Subdivisión máxima de arista antes de triangular un polígono de agua (contrato 5).
const WATER_EDGE_SUBDIV_MAX := 15.0


static func build(water_areas: Array, water_ways: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var areas_built := 0
	var areas_discarded := 0
	var tris_count := 0
	for area in water_areas:
		var n_tris := _add_water_area(st, area, sampler)
		if n_tris > 0:
			areas_built += 1
			tris_count += n_tris
		else:
			areas_discarded += 1

	var ways_built := 0
	for way in water_ways:
		if _add_water_way(st, way, sampler):
			ways_built += 1

	st.generate_normals()
	st.set_material(load(WATER_MATERIAL_PATH))
	var mesh := st.commit()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Water"
	mesh_instance.mesh = mesh

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("WaterBuilder: %d polígonos (%d descartados, %d tris), %d cintas de agua, %d ms" % [
		areas_built, areas_discarded, tris_count, ways_built, elapsed_ms])
	return mesh_instance


## Cierra la huella, orienta CCW (mismo criterio shoelace que BuildingBuilder), sin el
## punto de cierre duplicado.
static func _clean_footprint(footprint: Array) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for p in footprint:
		points.append(Vector2(p[0], p[1]))
	if points.size() > 1 and points[0].is_equal_approx(points[points.size() - 1]):
		points.remove_at(points.size() - 1)
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


## Reinserta puntos por interpolación lineal en cada arista del anillo (incluida la de
## cierre) para que ninguna supere `max_len` antes de triangular.
static func _subdivide_ring(points: Array[Vector2], max_len: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var n := points.size()
	for i in range(n):
		var a := points[i]
		var b := points[(i + 1) % n]
		result.append(a)
		var seg_len := a.distance_to(b)
		var steps := maxi(1, int(ceil(seg_len / max_len)))
		for s in range(1, steps):
			result.append(a.lerp(b, float(s) / float(steps)))
	return result


## Construye un polígono de agua. Retorna el número de triángulos emitidos (0 si se
## descarta: huella degenerada o Geometry2D.triangulate_polygon falla -- regla histórica
## de edificios, contrato 2 W-1).
static func _add_water_area(st: SurfaceTool, area: Dictionary, sampler: TerrainSampler) -> int:
	var points := _clean_footprint(area.get("footprint", []))
	if points.size() < 3:
		return 0
	var subdivided := _subdivide_ring(points, WATER_EDGE_SUBDIV_MAX)
	var polygon := PackedVector2Array(subdivided)
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return 0
	for i in range(0, triangles.size(), 3):
		st.add_vertex(_water_vertex(subdivided[triangles[i]], sampler))
		st.add_vertex(_water_vertex(subdivided[triangles[i + 1]], sampler))
		st.add_vertex(_water_vertex(subdivided[triangles[i + 2]], sampler))
	return triangles.size() / 3


## Cinta de eje de sección PLANA: a diferencia de road_builder.gd (cada vértice de cinta
## se apoya en el terreno bajo su propia posición), aquí AMBOS bordes de cada sección
## comparten la altura muestreada en el CENTRO (contrato 5) -- el agua es horizontal de
## lado a lado, no sigue el peralte lateral del terreno.
static func _add_water_way(st: SurfaceTool, way: Dictionary, sampler: TerrainSampler) -> bool:
	var points: Array = way.get("points", [])
	if points.size() < 2:
		return false
	var half_width: float = float(way.get("width", 3.0)) * 0.5
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]
	var n := points.size()

	for i in range(n - 1):
		var center0 := Vector2(points[i][0], points[i][1])
		var center1 := Vector2(points[i + 1][0], points[i + 1][1])
		var y0 := sampler.height_at(center0.x, center0.y) + WATER_LIFT
		var y1 := sampler.height_at(center1.x, center1.y) + WATER_LIFT

		var va0 := Vector3(offsets_a[i].x, y0, offsets_a[i].y)
		var vb0 := Vector3(offsets_b[i].x, y0, offsets_b[i].y)
		var va1 := Vector3(offsets_a[i + 1].x, y1, offsets_a[i + 1].y)
		var vb1 := Vector3(offsets_b[i + 1].x, y1, offsets_b[i + 1].y)

		st.add_vertex(va0)
		st.add_vertex(va1)
		st.add_vertex(vb0)

		st.add_vertex(vb0)
		st.add_vertex(va1)
		st.add_vertex(vb1)

	return true


static func _water_vertex(p: Vector2, sampler: TerrainSampler) -> Vector3:
	return Vector3(p.x, sampler.height_at(p.x, p.y) + WATER_LIFT, p.y)
