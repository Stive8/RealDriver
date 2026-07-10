class_name BuildingBuilder
extends RefCounted

const BUILDING_MATERIAL_PATH := "res://materials/building.tres"
const WALLS_MATERIAL_PATH := "res://materials/windows.tres"
const OUTLINE_MATERIAL_PATH := "res://materials/outline.tres"

const PALETTE_RESIDENTIAL: Array[Color] = [
	Color("d4b8a0"),
	Color("c4a88c"),
	Color("d0b898"),
	Color("bca488"),
]
const PALETTE_NEUTRAL: Array[Color] = [
	Color("b8b8b8"),
	Color("c8c0b0"),
	Color("b0b0a0"),
	Color("a8a8a0"),
]
const PALETTE_OFFICE: Array[Color] = [
	Color("8090a0"),
	Color("7090a8"),
	Color("8898a8"),
	Color("687888"),
]


static func build(buildings: Array) -> MeshInstance3D:
	var st_walls := SurfaceTool.new()
	st_walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_walls.set_smooth_group(-1)

	var st_tops := SurfaceTool.new()
	st_tops.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_tops.set_smooth_group(-1)

	var built_count := 0
	var discarded_count := 0
	var min_h := INF
	var max_h := -INF
	var count_low := 0
	var count_mid := 0
	var count_high := 0

	for building in buildings:
		var points := _clean_footprint(building["footprint"])
		if points.size() < 3:
			discarded_count += 1
			continue

		var height: float = float(building["height"])
		min_h = min(min_h, height)
		max_h = max(max_h, height)
		if height < 12.0:
			count_low += 1
		elif height <= 28.0:
			count_mid += 1
		else:
			count_high += 1

		var color: Color = _get_color_for_height(height, int(building["id"]))

		if _add_building(st_walls, st_tops, points, height, color):
			built_count += 1
		else:
			discarded_count += 1

	st_walls.generate_normals()
	st_tops.generate_normals()

	var mesh := ArrayMesh.new()
	st_walls.set_material(load(WALLS_MATERIAL_PATH))
	st_walls.commit(mesh)
	st_tops.set_material(load(BUILDING_MATERIAL_PATH))
	st_tops.commit(mesh)

	print("BuildingBuilder: %d edificios, %d descartados" % [built_count, discarded_count])
	print("  alturas: min=%.1f max=%.1f baja=%d media=%d alta=%d" % [min_h, max_h, count_low, count_mid, count_high])

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Buildings"
	mesh_instance.mesh = mesh
	return mesh_instance


static func _get_color_for_height(height: float, id: int) -> Color:
	if height < 12.0:
		return PALETTE_RESIDENTIAL[id % PALETTE_RESIDENTIAL.size()]
	elif height <= 28.0:
		return PALETTE_NEUTRAL[id % PALETTE_NEUTRAL.size()]
	else:
		return PALETTE_OFFICE[id % PALETTE_OFFICE.size()]


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


static func _add_building(st_walls: SurfaceTool, st_tops: SurfaceTool, points: Array[Vector2], height: float, color: Color) -> bool:
	var polygon := PackedVector2Array(points)
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return false

	# Top face (stays with plain toon material)
	st_tops.set_color(color)
	for i in range(0, triangles.size(), 3):
		st_tops.add_vertex(_to_world(points[triangles[i]], height))
		st_tops.add_vertex(_to_world(points[triangles[i + 1]], height))
		st_tops.add_vertex(_to_world(points[triangles[i + 2]], height))

	# Walls with window shader (UV.x = perimeter distance, UV.y = height)
	st_walls.set_color(color)
	var n := points.size()
	var perimeter_offset := 0.0
	for i in range(n):
		var p0 := points[i]
		var p1 := points[(i + 1) % n]
		var wall_length := p0.distance_to(p1)
		var bottom0 := _to_world(p0, 0.0)
		var bottom1 := _to_world(p1, 0.0)
		var top0 := _to_world(p0, height)
		var top1 := _to_world(p1, height)

		st_walls.set_uv(Vector2(perimeter_offset, 0.0))
		st_walls.add_vertex(bottom0)
		st_walls.set_uv(Vector2(perimeter_offset + wall_length, height))
		st_walls.add_vertex(top1)
		st_walls.set_uv(Vector2(perimeter_offset + wall_length, 0.0))
		st_walls.add_vertex(bottom1)

		st_walls.set_uv(Vector2(perimeter_offset, 0.0))
		st_walls.add_vertex(bottom0)
		st_walls.set_uv(Vector2(perimeter_offset, height))
		st_walls.add_vertex(top0)
		st_walls.set_uv(Vector2(perimeter_offset + wall_length, height))
		st_walls.add_vertex(top1)

		perimeter_offset += wall_length

	return true


static func build_outline(mesh: ArrayMesh) -> MeshInstance3D:
	var outline := MeshInstance3D.new()
	outline.name = "BuildingsOutline"
	outline.mesh = mesh
	outline.material_override = load(OUTLINE_MATERIAL_PATH)
	return outline


static func _to_world(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)
