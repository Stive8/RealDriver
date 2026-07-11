class_name RouteGenerator
extends RefCounted
## Generador de ruta en bucle sobre TrafficGraph (Fase M-2).
##
## Algoritmo: 1) elige una salida S cercana al centroide (preferencia por
## intersecciones tocadas por vía ancha); 2) Dijkstra dirigido desde S
## (respeta oneway); 3) candidato de retorno B entre los K nodos cuya
## distancia a S está más cerca de target_length/2 (seed=0 -> el mejor,
## seed>0 -> sorteo entre los K); 4) Dijkstra dirigido B->S penalizando x4
## las aristas+sentido usadas en la ida; 5) si el loop resultante es
## demasiado corto o no hay vuelta, degrada a ida-y-vuelta sobre aristas
## bidireccionales; 6) muestrea checkpoints cada `spacing` m sobre la
## polilínea final.
##
## Determinismo: todo desempate (selección de nodo en Dijkstra, elección de
## candidato, elección de checkpoint) se resuelve por la clave de nodo
## "%.2f|%.2f" (TrafficGraph.FUSE_FMT), nunca por orden de iteración.

# [ESTRUCTURAL] — válidas para cualquier ciudad.
const MIN_LOOP_RATIO := 0.6                        ## Umbral mínimo de loop vs target_length.
const RETURN_CANDIDATES_K := 5                     ## K candidatos de retorno.
const RETURN_PENALTY := 4.0                        ## Penalización x4 en aristas usadas en la ida.
const WIDE_ROAD_MIN_WIDTH := 8.0                   ## Ancho mínimo para candidatos de salida "anchos".
const CHECKPOINT_INTERSECTION_FRACTION := 1.0 / 3.0  ## Preferir intersección si está a < spacing * esto.

# [TUNEO-ZONA] — calibración de Jordán; otra ciudad DEBE recalibrar estas dos constantes.
# TARGET_LOOP_LENGTH=1500 cae justo del lado equivocado de un umbral de conectividad en
# el mapa de Jordán: a esa distancia no existe camino de vuelta dirigido válido desde
# ningún candidato B (probablemente por restricciones oneway) y la ruta degrada siempre a
# ida-y-vuelta — reportado por el humano como checkpoints que obligan a retroceder sobre
# el mismo tramo ya recorrido. 1450 sí produce un circuito cerrado real (longitud efectiva
# 1444.7 m, verificado headless: orden y conectividad correctos, checkpoints separados
# ≥ 111 m entre sí, un único nodo revisitado en todo el recorrido = el cierre salida/meta).
const TARGET_LOOP_LENGTH := 1450.0   ## Longitud objetivo del circuito (m).
const CHECKPOINT_SPACING := 180.0    ## Separación objetivo entre checkpoints (m).

const _EPS := 1e-6


class RouteData:
	var polyline: PackedVector2Array = PackedVector2Array()
	var checkpoints: Array = []  # Array[Dictionary{"pos": Vector2, "radius": float}]
	var length_m: float = 0.0
	var route_id: String = ""
	var degraded: bool = false


# ---------------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------------
static func generate(graph: TrafficGraph, target_length: float, spacing: float, seed_value: int = 0) -> RouteData:
	var t0 := Time.get_ticks_msec()
	var node_count: int = graph.node_pos.size()
	if node_count == 0:
		return null

	var node_keys := _build_node_keys(graph)
	var s := _pick_start(graph, node_keys)
	if s == -1:
		return null

	var route_data: RouteData = null
	var adjacency := _build_adjacency(graph, false)
	var dj := _dijkstra(node_count, adjacency, s, node_keys, {})
	var b := _pick_return_candidate(dj["dist"], s, target_length * 0.5, node_keys, seed_value)

	if b != -1:
		var outbound := _reconstruct_path(b, dj["prev_node"], dj["prev_edge"], dj["prev_dir"])
		var penalized: Dictionary = {}
		for use in outbound["edge_uses"]:
			penalized["%d_%d" % [use[0], use[1]]] = true

		var dj_back := _dijkstra(node_count, adjacency, b, node_keys, penalized)
		if dj_back["dist"][s] != INF:
			var inbound := _reconstruct_path(s, dj_back["prev_node"], dj_back["prev_edge"], dj_back["prev_dir"])
			var full_nodes: Array = outbound["nodes"].duplicate()
			for i in range(1, inbound["nodes"].size()):
				full_nodes.append(inbound["nodes"][i])

			var length_m := 0.0
			for use in outbound["edge_uses"]:
				length_m += graph.edge_length[use[0]]
			for use in inbound["edge_uses"]:
				length_m += graph.edge_length[use[0]]

			if length_m >= target_length * MIN_LOOP_RATIO:
				route_data = _build_route_data(graph, full_nodes, length_m, spacing, target_length, seed_value, false, node_keys)

	if route_data == null:
		route_data = _generate_degraded(graph, target_length, spacing, s, node_keys, seed_value)

	if route_data == null:
		print("[ruta] generación fallida: grafo insuficiente para target_length=%d" % int(target_length))
		return null

	print("[ruta] %d m, %d checkpoints, id=%s, degraded=%s, %d ms" % [
		int(route_data.length_m), route_data.checkpoints.size(), route_data.route_id,
		route_data.degraded, Time.get_ticks_msec() - t0])
	return route_data


