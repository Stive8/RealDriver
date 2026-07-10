class_name TrafficManager
extends Node3D
## Gestor cinemático del tráfico vehicular (Fases T-1 y T-2).
##
## Los agentes NO usan física de vehículo: son cuerpos `AnimatableBody3D`
## (`sync_to_physics`) de traffic_car.tscn, SIN script propio, movidos a mano por
## este manager. Un pool fijo de MAX_AGENTS cuerpos se crea al inicio (nunca se
## instancian/liberan en gameplay); cada índice tiene un registro `Agent` persistente
## que se activa/desactiva. La integración cinemática ocurre en `_physics_process`:
## se muestrea la posición sobre la polilínea del grafo + `LANE_OFFSET` a la derecha
## del sentido de marcha (esquinas redondeadas por Bézier), con yaw suavizado y
## reducción de velocidad ante curvas.
##
## T-2 añade: población por densidad, seguimiento en fila (listas por arista+sentido
## ordenadas por s, mantenidas incrementalmente), spawn/despawn por distancia y frustum,
## y anillos A/B (B simula 1 de cada 2 frames). FSM: CRUISING/FOLLOWING.
##
## T-3 añade intersecciones con reglas: un `IntersectionController` por nodo de grado >= 3
## (tipo ya clasificado en T-0) resuelve el paso por reservas de disco interior (1 vehículo
## a la vez). `_service_intersections` es la ÚNICA función que fija los estados APPROACHING /
## WAITING / CROSSING y el tope de velocidad del cruce; también las tres válvulas anti-atasco
## (reserva 6 s en el controlador, replan 45 s y despawn de atascado 60 s en el manager).
## BLOCKED queda reservado para T-4 (jugador).
##
## Toda la lógica de velocidad pasa por `_decide_target_speed(agent)` y toda la de ruta
## por `_decide_next_edge(agent, node)` (caminata aleatoria): son las DOS costuras únicas
## de decisión y el gancho para IA futura. No se añaden más costuras.

# ============================================================================
#  CONSTANTES DEL SISTEMA
# ============================================================================
# --- [ESTRUCTURAL] — válidas para cualquier ciudad (no dependen de la densidad local). ---

const DRIVING_SIDE_RIGHT := true      ## Lado de circulación (parámetro por país). RIGHT.

## LANE_OFFSET = clamp(width * FACTOR, MIN, MAX): desplazamiento lateral desde el eje
## de la vía hacia la derecha del sentido de marcha.
const LANE_OFFSET_FACTOR := 0.25
const LANE_OFFSET_MIN := 1.0
const LANE_OFFSET_MAX := 3.5

## Velocidad objetivo base por clase de vía (m/s).
const SPEED_BY_CLASS := {
	"service": 4.0, "living_street": 4.0,
	"residential": 8.3, "unclassified": 8.3,
	"tertiary": 11.0, "secondary": 12.5,
	"primary": 14.0, "trunk": 16.5, "motorway": 16.5,
}
const SPEED_DEFAULT := 8.3            ## Clase desconocida -> se trata como residencial.

## Integración cinemática (m/s^2). BRAKE_MAX se reserva para frenados de emergencia (T-2+).
const ACCEL := 3.0
const BRAKE_COMFORT := 4.0
const BRAKE_MAX := 8.0

## Reducción en curva: ante el próximo vértice de ángulo θ, tomar la curva a
## v <= lerp(target, CORNER_MIN_SPEED, clamp(θ / CORNER_FULL_ANGLE_DEG, 0, 1)).
const CORNER_MIN_SPEED := 3.0
const CORNER_FULL_ANGLE_DEG := 90.0

## Suavizado de yaw: lerp_angle con factor delta * YAW_SMOOTH.
## ESPEC da 8.0; bajado a 6.0 (dentro del ±30% permitido) para que el giro sea más gradual.
const YAW_SMOOTH := 6.0

## Redondeo de esquinas (refinamiento autorizado por el arquitecto sobre el muestreo
## en polilínea): cerca de cada nodo la posición se muestrea por un arco de Bézier
## cuadrático tangente a las dos líneas de carril, eliminando el salto lateral en curvas.
## No toca ruta, s, oneway ni colisión: solo la POSE mostrada.
const CORNER_BLEND := 3.0             ## Distancia base (m) del arco a cada lado del nodo.
const CORNER_BLEND_FRAC := 0.45       ## Tope: el arco nunca supera esta fracción de la arista.
const CORNER_PARALLEL_EPS := 0.0001   ## Por debajo de este |cross| las líneas son paralelas (recta).

## Paleta fija; color del auto = paleta[hash(índice de spawn) % tamaño].
const CAR_PALETTE: Array[Color] = [
	Color("cc3333"), Color("3366cc"), Color("e0e0e0"),
	Color("888888"), Color("335533"), Color("ddaa33"),
]

# --- [TUNEO-ZONA] — calibración de Jordán; otra ciudad DEBE recalibrarlos. ---
# Declarados aquí (único hogar, según el ESPEC). Su USO llega en T-2+ (spawn/anillos);
# en T-1 solo existe la constante, no la lógica que la consume.
const MAX_AGENTS := 40                ## Techo duro de agentes simultáneos.
const DENSITY_DIVISOR := 60.0         ## Población objetivo = min(MAX_AGENTS, metros_vía_r_B / DENSITY_DIVISOR).
const RING_A_RADIUS := 100.0          ## Sim completa + colisión activa.
const RING_B_RADIUS := 220.0          ## Sim simplificada; alinear con niebla de V-4.
const SPAWN_MIN_DIST := 80.0          ## Banda de spawn = [SPAWN_MIN_DIST, RING_B_RADIUS].
const DESPAWN_HYSTERESIS := 30.0      ## Despawn a > RING_B_RADIUS + histéresis y fuera de frustum.

