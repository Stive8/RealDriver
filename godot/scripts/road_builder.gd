class_name RoadBuilder
extends RefCounted

## [ESTRUCTURAL] Fase R-3: separación calle/terreno (escalera de mitigación: 0.15 -> 0.20
## si el humano reporta z-fighting con el terreno; anotar aquí si se sube).
const ROAD_LIFT := 0.10
## [ESTRUCTURAL] Ningún segmento de la polilínea de una vía supera esta longitud antes del
## miter join, para que la cinta siga el relieve en vez de cortar en línea recta sobre laderas.
const ROAD_SUBDIV_MAX_SEG := 10.0
const ROAD_MATERIAL_PATH := "res://materials/road.tres"
## Contrato 4 (ESPEC_SESION_RETROFIT_AGUA_V2, W-2): caja de tablero -- la cara inferior queda
## esta distancia por debajo de la cinta superior en cada vértice (no del terreno).
const DECK_BOX_DROP := 0.5
const DECK_UNDERSIDE_MATERIAL_PATH := "res://materials/road_deck_underside.tres"


static func build(roads: Array, sampler: TerrainSampler) -> MeshInstance3D:
	var start_ms := Time.get_ticks_msec()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_box := SurfaceTool.new()
	st_box.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_collision := SurfaceTool.new()
	st_collision.begin(Mesh.PRIMITIVE_TRIANGLES)

	var roads_processed := 0
	var points_inserted := 0
	var decks_built := 0
	var broken_splices := 0
	var has_deck_geometry := false

	var endpoint_counts := _count_endpoint_occurrences(roads)

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var deck: String = String(road.get("deck", ""))
		var is_deck_bridge := deck == "bridge" and not _has_broken_splice(points, endpoint_counts)

		var densified := _densify_points(points)
		points_inserted += densified["inserted"]
		var half_width: float = float(road["width"]) * 0.5

		if is_deck_bridge:
			_add_deck_strip(st, st_box, st_collision, densified["points"], half_width, sampler)
			has_deck_geometry = true
			decks_built += 1
		else:
			if deck == "bridge":
				broken_splices += 1
				print("RoadBuilder: vía id=%s deck=bridge con extremo sin empalme; drapeada como normal (regla de emergencia, contrato 4)" % str(road.get("id", "?")))
			_add_road_strip(st, densified["points"], half_width, sampler)
		roads_processed += 1

	st.generate_normals()
	var mesh := ArrayMesh.new()
	st.set_material(load(ROAD_MATERIAL_PATH))
	st.commit(mesh)

	if has_deck_geometry:
		st_box.generate_normals()
		st_box.set_material(load(DECK_UNDERSIDE_MATERIAL_PATH))
		st_box.commit(mesh)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh

	var decks_with_collision := 0
	if has_deck_geometry:
		mesh_instance.add_child(_build_deck_collision(st_collision))
		decks_with_collision = decks_built

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var vtx_count: int = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	var tri_count := vtx_count / 3
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d tableros (%d con colisión), %d empalmes rotos, %d ms" % [
		roads_processed, points_inserted, decks_built, decks_with_collision, broken_splices, elapsed_ms])
	print("RoadBuilder no-regresión: %d vértices / %d triángulos (superficie 0, cinta superior)" % [vtx_count, tri_count])
	return mesh_instance


static func _build_deck_collision(st_collision: SurfaceTool) -> StaticBody3D:
	var mesh := st_collision.commit()
	var body := StaticBody3D.new()
	body.name = "RoadDecksCollision"
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	return body


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


