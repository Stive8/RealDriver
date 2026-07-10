class_name PropScatter
extends RefCounted

const TREE_SPACING := 15.0
const TREE_LATERAL_OFFSET := 8.0
const TREE_ROAD_TYPES := ["residential", "living_street"]

const CAR_INTERVAL := 4
const CAR_LATERAL_OFFSET := 0.8
const CAR_ROAD_TYPES := ["residential", "secondary", "tertiary"]

const CAR_COLORS: Array[Color] = [
	Color("cc3333"),
	Color("3366cc"),
	Color("e0e0e0"),
	Color("888888"),
	Color("335533"),
	Color("ddaa33"),
]

const GRID_CELL := 60.0


static func scatter(roads: Array, buildings: Array) -> Node3D:
	var start_ms := Time.get_ticks_msec()

	var root := Node3D.new()
	root.name = "Props"

	var tree_mesh := _build_tree_mesh()
	var car_mesh := _build_car_mesh()

	var tree_positions := _sample_tree_positions(roads, buildings)
	var car_data := _sample_car_positions(roads)

	if tree_positions.size() > 0:
		var tree_mm := _make_multimesh(tree_mesh, tree_positions, false, [])
		var tree_mat := ShaderMaterial.new()
		tree_mat.shader = load("res://shaders/toon.gdshader")
		tree_mat.set_shader_parameter("use_vertex_color", true)
		var tree_mmi := MultiMeshInstance3D.new()
		tree_mmi.name = "Trees"
		tree_mmi.multimesh = tree_mm
		tree_mmi.material_override = tree_mat
		root.add_child(tree_mmi)

		# Add collisions for trees
		var tree_body := StaticBody3D.new()
		tree_body.name = "TreesCollision"
		var tree_shape := CylinderShape3D.new()
		tree_shape.radius = 0.5
		tree_shape.height = 3.0
		for xform in tree_positions:
			var col := CollisionShape3D.new()
			col.shape = tree_shape
			# Cylinder shape is centered, we need to offset it up by half height
			var col_xform = xform
			col_xform.origin.y += 1.5
			col.transform = col_xform
			tree_body.add_child(col)
		root.add_child(tree_body)

	if car_data.size() > 0:
		var car_transforms: Array[Transform3D] = []
		var car_colors: Array[Color] = []
		for d in car_data:
			car_transforms.append(d["transform"])
			car_colors.append(d["color"])
		var car_mm := _make_multimesh(car_mesh, car_transforms, true, car_colors)
		var car_mat := load("res://materials/car_props.tres") as Material
		var car_mmi := MultiMeshInstance3D.new()
		car_mmi.name = "Cars"
		car_mmi.multimesh = car_mm
		car_mmi.material_override = car_mat
		root.add_child(car_mmi)

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("%d árboles, %d autos decorativos, %d ms" % [tree_positions.size(), car_data.size(), elapsed_ms])
	return root


static func _make_multimesh(mesh: Mesh, transforms: Array[Transform3D], use_instance_color: bool, colors: Array[Color]) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.mesh = mesh
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if use_instance_color:
		mm.use_colors = true
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		if use_instance_color and i < colors.size():
			mm.set_instance_color(i, colors[i])
	return mm


static func _build_tree_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vcount := 0

	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.06
	cyl.height = 1.8
	cyl.radial_segments = 5
	vcount += _append_primitive_to_st(st, cyl, Color("5a3a1a"), Vector3(0, 0.9, 0), vcount)

	var sph := SphereMesh.new()
	sph.radius = 1.2
	sph.rings = 5
	sph.radial_segments = 6
	vcount += _append_primitive_to_st(st, sph, Color("3a8a2a"), Vector3(0, 2.2, 0), vcount)

	st.generate_normals()
	return st.commit()


static func _build_car_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var body := BoxMesh.new()
	body.size = Vector3(1.6, 0.8, 3.8)
	var vert_count := _append_primitive_to_st(st, body, Color(1, 1, 1, 1), Vector3(0, 0.4, 0), 0)

	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.16
	wheel.bottom_radius = 0.16
	wheel.height = 0.10
	wheel.radial_segments = 6

	var wheel_offsets := [
		Vector3(-0.7, 0.18, -1.4),
		Vector3( 0.7, 0.18, -1.4),
		Vector3(-0.7, 0.18,  1.4),
		Vector3( 0.7, 0.18,  1.4),
	]

	var w_arr: Array = wheel.surface_get_arrays(0)
	var wv: PackedVector3Array = w_arr[Mesh.ARRAY_VERTEX] if w_arr.size() > Mesh.ARRAY_VERTEX else PackedVector3Array()
	var wn: PackedVector3Array = w_arr[Mesh.ARRAY_NORMAL] if w_arr.size() > Mesh.ARRAY_NORMAL else PackedVector3Array()
	var wi: PackedInt32Array = w_arr[Mesh.ARRAY_INDEX] if w_arr.size() > Mesh.ARRAY_INDEX else PackedInt32Array()

	for wo in wheel_offsets:
		var local_base := vert_count
		for i in range(wv.size()):
			st.set_normal(wn[i] if i < wn.size() else Vector3.UP)
			st.set_uv(Vector2(1, 0))
			var v := wv[i]
			st.add_vertex(Vector3(v.y + wo.x, v.x + wo.y, v.z + wo.z))
		for j in range(wi.size()):
			st.add_index(local_base + wi[j])
		vert_count += wv.size()

	st.generate_normals()
	return st.commit()