## Marcadores de checkpoint (cilindro semitransparente por checkpoint, color distinto
## para el checkpoint de salida/meta). Usado por TimeTrialMode (Fase M-3) como HUD 3D
## propio del modo; los nodos hijos quedan en el mismo orden que route.checkpoints
## ("Checkpoint0".."CheckpointN-1"), así el modo puede indexarlos para atenuar/resaltar.
static func build_checkpoint_markers(checkpoints: Array) -> Node3D:
	return _build_checkpoint_markers(checkpoints)


# ---------------------------------------------------------------------------
# Selección de salida S
# ---------------------------------------------------------------------------
static func _build_node_keys(graph: TrafficGraph) -> PackedStringArray:
	var node_count: int = graph.node_pos.size()
	var node_keys := PackedStringArray()
	node_keys.resize(node_count)
	for i in range(node_count):
		node_keys[i] = TrafficGraph.FUSE_FMT % [graph.node_pos[i].x, graph.node_pos[i].y]
	return node_keys


static func _pick_start(graph: TrafficGraph, node_keys: PackedStringArray) -> int:
	var candidates: Array = []
	for n in graph.intersections:
		for e in graph.node_edges[n]:
			if graph.edge_width[e] >= WIDE_ROAD_MIN_WIDTH:
				candidates.append(n)
				break
	if candidates.is_empty():
		for n in graph.intersections:
			candidates.append(n)
	if candidates.is_empty():
		for i in range(graph.node_pos.size()):
			candidates.append(i)
	if candidates.is_empty():
		return -1

	var centroid := Vector2.ZERO
	for i in range(graph.node_pos.size()):
		centroid += graph.node_pos[i]
	centroid /= float(graph.node_pos.size())

	var best := -1
	var best_d := INF
	var best_key := ""
	for n in candidates:
		var d: float = graph.node_pos[n].distance_to(centroid)
		if best == -1 or d < best_d - _EPS or (absf(d - best_d) <= _EPS and node_keys[n] < best_key):
			best = n
			best_d = d
			best_key = node_keys[n]
	return best


# ---------------------------------------------------------------------------
# Dijkstra dirigido determinista (selección O(V^2); desempates por clave de nodo)
# ---------------------------------------------------------------------------
static func _build_adjacency(graph: TrafficGraph, bidirectional_only: bool) -> Array:
	var node_count: int = graph.node_pos.size()
	var adjacency: Array = []
	adjacency.resize(node_count)
	for i in range(node_count):
		adjacency[i] = []
	for e in range(graph.edge_from.size()):
		var a: int = graph.edge_from[e]
		var b: int = graph.edge_to[e]
		var ow: int = graph.edge_oneway[e]
		var length: float = graph.edge_length[e]
		if bidirectional_only:
			if ow != 0:
				continue
			adjacency[a].append([b, e, 1, length])
			adjacency[b].append([a, e, -1, length])
		else:
			if ow == 0 or ow == 1:
				adjacency[a].append([b, e, 1, length])
			if ow == 0 or ow == -1:
				adjacency[b].append([a, e, -1, length])
	return adjacency