## Seguimiento (car-following). [ESTRUCTURAL]
const GAP_BASE := 2.0                 ## Gap mínimo parachoques (m); por debajo, frenado a fondo.
const GAP_TIME := 1.2                 ## Componente por velocidad del gap deseado (s).
const CAR_LENGTH := 4.0               ## Longitud del auto (gap medido parachoques-a-parachoques).
const FOLLOW_GAIN := 1.0              ## Ganancia proporcional del control de seguimiento.

## Spawn / despawn / anillos. [ESTRUCTURAL salvo los radios/densidad, ya arriba]
const SPAWN_INTERVAL := 1.0           ## Tick del spawner (s).
const SPAWN_ATTEMPTS := 25            ## Intentos aleatorios por auto a colocar.
const MIN_SPAWN_SEP := 12.0           ## No spawnear con otro agente a < 12 m del punto.
const CLASSIFY_INTERVAL := 0.5        ## Reclasificación de anillos (~2 veces/s) + chequeo de despawn.

## Intersecciones (T-3). [ESTRUCTURAL]
const INT_RADIUS_FACTOR := 0.75       ## Radio del disco interior = FACTOR × max(width incidentes).
const INT_DISC_MAX_FRAC := 0.45       ## El disco nunca pasa de esta fracción de la arista de acceso.
const INT_APPROACH_MARGIN := 6.0      ## Margen sobre la distancia de frenado para empezar a APPROACHING.
const INT_ENTER_DIST := 3.0           ## A esta distancia de la línea (o menos) el elegido entra al disco.
const INT_WAIT_EPS := 0.5             ## Por debajo de esta distancia a la línea sin permiso -> WAITING (parado).
const STOP_SPEED_EPS := 0.3           ## Umbral de "detenido" para el contador de atasco.

## Válvulas anti-atasco restantes (la de reserva 6 s vive en IntersectionController). [ESTRUCTURAL]
const REPLAN_TIME := 45.0             ## Replan del agente si lleva este tiempo trabado antes de un cruce.
const STUCK_DESPAWN_TIME := 60.0      ## Despawn de atascado: detenido este tiempo, fuera de frustum, > SPAWN_MIN_DIST.

## Estados de la FSM (definición completa; T-2 usa CRUISING/FOLLOWING).
enum State { CRUISING, FOLLOWING, APPROACHING, WAITING, CROSSING, BLOCKED }


## Registro de un agente. Guardado en `_agents` (índice = id = índice de spawn en T-1).
class Agent extends RefCounted:
	var id: int = 0
	var active: bool = false
	var edge: int = -1            ## arista actual del grafo
	var dir: int = 1             ## sentido de marcha sobre la arista: +1 (from->to) o -1 (to->from)
	var s: float = 0.0          ## distancia recorrida desde el nodo de entrada
	var speed: float = 0.0      ## m/s
	var state: int = 0          ## State.CRUISING
	var ring: int = 0           ## 0 = Anillo A (sim completa), 1 = Anillo B (sim simplificada)
	var yaw: float = 0.0        ## yaw actual (suavizado)
	var awareness: Dictionary = {}   ## en T-1 vacío; player_distance/player_in_front llegan en T-4
	var next_edge: int = -1     ## arista planificada al llegar al vértice lejano (lookahead de 1)
	var next_dir: int = 0
	var prev_edge: int = -1     ## arista anterior (para redondear la esquina del nodo de entrada)
	var prev_dir: int = 0
	var body: AnimatableBody3D = null
	# --- T-3: cruce de intersección ---
	var cross_node: int = -1    ## nodo-intersección con el que el agente está comprometido (-1 = ninguno)
	var cross_cap: float = INF  ## tope de velocidad impuesto por el cruce (INF = sin tope); lo fija _service_intersections
	var edge_enter_time: float = 0.0  ## tiempo de sim al entrar a la arista actual (para el replan a 45 s)
	var stopped_time: float = 0.0     ## tiempo acumulado detenido (para el despawn de atascado a 60 s)


var _graph: TrafficGraph
var _player: Node3D
var _car_scene: PackedScene = preload("res://scenes/traffic_car.tscn")

# Pool fijo: MAX_AGENTS cuerpos creados al inicio; nunca se instancian/liberan en gameplay.
# Cada índice i tiene un Agent persistente (_agents[i]) atado a un cuerpo (_pool[i]).
# Array sin tipar porque GDScript no admite Array[InnerClass].
var _agents: Array = []               ## Array[Agent], tamaño MAX_AGENTS
var _pool: Array = []                 ## Array[AnimatableBody3D], paralelo a _agents
var _free: Array[int] = []            ## ids inactivos disponibles

# Listas por (arista, sentido) ordenadas por s ascendente; mantenidas incrementalmente
# (solo al spawnear/despawnear/cambiar de arista, nunca reordenando todo por frame).
# Clave = edge * 2 + (0 si dir==1, 1 si dir==-1).
var _edge_lists: Dictionary = {}

var _spawn_accum := 0.0
var _classify_accum := 0.0
var _report_accum := 0.0
var _hot_accum := 0.0                  ## acumulador del reporte por-intersección "caliente" (T-3)
var _phys_parity := 0                 ## paridad de frame de física (tick del Anillo B: 1 de cada 2)
var _target_pop := 0
var _spawn_candidates: PackedInt32Array = PackedInt32Array()
var _spawns := 0
var _despawns := 0
var _sim_time := 0.0                  ## reloj de simulación (fases de semáforo y timeouts)

# Un IntersectionController por nodo-intersección (T-3). Clave = node_index del grafo.
var _controllers: Dictionary = {}


