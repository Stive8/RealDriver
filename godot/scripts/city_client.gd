class_name CityClient
extends Node
## Cliente HTTP del backend (Fase C-3, contrato 5): geocodificar, pedir zona, sondear
## progreso, descargar. Hijo de GameFlow. Backend caido/sin red -> senal `offline`.

signal geocode_results(results: Array)
signal zone_requested(zone_id: String, status: String, queue_position: int)
signal zone_progress(zone_id: String, stage: String)
signal zone_ready(zone_id: String, meta_summary: Dictionary)
signal zone_failed(zone_id: String, reason: String)
signal zone_quota_exceeded(resets_at: String)
signal download_progress(zone_id: String, downloaded: int, total: int)
signal download_complete(zone_id: String)
signal catalog_received(catalog: Array)
signal offline

const POLL_INTERVAL := 3.0  ## [ESTRUCTURAL]

var _base_url: String = CityLibrary.DEFAULT_BACKEND_URL
var _client_id: String = ""

var _geocode_req: HTTPRequest
var _zone_req: HTTPRequest
var _poll_req: HTTPRequest
var _catalog_req: HTTPRequest
var _download_req: HTTPRequest

var _poll_timer: Timer
var _polling_zone_id: String = ""
var _downloading_zone_id: String = ""
var _download_tmp_path: String = ""


func _ready() -> void:
	_base_url = CityLibrary.get_backend_url()
	_client_id = CityLibrary.get_client_id()

	_geocode_req = _make_request()
	_geocode_req.request_completed.connect(_on_geocode_completed)

	_zone_req = _make_request()
	_zone_req.request_completed.connect(_on_zone_request_completed)

	_poll_req = _make_request()
	_poll_req.request_completed.connect(_on_poll_completed)

	_catalog_req = _make_request()
	_catalog_req.request_completed.connect(_on_catalog_completed)

	_download_req = _make_request()
	_download_req.request_completed.connect(_on_download_completed)

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.timeout.connect(_on_poll_timer_timeout)
	add_child(_poll_timer)


func _make_request() -> HTTPRequest:
	var req := HTTPRequest.new()
	add_child(req)
	return req


func geocode(query: String) -> void:
	var url := "%s/v1/geocode?q=%s" % [_base_url, query.uri_encode()]
	var err := _geocode_req.request(url)
	if err != OK:
		offline.emit()


func request_zone(lat: float, lon: float, size: String, name: String) -> void:
	var body := JSON.stringify({"lat": lat, "lon": lon, "size": size, "name": name})
	var headers := ["Content-Type: application/json", "X-Client-Id: %s" % _client_id]
	var err := _zone_req.request("%s/v1/zones" % _base_url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		offline.emit()


func poll_zone(zone_id: String) -> void:
	_polling_zone_id = zone_id
	_poll_now()
	_poll_timer.start()


func stop_polling() -> void:
	_polling_zone_id = ""
	_poll_timer.stop()


func fetch_catalog() -> void:
	var err := _catalog_req.request("%s/v1/catalog" % _base_url)
	if err != OK:
		offline.emit()


func download_zone(zone_id: String) -> void:
	_downloading_zone_id = zone_id
	_download_tmp_path = "user://cities_download_%s.tmp" % zone_id
	_download_req.download_file = _download_tmp_path
	var err := _download_req.request("%s/v1/zones/%s/map.json" % [_base_url, zone_id])
	if err != OK:
		offline.emit()


func _process(_delta: float) -> void:
	if _downloading_zone_id != "" and _download_req.get_http_client_status() == HTTPClient.STATUS_BODY:
		var total := _download_req.get_body_size()
		var downloaded := _download_req.get_downloaded_bytes()
		download_progress.emit(_downloading_zone_id, downloaded, maxi(total, downloaded))


func _poll_now() -> void:
	if _polling_zone_id == "":
		return
	var err := _poll_req.request("%s/v1/zones/%s" % [_base_url, _polling_zone_id])
	if err != OK:
		offline.emit()


func _on_poll_timer_timeout() -> void:
	_poll_now()


func _on_geocode_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		offline.emit()
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	geocode_results.emit(data if typeof(data) == TYPE_ARRAY else [])


func _on_zone_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		offline.emit()
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		offline.emit()
		return
	if response_code == 429:
		zone_quota_exceeded.emit(str(data.get("resets_at", "")))
		return
	zone_requested.emit(str(data.get("zone_id", "")), str(data.get("status", "")), int(data.get("queue_position", 0)))


func _on_poll_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		offline.emit()
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return
	var zone_id: String = str(data.get("zone_id", _polling_zone_id))
	var status: String = str(data.get("status", ""))
	match status:
		"ready":
			stop_polling()
			zone_ready.emit(zone_id, data.get("meta_summary", {}))
		"failed":
			stop_polling()
			zone_failed.emit(zone_id, str(data.get("reason", "")))
		_:
			zone_progress.emit(zone_id, str(data.get("stage", "")))


func _on_catalog_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		offline.emit()
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	catalog_received.emit(data if typeof(data) == TYPE_ARRAY else [])


func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var zone_id := _downloading_zone_id
	_downloading_zone_id = ""
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		offline.emit()
		return
	var dir_path := CityLibrary.local_map_path(zone_id).get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)
	var dest := CityLibrary.local_map_path(zone_id)
	var err := DirAccess.rename_absolute(_download_tmp_path, dest)
	if err != OK:
		push_error("CityClient: no se pudo mover la descarga a %s (error %d)" % [dest, err])
		return
	download_complete.emit(zone_id)
