class_name TrafficGraph
extends RefCounted
## Grafo de navegación de tráfico (Fase T-0).
##
## Construye un grafo topológico desde los `roads` de map.json (v1.0/v1.1):
##   nodo = punto único (fusión por clave exacta "%.2f|%.2f")
##   arista = segmento consecutivo de una vía (hereda road_id, highway, width, oneway, longitud)
##   intersección = nodo con >= 3 aristas · terminal = nodo con 1 arista · 2 aristas = continuación
##
## Resuelve SOLO la clasificación del controlador de cada intersección (signals ->
## SignalController; stop/give_way -> PriorityController con acceso que cede; nada ->
## PriorityController puro). La lógica de paso es de T-3.
##
## Cuenta cruces geométricos entre aristas NO conectadas topológicamente (segmentos
## que se intersectan en 2D sin compartir nodo) y lo reporta. No los conecta.

# Tipo de controlador resuelto en T-0 (la lógica de paso llega en T-3).
enum Controller { PRIORITY_PURE, PRIORITY_STOP, SIGNAL }

# [ESTRUCTURAL] — válidas para cualquier ciudad.
const FUSE_FMT := "%.2f|%.2f"       ## Clave de fusión de nodos (sin épsilon).
const CONTROL_BIND_DIST := 5.0      ## Vincular control al nodo más cercano si dista < 5 m.
const CROSS_CELL_SIZE := 30.0       ## Tamaño de celda del hash espacial para cruces (m).

const OVERLAY_Y := 0.3              ## Altura de las líneas del overlay de depuración.

# --- Datos del grafo ---
var node_pos: PackedVector2Array = PackedVector2Array()   ## índice -> Vector2(x, z)
var node_edges: Array = []                                ## índice -> Array[int] aristas incidentes

var edge_from: PackedInt32Array = PackedInt32Array()
var edge_to: PackedInt32Array = PackedInt32Array()
var edge_road_id: PackedInt32Array = PackedInt32Array()
var edge_highway: Array[String] = []
var edge_width: PackedFloat32Array = PackedFloat32Array()
var edge_oneway: PackedInt32Array = PackedInt32Array()
var edge_length: PackedFloat32Array = PackedFloat32Array()
var edge_deck: Array[String] = []
var edge_deck_y_from: PackedFloat32Array = PackedFloat32Array()  ## altura de cuerda de tablero en el nodo `from` (solo si edge_deck[i] != ""); 0.0 en aristas normales
var edge_deck_y_to: PackedFloat32Array = PackedFloat32Array()    ## idem, nodo `to`
var edge_capa: PackedInt32Array = PackedInt32Array()  ## capa_efectiva por arista (layer si existe; si no, bridge=+1/tunnel=-1/normal=0). Contrato 7, W-3.

# --- Clasificación ---
var intersections: PackedInt32Array = PackedInt32Array()  ## nodos con >= 3 aristas
var terminals: PackedInt32Array = PackedInt32Array()      ## nodos con 1 arista
var node_controller: Dictionary = {}                      ## node_index -> Controller (solo intersecciones)
var node_control_types: Dictionary = {}                   ## node_index -> Array[String] controles vinculados

# --- Diagnóstico ---
var controls_bound: int = 0
var controls_discarded: int = 0
var unconnected_crossings: int = 0
var build_ms: int = 0
var mixed_capa_intersections: int = 0  ## nodos grado>=3 excluidos de `intersections` por capa_efectiva mixta entre sus aristas (contrato 7, W-3; ver DECISION_PENDIENTE en _classify_nodes)

var _fuse: Dictionary = {}          ## clave "%.2f|%.2f" -> node_index


func build(roads: Array, controls: Array, sampler: TerrainSampler) -> void:
	var t0 := Time.get_ticks_msec()
	_build_nodes_and_edges(roads, sampler)
	_classify_nodes()
	_bind_controls(controls)
	_assign_controllers()
	_count_unconnected_crossings()
	build_ms = Time.get_ticks_msec() - t0