## El grafo y el jugador se inyectan ANTES de add_child (map_loader.gd).
func setup(graph: TrafficGraph, player: Node3D) -> void:
	_graph = graph
	_player = player


func _ready() -> void:
	if _graph == null or _graph.edge_from.is_empty():
		push_error("TrafficManager: grafo no asignado o sin aristas (setup() antes de add_child).")
		return
	_build_pool()
	_build_controllers()
	# Sembrar en deferred: así la Camera3D del jugador ya está en el árbol y su frustum
	# es válido (en main.tscn la cámara entra después de este nodo).
	call_deferred("_deferred_seed")


func _deferred_seed() -> void:
	_recompute_spawn_context()
	_seed_initial_population()
	print("[TrafficManager] pool=%d  poblacion inicial=%d/%d  (aristas en r_B contadas)" % [
		_pool.size(), _active_count(), _target_pop])


# ---------------------------------------------------------------------------
# Pool de cuerpos (creado una sola vez; color fijo por índice de pool)
# ---------------------------------------------------------------------------
func _build_pool() -> void:
	for i in range(MAX_AGENTS):
		var body := _car_scene.instantiate() as AnimatableBody3D
		(body.get_node("Body") as MeshInstance3D).mesh = _build_car_mesh(_color_for(i))
		body.visible = false
		add_child(body)
		_pool.append(body)
		var agent := Agent.new()
		agent.id = i
		agent.body = body
		_agents.append(agent)
		_free.append(i)


func _color_for(i: int) -> Color:
	return CAR_PALETTE[hash(i) % CAR_PALETTE.size()]


func _active_count() -> int:
	return MAX_AGENTS - _free.size()


# ---------------------------------------------------------------------------
# Controladores de intersección (T-3): uno por nodo con grado >= 3.
# La clasificación (tipo) ya la fijó T-0 en _graph.node_controller.
# ---------------------------------------------------------------------------
func _build_controllers() -> void:
	for n in _graph.intersections:
		var kind: int = _controller_kind(int(_graph.node_controller.get(n, TrafficGraph.Controller.PRIORITY_PURE)))
		var incident: Array = _graph.node_edges[n]
		var max_w := 0.0
		for e in incident:
			max_w = maxf(max_w, _graph.edge_width[e])
		var radius: float = maxf(1.5, INT_RADIUS_FACTOR * max_w)
		var ctrl := IntersectionController.new(n, kind, _graph.node_pos[n], radius)
		if kind == IntersectionController.Kind.SIGNAL:
			_assign_axes(ctrl, n, incident)
		_controllers[n] = ctrl


## Traduce el enum de TrafficGraph.Controller al enum de IntersectionController.Kind.
func _controller_kind(graph_ctrl: int) -> int:
	match graph_ctrl:
		TrafficGraph.Controller.SIGNAL:
			return IntersectionController.Kind.SIGNAL
		TrafficGraph.Controller.PRIORITY_STOP:
			return IntersectionController.Kind.PRIORITY_STOP
		_:
			return IntersectionController.Kind.PRIORITY_PURE


## Reparte las aristas incidentes en 2 ejes por orientación (clustering angular < 45°):
## eje 0 = aristas cuya línea (no dirigida) queda dentro de 45° de la primera; eje 1 = resto.
func _assign_axes(ctrl: IntersectionController, n: int, incident: Array) -> void:
	if incident.is_empty():
		return
	var npos := _graph.node_pos[n]
	var ref := _outward_unit(incident[0], n, npos)
	for e in incident:
		var u := _outward_unit(e, n, npos)
		# Líneas no dirigidas: mismo eje si el coseno absoluto supera cos(45°).
		var same := absf(u.dot(ref)) >= IntersectionController.AXIS_DOT_THRESHOLD
		ctrl.axis_of_edge[e] = 0 if same else 1


## Dirección unitaria de la arista `e` saliendo del nodo `n`.
func _outward_unit(e: int, n: int, npos: Vector2) -> Vector2:
	var other := _graph.edge_to[e] if _graph.edge_from[e] == n else _graph.edge_from[e]
	var v := _graph.node_pos[other] - npos
	return v.normalized() if v.length() > 0.0001 else Vector2.RIGHT


## Rango de prioridad de vía de la arista `e` (mayor gana el paso).
func _rank_for(e: int) -> int:
	return int(IntersectionController.RANK.get(_graph.edge_highway[e], IntersectionController.RANK_DEFAULT))


# ---------------------------------------------------------------------------
# Activación / despawn de agentes del pool
# ---------------------------------------------------------------------------
func _activate_agent(edge: int, dir: int, s0: float) -> void:
	if _free.is_empty():
		return
	var id: int = _free.pop_back()
	var a: Agent = _agents[id]
	a.active = true
	a.edge = edge
	a.dir = dir
	a.s = s0
	a.speed = 0.0
	a.state = State.CRUISING
	a.ring = 0
	a.prev_edge = -1
	a.prev_dir = 0
	a.cross_node = -1
	a.cross_cap = INF
	a.edge_enter_time = _sim_time
	a.stopped_time = 0.0
	_plan_next(a)
	var d := _edge_dir(edge, dir)
	a.yaw = atan2(d.x, d.y)
	a.body.visible = true
	_list_insert(id)
	_apply_pose(a, 1.0)   # pose inmediata (yaw ya en destino)
	_spawns += 1


func _despawn_agent(id: int) -> void:
	var a: Agent = _agents[id]
	# Liberar cualquier reserva/espera pendiente en su intersección.
	if a.cross_node >= 0 and _controllers.has(a.cross_node):
		(_controllers[a.cross_node] as IntersectionController).cancel(id)
	a.cross_node = -1
	_list_remove(id, a.edge, a.dir)
	a.active = false
	a.body.visible = false
	_free.append(id)
	_despawns += 1


