class_name GameUI
extends CanvasLayer
## HUD de flujo (Fase M-1): tres paneles placeholder mutuamente excluyentes
## (menú, pausa, resultados) pilotados por GameFlow. Todo tema por defecto.

signal mode_selected(index: int)
signal resume_requested
signal abort_requested
signal retry_requested
signal menu_requested
signal city_panel_opened
signal city_panel_closed
signal city_search_requested(query: String)
signal city_new_requested(lat: float, lon: float, size: String, name: String)
signal city_local_selected(zone_id: String)
signal city_catalog_download_requested(zone_id: String, name: String)

@onready var _menu_panel: Panel = $MenuPanel
@onready var _mode_buttons: VBoxContainer = $MenuPanel/Center/VBox/ModeButtons
@onready var _exit_button: Button = $MenuPanel/Center/VBox/ExitButton

@onready var _pause_panel: Panel = $PausePanel
@onready var _resume_button: Button = $PausePanel/Center/VBox/ResumeButton
@onready var _abort_button: Button = $PausePanel/Center/VBox/AbortButton

@onready var _results_panel: Panel = $ResultsPanel
@onready var _results_title: Label = $ResultsPanel/Center/VBox/Title
@onready var _results_stats: VBoxContainer = $ResultsPanel/Center/VBox/Stats
@onready var _results_record: Label = $ResultsPanel/Center/VBox/RecordLabel
@onready var _retry_button: Button = $ResultsPanel/Center/VBox/RetryButton
@onready var _results_menu_button: Button = $ResultsPanel/Center/VBox/MenuButton

@onready var _cities_button: Button = $MenuPanel/Center/VBox/CitiesButton
@onready var _city_panel: Panel = $CityPanel
@onready var _offline_label: Label = $CityPanel/Margin/VBox/OfflineLabel
@onready var _search_field: LineEdit = $CityPanel/Margin/VBox/SearchRow/SearchField
@onready var _search_button: Button = $CityPanel/Margin/VBox/SearchRow/SearchButton
@onready var _size_select: OptionButton = $CityPanel/Margin/VBox/SearchRow/SizeSelect
@onready var _request_status_label: Label = $CityPanel/Margin/VBox/RequestStatusLabel
@onready var _candidates_list: VBoxContainer = $CityPanel/Margin/VBox/CandidatesList
@onready var _library_list: VBoxContainer = $CityPanel/Margin/VBox/LibraryList
@onready var _baking_list: VBoxContainer = $CityPanel/Margin/VBox/BakingList
@onready var _catalog_list: VBoxContainer = $CityPanel/Margin/VBox/CatalogList
@onready var _city_back_button: Button = $CityPanel/Margin/VBox/BackButton

var _pending_candidates: Array = []
var _search_in_flight := false


func _ready() -> void:
	_exit_button.pressed.connect(func() -> void: get_tree().quit())
	_resume_button.pressed.connect(func() -> void: resume_requested.emit())
	_abort_button.pressed.connect(func() -> void: abort_requested.emit())
	_retry_button.pressed.connect(func() -> void: retry_requested.emit())
	_results_menu_button.pressed.connect(func() -> void: menu_requested.emit())
	_cities_button.pressed.connect(_on_cities_button_pressed)
	_search_button.pressed.connect(_on_search_pressed)
	_city_back_button.pressed.connect(_on_city_back_pressed)
	for size_id in ["S", "M", "L"]:
		_size_select.add_item(size_id)
	_size_select.select(1)  # M por defecto
	hide_all()


func show_menu(mode_names: Array) -> void:
	hide_all()
	_menu_panel.visible = true
	for child in _mode_buttons.get_children():
		child.queue_free()
	for i in range(mode_names.size()):
		var btn := Button.new()
		btn.text = String(mode_names[i])
		var idx := i
		btn.pressed.connect(func() -> void: mode_selected.emit(idx))
		_mode_buttons.add_child(btn)


func show_pause() -> void:
	hide_all()
	_pause_panel.visible = true


func show_results(result: Dictionary) -> void:
	hide_all()
	_results_panel.visible = true
	var success: bool = result.get("success", false)
	_results_title.text = "¡Completado!" if success else "Resultados"

	for child in _results_stats.get_children():
		child.queue_free()
	var stats: Array = result.get("stats", [])
	for pair in stats:
		var row := Label.new()
		row.text = "%s: %s" % [pair[0], pair[1]]
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_results_stats.add_child(row)

	_results_record.visible = bool(result.get("record", false))


func hide_all() -> void:
	_menu_panel.visible = false
	_pause_panel.visible = false
	_results_panel.visible = false
	_city_panel.visible = false