# ---------------------------------------------------------------------------
# Construcción de nodos y aristas
# ---------------------------------------------------------------------------
## Cuenta cuántas vías comparten cada extremo (clave FUSE_FMT) -- duplicado deliberado del
## algoritmo homónimo de road_builder.gd (misma convención que water_builder.gd al duplicar
## los helpers de footprint de building_builder.gd: pequeña duplicación local en vez de
## alcance cruzado a estáticos privados de otra clase).
func _count_road_endpoint_occurrences(roads: Array) -> Dictionary:
	var counts := {}
	for road in roads:
		var points: Array = road.get("points", [])
		if points.size() < 2:
			continue
		for p in [points[0], points[points.size() - 1]]:
			var key := FUSE_FMT % [float(p[0]), float(p[1])]
			counts[key] = counts.get(key, 0) + 1
	return counts


## Espejo de road_builder.gd::_has_broken_splice -- ambos extremos deben aparecer en
## >= 2 vías para que el tablero se construya como tal (si no, road_builder lo drapea
## como vía normal y este grafo debe coincidir con esa decisión).
func _has_broken_splice(points: Array, endpoint_counts: Dictionary) -> bool:
	for p in [points[0], points[points.size() - 1]]:
		var key := FUSE_FMT % [float(p[0]), float(p[1])]
		if endpoint_counts.get(key, 0) < 2:
			return true
	return false


func _build_nodes_and_edges(roads: Array, sampler: TerrainSampler) -> void:
	var endpoint_counts := _count_road_endpoint_occurrences(roads)

	for road in roads:
		var pts: Array = road.get("points", [])
		if pts.size() < 2:
			continue
		var rid := int(road.get("id", -1))
		var hw := String(road.get("highway", ""))
		var w := float(road.get("width", 6.0))
		# v1.1 retrocompatible: oneway ausente = 0 (bidireccional).
		var ow := int(road.get("oneway", 0))
		# Fase W-2 (contrato 7): deck ausente = "" (vía normal, sin interpolación de y).
		# edge_deck sólo debe valer "bridge" cuando road_builder.gd REALMENTE construye esta
		# vía como tablero (bridge Y sin empalme roto) -- no basta con que el JSON diga "bridge"
		# (ver road_builder.gd:39, misma regla de emergencia de empalme roto).
		var raw_deck := String(road.get("deck", ""))
		var is_built_deck := raw_deck == "bridge" and not _has_broken_splice(pts, endpoint_counts)
		var deck := "bridge" if is_built_deck else ""

		# Fase W-3 (contrato 7): capa_efectiva de la vía completa -- layer del tag OSM si existe,
		# si no bridge/tunnel/normal. Nota: usa raw_deck (el campo JSON), no `deck` (que ya pasó
		# por la regla de empalme roto) -- capa_efectiva es una propiedad de la vía tal como OSM
		# la etiquetó, independiente de si road_builder.gd terminó construyéndola como tablero.
		var capa: int
		if road.has("layer"):
			capa = int(road["layer"])
		elif raw_deck == "bridge":
			capa = 1
		elif raw_deck == "tunnel":
			capa = -1
		else:
			capa = 0

		# Cuerda global del tablero (espejo de road_builder.gd::_add_deck_strip): recta entre
		# el primer y último punto de la vía completa, NO entre los extremos de cada arista.
		# Sin ROAD_LIFT: la rama sin tablero de traffic_manager.gd tampoco lo suma.
		var chord_y: Array[float] = []
		if is_built_deck:
			var p0 := Vector2(pts[0][0], pts[0][1])
			var pN := Vector2(pts[pts.size() - 1][0], pts[pts.size() - 1][1])
			var h0 := sampler.height_at(p0.x, p0.y)
			var hN := sampler.height_at(pN.x, pN.y)
			var cum: Array[float] = [0.0]
			for i in range(pts.size() - 1):
				var a := Vector2(pts[i][0], pts[i][1])
				var b := Vector2(pts[i + 1][0], pts[i + 1][1])
				cum.append(cum[i] + a.distance_to(b))
			var total_len: float = cum[pts.size() - 1]
			for i in range(pts.size()):
				var t: float = 0.0 if total_len <= 0.0 else cum[i] / total_len
				chord_y.append(lerpf(h0, hN, t))

		var prev_node := _get_or_add_node(pts[0])
		for i in range(1, pts.size()):
			var cur_node := _get_or_add_node(pts[i])
			if cur_node == prev_node:
				# Puntos consecutivos idénticos tras redondeo: no hay segmento.
				continue
			var y_from: float = chord_y[i - 1] if is_built_deck else 0.0
			var y_to: float = chord_y[i] if is_built_deck else 0.0
			_add_edge(prev_node, cur_node, rid, hw, w, ow, deck, y_from, y_to, capa)
			prev_node = cur_node