# ---------------------------------------------------------------------------
# Listas por (arista, sentido) ordenadas por s (mantención incremental)
# ---------------------------------------------------------------------------
func _edge_key(edge: int, dir: int) -> int:
	return edge * 2 + (0 if dir == 1 else 1)


func _list_insert(id: int) -> void:
	var a: Agent = _agents[id]
	var key := _edge_key(a.edge, a.dir)
	if not _edge_lists.has(key):
		_edge_lists[key] = []
	var lst: Array = _edge_lists[key]
	var idx := lst.size()
	for i in range(lst.size()):
		if _agents[lst[i]].s > a.s:
			idx = i
			break
	lst.insert(idx, id)


func _list_remove(id: int, edge: int, dir: int) -> void:
	var key := _edge_key(edge, dir)
	if _edge_lists.has(key):
		(_edge_lists[key] as Array).erase(id)


# ---------------------------------------------------------------------------
# Contexto de spawn: población objetivo por densidad y aristas candidatas en r_B
# ---------------------------------------------------------------------------
func _recompute_spawn_context() -> void:
	var ppos := _player_pos()
	var meters := 0.0
	_spawn_candidates = PackedInt32Array()
	for e in range(_graph.edge_from.size()):
		var a := _graph.node_pos[_graph.edge_from[e]]
		var b := _graph.node_pos[_graph.edge_to[e]]
		var mid := (a + b) * 0.5
		var dm := ppos.distance_to(mid)
		if dm <= RING_B_RADIUS:
			meters += _graph.edge_length[e]
			# Candidata si algún punto suyo puede caer en la banda de spawn.
			if dm >= SPAWN_MIN_DIST - _graph.edge_length[e]:
				_spawn_candidates.append(e)
	_target_pop = mini(MAX_AGENTS, int(meters / DENSITY_DIVISOR))


func _seed_initial_population() -> void:
	while _active_count() < _target_pop:
		var placed := false
		for _i in range(SPAWN_ATTEMPTS):
			if _try_spawn_once():
				placed = true
				break
		if not placed:
			break   # no se pudo colocar más con las reglas actuales


func _try_spawn_once() -> bool:
	if _free.is_empty() or _spawn_candidates.is_empty():
		return false
	var cam := get_viewport().get_camera_3d()
	var ppos := _player_pos()
	var e: int = _spawn_candidates[randi() % _spawn_candidates.size()]
	var dir := _random_allowed_dir(e)
	if dir == 0:
		return false
	var s0 := randf() * _graph.edge_length[e]
	var p2 := _lane_point(e, dir, s0)
	var dist := ppos.distance_to(p2)
	if dist < SPAWN_MIN_DIST or dist > RING_B_RADIUS:
		return false
	var world := Vector3(p2.x, 0.0, p2.y)
	# Fuera de frustum para el punto y para el punto + 2 m de altura (evita pop-in).
	if cam != null and (cam.is_position_in_frustum(world) or cam.is_position_in_frustum(world + Vector3(0, 2, 0))):
		return false
	if _agent_within(p2, MIN_SPAWN_SEP):
		return false
	_activate_agent(e, dir, s0)
	return true


func _random_allowed_dir(e: int) -> int:
	var ow: int = _graph.edge_oneway[e]
	if ow == 1:
		return 1
	if ow == -1:
		return -1
	return 1 if randf() < 0.5 else -1


func _lane_point(e: int, dir: int, s: float) -> Vector2:
	var d := _edge_dir(e, dir)
	var entry := _graph.node_pos[_graph.edge_from[e] if dir == 1 else _graph.edge_to[e]]
	return entry + d * s + _right(d) * _lane_offset(e)


func _agent_within(pos2: Vector2, r: float) -> bool:
	var r2 := r * r
	for a in _agents:
		if a.active and _agent_pos2(a).distance_squared_to(pos2) < r2:
			return true
	return false


## Posición planar del agente derivada de su estado (edge, dir, s), no del cuerpo:
## evita depender del readback de global_position (que sync_to_physics puede retrasar).
## Ignora el arco de esquina (desvío < CORNER_BLEND), irrelevante para distancia/separación.
func _agent_pos2(a: Agent) -> Vector2:
	return _lane_point(a.edge, a.dir, a.s)


func _player_pos() -> Vector2:
	if _player == null:
		return Vector2.ZERO
	var p := _player.global_position
	return Vector2(p.x, p.z)


# ---------------------------------------------------------------------------
# Anillos A/B + despawn por distancia (reclasificación ~2 veces/s)
# ---------------------------------------------------------------------------
func _classify_tick() -> void:
	var cam := get_viewport().get_camera_3d()
	var ppos := _player_pos()
	var despawn_r := RING_B_RADIUS + DESPAWN_HYSTERESIS
	for a in _agents:
		if not a.active:
			continue
		var pos2 := _agent_pos2(a)
		var dist := ppos.distance_to(pos2)
		a.ring = 0 if dist <= RING_A_RADIUS else 1
		# Despawn por distancia (histéresis) o válvula de atascado (60 s detenido), ambos
		# solo fuera de frustum. La de atasco exige además estar más allá de SPAWN_MIN_DIST.
		var far_out: bool = dist > despawn_r
		var stuck: bool = a.stopped_time > STUCK_DESPAWN_TIME and dist > SPAWN_MIN_DIST
		if far_out or stuck:
			var in_view := cam != null and cam.is_position_in_frustum(Vector3(pos2.x, 0.0, pos2.y))
			if not in_view:
				_despawn_agent(a.id)