# ---------------------------------------------------------------------------
# Ciudades (Fase C-3)
# ---------------------------------------------------------------------------
func _on_cities_button_pressed() -> void:
	hide_all()
	_city_panel.visible = true
	_request_status_label.visible = false
	city_panel_opened.emit()


## Mensaje visible tras pedir una zona: encolada/generando/lista/fallida/cuota agotada.
## Sin esto, un pedido bloqueado por cuota (o cualquier otro) no deja rastro en la UI --
## reportado por el humano probando ("no hay ningun aviso de que ya esta en proceso").
func show_request_status(text: String) -> void:
	_request_status_label.visible = true
	_request_status_label.text = text


func _on_city_back_pressed() -> void:
	_city_panel.visible = false
	_menu_panel.visible = true
	city_panel_closed.emit()


func _on_search_pressed() -> void:
	# Guarda contra doble clic mientras la busqueda anterior sigue en vuelo: sin esto,
	# un segundo clic durante ese lapso (~2s si el backend no responde) llama de nuevo a
	# HTTPRequest.request() en el mismo nodo y el motor tira "HTTPRequest is processing
	# a request" (reportado por el humano probando sin el backend levantado).
	if _search_in_flight:
		return
	var query := _search_field.text.strip_edges()
	if query == "":
		return
	_search_in_flight = true
	_search_button.disabled = true
	_search_button.text = "Buscando..."
	city_search_requested.emit(query)


func set_offline(is_offline: bool) -> void:
	_offline_label.visible = is_offline
	_search_in_flight = false
	_search_button.disabled = is_offline
	_search_button.text = "Buscar"


func show_geocode_results(results: Array) -> void:
	set_offline(false)  # una respuesta exitosa prueba que el backend SI esta disponible
	_pending_candidates = results
	for child in _candidates_list.get_children():
		child.queue_free()
	for i in range(results.size()):
		var r: Dictionary = results[i]
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = str(r.get("name", ""))
		label.custom_minimum_size = Vector2(360, 0)
		row.add_child(label)
		var btn := Button.new()
		btn.text = "Pedir"
		var idx := i
		btn.pressed.connect(func() -> void: _on_candidate_requested(idx))
		row.add_child(btn)
		_candidates_list.add_child(row)


func _on_candidate_requested(index: int) -> void:
	if index < 0 or index >= _pending_candidates.size():
		return
	var r: Dictionary = _pending_candidates[index]
	var size_id: String = _size_select.get_item_text(_size_select.selected)
	show_request_status("Pidiendo %s..." % str(r.get("name", "")))
	city_new_requested.emit(float(r.get("lat", 0.0)), float(r.get("lon", 0.0)), size_id, str(r.get("name", "")))


func show_local_library(cities: Array, selected_zone_id: String) -> void:
	for child in _library_list.get_children():
		child.queue_free()
	for c in cities:
		var row := HBoxContainer.new()
		var zone_id: String = str(c.get("zone_id", ""))
		var suffix := "  (En uso)" if zone_id == selected_zone_id else ""
		var label := Label.new()
		label.text = "%s [%s]%s" % [str(c.get("name", "")), str(c.get("zone_size", "")), suffix]
		label.custom_minimum_size = Vector2(300, 0)
		row.add_child(label)
		var btn := Button.new()
		btn.text = "Conducir"
		btn.disabled = zone_id == selected_zone_id
		btn.pressed.connect(func() -> void: city_local_selected.emit(zone_id))
		row.add_child(btn)
		_library_list.add_child(row)


func show_baking_list(entries: Array) -> void:
	for child in _baking_list.get_children():
		child.queue_free()
	for e in entries:
		var label := Label.new()
		var stage: String = str(e.get("stage", ""))
		var suffix := " (etapa: %s)" % stage if stage != "" else " (en cola, posicion %d)" % int(e.get("queue_position", 0))
		label.text = "%s%s" % [str(e.get("name", e.get("zone_id", ""))), suffix]
		_baking_list.add_child(label)


## Antes esta lista era solo texto (Label), sin forma de elegir ninguna ciudad -- el
## humano reporto exactamente eso ("hay varias, pero no tengo como seleccionar ninguna").
func show_catalog(entries: Array) -> void:
	for child in _catalog_list.get_children():
		child.queue_free()
	for e in entries:
		var row := HBoxContainer.new()
		var zone_id: String = str(e.get("zone_id", ""))
		var city_name: String = str(e.get("name", ""))
		var label := Label.new()
		label.text = "%s [%s] %s" % [city_name, str(e.get("zone_size", "")), str(e.get("flags", []))]
		label.custom_minimum_size = Vector2(360, 0)
		row.add_child(label)
		var btn := Button.new()
		btn.text = "Descargar"
		btn.pressed.connect(func() -> void: city_catalog_download_requested.emit(zone_id, city_name))
		row.add_child(btn)
		_catalog_list.add_child(row)
