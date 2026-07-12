class_name LoadingScreen
extends CanvasLayer
## Pantalla de carga (Fase C-3, contrato 5): bloqueante SOLO durante descarga+carga.
## Barra real durante la descarga; mensaje generico durante la construccion del mundo
## (Godot no expone progreso de _ready(), asi que esa fase es indeterminada).

const FLAGS_TEXT := {
	"sparse_buildings": "Zona con pocos edificios en OSM",
	"steep": "Ciudad empinada",
}
const ATTRIBUTION := "Datos del mapa © OpenStreetMap contributors (ODbL)"

@onready var _panel: Panel = $Panel
@onready var _name_label: Label = $Panel/Center/VBox/NameLabel
@onready var _status_label: Label = $Panel/Center/VBox/StatusLabel
@onready var _flags_label: Label = $Panel/Center/VBox/FlagsLabel
@onready var _progress_bar: ProgressBar = $Panel/Center/VBox/ProgressBar
@onready var _attribution_label: Label = $Panel/Center/VBox/AttributionLabel


func _ready() -> void:
	_attribution_label.text = ATTRIBUTION
	hide_screen()


func show_downloading(city_name: String, flags: Array) -> void:
	_panel.visible = true
	_name_label.text = city_name
	_status_label.text = "Descargando..."
	_flags_label.text = _flags_to_text(flags)
	_flags_label.visible = not flags.is_empty()
	_progress_bar.visible = true
	_progress_bar.value = 0.0


func set_progress(fraction: float) -> void:
	_progress_bar.value = clampf(fraction, 0.0, 1.0) * 100.0


func show_building() -> void:
	_status_label.text = "Construyendo el mundo..."
	_progress_bar.visible = false


func hide_screen() -> void:
	_panel.visible = false


func _flags_to_text(flags: Array) -> String:
	var parts: Array = []
	for f in flags:
		parts.append(FLAGS_TEXT.get(f, str(f)))
	return ", ".join(parts)