func _spawn_tick() -> void:
	_recompute_spawn_context()
	if _active_count() >= _target_pop:
		return
	for _i in range(SPAWN_ATTEMPTS):
		if _try_spawn_once():
			return


func _print_report() -> void:
	var a_count := 0
	var b_count := 0
	for a in _agents:
		if a.active:
			if a.ring == 0:
				a_count += 1
			else:
				b_count += 1
	print("[TrafficManager] activos %d (A:%d B:%d) | spawns %d | despawns %d | pobl. objetivo %d" % [
		_active_count(), a_count, b_count, _spawns, _despawns, _target_pop])


## Diagnóstico opcional (T-3): concesiones/timeouts del último minuto en la intersección
## con más concesiones. Resetea contadores tras imprimir.
func _print_hot_intersection() -> void:
	var hot: IntersectionController = null
	for n in _controllers:
		var c: IntersectionController = _controllers[n]
		if hot == null or c.grants > hot.grants:
			hot = c
	if hot != null and hot.grants > 0:
		print("[Intersección %d] concesiones/min:%d  timeouts/min:%d" % [hot.node, hot.grants, hot.timeouts])
	for n in _controllers:
		var c2: IntersectionController = _controllers[n]
		c2.grants = 0
		c2.timeouts = 0


# ---------------------------------------------------------------------------
# Integración cinemática por frame de física
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_sim_time += delta
	_phys_parity = 1 - _phys_parity
	for agent in _agents:
		if not agent.active:
			continue
		if agent.ring == 1:
			# Anillo B: tick de simulación 1 de cada 2 frames, con delta doble (mismo ritmo real).
			if _phys_parity == 0:
				_update_agent(agent, delta * 2.0)
		else:
			_update_agent(agent, delta)

	_spawn_accum += delta
	if _spawn_accum >= SPAWN_INTERVAL:
		_spawn_accum = 0.0
		_spawn_tick()

	_classify_accum += delta
	if _classify_accum >= CLASSIFY_INTERVAL:
		_classify_accum = 0.0
		_classify_tick()

	_report_accum += delta
	if _report_accum >= 5.0:
		_report_accum = 0.0
		_print_report()

	_hot_accum += delta
	if _hot_accum >= 60.0:
		_hot_accum = 0.0
		_print_hot_intersection()


func _update_agent(agent: Agent, delta: float) -> void:
	var start_edge := agent.edge
	var start_dir := agent.dir

	# FSM de intersección (T-3): fija estados APPROACHING/WAITING/CROSSING y agent.cross_cap
	# ANTES de decidir velocidad, para que el tope del cruce entre en _decide_target_speed.
	_service_intersections(agent)

	var target := _decide_target_speed(agent)   # tope por base/curva/seguimiento/cruce; fija CRUISING/FOLLOWING
	# Frenado a fondo cuando el seguimiento pide detenerse (gap crítico); si no, confort.
	var brake := BRAKE_MAX if (agent.state == State.FOLLOWING and target < 0.5) else BRAKE_COMFORT
	if target > agent.speed:
		agent.speed = minf(target, agent.speed + ACCEL * delta)
	else:
		agent.speed = maxf(target, agent.speed - brake * delta)

	agent.s += agent.speed * delta

	# Cruzar de arista si se sobrepasa su longitud (while por si la arista es corta).
	var guard := 0
	while agent.s >= _graph.edge_length[agent.edge] and guard < 8:
		guard += 1
		var overflow := agent.s - _graph.edge_length[agent.edge]
		_advance_to_next_edge(agent)
		agent.s = overflow

	# Mantención incremental de listas: solo si cambió de (arista, sentido).
	if agent.edge != start_edge or agent.dir != start_dir:
		_list_remove(agent.id, start_edge, start_dir)
		_list_insert(agent.id)

	# Contador de atasco (válvula de despawn a 60 s).
	if agent.speed < STOP_SPEED_EPS:
		agent.stopped_time += delta
	else:
		agent.stopped_time = 0.0

	# Válvula anti-deadlock: si lleva demasiado trabado acercándose/esperando en un cruce,
	# re-sortear la salida (caminata aleatoria) para no insistir en una ruta bloqueada.
	if (agent.state == State.APPROACHING or agent.state == State.WAITING) \
			and _sim_time - agent.edge_enter_time > REPLAN_TIME:
		_plan_next(agent)
		agent.edge_enter_time = _sim_time

	_apply_pose(agent, delta)


func _advance_to_next_edge(agent: Agent) -> void:
	if agent.next_edge < 0:
		# Sin plan (no debería ocurrir): replanificar desde el vértice lejano actual.
		_plan_next(agent)
	agent.prev_edge = agent.edge
	agent.prev_dir = agent.dir
	agent.edge = agent.next_edge
	agent.dir = agent.next_dir
	agent.edge_enter_time = _sim_time
	_plan_next(agent)


