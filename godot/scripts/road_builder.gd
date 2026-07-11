class_name RoadBuilder
extends RefCounted

## [ESTRUCTURAL] Fase R-3: separación calle/terreno (escalera de mitigación: 0.15 -> 0.20
## si el humano reporta z-fighting con el terreno; anotar aquí si se sube).
const ROAD_LIFT := 0.10
## [ESTRUCTURAL] Ningún segmento de la polilínea de una vía supera esta longitud antes del
## miter join, para que la cinta siga el relieve en vez de cortar en línea recta sobre laderas.
const ROAD_SUBDIV_MAX_SEG := 10.0
## Tope de cos(theta/2) en el miter join; evita puntas en giros cerrados.
const MITER_COS_CLAMP := 0.35
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
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d ms" % [
		roads_processed, points_inserted, elapsed_ms])
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
	var n := points.size()
	var offsets_a: Array[Vector2] = []
	var offsets_b: Array[Vector2] = []

	for i in range(n):
		var center := Vector2(points[i][0], points[i][1])
		var offset_vec: Vector2

		if i == 0:
			var dir := (Vector2(points[1][0], points[1][1]) - center).normalized()
			offset_vec = Vector2(dir.y, -dir.x) * half_width
		elif i == n - 1:
			var prev := Vector2(points[i - 1][0], points[i - 1][1])
			var dir := (center - prev).normalized()
			offset_vec = Vector2(dir.y, -dir.x) * half_width
		else:
			# DECISION_PENDIENTE: el espec dice "bisectriz de las direcciones adyacentes";
			# se interpreta como bisectriz de las NORMALES de esas direcciones (miter join
			# estándar), ya que la bisectriz de las direcciones de viaje no produce un
			# offset perpendicular a la vía. Revisar con el arquitecto si se buscaba otra cosa.
			var prev := Vector2(points[i - 1][0], points[i - 1][1])
			var next := Vector2(points[i + 1][0], points[i + 1][1])
			var dir_in := (center - prev).normalized()
			var dir_out := (next - center).normalized()
			var normal_in := Vector2(dir_in.y, -dir_in.x)
			var normal_out := Vector2(dir_out.y, -dir_out.x)
			var bisector_sum := normal_in + normal_out
			if bisector_sum.length() < 0.001:
				# Giro de ~180 grados: la bisectriz colapsa, usar la normal de entrada.
				offset_vec = normal_in * half_width
			else:
				var bisector := bisector_sum.normalized()
				var cos_half := sqrt(maxf(0.0, (1.0 + dir_in.dot(dir_out)) * 0.5))
				var miter_len := half_width / maxf(MITER_COS_CLAMP, cos_half)
				offset_vec = bisector * miter_len

		offsets_a.append(center + offset_vec)
		offsets_b.append(center - offset_vec)

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