static func _dijkstra(node_count: int, adjacency: Array, source: int, node_keys: PackedStringArray, penalized: Dictionary) -> Dictionary:
	var dist := PackedFloat32Array()
	dist.resize(node_count)
	for i in range(node_count):
		dist[i] = INF
	var prev_node := PackedInt32Array()
	prev_node.resize(node_count)
	for i in range(node_count):
		prev_node[i] = -1
	var prev_edge := PackedInt32Array()
	prev_edge.resize(node_count)
	for i in range(node_count):
		prev_edge[i] = -1
	var prev_dir := PackedInt32Array()
	prev_dir.resize(node_count)
	var visited := PackedByteArray()
	visited.resize(node_count)

	dist[source] = 0.0

	for _iter in range(node_count):
		var u := -1
		var best_dist := INF
		var best_key := ""
		for i in range(node_count):
			if visited[i] or dist[i] == INF:
				continue
			if u == -1 or dist[i] < best_dist - _EPS or (absf(dist[i] - best_dist) <= _EPS and node_keys[i] < best_key):
				u = i
				best_dist = dist[i]
				best_key = node_keys[i]
		if u == -1:
			break
		visited[u] = 1
		for link in adjacency[u]:
			var v: int = link[0]
			var eidx: int = link[1]
			var dirn: int = link[2]
			if visited[v]:
				continue
			var base_cost: float = link[3]
			var pk := "%d_%d" % [eidx, dirn]
			var cost: float = base_cost * (RETURN_PENALTY if penalized.has(pk) else 1.0)
			var nd: float = dist[u] + cost
			if nd < dist[v] - _EPS:
				dist[v] = nd
				prev_node[v] = u
				prev_edge[v] = eidx
				prev_dir[v] = dirn
			elif absf(nd - dist[v]) <= _EPS and prev_node[v] != -1 and node_keys[u] < node_keys[prev_node[v]]:
				prev_node[v] = u
				prev_edge[v] = eidx
				prev_dir[v] = dirn

	return {"dist": dist, "prev_node": prev_node, "prev_edge": prev_edge, "prev_dir": prev_dir}


static func _reconstruct_path(target: int, prev_node: PackedInt32Array, prev_edge: PackedInt32Array, prev_dir: PackedInt32Array) -> Dictionary:
	var nodes: Array = [target]
	var edge_uses: Array = []
	var cur := target
	while prev_node[cur] != -1:
		edge_uses.append([prev_edge[cur], prev_dir[cur]])
		cur = prev_node[cur]
		nodes.append(cur)
	nodes.reverse()
	edge_uses.reverse()
	return {"nodes": nodes, "edge_uses": edge_uses}


static func _pick_return_candidate(dist: PackedFloat32Array, source: int, half_target: float, node_keys: PackedStringArray, seed_value: int) -> int:
	var scored: Array = []
	for i in range(dist.size()):
		if i == source or dist[i] == INF:
			continue
		scored.append([absf(dist[i] - half_target), node_keys[i], i])
	if scored.is_empty():
		return -1
	var cmp := func(a, b):
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1]
	scored.sort_custom(cmp)
	var k: int = mini(RETURN_CANDIDATES_K, scored.size())
	if seed_value == 0:
		return scored[0][2]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return scored[rng.randi_range(0, k - 1)][2]


# ---------------------------------------------------------------------------
# Degradación a ida-y-vuelta (solo aristas bidireccionales)
# ---------------------------------------------------------------------------
static func _generate_degraded(graph: TrafficGraph, target_length: float, spacing: float, s: int, node_keys: PackedStringArray, seed_value: int) -> RouteData:
	var node_count: int = graph.node_pos.size()
	var adjacency := _build_adjacency(graph, true)
	var dj := _dijkstra(node_count, adjacency, s, node_keys, {})
	var b := _pick_return_candidate(dj["dist"], s, target_length * 0.5, node_keys, seed_value)
	if b == -1:
		return null

	var forward := _reconstruct_path(b, dj["prev_node"], dj["prev_edge"], dj["prev_dir"])
	var length_one_way := 0.0
	for use in forward["edge_uses"]:
		length_one_way += graph.edge_length[use[0]]
	var length_m := length_one_way * 2.0
	if length_m < target_length * MIN_LOOP_RATIO:
		return null

	var full_nodes: Array = forward["nodes"].duplicate()
	var rev: Array = forward["nodes"].duplicate()
	rev.reverse()
	for i in range(1, rev.size()):
		full_nodes.append(rev[i])

	return _build_route_data(graph, full_nodes, length_m, spacing, target_length, seed_value, true, node_keys)


# ---------------------------------------------------------------------------
# Construcción de RouteData: polilínea, checkpoints, route_id
# ---------------------------------------------------------------------------
static func _build_route_data(graph: TrafficGraph, node_seq: Array, length_m: float, spacing: float, target_length: float, seed_value: int, degraded: bool, node_keys: PackedStringArray) -> RouteData:
	var polyline := PackedVector2Array()
	for n in node_seq:
		polyline.append(graph.node_pos[n])

	var cum := PackedFloat32Array()
	cum.resize(node_seq.size())
	cum[0] = 0.0
	for i in range(1, node_seq.size()):
		cum[i] = cum[i - 1] + graph.node_pos[node_seq[i - 1]].distance_to(graph.node_pos[node_seq[i]])

	var intersection_set: Dictionary = {}
	for n in graph.intersections:
		intersection_set[n] = true

	var checkpoints := _build_checkpoints(graph, node_seq, cum, spacing, intersection_set, node_keys)

	var rd := RouteData.new()
	rd.polyline = polyline
	rd.checkpoints = checkpoints
	rd.length_m = length_m
	rd.degraded = degraded
	rd.route_id = _make_route_id(target_length, seed_value, checkpoints)
	return rd


