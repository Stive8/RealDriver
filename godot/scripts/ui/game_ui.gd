class_name GameUI
extends CanvasLayer
## HUD de flujo (Fase M-1): tres paneles placeholder mutuamente excluyentes
## (menú, pausa, resultados) pilotados por GameFlow. Todo tema por defecto.

signal mode_selected(index: int)
signal resume_requested
signal abort_requested
signal retry_requested
signal menu_requested

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


func _ready() -> void:
	_exit_button.pressed.connect(func() -> void: get_tree().quit())
	_resume_button.pressed.connect(func() -> void: resume_requested.emit())
	_abort_button.pressed.connect(func() -> void: abort_requested.emit())
	_retry_button.pressed.connect(func() -> void: retry_requested.emit())
	_results_menu_button.pressed.connect(func() -> void: menu_requested.emit())
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