# ---------------------------------------------------------------------------
# FSM de intersección (T-3): la ÚNICA función que fija los estados APPROACHING /
# WAITING / CROSSING y calcula el tope de velocidad del cruce (agent.cross_cap).
# CRUISING/FOLLOWING los sigue fijando _decide_target_speed cuando el agente NO está
# comprometido con un cruce. BLOCKED se reserva para T-4 (jugador).
# ---------------------------------------------------------------------------
func _service_intersections(agent: Agent) -> void:
	# --- Ya cruzando: liberar la reserva al salir del disco por la arista de salida. ---
	if agent.state == State.CROSSING and agent.cross_node >= 0:
		agent.cross_cap = INF
		var ctrl_c: IntersectionController = _controllers[agent.cross_node]
		var on_exit_edge := _entry_node(agent) == agent.cross_node   # ya pasó el nodo
		var dist_center := _agent_pos2(agent).distance_to(ctrl_c.center)
		if on_exit_edge and dist_center > ctrl_c.radius + 0.5:
			ctrl_c.release(agent.id)
			agent.cross_node = -1
			agent.state = State.CRUISING
		return

	var far := _far_node(agent)
	# --- Nodo de llegada con controlador: gestionar aproximación/espera/entrada. ---
	if _controllers.has(far):
		var ctrl: IntersectionController = _controllers[far]
		var len_e := _graph.edge_length[agent.edge]
		var r_eff := minf(ctrl.radius, len_e * INT_DISC_MAX_FRAC)
		var s_stop := maxf(0.0, len_e - r_eff)   # línea de detención: borde del disco
		var dist_line := s_stop - agent.s
		var d_stop := (agent.speed * agent.speed) / (2.0 * BRAKE_COMFORT)

		# Comprometerse con el cruce al entrar en distancia de frenado + margen.
		if agent.cross_node != far and dist_line <= d_stop + INT_APPROACH_MARGIN:
			agent.cross_node = far
			agent.state = State.APPROACHING
			ctrl.request(agent.id, _rank_for(agent.edge), agent.edge, _sim_time)

		if agent.cross_node == far:
			var granted := ctrl.can_enter(agent.id, _sim_time)
			if granted and dist_line <= INT_ENTER_DIST:
				# Elegido y pegado a la línea: ocupa el disco y cruza.
				ctrl.enter(agent.id, _sim_time)
				agent.state = State.CROSSING
				agent.cross_cap = INF
			elif granted:
				# Elegido pero aún lejos: reservado, rueda hasta la línea sin frenar por el cruce.
				agent.state = State.APPROACHING
				agent.cross_cap = INF
			else:
				# Sin permiso: frenar para detenerse en la línea.
				agent.cross_cap = sqrt(2.0 * BRAKE_COMFORT * maxf(0.0, dist_line))
				if dist_line <= INT_WAIT_EPS:
					agent.state = State.WAITING
					agent.cross_cap = 0.0
				else:
					agent.state = State.APPROACHING
			return

	# --- Sin cruce activo: soltar cualquier compromiso residual y volver a crucero. ---
	if agent.cross_node >= 0 and _controllers.has(agent.cross_node):
		(_controllers[agent.cross_node] as IntersectionController).cancel(agent.id)
	agent.cross_node = -1
	agent.cross_cap = INF
	if agent.state == State.APPROACHING or agent.state == State.WAITING or agent.state == State.CROSSING:
		agent.state = State.CRUISING


# ---------------------------------------------------------------------------
# COSTURA 1 — velocidad objetivo (todo el ajuste de velocidad pasa por aquí)
# ---------------------------------------------------------------------------
## Devuelve la velocidad objetivo combinando base de clase, curva, seguimiento y el tope
## del cruce (agent.cross_cap, ya fijado por _service_intersections). Fija CRUISING/FOLLOWING
## SOLO cuando el agente no está comprometido con un cruce (APPROACHING/WAITING/CROSSING los
## posee la FSM de intersección y no deben sobrescribirse aquí).
func _decide_target_speed(agent: Agent) -> float:
	var base: float = SPEED_BY_CLASS.get(_graph.edge_highway[agent.edge], SPEED_DEFAULT)
	# Velocidad máxima con la que se puede tomar la curva del próximo vértice.
	var corner_cap := _corner_speed_cap(agent, base)
	# Limitar por la distancia restante para poder frenar a corner_cap con BRAKE_COMFORT.
	var remaining := maxf(0.0, _graph.edge_length[agent.edge] - agent.s)
	var v_allow := sqrt(corner_cap * corner_cap + 2.0 * BRAKE_COMFORT * remaining)
	var target := minf(base, v_allow)
	# Tope del cruce (detenerse en la línea si no hay permiso; INF si no aplica).
	target = minf(target, agent.cross_cap)

	# ¿El agente está bajo control de la FSM de intersección? Si es así, no tocar su estado.
	var engaged := agent.state == State.APPROACHING or agent.state == State.WAITING \
			or agent.state == State.CROSSING

	# Seguimiento: no cerrar el gap con el líder (misma arista o la siguiente de la ruta).
	if not engaged:
		agent.state = State.CRUISING
	var lead := _leader_gap(agent)
	if lead["has"]:
		var gap: float = lead["gap"]
		if gap < GAP_BASE:
			if not engaged:
				agent.state = State.FOLLOWING
			return 0.0   # gap crítico -> frenado a fondo
		var desired := GAP_BASE + agent.speed * GAP_TIME
		var follow: float = lead["speed"] + (gap - desired) * FOLLOW_GAIN
		if follow < target:
			target = maxf(0.0, follow)
			if not engaged:
				agent.state = State.FOLLOWING
	return target


## Gap (parachoques) y velocidad del líder más cercano por delante. Mira primero la
## misma (arista, sentido); si no hay, la arista siguiente de la ruta (lookahead de 1).
func _leader_gap(agent: Agent) -> Dictionary:
	var lst: Array = _edge_lists.get(_edge_key(agent.edge, agent.dir), [])
	var best := -1
	var best_s := INF
	for oid in lst:
		if oid == agent.id:
			continue
		var os: float = _agents[oid].s
		if os >= agent.s and os < best_s:
			best_s = os
			best = oid
	if best >= 0:
		return {"has": true, "gap": (best_s - agent.s) - CAR_LENGTH, "speed": _agents[best].speed}

	if agent.next_edge >= 0:
		var lst2: Array = _edge_lists.get(_edge_key(agent.next_edge, agent.next_dir), [])
		var min_s := INF
		var lead2 := -1
		for oid in lst2:
			var os2: float = _agents[oid].s
			if os2 < min_s:
				min_s = os2
				lead2 = oid
		if lead2 >= 0:
			var gap := (_graph.edge_length[agent.edge] - agent.s) + min_s - CAR_LENGTH
			return {"has": true, "gap": gap, "speed": _agents[lead2].speed}

	return {"has": false}


