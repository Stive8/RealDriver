class_name RoadBuilder
extends RefCounted

## [ESTRUCTURAL] Fase R-3: separación calle/terreno (escalera de mitigación: 0.15 -> 0.20
## si el humano reporta z-fighting con el terreno; anotar aquí si se sube).
const ROAD_LIFT := 0.10
## [ESTRUCTURAL] Ningún segmento de la polilínea de una vía supera esta longitud antes del
## miter join, para que la cinta siga el relieve en vez de cortar en línea recta sobre laderas.
const ROAD_SUBDIV_MAX_SEG := 10.0
const ROAD_MATERIAL_PATH := "res://materials/road.tres"


static func build(roads: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var roads_processed := 0
	var points_inserted := 0

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var densified := _densify_points(points)
		points_inserted += densified["inserted"]
		var half_width: float = float(road["width"]) * 0.5
		_add_road_strip(st, densified["points"], half_width, sampler)
		roads_processed += 1

	st.generate_normals()
	st.set_material(load(ROAD_MATERIAL_PATH))
	var mesh := st.commit()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var vtx_count: int = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	var tri_count := vtx_count / 3
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d ms" % [
		roads_processed, points_inserted, elapsed_ms])
	print("RoadBuilder no-regresión: %d vértices / %d triángulos" % [vtx_count, tri_count])
	return mesh_instance


## Reinserta puntos por interpolación lineal 2D para que ningún segmento supere
## ROAD_SUBDIV_MAX_SEG. El algoritmo de miter/bisectriz corre después, sin cambios,
## sobre la polilínea densificada resultante.
static func _densify_points(points: Array) -> Dictionary:
	var result: Array = [points[0]]
	var inserted := 0
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		var seg_len := a.distance_to(b)
		var steps := maxi(1, int(ceil(seg_len / ROAD_SUBDIV_MAX_SEG)))
		for s in range(1, steps + 1):
			var p := a.lerp(b, float(s) / float(steps))
			result.append([p.x, p.y])
		inserted += steps - 1
	return {"points": result, "inserted": inserted}


static func _add_road_strip(st: SurfaceTool, points: Array, half_width: float, sampler: TerrainSampler) -> void:
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]
	var n := points.size()

	for i in range(n - 1):
		var va0 := _ribbon_vertex(offsets_a[i], sampler)
		var vb0 := _ribbon_vertex(offsets_b[i], sampler)
		var va1 := _ribbon_vertex(offsets_a[i + 1], sampler)
		var vb1 := _ribbon_vertex(offsets_b[i + 1], sampler)

		st.add_vertex(va0)
		st.add_vertex(va1)
		st.add_vertex(vb0)

		st.add_vertex(vb0)
		st.add_vertex(va1)
		st.add_vertex(vb1)


## Cada vértice de la cinta se apoya en el terreno bajo su propia posición (no en el
## eje de la vía): así la calle sigue el relieve también en peraltes laterales.
static func _ribbon_vertex(p: Vector2, sampler: TerrainSampler) -> Vector3:
	return Vector3(p.x, sampler.height_at(p.x, p.y) + ROAD_LIFT, p.y)
