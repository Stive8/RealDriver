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
const MODES: Array[GDScript] = [
	preload("res://scripts/modes/free_drive_mode.gd"),
	preload("res://scripts/modes/time_trial/time_trial_mode.gd"),
]

@export var vehicle_path: NodePath
@export var map_path: NodePath
@export var game_ui_path: NodePath
@export var mode_hud_path: NodePath
@export var minimap_path: NodePath  # opcional; vacío hasta M-4 (o si está deshabilitado)
@export var loading_screen_path: NodePath

@onready var _vehicle: VehicleBody3D = get_node(vehicle_path) as VehicleBody3D
@onready var _map: Node3D = get_node(map_path) as Node3D
@onready var _game_ui: GameUI = get_node(game_ui_path) as GameUI
@onready var _mode_hud: CanvasLayer = get_node(mode_hud_path) as CanvasLayer

var _state: int = -1  # -1 = aún no ha entrado a ningún estado (solo para el primer print)
var _mode: GameMode = null
var _minimap: Minimap = null

var _city_client: CityClient
var _loading_screen: LoadingScreen
var _pending_city_name: String = ""


func _ready() -> void:
	if minimap_path != NodePath(""):
		_minimap = get_node(minimap_path) as Minimap

	_game_ui.mode_selected.connect(_on_mode_selected)
	_game_ui.resume_requested.connect(_on_resume_requested)
	_game_ui.abort_requested.connect(_on_abort_requested)
	_game_ui.retry_requested.connect(_on_retry_requested)
	_game_ui.menu_requested.connect(_on_menu_requested)

	_loading_screen = get_node(loading_screen_path) as LoadingScreen

	_city_client = CityClient.new()
	add_child(_city_client)
	_city_client.geocode_results.connect(_on_geocode_results)
	_city_client.zone_requested.connect(_on_zone_requested)
	_city_client.zone_progress.connect(_on_zone_progress)
	_city_client.zone_ready.connect(_on_zone_ready)
	_city_client.zone_failed.connect(_on_zone_failed)
	_city_client.zone_quota_exceeded.connect(_on_zone_quota_exceeded)
	_city_client.download_progress.connect(_on_download_progress)
	_city_client.download_complete.connect(_on_download_complete)
	_city_client.catalog_received.connect(_on_catalog_received)
	_city_client.offline.connect(_on_city_client_offline)

	_game_ui.city_panel_opened.connect(_on_city_panel_opened)
	_game_ui.city_search_requested.connect(_on_city_search_requested)
	_game_ui.city_new_requested.connect(_on_city_new_requested)
	_game_ui.city_local_selected.connect(_on_city_local_selected)

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
	if _minimap != null:
		_minimap.set_active_mode(_mode)

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
	if _minimap != null:
		_minimap.set_active_mode(null)
	_mode.stop_mode()
	_mode.queue_free()
	_mode = null


# ---------------------------------------------------------------------------
# Ciudades (Fase C-3)
# ---------------------------------------------------------------------------
func _on_city_panel_opened() -> void:
	_refresh_local_library()
	_city_client.fetch_catalog()


func _refresh_local_library() -> void:
	_game_ui.show_local_library(CityLibrary.list_local(), CityLibrary.get_selected_zone())


func _on_city_search_requested(query: String) -> void:
	_city_client.geocode(query)


func _on_geocode_results(results: Array) -> void:
	_game_ui.show_geocode_results(results)


func _on_catalog_received(catalog: Array) -> void:
	_game_ui.show_catalog(catalog)


func _on_city_new_requested(lat: float, lon: float, size: String, name: String) -> void:
	_pending_city_name = name
	_city_client.request_zone(lat, lon, size, name)


func _on_zone_requested(zone_id: String, status: String, queue_position: int) -> void:
	if status == "ready":
		_game_ui.show_request_status("%s ya estaba lista, descargando..." % _pending_city_name)
		_city_client.download_zone(zone_id)
		return
	_city_client.poll_zone(zone_id)
	_game_ui.show_request_status("%s encolada (posicion %d)" % [_pending_city_name, queue_position])
	_game_ui.show_baking_list([{"zone_id": zone_id, "name": _pending_city_name, "queue_position": queue_position}])


func _on_zone_progress(zone_id: String, stage: String) -> void:
	_game_ui.show_request_status("%s: generando (%s)" % [_pending_city_name, stage])
	_game_ui.show_baking_list([{"zone_id": zone_id, "name": _pending_city_name, "stage": stage}])


func _on_zone_ready(zone_id: String, meta_summary: Dictionary) -> void:
	_pending_city_name = str(meta_summary.get("name", _pending_city_name))
	_loading_screen.show_downloading(_pending_city_name, meta_summary.get("stats", {}).get("flags", []))
	_city_client.download_zone(zone_id)


func _on_zone_failed(_zone_id: String, reason: String) -> void:
	print("[ciudades] generacion fallida: %s" % reason)
	_game_ui.show_request_status("Generacion fallida: %s" % reason)
	_refresh_local_library()


func _on_zone_quota_exceeded(resets_at: String) -> void:
	print("[ciudades] cuota agotada, reinicia %s" % resets_at)
	_game_ui.show_request_status("Cuota diaria agotada. Intenta de nuevo despues de %s" % resets_at)


func _on_download_progress(_zone_id: String, downloaded: int, total: int) -> void:
	if total > 0:
		_loading_screen.set_progress(float(downloaded) / float(total))


func _on_download_complete(zone_id: String) -> void:
	_loading_screen.show_building()
	CityLibrary.set_selected(zone_id)
	call_deferred("_reload_into_new_city")


func _reload_into_new_city() -> void:
	get_tree().reload_current_scene()


func _on_city_local_selected(zone_id: String) -> void:
	_loading_screen.show_downloading(zone_id, [])
	_loading_screen.show_building()
	CityLibrary.set_selected(zone_id)
	call_deferred("_reload_into_new_city")


func _on_city_client_offline() -> void:
	_game_ui.set_offline(true)


func _set_state(new_state: int, mode_id: String = "") -> void:
	var suffix := " (%s)" % mode_id if mode_id != "" else ""
	var from_name: String = "INIT" if _state < 0 else STATE_NAMES[_state]
	print("[flow] %s -> %s%s" % [from_name, STATE_NAMES[new_state], suffix])
	_state = new_state
