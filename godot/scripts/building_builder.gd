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


static func _compute_footprint_aabb(points: Array[Vector2]) -> Vector2:
	var min_x := INF; var max_x := -INF
	var min_y := INF; var max_y := -INF
	for p in points:
		if p.x < min_x: min_x = p.x
		if p.x > max_x: max_x = p.x
		if p.y < min_y: min_y = p.y
		if p.y > max_y: max_y = p.y
	return Vector2(max_x - min_x, max_y - min_y)


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

	var fp_size := _compute_footprint_aabb(points)
	var fp_w := fp_size.x
	var fp_d := fp_size.y
	var fp_area := fp_w * fp_d
	var fp_ratio := fp_w / maxf(fp_d, 0.01)

	var best: Dictionary = {}
	var best_score := -INF

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

		if score > best_score:
			best_score = score
			best = entry

	return best


static func build_with_assets(buildings: Array, sampler: TerrainSampler) -> Node3D:
	var root := Node3D.new()
	root.name = "Buildings"

	var asset_groups := {}
	var asset_templates := {}
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
			asset_templates[path] = scene
			asset_groups[path] = []

		var fp_size := _compute_footprint_aabb(points)
		var centroid := _footprint_centroid(points)

		asset_groups[path].append({
			"centroid": centroid,
			"base_y": base_y,
			"fp_size": fp_size,
			"height": height
		})
		built_count += 1

	# Create MultiMeshInstance3D per unique asset
	for path in asset_groups:
		var scene := asset_templates[path] as PackedScene
		var template := scene.instantiate() as Node3D

		var material := _extract_material(template)
		var merged_mesh := _merge_asset_mesh(template)
		template.queue_free()

		if merged_mesh == null:
			discarded_count += asset_groups[path].size()
			built_count -= asset_groups[path].size()
			continue

		var aabb := merged_mesh.get_aabb()
		if aabb.size.length() < 0.01:
			discarded_count += asset_groups[path].size()
			built_count -= asset_groups[path].size()
			continue

		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = merged_mesh
		if material != null and merged_mesh.get_surface_count() > 0:
			merged_mesh.surface_set_material(0, material)

		var entries: Array = asset_groups[path]
		multimesh.instance_count = entries.size()

		for i in range(entries.size()):
			var e: Dictionary = entries[i] as Dictionary
			if e.is_empty():
				continue
			var fp_size: Vector2 = e["fp_size"] as Vector2
			var base_y: float = e["base_y"]
			var height: float = e["height"]
			var centroid: Vector2 = e["centroid"] as Vector2
			var s_x := fp_size.x / maxf(aabb.size.x, 0.01)
			var s_z := fp_size.y / maxf(aabb.size.z, 0.01)
			var s_y := height / maxf(aabb.size.y, 0.01)
			var xform := Transform3D(Basis().scaled(Vector3(s_x, s_y, s_z)), Vector3(centroid.x, base_y, centroid.y))
			multimesh.set_instance_transform(i, xform)

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = multimesh
		root.add_child(mmi)

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	print("BuildingBuilder: %d edificios con assets (multimesh), %d descartados, %d ms" % [built_count, discarded_count, elapsed_ms])

	return root


static func _merge_asset_mesh(node: Node3D) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	_append_mesh_tree_local(st, node, Transform3D.IDENTITY)
	var mesh := st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	return mesh


static func _append_mesh_tree_local(st: SurfaceTool, node: Node3D, xform: Transform3D):
	if node is MeshInstance3D and node.mesh != null:
		for i in range(node.mesh.get_surface_count()):
			st.append_from(node.mesh, i, xform * node.transform)
	for child in node.get_children():
		if child is Node3D:
			_append_mesh_tree_local(st, child, xform)


static func _extract_material(node: Node3D) -> Material:
	if node is MeshInstance3D and node.mesh != null:
		for i in range(node.mesh.get_surface_count()):
			var mat: Material = node.mesh.surface_get_material(i)
			if mat != null:
				return mat
	for child in node.get_children():
		if child is Node3D:
			var mat: Material = _extract_material(child)
			if mat != null:
				return mat
	return null