func _get_or_add_node(p) -> int:
	var x := float(p[0])
	var z := float(p[1])
	var key := FUSE_FMT % [x, z]
	if _fuse.has(key):
		return _fuse[key]
	var idx := node_pos.size()
	node_pos.append(Vector2(x, z))
	node_edges.append([])
	_fuse[key] = idx
	return idx


func _add_edge(a: int, b: int, rid: int, hw: String, w: float, ow: int, deck: String, y_from: float, y_to: float, capa: int) -> void:
	var eidx := edge_from.size()
	edge_from.append(a)
	edge_to.append(b)
	edge_road_id.append(rid)
	edge_highway.append(hw)
	edge_width.append(w)
	edge_oneway.append(ow)
	edge_length.append(node_pos[a].distance_to(node_pos[b]))
	edge_deck.append(deck)
	edge_deck_y_from.append(y_from)
	edge_deck_y_to.append(y_to)
	edge_capa.append(capa)
	node_edges[a].append(eidx)
	node_edges[b].append(eidx)


# ---------------------------------------------------------------------------
# Clasificación topológica de nodos
# ---------------------------------------------------------------------------
func _classify_nodes() -> void:
	for i in range(node_pos.size()):
		var deg: int = node_edges[i].size()
		if deg >= 3:
			if _same_capa(node_edges[i]):
				intersections.append(i)
			else:
				mixed_capa_intersections += 1
		elif deg == 1:
			terminals.append(i)


## Contrato 7 (W-3): las intersecciones de este grafo se forman SOLO por fusión de nodos por
## coordenada (_get_or_add_node) -- inspección obligatoria confirmó que no hay detección 2D de
## cruces alimentando la lógica de paso (_count_unconnected_crossings es solo diagnóstico, leído
## únicamente por print_diagnostics/unconnected_crossings_pct). Aplica la regla (i) del contrato.
##
## DECISION_PENDIENTE (humano confirmó 2026-07-13, ver docs/superpowers/plans/2026-07-13-retrofit-agua-w3.md):
## el contrato pide "guarda en la fusión: dos endpoints de capa distinta NO se fusionan", pero
## aplicado ahí de forma literal e incondicional rompería los empalmes deck<->vía de aproximación
## que W-2 ya construye y el humano ya validó (el extremo de una vía deck=bridge SIEMPRE comparte
## coordenada exacta con la vía vecina a nivel que continúa, por cómo OSM parte una vía en el
## punto donde empieza/termina el puente) -- desconectar esos nodos aislaría los 5 tableros de
## Jordán del grafo de tráfico, una regresión directa contra el checklist ya aceptado de W-2.
## Los nodos de grado 2 (el caso de un empalme simple) NUNCA reciben controlador (solo grado>=3
## se clasifica como intersección, ver arriba), así que fusionarlos sin importar la capa es
## inofensivo para la lógica de paso. El guarda se aplica entonces en la CLASIFICACIÓN: un nodo
## de grado>=3 solo se vuelve intersección (con IntersectionController compartido) si TODAS sus
## aristas incidentes tienen la misma capa_efectiva; si son mixtas, se excluye de intersections Y
## de terminals (no recibe controlador) y se cuenta en mixed_capa_intersections -- así un puente
## que por coincidencia de redondeo comparte nodo con una vía inferior nunca comparte
## ceda-el-paso con ella, sin tocar la conectividad real de ningún empalme legítimo.
func _same_capa(edges: Array) -> bool:
	if edges.is_empty():
		return true
	var first: int = edge_capa[edges[0]]
	for e in edges:
		if edge_capa[e] != first:
			return false
	return true


# ---------------------------------------------------------------------------
# Vinculación de controles al nodo más cercano (< 5 m); si no, se descarta y cuenta.
# ---------------------------------------------------------------------------
func _bind_controls(controls: Array) -> void:
	for c in controls:
		var pos_arr: Array = c.get("pos", [])
		if pos_arr.size() < 2:
			controls_discarded += 1
			continue
		var cpos := Vector2(float(pos_arr[0]), float(pos_arr[1]))
		var ctype := String(c.get("type", ""))
		var best := -1
		var best_d := CONTROL_BIND_DIST
		for i in range(node_pos.size()):
			var d := cpos.distance_to(node_pos[i])
			if d < best_d:
				best_d = d
				best = i
		if best == -1:
			controls_discarded += 1
		else:
			controls_bound += 1
			if not node_control_types.has(best):
				node_control_types[best] = []
			node_control_types[best].append(ctype)