## Tablero de puente (contrato 4, W-2): cuerda entre extremos (NO muestrea terreno por
## vértice), más caja (cara inferior + costados) y colisión aparte para la cinta superior.
static func _add_deck_strip(st: SurfaceTool, st_box: SurfaceTool, st_collision: SurfaceTool, points: Array, half_width: float, sampler: TerrainSampler) -> void:
	var n := points.size()
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]

	var p0 := Vector2(points[0][0], points[0][1])
	var pN := Vector2(points[n - 1][0], points[n - 1][1])
	var h0 := sampler.height_at(p0.x, p0.y)
	var hN := sampler.height_at(pN.x, pN.y)

	var cum: Array[float] = [0.0]
	for i in range(n - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		cum.append(cum[i] + a.distance_to(b))
	var total_len: float = cum[n - 1]

	var top_heights: Array[float] = []
	for i in range(n):
		var t: float = 0.0 if total_len <= 0.0 else cum[i] / total_len
		top_heights.append(lerpf(h0, hN, t) + ROAD_LIFT)

	for i in range(n - 1):
		var ya0 := Vector3(offsets_a[i].x, top_heights[i], offsets_a[i].y)
		var yb0 := Vector3(offsets_b[i].x, top_heights[i], offsets_b[i].y)
		var ya1 := Vector3(offsets_a[i + 1].x, top_heights[i + 1], offsets_a[i + 1].y)
		var yb1 := Vector3(offsets_b[i + 1].x, top_heights[i + 1], offsets_b[i + 1].y)

		# Cinta superior (visual, mismo material que vías normales -- mismo st que build()).
		st.add_vertex(ya0)
		st.add_vertex(ya1)
		st.add_vertex(yb0)
		st.add_vertex(yb0)
		st.add_vertex(ya1)
		st.add_vertex(yb1)

		# Colisión aparte, SOLO la cinta superior (contrato 4).
		st_collision.add_vertex(ya0)
		st_collision.add_vertex(ya1)
		st_collision.add_vertex(yb0)
		st_collision.add_vertex(yb0)
		st_collision.add_vertex(ya1)
		st_collision.add_vertex(yb1)

		# Caja: cara inferior (DECK_BOX_DROP por debajo, winding invertido) + costados.
		var za0 := Vector3(ya0.x, ya0.y - DECK_BOX_DROP, ya0.z)
		var zb0 := Vector3(yb0.x, yb0.y - DECK_BOX_DROP, yb0.z)
		var za1 := Vector3(ya1.x, ya1.y - DECK_BOX_DROP, ya1.z)
		var zb1 := Vector3(yb1.x, yb1.y - DECK_BOX_DROP, yb1.z)

		st_box.add_vertex(za0)
		st_box.add_vertex(zb0)
		st_box.add_vertex(za1)
		st_box.add_vertex(za1)
		st_box.add_vertex(zb0)
		st_box.add_vertex(zb1)

		# Costado A (borde offsets_a).
		st_box.add_vertex(za0)
		st_box.add_vertex(ya1)
		st_box.add_vertex(za1)
		st_box.add_vertex(za0)
		st_box.add_vertex(ya0)
		st_box.add_vertex(ya1)

		# Costado B (borde offsets_b, orden espejado respecto al costado A).
		st_box.add_vertex(zb0)
		st_box.add_vertex(zb1)
		st_box.add_vertex(yb1)
		st_box.add_vertex(zb0)
		st_box.add_vertex(yb1)
		st_box.add_vertex(yb0)


## Cada vértice de la cinta se apoya en el terreno bajo su propia posición (no en el
## eje de la vía): así la calle sigue el relieve también en peraltes laterales.
static func _ribbon_vertex(p: Vector2, sampler: TerrainSampler) -> Vector3:
	return Vector3(p.x, sampler.height_at(p.x, p.y) + ROAD_LIFT, p.y)


## Cuenta cuántas vías comparten cada extremo (clave "%.2f|%.2f", MISMO formato que
## TrafficGraph.FUSE_FMT) -- usado por la regla de emergencia "empalme roto" (contrato 4):
## si un extremo de una vía deck=bridge no aparece en ninguna OTRA vía, esa vía se
## drapea como normal en vez de construirse como tablero.
static func _count_endpoint_occurrences(roads: Array) -> Dictionary:
	var counts := {}
	for road in roads:
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		for p in [points[0], points[points.size() - 1]]:
			var key := "%.2f|%.2f" % [float(p[0]), float(p[1])]
			counts[key] = counts.get(key, 0) + 1
	return counts


static func _has_broken_splice(points: Array, endpoint_counts: Dictionary) -> bool:
	for p in [points[0], points[points.size() - 1]]:
		var key := "%.2f|%.2f" % [float(p[0]), float(p[1])]
		if endpoint_counts.get(key, 0) < 2:
			return true
	return false
