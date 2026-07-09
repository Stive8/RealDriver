class_name RoadBuilder
extends RefCounted

const Y_OFFSET := 0.05
## Tope de cos(theta/2) en el miter join; evita puntas en giros cerrados.
const MITER_COS_CLAMP := 0.35
const ROAD_MATERIAL_PATH := "res://materials/road.tres"


static func build(roads: Array) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var half_width: float = float(road["width"]) * 0.5
		_add_road_strip(st, points, half_width)

	st.generate_normals()
	st.set_material(load(ROAD_MATERIAL_PATH))
	var mesh := st.commit()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh
	return mesh_instance


static func _add_road_strip(st: SurfaceTool, points: Array, half_width: float) -> void:
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
		var va0 := Vector3(offsets_a[i].x, Y_OFFSET, offsets_a[i].y)
		var vb0 := Vector3(offsets_b[i].x, Y_OFFSET, offsets_b[i].y)
		var va1 := Vector3(offsets_a[i + 1].x, Y_OFFSET, offsets_a[i + 1].y)
		var vb1 := Vector3(offsets_b[i + 1].x, Y_OFFSET, offsets_b[i + 1].y)

		st.add_vertex(va0)
		st.add_vertex(va1)
		st.add_vertex(vb0)

		st.add_vertex(vb0)
		st.add_vertex(va1)
		st.add_vertex(vb1)
