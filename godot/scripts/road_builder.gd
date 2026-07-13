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
## Contrato 6 (ESPEC_SESION_RETROFIT_AGUA_V2, W-4): generaliza la cuerda simple de W-2.
## Metros de despeje sintético por nivel de capa sobre el terreno LOCAL en cada punto de
## una vía elevada (no solo en sus extremos).
const LAYER_CLEARANCE := 5.0
## Contrato 6 (W-4): umbral de despeje sobre terreno que activa caja+colisión -- reemplaza
## la regla "solo deck" de W-2; una sola regla cubre tableros Y rampas (Tarea 2).
const ELEVATED_EPS := 0.5


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
	var elevated_built := 0
	var broken_splices := 0
	var ramps_built := 0
	var residual_steps := 0
	var has_box_geometry := false
	var elevated_collision_len := 0.0

	var endpoint_counts := _count_endpoint_occurrences(roads)
	var endpoint_heights := _compute_elevated_endpoint_heights(roads, endpoint_counts, sampler)

	for road in roads:
		var points: Array = road["points"]
		if points.size() < 2:
			continue
		var is_elev := _is_elevated(road)
		var is_elev_built := is_elev and not _has_broken_splice(points, endpoint_counts)

		var densified := _densify_points(points)
		points_inserted += densified["inserted"]
		var half_width: float = float(road["width"]) * 0.5

		if is_elev_built:
			var capa := _elev_capa(road)
			var heights := _compute_elevated_heights(densified["points"], points, capa, sampler)
			var res := _add_elevated_strip(st, st_box, st_collision, densified["points"], half_width, heights, sampler)
			has_box_geometry = has_box_geometry or res["has_box"]
			elevated_collision_len += float(res["collision_len"])
			elevated_built += 1
		else:
			if is_elev:
				broken_splices += 1
				print("RoadBuilder: vía id=%s elevada (deck/layer) con extremo sin empalme; drapeada como normal (regla de emergencia, contrato 4/6)" % str(road.get("id", "?")))
			_add_road_strip(st, densified["points"], half_width, sampler)
		roads_processed += 1

	st.generate_normals()
	var mesh := ArrayMesh.new()
	st.set_material(load(ROAD_MATERIAL_PATH))
	st.commit(mesh)

	if has_box_geometry:
		st_box.generate_normals()
		# DECISION_PENDIENTE (heredado de W-2, sigue aplicando en W-4): el ESPEC prescribe
		# color de vértice ×0.8 para inferior/costados; road_builder.gd no usa color de
		# vértice en ningún lugar, así que se usa un segundo material con albedo
		# precomputado ×0.8 -- resultado visual idéntico, cero riesgo al camino verificado.
		st_box.set_material(load(DECK_UNDERSIDE_MATERIAL_PATH))
		st_box.commit(mesh)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roads"
	mesh_instance.mesh = mesh

	if has_box_geometry:
		mesh_instance.add_child(_build_deck_collision(st_collision))

	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var vtx_count: int = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	var tri_count := vtx_count / 3
	print("RoadBuilder: %d vías, %d puntos insertados por subdivisión, %d vías elevadas por capa, %d rampas generadas, %d escalones residuales, %.1f m de colisión elevada, %d empalmes rotos, %d ms" % [
		roads_processed, points_inserted, elevated_built, ramps_built, residual_steps, elevated_collision_len, broken_splices, elapsed_ms])
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


## Contrato 6 (W-4): cinta con alturas ARBITRARIAS por vértice, ya resueltas por el
## llamador (tablero elevado en esta tarea; rampa en la Tarea 2 -- misma función para
## ambas). Reemplaza a _add_deck_strip de W-2: la regla de caja+colisión ya no es "todo o
## nada por vía", es POR SEGMENTO según su despeje sobre el terreno local (ELEVATED_EPS) --
## "una sola regla cubre tableros Y rampas" (contrato 6).
static func _add_elevated_strip(st: SurfaceTool, st_box: SurfaceTool, st_collision: SurfaceTool, points: Array, half_width: float, heights: Array[float], sampler: TerrainSampler) -> Dictionary:
	var offsets := RibbonUtil.compute_offsets(points, half_width)
	var offsets_a: Array[Vector2] = offsets["a"]
	var offsets_b: Array[Vector2] = offsets["b"]
	var n := points.size()
	var has_box := false
	var collision_len := 0.0

	for i in range(n - 1):
		var ya0 := Vector3(offsets_a[i].x, heights[i], offsets_a[i].y)
		var yb0 := Vector3(offsets_b[i].x, heights[i], offsets_b[i].y)
		var ya1 := Vector3(offsets_a[i + 1].x, heights[i + 1], offsets_a[i + 1].y)
		var yb1 := Vector3(offsets_b[i + 1].x, heights[i + 1], offsets_b[i + 1].y)

		# Cinta superior (visual, mismo material que vías normales -- mismo st que build()).
		st.add_vertex(ya0)
		st.add_vertex(ya1)
		st.add_vertex(yb0)
		st.add_vertex(yb0)
		st.add_vertex(ya1)
		st.add_vertex(yb1)

		# Despeje sobre terreno LOCAL en cada extremo del segmento (eje de la vía, no los
		# bordes -- suficiente para decidir "elevado" sin duplicar el muestreo por borde).
		var p0 := Vector2(points[i][0], points[i][1])
		var p1 := Vector2(points[i + 1][0], points[i + 1][1])
		var clr0 := heights[i] - sampler.height_at(p0.x, p0.y)
		var clr1 := heights[i + 1] - sampler.height_at(p1.x, p1.y)
		if clr0 > ELEVATED_EPS or clr1 > ELEVATED_EPS:
			has_box = true
			collision_len += p0.distance_to(p1)

			# Colisión aparte, SOLO la cinta superior (contrato 4/6).
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

	return {"has_box": has_box, "collision_len": collision_len}


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