static func _build_checkpoints(graph: TrafficGraph, node_seq: Array, cum: PackedFloat32Array, spacing: float, intersection_set: Dictionary, node_keys: PackedStringArray) -> Array:
	var checkpoints: Array = []
	var total: float = cum[cum.size() - 1]
	# Nodos ya usados como checkpoint (por índice de nodo, no de posición en node_seq): una
	# ruta degradada (ida y vuelta) recorre las MISMAS intersecciones dos veces con
	# distancias acumuladas distintas, así que un nodo puede volver a ser "el más cercano"
	# al marcar de la vuelta aunque ya se haya usado en la ida. Deduplicar solo contra el
	# checkpoint inmediatamente anterior ("sin duplicados consecutivos") no alcanza para
	# ese caso: el jugador cobra un checkpoint y el siguiente lo manda literalmente al mismo
	# sitio. Se deduplica contra TODOS los ya elegidos.
	var used_nodes: Dictionary = {}
	var mark := spacing
	var near_threshold := spacing * CHECKPOINT_INTERSECTION_FRACTION

	while mark < total:
		var best_all := -1
		var best_all_diff := INF
		var best_near := -1
		var best_near_diff := INF
		for i in range(node_seq.size()):
			var diff: float = absf(cum[i] - mark)
			var n: int = node_seq[i]
			if best_all == -1 or diff < best_all_diff - _EPS or (absf(diff - best_all_diff) <= _EPS and node_keys[n] < node_keys[node_seq[best_all]]):
				best_all = i
				best_all_diff = diff
			if diff < near_threshold and intersection_set.has(n):
				if best_near == -1 or diff < best_near_diff - _EPS or (absf(diff - best_near_diff) <= _EPS and node_keys[n] < node_keys[node_seq[best_near]]):
					best_near = i
					best_near_diff = diff

		var chosen_i: int = best_near if best_near != -1 else best_all
		var chosen_node: int = node_seq[chosen_i]
		if not used_nodes.has(chosen_node):
			checkpoints.append({"pos": graph.node_pos[chosen_node], "radius": _checkpoint_radius(graph, chosen_node)})
			used_nodes[chosen_node] = true
		mark += spacing

	var start_node: int = node_seq[0]
	if not used_nodes.has(start_node):
		checkpoints.append({"pos": graph.node_pos[start_node], "radius": _checkpoint_radius(graph, start_node)})
	return checkpoints


static func _checkpoint_radius(graph: TrafficGraph, node_idx: int) -> float:
	var max_width := 0.0
	for e in graph.node_edges[node_idx]:
		max_width = maxf(max_width, graph.edge_width[e])
	return clampf(max_width * 0.5 + 3.0, 6.0, 12.0)


static func _make_route_id(target_length: float, seed_value: int, checkpoints: Array) -> String:
	var coord_str := ""
	for cp in checkpoints:
		var p: Vector2 = cp["pos"]
		coord_str += "%.2f,%.2f;" % [p.x, p.y]
	var h: int = coord_str.hash()
	var h8 := "%08x" % (h & 0xFFFFFFFF)
	return "tt_v1_L%d_s%d_%s" % [int(target_length), seed_value, h8]


# ---------------------------------------------------------------------------
# Visualización: cilindros de checkpoint
# ---------------------------------------------------------------------------
static func _build_checkpoint_markers(checkpoints: Array) -> Node3D:
	var root := Node3D.new()
	root.name = "RouteCheckpoints"
	for i in range(checkpoints.size()):
		var cp: Dictionary = checkpoints[i]
		var is_start_finish := (i == checkpoints.size() - 1)
		root.add_child(_build_checkpoint_cylinder(cp["pos"], cp["radius"], is_start_finish, i))
	return root


static func _build_checkpoint_cylinder(pos: Vector2, radius: float, is_start_finish: bool, index: int) -> MeshInstance3D:
	const CYLINDER_HEIGHT := 4.0
	var cyl := CylinderMesh.new()
	cyl.height = CYLINDER_HEIGHT
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Cull por defecto (una sola cara): el checkpoint de salida/meta encierra el punto de
	# spawn del vehículo y la cámara de persecución queda cerca o dentro de él; con ambas
	# caras renderizadas (CULL_DISABLED) esa malla semitransparente auto-solapada titila.
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.35) if is_start_finish else Color(0.1, 0.75, 1.0, 0.35)
	var mi := MeshInstance3D.new()
	mi.name = "Checkpoint%d" % index
	mi.mesh = cyl
	mi.material_override = mat
	mi.position = Vector3(pos.x, CYLINDER_HEIGHT * 0.5, pos.y)
	return mi
