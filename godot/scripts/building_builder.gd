class_name BuildingBuilder
extends RefCounted

const BUILDING_MATERIAL_PATH := "res://materials/building.tres"
const WALLS_MATERIAL_PATH := "res://materials/windows.tres"
const OUTLINE_MATERIAL_PATH := "res://materials/outline.tres"
const BUILDING_MANIFEST_PATH := "res://models/buildings/manifest.json"

static var _manifest: Array = []
static var _manifest_loaded := false

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


# ──────────────────────────────────────────────────────────────────────────────
# Fase 2: Asset-based buildings via manifest matching
# ──────────────────────────────────────────────────────────────────────────────

static func _load_manifest() -> Array:
	if _manifest_loaded:
		return _manifest
	var file := FileAccess.open(BUILDING_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("BuildingBuilder: no se pudo abrir manifest.json")
		return []
	var text := file.get_as_text()
	file.close()
	var json = JSON.parse_string(text)
	if typeof(json) != TYPE_ARRAY:
		push_error("BuildingBuilder: manifest.json inválido")
		return []
	_manifest = json as Array
	_manifest_loaded = true
	return _manifest


static func _compute_obb(points: Array[Vector2]) -> Dictionary:
	var best_area := INF
	var best_obb := {}
	var n := points.size()
	for i in range(n):
		var p1 = points[i]
		var p2 = points[(i + 1) % n]
		var dir = (p2 - p1).normalized()
		if dir.length_squared() < 0.001: continue
		var normal = Vector2(-dir.y, dir.x)
		var min_d = INF
		var max_d = -INF
		var min_n = INF
		var max_n = -INF
		for p in points:
			var d = p.dot(dir)
			var n_dot = p.dot(normal)
			if d < min_d: min_d = d
			if d > max_d: max_d = d
			if n_dot < min_n: min_n = n_dot
			if n_dot > max_n: max_n = n_dot
		var area = (max_d - min_d) * (max_n - min_n)
		if area < best_area:
			best_area = area
			var center = dir * ((max_d + min_d) * 0.5) + normal * ((max_n + min_n) * 0.5)
			best_obb = {
				"center": center,
				"size": Vector2(max_d - min_d, max_n - min_n),
				"angle": dir.angle()
			}
	if best_obb.is_empty():
		return {"center": _footprint_centroid(points), "size": Vector2.ONE, "angle": 0.0}
	return best_obb


static func _get_scene_aabb(node: Node) -> AABB:
	var aabb := AABB()
	var found := false
	if node is MeshInstance3D and node.mesh != null:
		aabb = node.mesh.get_aabb()
		found = true
	for child in node.get_children():
		var child_aabb := _get_scene_aabb(child)
		if child_aabb.size.length() > 0:
			if not found:
				aabb = child_aabb
				found = true
			else:
				aabb = aabb.merge(child_aabb)
	return aabb


static func _footprint_centroid(points: Array[Vector2]) -> Vector2:
	var centroid := Vector2.ZERO
	for p in points:
		centroid += p
	return centroid / points.size()


static func _pick_best_asset(points: Array[Vector2], height: float, style: String) -> Dictionary:
	var manifest := _load_manifest()
	if manifest.is_empty():
		return {}

	var obb := _compute_obb(points)
	var fp_w: float = obb.size.x
	var fp_d: float = obb.size.y
	var fp_area: float = fp_w * fp_d
	var fp_ratio: float = fp_w / maxf(fp_d, 0.01)

	var candidates := []

	for entry in manifest:
		var asset_style: String = entry.get("style", "mixed")
		var style_match := 1.0 if (asset_style == style or style == "mixed") else 0.5

		var asset_w: float = entry.get("width", 1.0)
		var asset_d: float = entry.get("depth", 1.0)
		var asset_h: float = entry.get("height", 1.0)

		var area_diff := absf(fp_area - (asset_w * asset_d)) / maxf(fp_area, 0.1)
		var ratio_diff := absf(fp_ratio - (asset_w / maxf(asset_d, 0.01)))
		var height_diff := absf(height - asset_h) / maxf(height, 0.1)

		var score := 0.0
		score += (1.0 - minf(area_diff, 1.0)) * 0.4
		score += (1.0 - minf(ratio_diff, 2.0) / 2.0) * 0.2
		score += (1.0 - minf(height_diff, 1.0)) * 0.25
		score += style_match * 0.15

		candidates.append({"entry": entry, "score": score})

	candidates.sort_custom(func(a, b): return a.score > b.score)
	
	if candidates.is_empty():
		return {}
		
	var top_n: int = mini(4, candidates.size())
	return candidates[randi() % top_n]["entry"]


static func build_with_assets(buildings: Array, sampler: TerrainSampler) -> Node3D:
	var root := Node3D.new()
	root.name = "Buildings"

	var asset_groups := {}
	var asset_meshes := {}
	var built_count := 0
	var discarded_count := 0
	var start_ms := Time.get_ticks_msec()

	for building in buildings:
		var points := _clean_footprint(building["footprint"])
		if points.size() < 3:
			discarded_count += 1
			continue

		var height: float = float(building["height"])
		var terrain_range := _terrain_range_for(points, sampler)
		var base_y: float = terrain_range.x
		var t_max: float = terrain_range.y
		var effective_height: float = maxf(height, (t_max - base_y) + MIN_ROOF_CLEARANCE)

		var style: String = "residential"
		if height > 28.0:
			style = "industrial"
		elif height > 12.0:
			style = "commercial"

		var best := _pick_best_asset(points, height, style)
		if best.is_empty():
			discarded_count += 1
			continue

		var path: String = best.get("path", "")
		if path.is_empty():
			discarded_count += 1
			continue

		if not asset_groups.has(path):
			var scene := load(path) as PackedScene
			if scene == null:
				discarded_count += 1
				continue
			var template := scene.instantiate() as Node3D
			var merged_mesh := _merge_asset_mesh(template)
			template.queue_free()
			if merged_mesh == null:
				discarded_count += 1
				continue
			asset_meshes[path] = merged_mesh
			asset_groups[path] = []

		var obb := _compute_obb(points)
		var fp_size: Vector2 = obb.size
		var centroid: Vector2 = obb.center
		var angle: float = obb.angle

		asset_groups[path].append({
			"centroid": centroid,
			"base_y": base_y,
			"fp_size": fp_size,
			"height": effective_height,
			"angle": angle
		})
		built_count += 1

	# Create MultiMeshInstance3D per unique asset (merged mesh with all materials preserved)
	for path in asset_groups:
		var merged_mesh := asset_meshes[path] as ArrayMesh
		var maabb := merged_mesh.get_aabb()
		if maabb.size.length() < 0.01:
			discarded_count += asset_groups[path].size()
			built_count -= asset_groups[path].size()
			continue

		var bottom_offset_y := -maabb.position.y
		var center_x := maabb.position.x + maabb.size.x * 0.5
		var center_z := maabb.position.z + maabb.size.z * 0.5

		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = merged_mesh

		var entries: Array = asset_groups[path]
		multimesh.instance_count = entries.size()

		for i in range(entries.size()):
			var e: Dictionary = entries[i] as Dictionary
			if e.is_empty():
				continue
			var fp_size: Vector2 = e["fp_size"]
			var base_y: float = e["base_y"]
			var height: float = e["height"]
			var centroid: Vector2 = e["centroid"]
			var angle: float = e["angle"]
			
			var effective_height: float = height + BUILDING_SKIRT
			var s_x: float = fp_size.x / maxf(maabb.size.x, 0.01)
			var s_z: float = fp_size.y / maxf(maabb.size.z, 0.01)
			var s_y: float = effective_height / maxf(maabb.size.y, 0.01)
			
			var basis := Basis().scaled(Vector3(s_x, s_y, s_z))
			var rot_basis := Basis(Vector3.DOWN, angle)
			basis = rot_basis * basis
			
			var ofs_local := Vector3(-center_x * s_x, bottom_offset_y * s_y, -center_z * s_z)
			var ofs_rotated: Vector3 = rot_basis * ofs_local
			
			var pos: Vector3 = Vector3(centroid.x, base_y - BUILDING_SKIRT, centroid.y) + ofs_rotated
			var xform := Transform3D(basis, pos)
			multimesh.set_instance_transform(i, xform)

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = multimesh
		root.add_child(mmi)

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("BuildingBuilder: %d edificios con assets (multimesh), %d descartados, %d ms" % [built_count, discarded_count, elapsed_ms])

	return root


static func _get_or_create_chunk(parent: Node3D, cx: int, cz: int) -> Node3D:
	var cname := "Chunk_" + str(cx) + "_" + str(cz)
	for child in parent.get_children():
		if child.name == cname:
			return child
	var chunk := Node3D.new()
	chunk.name = cname
	parent.add_child(chunk)
	return chunk


static func _merge_asset_mesh(node: Node3D) -> ArrayMesh:
	var groups := {}
	_collect_mesh_parts(node, Transform3D.IDENTITY, groups)
	if groups.is_empty():
		return null

	var mesh := ArrayMesh.new()
	for mat_key in groups:
		var parts: Array = groups[mat_key]
		var part_mat: Material = parts[0][3]

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for part in parts:
			st.append_from(part[0] as Mesh, part[1] as int, part[2] as Transform3D)

		var part_mesh := st.commit()
		if part_mesh == null or part_mesh.get_surface_count() == 0:
			continue

		for s in range(part_mesh.get_surface_count()):
			var arr := part_mesh.surface_get_arrays(s)
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			if part_mat != null:
				mesh.surface_set_material(mesh.get_surface_count() - 1, part_mat)

	if mesh.get_surface_count() == 0:
		return null
	return mesh


static func _collect_mesh_parts(node: Node3D, xform: Transform3D, groups: Dictionary):
	var current_xform := xform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		for i in range(node.mesh.get_surface_count()):
			var mat: Material = node.mesh.surface_get_material(i)
			var key := str(mat) if mat != null else "__null__"
			if not groups.has(key):
				groups[key] = []
			groups[key].append([node.mesh, i, current_xform, mat])
	for child in node.get_children():
		if child is Node3D:
			_collect_mesh_parts(child, current_xform, groups)


static func build_collision_boxes(buildings: Array, sampler: TerrainSampler, chunk_size: float = 100.0) -> Node3D:
	var root := Node3D.new()
	root.name = "BuildingsCollision"

	for building in buildings:
		var points := _clean_footprint(building["footprint"])
		if points.size() < 3:
			continue

		var height: float = float(building["height"])
		var terrain_range := _terrain_range_for(points, sampler)
		var base_y: float = terrain_range.x
		var t_max: float = terrain_range.y
		var effective_height: float = maxf(height, (t_max - base_y) + MIN_ROOF_CLEARANCE)
		var obb := _compute_obb(points)
		var centroid: Vector2 = obb.center

		var body := StaticBody3D.new()
		body.position = Vector3(centroid.x, 0, centroid.y)

		var polygon := PackedVector2Array(points)
		var triangles := Geometry2D.triangulate_polygon(polygon)
		if triangles.is_empty():
			continue
			
		var faces := PackedVector3Array()
		var top_y = base_y + effective_height
		var bottom_y = base_y - BUILDING_SKIRT
		
		for i in range(0, triangles.size(), 3):
			var a = points[triangles[i]]
			var b = points[triangles[i+1]]
			var c = points[triangles[i+2]]
			
			faces.append(Vector3(a.x - centroid.x, top_y, a.y - centroid.y))
			faces.append(Vector3(b.x - centroid.x, top_y, b.y - centroid.y))
			faces.append(Vector3(c.x - centroid.x, top_y, c.y - centroid.y))
			
			faces.append(Vector3(c.x - centroid.x, bottom_y, c.y - centroid.y))
			faces.append(Vector3(b.x - centroid.x, bottom_y, b.y - centroid.y))
			faces.append(Vector3(a.x - centroid.x, bottom_y, a.y - centroid.y))
			
		var n = points.size()
		for i in range(n):
			var p0 = points[i]
			var p1 = points[(i+1)%n]
			var t0 = Vector3(p0.x - centroid.x, top_y, p0.y - centroid.y)
			var t1 = Vector3(p1.x - centroid.x, top_y, p1.y - centroid.y)
			var b0 = Vector3(p0.x - centroid.x, bottom_y, p0.y - centroid.y)
			var b1 = Vector3(p1.x - centroid.x, bottom_y, p1.y - centroid.y)
			
			faces.append(b0); faces.append(t0); faces.append(t1)
			faces.append(b0); faces.append(t1); faces.append(b1)

		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)

		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)

		var cx := int(floor(centroid.x / chunk_size))
		var cz := int(floor(centroid.y / chunk_size))
		var chunk_node := _get_or_create_chunk(root, cx, cz)
		chunk_node.add_child(body)

	print("BuildingBuilder: %d collision boxes creadas" % buildings.size())
	return root