## Contrato 6 (W-4): una vía es "elevada" si es tablero (deck=bridge) o tiene layer>0
## explícito. layer<0 sin tunnel se trata como capa 0 (drapeada) -- NO es elevada. Los
## túneles (deck=tunnel) NUNCA son elevados: drapeado normal, sin cambios desde W-2.
static func _is_elevated(road: Dictionary) -> bool:
	var deck: String = String(road.get("deck", ""))
	if deck == "bridge":
		return true
	if road.has("layer") and int(road["layer"]) > 0:
		return true
	return false


## Contrato 6 (W-4): capa = layer si existe (clamp [1,3]); si no, 1 (deck=bridge sin layer).
static func _elev_capa(road: Dictionary) -> int:
	var raw: int = int(road["layer"]) if road.has("layer") else 1
	return clampi(raw, 1, 3)


static func _arc_length(points: Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		total += a.distance_to(b)
	return total


static func _cumulative_arc_length(points: Array) -> Array[float]:
	var cum: Array[float] = [0.0]
	for i in range(points.size() - 1):
		var a := Vector2(points[i][0], points[i][1])
		var b := Vector2(points[i + 1][0], points[i + 1][1])
		cum.append(cum[i] + a.distance_to(b))
	return cum


## Contrato 6 (W-4): h_tablero(t) = max(cuerda(t), height_at(t) + capa*LAYER_CLEARANCE) +
## ROAD_LIFT, evaluado en cada punto de `densified_points`. `original_points` ancla h0/hN y
## la longitud total de arco de la cuerda -- misma equivalencia densificado/original que W-3
## ya estableció (la densificación solo inserta puntos colineales, así que el arco y la
## fracción t en cualquier punto compartido son idénticos calculados sobre cualquiera de
## las dos listas).
static func _compute_elevated_heights(densified_points: Array, original_points: Array, capa: int, sampler: TerrainSampler) -> Array[float]:
	var p0 := Vector2(original_points[0][0], original_points[0][1])
	var pN := Vector2(original_points[original_points.size() - 1][0], original_points[original_points.size() - 1][1])
	var h0 := sampler.height_at(p0.x, p0.y)
	var hN := sampler.height_at(pN.x, pN.y)
	var total_len := _arc_length(original_points)

	var n := densified_points.size()
	var cum := _cumulative_arc_length(densified_points)
	var heights: Array[float] = []
	for i in range(n):
		var t: float = 0.0 if total_len <= 0.0 else cum[i] / total_len
		var chord := lerpf(h0, hN, t)
		var p := Vector2(densified_points[i][0], densified_points[i][1])
		var floor_h := sampler.height_at(p.x, p.y) + float(capa) * LAYER_CLEARANCE
		heights.append(maxf(chord, floor_h) + ROAD_LIFT)
	return heights


## Contrato 6 (W-4): altura resuelta de cada extremo de vía elevada Y CONSTRUIDA (sin
## empalme roto) -- ancla para las rampas de aproximación de sus vías vecinas (Tarea 2). En
## el extremo exacto (t=0 o t=1) la cuerda vale EXACTAMENTE height_at(extremo) por
## construcción, así que el máximo con el término de capa siempre lo gana (capa>=1 =>
## +LAYER_CLEARANCE>=5m>0): el extremo resuelto es SIEMPRE
## height_at(extremo) + capa*LAYER_CLEARANCE + ROAD_LIFT, sin necesidad de evaluar max().
static func _compute_elevated_endpoint_heights(roads: Array, endpoint_counts: Dictionary, sampler: TerrainSampler) -> Dictionary:
	var result := {}
	for road in roads:
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		if not _is_elevated(road):
			continue
		if _has_broken_splice(points, endpoint_counts):
			continue
		var capa := _elev_capa(road)
		var p0 := Vector2(points[0][0], points[0][1])
		var pN := Vector2(points[points.size() - 1][0], points[points.size() - 1][1])
		var h0 := sampler.height_at(p0.x, p0.y) + float(capa) * LAYER_CLEARANCE + ROAD_LIFT
		var hN := sampler.height_at(pN.x, pN.y) + float(capa) * LAYER_CLEARANCE + ROAD_LIFT
		result["%.2f|%.2f" % [p0.x, p0.y]] = h0
		result["%.2f|%.2f" % [pN.x, pN.y]] = hN
	return result
