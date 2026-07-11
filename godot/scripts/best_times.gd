class_name BestTimes
extends RefCounted
## Persistencia de mejores tiempos (Fase M-3): todo estático, sobre user://best_times.cfg.
## Sección = city_id, clave = route_id, valor = {"ms": int, "date": ISO-8601}.
## Cambiar el algoritmo de rutas o regenerar el mapa produce route_id/city_id nuevos:
## los tiempos viejos no se corrompen, simplemente dejan de competir (ver ESPEC).

const SAVE_PATH := "user://best_times.cfg"


## "city_<lat>_<lon>" desde map_meta.origin (4 decimales; "-" -> "m", "." -> "_");
## prefiere meta.name si existiera (hoy no existe en map.json).
static func compute_city_id(map_meta: Dictionary) -> String:
	var city_name: String = str(map_meta.get("name", ""))
	if city_name != "":
		return "city_%s" % city_name.to_lower().replace(" ", "_")
	var origin: Dictionary = map_meta.get("origin", {})
	var lat: float = origin.get("lat", 0.0)
	var lon: float = origin.get("lon", 0.0)
	return "city_%s_%s" % [_format_coord(lat), _format_coord(lon)]


static func _format_coord(v: float) -> String:
	return ("%.4f" % v).replace("-", "m").replace(".", "_")


## -1 si no hay tiempo guardado para esa ciudad+ruta.
static func get_best(city_id: String, route_id: String) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return -1
	var entry = cfg.get_value(city_id, route_id, null)
	if typeof(entry) != TYPE_DICTIONARY or not entry.has("ms"):
		return -1
	return int(entry["ms"])


## Guarda ms si es un récord nuevo (o el primero para esa ciudad+ruta). Devuelve true si lo es.
static func try_save(city_id: String, route_id: String, ms: int) -> bool:
	var previous := get_best(city_id, route_id)
	var is_record := previous == -1 or ms < previous
	if is_record:
		var cfg := ConfigFile.new()
		cfg.load(SAVE_PATH)  # ok si el archivo aún no existe: cfg queda vacío
		cfg.set_value(city_id, route_id, {"ms": ms, "date": Time.get_datetime_string_from_system(true)})
		var err := cfg.save(SAVE_PATH)
		if err != OK:
			push_error("BestTimes: no se pudo guardar %s (error %d)" % [SAVE_PATH, err])
	return is_record