static func _append_primitive_to_st(st: SurfaceTool, prim: PrimitiveMesh, color: Color, offset: Vector3, base_vertex: int) -> int:
	var arr: Array = prim.surface_get_arrays(0)
	if arr.is_empty():
		return 0
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] if arr.size() > Mesh.ARRAY_VERTEX else PackedVector3Array()
	var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr.size() > Mesh.ARRAY_NORMAL else PackedVector3Array()
	var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr.size() > Mesh.ARRAY_INDEX else PackedInt32Array()

	for i in range(verts.size()):
		if i < normals.size():
			st.set_normal(normals[i])
		else:
			st.set_normal(Vector3.UP)
		st.set_color(color)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(verts[i] + offset)

	if indices.size() > 0:
		for j in range(indices.size()):
			st.add_index(base_vertex + indices[j])
	else:
		for j in range(verts.size()):
			st.add_index(base_vertex + j)

	return verts.size()


static func _sample_tree_positions(roads: Array, buildings: Array) -> Array[Transform3D]:
	var grid := _build_footprint_grid(buildings)
	var result: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()

	for road in roads:
		if not TREE_ROAD_TYPES.has(road["highway"]):
			continue
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var half_w: float = float(road.get("width", 6.0)) * 0.5

		for seg in range(points.size() - 1):
			var a := _to_v2(points[seg])
			var b := _to_v2(points[seg + 1])
			var seg_dir := (b - a).normalized()
			var seg_len := a.distance_to(b)
			var perp := Vector2(seg_dir.y, -seg_dir.x)
			if seg_len < 1.0:
				continue

			var steps := maxi(1, int(seg_len / TREE_SPACING))
			for s in range(steps):
				var t := (float(s) + 0.5) / float(steps)
				var center := a.lerp(b, t)
				var side := 1 if (s % 2 == 0) else -1
				var offset_vec := perp * side * (half_w + TREE_LATERAL_OFFSET)
				var px := center.x + offset_vec.x
				var pz := center.y + offset_vec.y

				if _point_in_any_building(px, pz, grid):
					continue

				var hash_seed := int(px * 1000 + pz * 1000)
				rng.seed = hash_seed
				var yaw := rng.randf_range(0.0, TAU)
				var xform := Transform3D.IDENTITY
				xform.origin = Vector3(px, 0.0, pz)
				xform = xform.rotated(Vector3.UP, yaw)
				result.append(xform)

	return result


static func _sample_car_positions(roads: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()

	for road in roads:
		if not CAR_ROAD_TYPES.has(road["highway"]):
			continue
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var half_w: float = float(road.get("width", 6.0)) * 0.5
		var road_id: int = int(road.get("id", 0))

		for seg in range(points.size() - 1):
			var seg_hash := road_id * 1000 + seg
			rng.seed = seg_hash
			if rng.randi() % CAR_INTERVAL != 0:
				continue

			var a := _to_v2(points[seg])
			var b := _to_v2(points[seg + 1])
			var seg_dir := (b - a).normalized()
			var seg_len := a.distance_to(b)
			if seg_len < 2.0:
				continue
			var perp := Vector2(seg_dir.y, -seg_dir.x)

			var side := 1 if (seg % 2 == 0) else -1
			var center := (a + b) * 0.5
			var offset_vec := perp * side * (half_w + CAR_LATERAL_OFFSET)
			var px := center.x + offset_vec.x
			var pz := center.y + offset_vec.y

			var car_yaw := atan2(seg_dir.x, seg_dir.y)
			if seg % 2 == 0:
				car_yaw += PI
			var xform := Transform3D.IDENTITY
			xform.origin = Vector3(px, 0.0, pz)
			xform = xform.rotated(Vector3.UP, car_yaw)

			var color_hash := int(px * 100 + pz * 100)
			rng.seed = color_hash
			var color := CAR_COLORS[rng.randi() % CAR_COLORS.size()]

			result.append({"transform": xform, "color": color})

	return result


static func _build_footprint_grid(buildings: Array) -> Dictionary:
	var grid: Dictionary = {}
	for b in buildings:
		var fp: Array = b["footprint"]
		if fp.size() < 3:
			continue
		var min_x := INF
		var min_z := INF
		var max_x := -INF
		var max_z := -INF
		for p in fp:
			var xf := float(p[0])
			var zf := float(p[1])
			if xf < min_x: min_x = xf
			if zf < min_z: min_z = zf
			if xf > max_x: max_x = xf
			if zf > max_z: max_z = zf
		var cx0 := int(floor(min_x / GRID_CELL))
		var cz0 := int(floor(min_z / GRID_CELL))
		var cx1 := int(floor(max_x / GRID_CELL))
		var cz1 := int(floor(max_z / GRID_CELL))
		for cx in range(cx0, cx1 + 1):
			for cz in range(cz0, cz1 + 1):
				var key := str(cx) + "," + str(cz)
				if not grid.has(key):
					grid[key] = []
				grid[key].append(fp)
	return grid


static func _point_in_any_building(px: float, pz: float, grid: Dictionary) -> bool:
	var cx := int(floor(px / GRID_CELL))
	var cz := int(floor(pz / GRID_CELL))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := str(cx + dx) + "," + str(cz + dz)
			if not grid.has(key):
				continue
			var candidates: Array = grid[key]
			for fp in candidates:
				if _point_in_polygon(px, pz, fp):
					return true
	return false


static func _point_in_polygon(px: float, pz: float, polygon: Array) -> bool:
	var inside := false
	var n := polygon.size()
	var j := n - 1
	for i in range(n):
		var xi := float(polygon[i][0])
		var zi := float(polygon[i][1])
		var xj := float(polygon[j][0])
		var zj := float(polygon[j][1])
		if ((zi > pz) != (zj > pz)) and (px < (xj - xi) * (pz - zi) / (zj - zi) + xi):
			inside = not inside
		j = i
	return inside


static func _to_v2(p) -> Vector2:
	return Vector2(float(p[0]), float(p[1]))