func _corner_speed_cap(agent: Agent, base: float) -> float:
	if agent.next_edge < 0:
		return base
	var d_cur := _edge_dir(agent.edge, agent.dir)
	var d_next := _edge_dir(agent.next_edge, agent.next_dir)
	var theta := absf(rad_to_deg(d_cur.angle_to(d_next)))
	var t := clampf(theta / CORNER_FULL_ANGLE_DEG, 0.0, 1.0)
	return lerpf(base, CORNER_MIN_SPEED, t)


# ---------------------------------------------------------------------------
# COSTURA 2 — próxima arista (caminata aleatoria; sin destino, sin A*)
# ---------------------------------------------------------------------------
## Planifica, con lookahead de 1, la arista a tomar al llegar al vértice lejano
## de la arista actual. Se llama solo al entrar a una arista (no por frame).
func _plan_next(agent: Agent) -> void:
	var far := _far_node(agent)
	var choice := _decide_next_edge(agent, far)
	agent.next_edge = choice[0]
	agent.next_dir = choice[1]


## Devuelve [edge, dir]. En cada intersección, salida al azar excluyendo la de
## origen; media vuelta solo si no hay otra salida (terminal / calle ciega).
func _decide_next_edge(agent: Agent, node: int) -> Array:
	var incident: Array = _graph.node_edges[node]
	var arrival := agent.edge
	var candidates: Array = []
	for e in incident:
		if e == arrival:
			continue
		var dir := _leaving_dir(e, node)
		if dir != 0:
			candidates.append([e, dir])

	if candidates.is_empty():
		# Sin salida permitida: media vuelta sobre la arista de llegada.
		var back := _leaving_dir(arrival, node)
		if back != 0:
			return [arrival, back]
		return [arrival, -agent.dir]   # caso degenerado (one-way ciego): invertir igual

	return candidates[randi() % candidates.size()]


## Sentido en que hay que viajar para SALIR de `node` por la arista `e`,
## respetando oneway. 0 = no permitido (o e no incide en node).
func _leaving_dir(e: int, node: int) -> int:
	var ow: int = _graph.edge_oneway[e]
	if _graph.edge_from[e] == node:
		return 1 if (ow == 0 or ow == 1) else 0
	elif _graph.edge_to[e] == node:
		return -1 if (ow == 0 or ow == -1) else 0
	return 0


# ---------------------------------------------------------------------------
# Muestreo de pose sobre el grafo
# ---------------------------------------------------------------------------
func _apply_pose(agent: Agent, delta: float) -> void:
	var d := _edge_dir(agent.edge, agent.dir)
	var entry := _graph.node_pos[_entry_node(agent)]
	var len_e := _graph.edge_length[agent.edge]

	# Pose base: línea de carril recta (centro de la arista + offset a la derecha).
	var pos2 := entry + d * agent.s + _right(d) * _lane_offset(agent.edge)
	var head := d

	# --- Redondeo de esquinas: arco cerca del nodo de llegada o del de entrada. ---
	# Ambos lados calculan el MISMO Bézier (mismos args) => la pose es continua al cruzar.
	var handled := false
	if agent.next_edge >= 0:
		var blend := _corner_blend(agent.edge, agent.next_edge)
		var r := len_e - agent.s            # distancia al nodo de llegada
		if r < blend:
			var bez := _corner_bezier(agent.edge, agent.dir, agent.next_edge, agent.next_dir, _far_node(agent))
			if bez["ok"]:
				var t := 0.5 * (1.0 - r / blend)     # 0 en el borde del arco -> 0.5 en el nodo
				pos2 = _bezier_pos(bez, t)
				head = _bezier_dir(bez, t)
				handled = true
	if not handled and agent.prev_edge >= 0:
		var blend_in := _corner_blend(agent.prev_edge, agent.edge)
		if agent.s < blend_in:
			var bez2 := _corner_bezier(agent.prev_edge, agent.prev_dir, agent.edge, agent.dir, _entry_node(agent))
			if bez2["ok"]:
				var t2 := 0.5 + 0.5 * (agent.s / blend_in)   # 0.5 en el nodo -> 1 al salir del arco
				pos2 = _bezier_pos(bez2, t2)
				head = _bezier_dir(bez2, t2)

	var target_yaw := atan2(head.x, head.y)   # head.y es la componente Z del mundo
	agent.yaw = lerp_angle(agent.yaw, target_yaw, delta * YAW_SMOOTH)

	# AnimatableBody3D con sync_to_physics: se mueve fijando el transform completo en
	# _physics_process (no basta con global_position, que la sincronización descarta).
	var basis := Basis(Vector3.UP, agent.yaw)
	agent.body.global_transform = Transform3D(basis, Vector3(pos2.x, 0.0, pos2.y))


## Derecha del sentido de marcha `d`. Con +X=este y +Z=sur (proyección del pipeline),
## la derecha es Vector2(-d.y, d.x); DRIVING_SIDE la invierte si fuera LEFT.
func _right(d: Vector2) -> Vector2:
	var r := Vector2(-d.y, d.x)
	return r if DRIVING_SIDE_RIGHT else -r


## Longitud del arco a cada lado del nodo, acotada para no solapar arcos en aristas cortas.
func _corner_blend(edge_a: int, edge_b: int) -> float:
	return minf(CORNER_BLEND, minf(
		_graph.edge_length[edge_a] * CORNER_BLEND_FRAC,
		_graph.edge_length[edge_b] * CORNER_BLEND_FRAC))


