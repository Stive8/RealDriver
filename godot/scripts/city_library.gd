class_name CityLibrary
extends RefCounted
## Biblioteca local de ciudades (Fase C-3): todo estatico, sobre user://cities/<zone_id>/
## y user://settings.cfg. Contrato 5 (ESPEC_SESION_CIUDADES2).

const CITIES_DIR := "user://cities"
const SETTINGS_PATH := "user://settings.cfg"
const FALLBACK_MAP_PATH := "res://data/map.json"
const DEFAULT_BACKEND_URL := "http://127.0.0.1:8000"

const _SETTINGS_SECTION := "city"
const _KEY_SELECTED_ZONE := "selected_zone"
const _KEY_CLIENT_ID := "client_id"
const _KEY_BACKEND_URL := "backend_url"


static func local_map_path(zone_id: String) -> String:
	return "%s/%s/map.json" % [CITIES_DIR, zone_id]


## Ruta del map.json de la ciudad seleccionada, o res://data/map.json si no hay
## seleccion o el archivo seleccionado no existe / no es JSON valido con meta.
static func get_selected_map_path() -> String:
	var zone_id := get_selected_zone()
	if zone_id == "":
		return FALLBACK_MAP_PATH
	var path := local_map_path(zone_id)
	if not _is_valid_map(path):
		return FALLBACK_MAP_PATH
	return path


static func _is_valid_map(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	return typeof(data) == TYPE_DICTIONARY and data.has("meta")


static func get_selected_zone() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return ""
	return str(cfg.get_value(_SETTINGS_SECTION, _KEY_SELECTED_ZONE, ""))


static func set_selected(zone_id: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # ok si aun no existe
	cfg.set_value(_SETTINGS_SECTION, _KEY_SELECTED_ZONE, zone_id)
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_error("CityLibrary: no se pudo guardar %s (error %d)" % [SETTINGS_PATH, err])


## client_id persistente (UUID v4 generado la primera vez que se necesita).
static func get_client_id() -> String:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	var existing: String = str(cfg.get_value(_SETTINGS_SECTION, _KEY_CLIENT_ID, ""))
	if existing != "":
		return existing
	var new_id := _generate_uuid_v4()
	cfg.set_value(_SETTINGS_SECTION, _KEY_CLIENT_ID, new_id)
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_error("CityLibrary: no se pudo guardar %s (error %d)" % [SETTINGS_PATH, err])
	return new_id


static func get_backend_url() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return DEFAULT_BACKEND_URL
	return str(cfg.get_value(_SETTINGS_SECTION, _KEY_BACKEND_URL, DEFAULT_BACKEND_URL))


## Todas las ciudades locales validas: {zone_id, name, zone_size, flags, path}.
static func list_local() -> Array:
	var result: Array = []
	var dir := DirAccess.open(CITIES_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry != "." and entry != "..":
			var path := local_map_path(entry)
			if _is_valid_map(path):
				var file := FileAccess.open(path, FileAccess.READ)
				var data = JSON.parse_string(file.get_as_text())
				file.close()
				var meta: Dictionary = data.get("meta", {})
				var stats: Dictionary = meta.get("stats", {})
				result.append({
					"zone_id": entry,
					"name": str(meta.get("name", entry)),
					"zone_size": str(meta.get("zone_size", "")),
					"flags": stats.get("flags", []),
					"path": path,
				})
		entry = dir.get_next()
	dir.list_dir_end()
	return result


static func _generate_uuid_v4() -> String:
	var bytes := PackedByteArray()
	for i in range(16):
		bytes.append(randi() % 256)
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
