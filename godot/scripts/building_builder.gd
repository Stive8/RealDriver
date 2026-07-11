class_name BuildingBuilder
extends RefCounted

const BUILDING_MATERIAL_PATH := "res://materials/building.tres"
const WALLS_MATERIAL_PATH := "res://materials/windows.tres"
const OUTLINE_MATERIAL_PATH := "res://materials/outline.tres"

## [ESTRUCTURAL] Fase R-3: faldón bajo la base del edificio (esconde el hueco en laderas
## donde el punto más bajo de la huella no coincide con el más alto).
const BUILDING_SKIRT := 1.0

## [ESTRUCTURAL] Fase R-5: despeje mínimo del techo sobre el punto MÁS ALTO del terreno bajo
## la huella (evita que el techo plano quede bajo tierra en huellas largas sobre ladera).
const MIN_ROOF_CLEARANCE := 3.0

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


static func build(buildings: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
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
	var min_base_y := INF
	var max_base_y := -INF
	var extended_count := 0
	var max_extension := 0.0

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

		var terrain_range := _terrain_range_for(points, sampler)
		var base_y: float = terrain_range.x
		var t_max: float = terrain_range.y
		min_base_y = minf(min_base_y, base_y)
		max_base_y = maxf(max_base_y, base_y)

		# Fase R-5: el techo (plano, a base_y + altura_efectiva) siempre despeja el punto
		# más alto del terreno bajo la huella por al menos MIN_ROOF_CLEARANCE. Para la
		# inmensa mayoría de edificios altura_efectiva == height (su altura real ya sobra);
		# solo huellas largas sobre ladera pronunciada la extienden.
		var effective_height: float = maxf(height, (t_max - base_y) + MIN_ROOF_CLEARANCE)
		if effective_height > height:
			extended_count += 1
			max_extension = maxf(max_extension, effective_height - height)

		var color: Color = _get_color_for_height(height, int(building["id"]))

		if _add_building(st_walls, st_tops, points, effective_height, base_y, color):
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

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("BuildingBuilder: %d edificios, %d descartados, %d ms" % [built_count, discarded_count, elapsed_ms])
	print("  alturas: min=%.1f max=%.1f baja=%d media=%d alta=%d" % [min_h, max_h, count_low, count_mid, count_high])
	print("  base_y: min=%.1f max=%.1f" % [min_base_y, max_base_y])
	print("  %d edificios con altura extendida (max +%.1f m)" % [extended_count, max_extension])

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Buildings"
	mesh_instance.mesh = mesh
	return mesh_instance


## Rango de terreno bajo la huella del edificio: x = mínimo (punto de apoyo, "base_y", ver
## R-3), y = máximo (Fase R-5: para que el techo nunca quede bajo el punto más alto).
static func _terrain_range_for(points: Array[Vector2], sampler: TerrainSampler) -> Vector2:
	var t_min := INF
	var t_max := -INF
	for p in points:
		var h := sampler.height_at(p.x, p.y)
		t_min = minf(t_min, h)
		t_max = maxf(t_max, h)
	return Vector2(t_min, t_max)


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


static func _add_building(st_walls: SurfaceTool, st_tops: SurfaceTool, points: Array[Vector2], wall_height: float, base_y: float, color: Color) -> bool:
	var polygon := PackedVector2Array(points)
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return false

	var top_y := base_y + wall_height

	# Top face (stays with plain toon material)
	st_tops.set_color(color)
	for i in range(0, triangles.size(), 3):
		st_tops.add_vertex(_to_world(points[triangles[i]], top_y))
		st_tops.add_vertex(_to_world(points[triangles[i + 1]], top_y))
		st_tops.add_vertex(_to_world(points[triangles[i + 2]], top_y))

	# Walls with window shader (UV.x = perimeter distance, UV.y = altura RELATIVA a la
	# base propia del edificio 0..wall_height: la grilla de ventanas de V-2 se alinea a
	# base_y, no a y=0 global, aunque el mundo Y sí lo desplace [base_y-BUILDING_SKIRT, top_y]).
	st_walls.set_color(color)
	var n := points.size()
	var perimeter_offset := 0.0
	var bottom_y := base_y - BUILDING_SKIRT
	for i in range(n):
		var p0 := points[i]
		var p1 := points[(i + 1) % n]
		var wall_length := p0.distance_to(p1)
		var bottom0 := _to_world(p0, bottom_y)
		var bottom1 := _to_world(p1, bottom_y)
		var top0 := _to_world(p0, top_y)
		var top1 := _to_world(p1, top_y)

		st_walls.set_uv(Vector2(perimeter_offset, 0.0))
		st_walls.add_vertex(bottom0)
		st_walls.set_uv(Vector2(perimeter_offset + wall_length, wall_height))
		st_walls.add_vertex(top1)
		st_walls.set_uv(Vector2(perimeter_offset + wall_length, 0.0))
		st_walls.add_vertex(bottom1)

		st_walls.set_uv(Vector2(perimeter_offset, 0.0))
		st_walls.add_vertex(bottom0)
		st_walls.set_uv(Vector2(perimeter_offset, wall_height))
		st_walls.add_vertex(top0)
		st_walls.set_uv(Vector2(perimeter_offset + wall_length, wall_height))
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