## Puntos de control del Bézier cuadrático que redondea la esquina en `node` entre la
## arista de entrada y la de salida (tangente a ambas líneas de carril). ok=false si son
## casi rectas/paralelas (no hay esquina que redondear).
func _corner_bezier(edge_in: int, dir_in: int, edge_out: int, dir_out: int, node: int) -> Dictionary:
	var n := _graph.node_pos[node]
	var d_in := _edge_dir(edge_in, dir_in)
	var d_out := _edge_dir(edge_out, dir_out)
	var a_in := n + _right(d_in) * _lane_offset(edge_in)     # punto de la línea de carril entrante en el nodo
	var a_out := n + _right(d_out) * _lane_offset(edge_out)  # punto de la línea de carril saliente en el nodo
	var blend := _corner_blend(edge_in, edge_out)

	var c = _line_intersection(a_in, d_in, a_out, d_out)   # Variant: Vector2 o null
	if c == null:
		return {"ok": false}
	return {
		"ok": true,
		"p0": a_in - d_in * blend,   # entra tangente a la línea entrante
		"c": c,                       # vértice de la esquina (intersección de ambas líneas)
		"p1": a_out + d_out * blend, # sale tangente a la línea saliente
	}


func _bezier_pos(bez: Dictionary, t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * bez["p0"] + 2.0 * u * t * bez["c"] + t * t * bez["p1"]


func _bezier_dir(bez: Dictionary, t: float) -> Vector2:
	var v: Vector2 = 2.0 * (1.0 - t) * (bez["c"] - bez["p0"]) + 2.0 * t * (bez["p1"] - bez["c"])
	return v.normalized() if v.length() > 0.0001 else Vector2.RIGHT


## Intersección de dos rectas (punto + dirección). null si son (casi) paralelas.
func _line_intersection(p1: Vector2, d1: Vector2, p2: Vector2, d2: Vector2):
	var denom := d1.x * d2.y - d1.y * d2.x
	if absf(denom) < CORNER_PARALLEL_EPS:
		return null
	var diff := p2 - p1
	var s := (diff.x * d2.y - diff.y * d2.x) / denom
	return p1 + d1 * s


func _lane_offset(e: int) -> float:
	return clampf(_graph.edge_width[e] * LANE_OFFSET_FACTOR, LANE_OFFSET_MIN, LANE_OFFSET_MAX)


func _edge_dir(edge: int, dir: int) -> Vector2:
	var a := _graph.node_pos[_graph.edge_from[edge]]
	var b := _graph.node_pos[_graph.edge_to[edge]]
	var v := (b - a) if dir == 1 else (a - b)
	return v.normalized() if v.length() > 0.0001 else Vector2.RIGHT


func _entry_node(agent: Agent) -> int:
	return _graph.edge_from[agent.edge] if agent.dir == 1 else _graph.edge_to[agent.edge]


func _far_node(agent: Agent) -> int:
	return _graph.edge_to[agent.edge] if agent.dir == 1 else _graph.edge_from[agent.edge]


# ---------------------------------------------------------------------------
# Malla del auto (estilo autos estacionados de V-3): carrocería 1.7x1.3x4.0 con
# color por vertex color + 4 ruedas con UV.x=1 (el shader toon_car las oscurece).
# ---------------------------------------------------------------------------
func _build_car_mesh(color: Color) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var body := BoxMesh.new()
	body.size = Vector3(1.7, 1.3, 4.0)
	var vcount := _append_prim(st, body, color, Vector2(0, 0), Vector3(0, 0.9, 0), 0)

	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.33
	wheel.bottom_radius = 0.33
	wheel.height = 0.25
	wheel.radial_segments = 6

	var offsets := [
		Vector3(-0.75, 0.33, -1.35), Vector3(0.75, 0.33, -1.35),
		Vector3(-0.75, 0.33,  1.35), Vector3(0.75, 0.33,  1.35),
	]
	var w_arr: Array = wheel.surface_get_arrays(0)
	var wv: PackedVector3Array = w_arr[Mesh.ARRAY_VERTEX]
	var wn: PackedVector3Array = w_arr[Mesh.ARRAY_NORMAL]
	var wi: PackedInt32Array = w_arr[Mesh.ARRAY_INDEX]

	for wo in offsets:
		var base := vcount
		for i in range(wv.size()):
			st.set_normal(wn[i] if i < wn.size() else Vector3.UP)
			st.set_color(color)
			st.set_uv(Vector2(1, 0))   # UV.x=1 -> rueda oscura en toon_car.gdshader
			var v: Vector3 = wv[i]
			# Cilindro tumbado (eje de giro sobre X): se intercambian X<->Y como en prop_scatter.
			st.add_vertex(Vector3(v.y + wo.x, v.x + wo.y, v.z + wo.z))
		for j in range(wi.size()):
			st.add_index(base + wi[j])
		vcount += wv.size()

	st.generate_normals()
	return st.commit()


func _append_prim(st: SurfaceTool, prim: PrimitiveMesh, color: Color, uv: Vector2, offset: Vector3, base_vertex: int) -> int:
	var arr: Array = prim.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr.size() > Mesh.ARRAY_NORMAL else PackedVector3Array()
	var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr.size() > Mesh.ARRAY_INDEX else PackedInt32Array()
	for i in range(verts.size()):
		st.set_normal(normals[i] if i < normals.size() else Vector3.UP)
		st.set_color(color)
		st.set_uv(uv)
		st.add_vertex(verts[i] + offset)
	for j in range(indices.size()):
		st.add_index(base_vertex + indices[j])
	return verts.size()
