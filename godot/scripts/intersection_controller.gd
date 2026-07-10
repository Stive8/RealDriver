class_name IntersectionController
extends RefCounted
## Controlador de una intersección (Fase T-3). La CLASIFICACIÓN (qué tipo es cada
## intersección) ya la resolvió T-0 en `TrafficGraph.node_controller`; aquí vive solo
## la LÓGICA DE PASO en tiempo de ejecución.
##
## Modelo de reserva único para los tres tipos: el interior de la intersección es un
## disco de radio `0.75 × max(width incidentes)` y admite UN vehículo a la vez
## (constante del sistema). Un agente que se acerca se registra con `request`; el
## controlador concede el paso a lo sumo a un agente (`can_enter`), que ocupa el disco
## con `enter` y lo libera con `release` al salir. Tres variantes:
##
##   PRIORITY_PURE : concede al de mayor rango de vía; empate -> ticket FIFO.
##   PRIORITY_STOP : intersección con stop/give_way vinculado. Ver DECISION_PENDIENTE.
##   SIGNAL        : 2 fases por eje (clustering angular < 45°), verde 8 s + ámbar 2 s.
##                   Solo el eje en verde puede iniciar cruce; en ámbar el disco se vacía.
##
## Anti-atasco: si el ocupante no libera en RESERVATION_TIMEOUT s, se libera la reserva
## (una de las tres válvulas; las otras dos —replan 45 s y despawn 60 s— viven en el manager).

enum Kind { PRIORITY_PURE, PRIORITY_STOP, SIGNAL }

## Ranking de prioridad por clase de vía (mayor cede el paso al menor... al revés:
## el de MENOR rango cede al de MAYOR). [ESTRUCTURAL]
const RANK := {
	"motorway": 7, "trunk": 7,
	"primary": 6, "secondary": 5, "tertiary": 4,
	"residential": 3, "unclassified": 3,
	"living_street": 2, "service": 1,
}
const RANK_DEFAULT := 3               ## Clase desconocida -> se trata como residencial.

## Semáforo: verde 8 s + ámbar 2 s por eje; el ciclo alterna eje 0 y eje 1. [ESTRUCTURAL]
const GREEN_TIME := 8.0
const AMBER_TIME := 2.0

## Válvula anti-atasco: libera la reserva si el ocupante no salió en este tiempo. [ESTRUCTURAL]
const RESERVATION_TIMEOUT := 6.0

## Umbral de eje para el clustering angular de fases (líneas dentro de 45° = mismo eje).
const AXIS_DOT_THRESHOLD := 0.70710678   ## cos(45°)

var node: int = -1
var kind: int = Kind.PRIORITY_PURE
var center: Vector2 = Vector2.ZERO
var radius: float = 4.0                ## radio del disco interior

## Solo SIGNAL: arista incidente -> eje (0 o 1).
var axis_of_edge: Dictionary = {}
var _cycle: float = 2.0 * (GREEN_TIME + AMBER_TIME)

# --- Estado en tiempo de ejecución ---
var _occupant: int = -1                ## id del agente dentro del disco (-1 = libre)
var _occupant_since: float = 0.0
## agentes esperando: id -> { "rank": int, "ticket": int, "axis": int }
var _waiting: Dictionary = {}
var _ticket_seq: int = 0

# --- Diagnóstico (concesiones/timeouts, leído por el manager para la intersección "caliente") ---
var grants: int = 0
var timeouts: int = 0


func _init(p_node: int, p_kind: int, p_center: Vector2, p_radius: float) -> void:
	node = p_node
	kind = p_kind
	center = p_center
	radius = p_radius


## Registra (idempotente) a un agente como aspirante a cruzar. `rank` deriva de la clase
## de la arista por la que llega; `edge` fija su eje si es semáforo.
func request(agent_id: int, rank: int, edge: int, _now: float) -> void:
	if _waiting.has(agent_id):
		return
	_waiting[agent_id] = {
		"rank": rank,
		"ticket": _ticket_seq,
		"axis": int(axis_of_edge.get(edge, 0)),
	}
	_ticket_seq += 1


## ¿Puede este agente iniciar el cruce AHORA? Solo el elegido, y solo con el disco libre.
func can_enter(agent_id: int, now: float) -> bool:
	_check_timeout(now)
	if _occupant != -1 and _occupant != agent_id:
		return false
	if not _waiting.has(agent_id):
		return false
	return _choose(now) == agent_id


## El agente ocupa el disco (sale de la cola de espera).
func enter(agent_id: int, now: float) -> void:
	_occupant = agent_id
	_occupant_since = now
	_waiting.erase(agent_id)
	grants += 1


## El agente sale del disco y libera la reserva.
func release(agent_id: int) -> void:
	if _occupant == agent_id:
		_occupant = -1


## Retira a un agente (replan / despawn / pérdida de contacto).
func cancel(agent_id: int) -> void:
	_waiting.erase(agent_id)
	if _occupant == agent_id:
		_occupant = -1


# ---------------------------------------------------------------------------
# Interno
# ---------------------------------------------------------------------------
func _check_timeout(now: float) -> void:
	if _occupant != -1 and now - _occupant_since > RESERVATION_TIMEOUT:
		_occupant = -1
		timeouts += 1


## Devuelve el id del agente al que le toca entrar (o -1). Disco libre garantizado por caller.
func _choose(now: float) -> int:
	if _occupant != -1 or _waiting.is_empty():
		return -1

	if kind == Kind.SIGNAL:
		var green := _green_axis(now)
		if green == -1:
			return -1   # ámbar: nadie inicia, el disco se vacía
		# FIFO entre los que esperan en el eje verde.
		var best := -1
		var best_ticket := 0x7FFFFFFF
		for id in _waiting:
			var w: Dictionary = _waiting[id]
			if int(w["axis"]) == green and int(w["ticket"]) < best_ticket:
				best_ticket = int(w["ticket"])
				best = id
		return best

	# PRIORITY_PURE / PRIORITY_STOP: mayor rango; empate -> ticket FIFO.
	# DECISION_PENDIENTE: T-0 vincula stop/give_way al NODO, no al acceso concreto, así que
	# no se puede saber qué agente llega por el acceso que "cede siempre". PRIORITY_STOP usa
	# por ahora la misma lógica rango/FIFO que PRIORITY_PURE. Jordán no tiene stop/give_way
	# (0 en T-0), por lo que esta rama no se ejercita; recalibrar cuando una ciudad los tenga.
	var pbest := -1
	var pbest_rank := -1
	var pbest_ticket := 0x7FFFFFFF
	for id in _waiting:
		var w2: Dictionary = _waiting[id]
		var r := int(w2["rank"])
		var tk := int(w2["ticket"])
		if r > pbest_rank or (r == pbest_rank and tk < pbest_ticket):
			pbest_rank = r
			pbest_ticket = tk
			pbest = id
	return pbest


## Eje en verde según el reloj de simulación (fase pura del tiempo, sin estado por frame).
## Layout del ciclo: [0,G) eje0 verde · [G,G+A) eje0 ámbar · [G+A,2G+A) eje1 verde · resto ámbar.
## -1 = ámbar (ningún eje inicia cruce).
func _green_axis(now: float) -> int:
	var t := fmod(now, _cycle)
	if t < GREEN_TIME:
		return 0
	if t < GREEN_TIME + AMBER_TIME:
		return -1
	if t < 2.0 * GREEN_TIME + AMBER_TIME:
		return 1
	return -1