func _assign_controllers() -> void:
	for n in intersections:
		var ctrl := Controller.PRIORITY_PURE
		if node_control_types.has(n):
			var types: Array = node_control_types[n]
			if "signals" in types:
				ctrl = Controller.SIGNAL
			elif ("stop" in types) or ("give_way" in types):
				ctrl = Controller.PRIORITY_STOP
		node_controller[n] = ctrl


# ---------------------------------------------------------------------------
# Cruces geométricos entre aristas NO conectadas (no comparten nodo).
# Hash espacial por celdas para evitar el O(E^2) ingenuo.
# ---------------------------------------------------------------------------
func _count_unconnected_crossings() -> void:
	var grid: Dictionary = {}
	var inv := 1.0 / CROSS_CELL_SIZE
	var edge_count := edge_from.size()

	for e in range(edge_count):
		var a := node_pos[edge_from[e]]
		var b := node_pos[edge_to[e]]
		var min_cx := int(floor(minf(a.x, b.x) * inv))
		var max_cx := int(floor(maxf(a.x, b.x) * inv))
		var min_cy := int(floor(minf(a.y, b.y) * inv))
		var max_cy := int(floor(maxf(a.y, b.y) * inv))
		for cx in range(min_cx, max_cx + 1):
			for cy in range(min_cy, max_cy + 1):
				var k := Vector2i(cx, cy)
				if not grid.has(k):
					grid[k] = PackedInt32Array()
				grid[k].append(e)

	var seen: Dictionary = {}
	for k in grid:
		var arr: PackedInt32Array = grid[k]
		var m := arr.size()
		for i in range(m):
			for j in range(i + 1, m):
				var e1: int = arr[i]
				var e2: int = arr[j]
				var lo: int = min(e1, e2)
				var hi: int = max(e1, e2)
				var pk: int = lo * 1000000 + hi
				if seen.has(pk):
					continue
				seen[pk] = true
				# Comparten nodo -> topológicamente conectadas (adyacentes): no es "no conectado".
				if edge_from[e1] == edge_from[e2] or edge_from[e1] == edge_to[e2] \
						or edge_to[e1] == edge_from[e2] or edge_to[e1] == edge_to[e2]:
					continue
				var hit = Geometry2D.segment_intersects_segment(
					node_pos[edge_from[e1]], node_pos[edge_to[e1]],
					node_pos[edge_from[e2]], node_pos[edge_to[e2]])
				if hit != null:
					unconnected_crossings += 1


func unconnected_crossings_pct() -> float:
	# "Cruces visibles" = cruces conectados (nodos-intersección) + cruces sólo geométricos.
	# El % responde: de todos los cruces visibles, ¿qué fracción NO está topológicamente conectada?
	var visible := unconnected_crossings + intersections.size()
	if visible == 0:
		return 0.0
	return 100.0 * float(unconnected_crossings) / float(visible)


func _controller_breakdown() -> Array:
	var sig := 0
	var pstop := 0
	var ppure := 0
	for n in node_controller:
		match int(node_controller[n]):
			Controller.SIGNAL:
				sig += 1
			Controller.PRIORITY_STOP:
				pstop += 1
			_:
				ppure += 1
	return [sig, pstop, ppure]


func print_diagnostics() -> void:
	var bd := _controller_breakdown()
	print("[TrafficGraph] nodos:%d  aristas:%d  intersecciones:%d  terminales:%d" % [
		node_pos.size(), edge_from.size(), intersections.size(), terminals.size()])
	print("[TrafficGraph] controladores -> signal:%d  priority_stop:%d  priority_pure:%d" % [
		bd[0], bd[1], bd[2]])
	print("[TrafficGraph] controles vinculados:%d  descartados:%d" % [
		controls_bound, controls_discarded])
	print("[TrafficGraph] cruces no conectados:%d  (%.1f%% de cruces visibles)" % [
		unconnected_crossings, unconnected_crossings_pct()])
	print("[TrafficGraph] intersecciones con capa mixta excluidas: %d" % mixed_capa_intersections)
	print("[TrafficGraph] construccion: %d ms" % build_ms)


