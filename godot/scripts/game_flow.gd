extends Node
## FSM del flujo de juego (Fase M-1): MENU -> RUNNING -> (PAUSED <-> RUNNING) -> RESULTS -> MENU,
## con PAUSED -> MENU (Abandonar). El árbol nunca se pausa: "pausa" = vehicle.input_enabled = false
## + mode.set_paused(true); el tráfico sigue vivo.

enum State { MENU, RUNNING, PAUSED, RESULTS }

const STATE_NAMES := ["MENU", "RUNNING", "PAUSED", "RESULTS"]

# Registro de modos disponibles. Añadir un modo futuro = nueva carpeta + una línea aquí.
# DECISION_PENDIENTE: el ESPEC pide `[FreeDriveMode]` (identificador directo de la clase),
# pero GDScript 4.4 no lo admite como expresión constante ("Assigned value for constant
# 'MODES' isn't a constant expression", verificado con --check-only). preload() del mismo
# script sí es constante y produce el mismo GDScript/class_name; se usa preload().
const MODES: Array[GDScript] = [preload("res://scripts/modes/free_drive_mode.gd")]

@export var vehicle_path: NodePath
@export var map_path: NodePath
@export var game_ui_path: NodePath
@export var mode_hud_path: NodePath
@export var minimap_path: NodePath  # opcional; vacío hasta M-4 (o si está deshabilitado)

@onready var _vehicle: VehicleBody3D = get_node(vehicle_path) as VehicleBody3D
@onready var _map: Node3D = get_node(map_path) as Node3D
@onready var _game_ui: GameUI = get_node(game_ui_path) as GameUI
@onready var _mode_hud: CanvasLayer = get_node(mode_hud_path) as CanvasLayer

var _state: int = -1  # -1 = aún no ha entrado a ningún estado (solo para el primer print)
var _mode: GameMode = null
var _minimap: Node = null


func _ready() -> void:
	if minimap_path != NodePath(""):
		_minimap = get_node(minimap_path)

	_game_ui.mode_selected.connect(_on_mode_selected)
	_game_ui.resume_requested.connect(_on_resume_requested)
	_game_ui.abort_requested.connect(_on_abort_requested)
	_game_ui.retry_requested.connect(_on_retry_requested)
	_game_ui.menu_requested.connect(_on_menu_requested)

	_enter_menu()


func _unhandled_input(event: InputEvent) -> void:
	if _state == State.RUNNING and event.is_action_pressed("ui_pause"):
		_enter_paused()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# MENU
# ---------------------------------------------------------------------------
func _enter_menu() -> void:
	_set_state(State.MENU)
	_vehicle.input_enabled = false
	var names: Array = []
	for mode_script in MODES:
		names.append(_mode_display_name(mode_script))
	_game_ui.show_menu(names)


func _mode_display_name(mode_script: GDScript) -> String:
	var probe: GameMode = mode_script.new()
	var display_name := probe.get_display_name()
	probe.free()
	return display_name


func _on_mode_selected(index: int) -> void:
	if _state != State.MENU:
		return
	_spawn_and_start_mode(index)


func _spawn_and_start_mode(index: int) -> void:
	var mode_script: GDScript = MODES[index]
	_mode = mode_script.new() as GameMode
	add_child(_mode)
	_mode.finished.connect(_on_mode_finished)
	_mode.aborted.connect(_on_mode_aborted)

	var ctx := ModeContext.new()
	ctx.vehicle = _vehicle
	ctx.graph = _map.graph
	ctx.map_meta = _map.map_meta
	ctx.hud_layer = _mode_hud
	ctx.minimap = _minimap
	_mode.configure(ctx)

	_set_state(State.RUNNING, _mode.get_mode_id())
	_game_ui.hide_all()
	_vehicle.input_enabled = true
	_mode.start_mode()


# ---------------------------------------------------------------------------
# PAUSED
# ---------------------------------------------------------------------------
func _enter_paused() -> void:
	_set_state(State.PAUSED, _mode.get_mode_id())
	_vehicle.input_enabled = false
	_mode.set_paused(true)
	_game_ui.show_pause()


func _on_resume_requested() -> void:
	if _state != State.PAUSED:
		return
	_set_state(State.RUNNING, _mode.get_mode_id())
	_game_ui.hide_all()
	_vehicle.input_enabled = true
	_mode.set_paused(false)


func _on_abort_requested() -> void:
	if _state != State.PAUSED:
		return
	_stop_and_free_mode()
	_enter_menu()


# ---------------------------------------------------------------------------
# RESULTS
# ---------------------------------------------------------------------------
func _on_mode_finished(result: Dictionary) -> void:
	_set_state(State.RESULTS, _mode.get_mode_id())
	_vehicle.input_enabled = false
	_game_ui.show_results(result)


func _on_retry_requested() -> void:
	if _state != State.RESULTS:
		return
	_set_state(State.RUNNING, _mode.get_mode_id())
	_game_ui.hide_all()
	_vehicle.input_enabled = true
	_mode.start_mode()


func _on_menu_requested() -> void:
	if _state != State.RESULTS:
		return
	_stop_and_free_mode()
	_enter_menu()


# ---------------------------------------------------------------------------
# Común
# ---------------------------------------------------------------------------
func _on_mode_aborted() -> void:
	_stop_and_free_mode()
	_enter_menu()


func _stop_and_free_mode() -> void:
	if _mode == null:
		return
	_mode.stop_mode()
	_mode.queue_free()
	_mode = null


func _set_state(new_state: int, mode_id: String = "") -> void:
	var suffix := " (%s)" % mode_id if mode_id != "" else ""
	var from_name: String = "INIT" if _state < 0 else STATE_NAMES[_state]
	print("[flow] %s -> %s%s" % [from_name, STATE_NAMES[new_state], suffix])
	_state = new_state