# ---------------------------------------------------------------------------
# Overlay de depuración (tecla G): aristas por clase, sentidos oneway, nodos.
# Fase R-3: sus líneas/esferas son puramente visuales (no las lee ninguna lógica de
# tráfico), así que su y pasa de OVERLAY_Y fijo a sampler.height_at + OVERLAY_Y.
# ---------------------------------------------------------------------------
func build_debug_overlay(sampler: TerrainSampler) -> Node3D:
	var root := Node3D.new()
	root.name = "TrafficDebugOverlay"
	root.add_child(_build_edge_lines(sampler))
	root.add_child(_build_node_spheres(sampler))
	return root


func _unshaded_vertex_color_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _class_color(highway: String) -> Color:
	match highway:
		"motorway", "trunk":
			return Color(0.85, 0.15, 0.15)
		"primary":
			return Color(0.95, 0.55, 0.10)
		"secondary":
			return Color(0.95, 0.85, 0.15)
		"tertiary":
			return Color(0.55, 0.85, 0.25)
		"residential", "unclassified":
			return Color(0.35, 0.65, 0.95)
		"living_street":
			return Color(0.60, 0.45, 0.85)
		"service":
			return Color(0.55, 0.55, 0.55)
		_:
			return Color(0.8, 0.8, 0.8)


func _build_edge_lines(sampler: TerrainSampler) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var mat := _unshaded_vertex_color_material()
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)

	for e in range(edge_from.size()):
		var a := node_pos[edge_from[e]]
		var b := node_pos[edge_to[e]]
		var col := _class_color(edge_highway[e])
		_line(im, a, b, col, sampler)

		var ow: int = edge_oneway[e]
		if ow != 0:
			# Sentido de viaje: 1 = orden de points (from->to); -1 = inverso.
			var ta := a if ow == 1 else b
			var tb := b if ow == 1 else a
			_arrow(im, ta, tb, col, sampler)

	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.name = "TrafficEdges"
	mi.mesh = im
	return mi


func _line(im: ImmediateMesh, a: Vector2, b: Vector2, col: Color, sampler: TerrainSampler) -> void:
	im.surface_set_color(col)
	im.surface_add_vertex(Vector3(a.x, sampler.height_at(a.x, a.y) + OVERLAY_Y, a.y))
	im.surface_set_color(col)
	im.surface_add_vertex(Vector3(b.x, sampler.height_at(b.x, b.y) + OVERLAY_Y, b.y))


func _arrow(im: ImmediateMesh, a: Vector2, b: Vector2, col: Color, sampler: TerrainSampler) -> void:
	# Chevron corto cerca de la cabeza (b) apuntando en el sentido de viaje a->b.
	var seg := b - a
	var length := seg.length()
	if length < 0.5:
		return
	var d := seg / length
	var perp := Vector2(-d.y, d.x)
	var size := clampf(length * 0.25, 1.0, 4.0)
	var tip := a.lerp(b, 0.7)
	var p1 := tip - d * size + perp * size * 0.5
	var p2 := tip - d * size - perp * size * 0.5
	_line(im, tip, p1, col, sampler)
	_line(im, tip, p2, col, sampler)


func _build_node_spheres(sampler: TerrainSampler) -> MultiMeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 1.5
	sphere.height = 3.0
	sphere.radial_segments = 6
	sphere.rings = 3

	# (posición, color) para cada nodo destacado.
	var items: Array = []
	for n in intersections:
		items.append([node_pos[n], _controller_color(int(node_controller.get(n, Controller.PRIORITY_PURE)))])
	for n in terminals:
		items.append([node_pos[n], Color(0.9, 0.2, 0.2)])  # terminal = rojo

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sphere
	mm.instance_count = items.size()
	for i in range(items.size()):
		var pos: Vector2 = items[i][0]
		var xform := Transform3D(Basis.IDENTITY, Vector3(pos.x, sampler.height_at(pos.x, pos.y) + OVERLAY_Y + 1.0, pos.y))
		mm.set_instance_transform(i, xform)
		mm.set_instance_color(i, items[i][1])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "TrafficNodes"
	mmi.multimesh = mm
	mmi.material_override = _unshaded_vertex_color_material()
	return mmi


func _controller_color(ctrl: int) -> Color:
	match ctrl:
		Controller.SIGNAL:
			return Color(0.2, 0.9, 0.3)    # verde = SignalController
		Controller.PRIORITY_STOP:
			return Color(1.0, 0.9, 0.1)    # amarillo = con stop/give_way
		_:
			return Color(0.6, 0.6, 0.6)    # gris = PriorityController puro
