# Fase C-3 — Cliente Godot: biblioteca, descarga y carga de cualquier ciudad — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended for this plan — no test framework exists for GDScript in this project; verification is headless Godot runs + human visual checklist, not unit tests). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the C-2 backend to the actual game: a "Ciudades" menu button opens a panel to search/request/select any city, a loading screen handles download+build, and the world (perimeter, spawn, route length, minimap resolution) adapts to whatever city is loaded instead of Jordán's hand-tuned constants.

**Architecture:** Two new standalone scripts (`city_library.gd` static file/settings manager, `city_client.gd` an `HTTPRequest`-driving `Node`) plus surgical edits to the 6 files the spec's closed list permits. No test framework exists for GDScript here (no `gdUnit`/`GUT` in the repo) — verification is `godot --headless --quit-after N` runs (catches load-time script/scene errors and prints diagnostics) plus the human's own visual checklist from the spec, since 3D/UI behavior can't be observed by the agent.

**Tech Stack:** Godot 4.4 stable GDScript, static typing where reasonable. `HTTPRequest` (native, no plugins). No autoloads (persistence via static classes, `best_times.gd` pattern).

## Global Constraints

- **Closed file list — touch ONLY these existing files, and ONLY in the way described:**
  - `map_loader.gd`: load from variable path (library or `res://data/map.json` fallback), expose extended `map_meta`, build perimeter from `stats.extent_m`, position vehicle at the derived spawn via `vehicle.teleport()`.
  - `route_generator.gd`: extract the existing exit-choice rule to `static func pick_start_node(graph) -> Dictionary`; `generate()` reuses it. Zero behavior change to route generation itself.
  - `time_trial_mode.gd` / `minimap/minimap.gd`: replace their `[TUNEO-ZONA]` constants with the structural formulas (reading `map_meta`).
  - `game_flow.gd` / `ui/game_ui.gd` / `ui/game_ui.tscn`: "Ciudades" button + CityPanel + loading-screen integration. M-1 placeholder pattern (`Panel`/`Label`/`Button`/`LineEdit`, default theme), nothing fancier.
  - `main.tscn`: remove the hardcoded Vehicle spawn transform (moves to code); instantiate `loading_screen.tscn`.
  - `vehicle.gd`, traffic, shaders, relief builders: **not touched.**
- No new files beyond `city_library.gd`, `city_client.gd`, `ui/loading_screen.gd`, `ui/loading_screen.tscn` — CityPanel's logic lives inside `game_ui.gd` (a new `Panel` node in `game_ui.tscn`, not a separate script), matching how the repo tree in the spec lists no separate `city_panel.gd`.
- No autoloads; `city_client.gd` is a plain `Node` added as a child of `GameFlow` (same pattern already used for spawned `GameMode` children).
- Changing city = `CityLibrary.set_selected(zone_id)` + `get_tree().reload_current_scene()`. **Never** hot-swap the loaded map.
- `BACKEND_URL` default `http://127.0.0.1:8000`, `POLL_INTERVAL` `3.0s` — both structural constants per contract.
- Out of scope entirely (not just this phase): multiplayer, accounts, payments, LOD, world streaming, procedural infill for sparse zones, self-hosted mirrors.

### Contract 5 (Godot client) — reproduced for reference

- `city_library.gd` (`class_name CityLibrary`, all-static): local cities at `user://cities/<zone_id>/map.json`; selection persisted in `user://settings.cfg` (key `selected_zone`; also stores `client_id`, `backend_url`). `get_selected_map_path() -> String` (fallback `res://data/map.json` if nothing selected or the file is missing/invalid).
- `city_client.gd` (`Node`, child of GameFlow): talks to the backend via `HTTPRequest` (geocode, request a zone, poll every `POLL_INTERVAL`, download via `download_file` to a temp path then move on completion, progress via `get_downloaded_bytes()/get_body_size()`). Backend down or offline → `offline` signal (CityPanel disables search/generation with a message; the local library always works).
- Loading screen (`loading_screen.tscn`): visible during download (real progress bar) and build; shows `meta.name`, flags as friendly text ("zona con pocos edificios en OSM", "ciudad empinada"), and the attribution: "Datos del mapa © OpenStreetMap contributors (ODbL)". CityPanel's footer: "Búsqueda: © OpenStreetMap / Nominatim".

### Contract 6 (structural formulas) — reproduced for reference

| Before (tuned) | Now (formula, from `map_meta.stats`) |
|---|---|
| `TARGET_LOOP_LENGTH` | `clamp(0.8 * max(span_x, span_z), 800.0, 3000.0)` |
| `CHECKPOINT_SPACING` | `clamp(TARGET_LOOP_LENGTH / 8.0, 120.0, 250.0)` |
| `MINIMAP_VIEW_RADIUS` | fixed `150.0` |
| `MINIMAP_BAKE_RES` | `1024` if `max(span_x, span_z) <= 2000.0` else `2048` |
| Perimeter | boxes at `extent_m` ± 30 m |
| Vehicle spawn | `RouteGenerator.pick_start_node(graph)` + `terrain_sampler.height_at + 1`, yaw toward the neighbor of the widest edge |

If the JSON is 1.1/1.2 (no `stats`): Jordán legacy defaults, hardcoded **only** in the compatibility branch, commented as legacy: `span 1860×1056`, `extent [-560.0, -530.0, 560.0, 530.0]` (never actually hit today — the packaged Jordán map is already 1.3 with real `stats` since Fase C-1 — this branch only protects against a stray old cache file).

## File Structure

```
godot/
├── scenes/
│   ├── main.tscn                    (MODIFY: remove Vehicle transform, add LoadingScreen instance)
│   └── ui/
│       ├── game_ui.tscn             (MODIFY: + CityPanel)
│       └── loading_screen.tscn      (NEW)
└── scripts/
    ├── city_library.gd              (NEW)
    ├── city_client.gd               (NEW)
    ├── map_loader.gd                (MODIFY)
    ├── game_flow.gd                 (MODIFY)
    ├── modes/time_trial/
    │   ├── route_generator.gd       (MODIFY: extract pick_start_node)
    │   └── time_trial_mode.gd       (MODIFY: structural formulas)
    ├── minimap/minimap.gd           (MODIFY: structural formulas)
    └── ui/
        ├── game_ui.gd               (MODIFY: CityPanel logic)
        └── loading_screen.gd        (NEW)
```

## Interfaces summary (for cross-task reference)

- `RouteGenerator.pick_start_node(graph: TrafficGraph) -> Dictionary` — `{}` if no valid node, else `{"index": int, "pos": Vector2, "yaw": float}`.
- `CityLibrary.get_selected_map_path() -> String`
- `CityLibrary.set_selected(zone_id: String) -> void`
- `CityLibrary.list_local() -> Array[Dictionary]` — `{zone_id, name, zone_size, flags, path}` for every `user://cities/<zone_id>/map.json` that parses.
- `CityLibrary.get_client_id() -> String`
- `CityLibrary.get_backend_url() -> String`
- `CityLibrary.local_map_path(zone_id: String) -> String`
- `CityClient` (Node) signals: `geocode_results(results: Array)`, `zone_requested(zone_id: String, status: String, queue_position: int)`, `zone_progress(zone_id: String, stage: String)`, `zone_ready(zone_id: String, meta_summary: Dictionary)`, `zone_failed(zone_id: String, reason: String)`, `download_progress(zone_id: String, downloaded: int, total: int)`, `download_complete(zone_id: String)`, `offline`
- `CityClient` methods: `geocode(query: String) -> void`, `request_zone(lat: float, lon: float, size: String, name: String) -> void`, `poll_zone(zone_id: String) -> void` (also starts auto-poll timer), `download_zone(zone_id: String) -> void`, `fetch_catalog() -> void` (emits `catalog_received(Array)`)
- `GameUI` new signals: `city_panel_opened`, `city_panel_closed`, `city_search_requested(query: String)`, `city_new_requested(lat: float, lon: float, size: String, name: String)`, `city_local_selected(zone_id: String)`
- `LoadingScreen` (CanvasLayer) methods: `show_downloading(name: String, flags: Array)`, `set_progress(fraction: float)`, `show_building()`, `hide_screen()`

---

### Task 1: `route_generator.gd` — extract `pick_start_node`

**Files:** Modify `godot/scripts/modes/time_trial/route_generator.gd`.

- [ ] **Step 1: Add the public function + yaw helper, keep `generate()` behavior identical**

Insert after `_build_node_keys` (around line 122), and change `generate()`'s S-selection:

```gdscript
## Nodo de partida "canonico" del grafo: interseccion mas cercana al centroide con
## preferencia por vias anchas (misma regla que usa generate() para elegir S), mas el
## rumbo hacia el vecino de la arista mas ancha en ese nodo. Reusado por map_loader.gd
## (Fase C-3) para el spawn del vehiculo al cargar cualquier ciudad.
static func pick_start_node(graph: TrafficGraph) -> Dictionary:
	if graph.node_pos.size() == 0:
		return {}
	var node_keys := _build_node_keys(graph)
	var s := _pick_start(graph, node_keys)
	if s == -1:
		return {}
	return {"index": s, "pos": graph.node_pos[s], "yaw": _widest_neighbor_yaw(graph, s)}


static func _widest_neighbor_yaw(graph: TrafficGraph, node_idx: int) -> float:
	var best_edge := -1
	var best_width := -1.0
	for e in graph.node_edges[node_idx]:
		if graph.edge_width[e] > best_width:
			best_width = graph.edge_width[e]
			best_edge = e
	if best_edge == -1:
		return 0.0
	var neighbor: int = graph.edge_to[best_edge] if graph.edge_from[best_edge] == node_idx else graph.edge_from[best_edge]
	var dir: Vector2 = graph.node_pos[neighbor] - graph.node_pos[node_idx]
	return atan2(dir.x, dir.y) if dir.length() > _EPS else 0.0
```

In `generate()` (around line 57-60), replace:
```gdscript
	var node_keys := _build_node_keys(graph)
	var s := _pick_start(graph, node_keys)
	if s == -1:
		return null
```
with:
```gdscript
	var node_keys := _build_node_keys(graph)
	var start := pick_start_node(graph)
	if start.is_empty():
		return null
	var s: int = start["index"]
```

- [ ] **Step 2: Headless syntax/load check**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3`
Expected: identical output to the pre-change baseline (same road/building/graph counts, same `[ruta]` line does NOT appear yet — RouteGenerator.generate() only runs when a time-trial starts, which doesn't happen in a 3-frame headless boot). No new errors/warnings.

---

### Task 2: `time_trial_mode.gd` + `minimap.gd` — structural formulas

**Files:** Modify both.

- [ ] **Step 1: `time_trial_mode.gd` — compute loop length/spacing from `map_meta.stats`**

Remove the `[TUNEO-ZONA]` block (lines 26-35: the comment plus `TARGET_LOOP_LENGTH`/`CHECKPOINT_SPACING` consts are **deleted from this file** — they never lived here to begin with as usable values; `time_trial_mode.gd` referenced `RouteGenerator.TARGET_LOOP_LENGTH`/`RouteGenerator.CHECKPOINT_SPACING`, which are `route_generator.gd`'s own now-orphaned `[TUNEO-ZONA]` constants. `route_generator.gd` is not in scope for further edits this phase beyond Task 1 (closed list), so those two constants stay physically in that file, unused — noted below).

Add near the top of `time_trial_mode.gd` (after the existing `[ESTRUCTURAL]` constants, before `var _ctx`):
```gdscript
# [ESTRUCTURAL] Fase C-3: formulas que reemplazan TARGET_LOOP_LENGTH/CHECKPOINT_SPACING
# (esas dos siguen existiendo, sin uso, en route_generator.gd -- ese archivo solo admite
# la extraccion de pick_start_node en esta fase, ver ESPEC_SESION_CIUDADES2 lista cerrada).
const LOOP_LENGTH_FACTOR := 0.8
const LOOP_LENGTH_MIN := 800.0
const LOOP_LENGTH_MAX := 3000.0
const CHECKPOINT_SPACING_DIVISOR := 8.0
const CHECKPOINT_SPACING_MIN := 120.0
const CHECKPOINT_SPACING_MAX := 250.0
# Legado (contrato 6): map.json 1.1/1.2 sin `stats` -> span de Jordan tal como era antes
# de este bloque. Vivo solo por compatibilidad; el Jordan empaquetado ya trae stats.
const LEGACY_SPAN_X := 1860.0
const LEGACY_SPAN_Z := 1056.0
```

Replace the `start_mode()` route generation call (line 63):
```gdscript
	_route = RouteGenerator.generate(_ctx.graph, RouteGenerator.TARGET_LOOP_LENGTH, RouteGenerator.CHECKPOINT_SPACING, ROUTE_SEED)
```
with:
```gdscript
	var formulas := _compute_route_formulas(_ctx.map_meta)
	print("[tt] loop objetivo=%.0f m spacing=%.0f m" % [formulas["target_loop_length"], formulas["checkpoint_spacing"]])
	_route = RouteGenerator.generate(_ctx.graph, formulas["target_loop_length"], formulas["checkpoint_spacing"], ROUTE_SEED)
```

Add the formula function (near `_terrain_sampler()`, same file):
```gdscript
## Contrato 6 (ESPEC_SESION_CIUDADES2): reemplaza los [TUNEO-ZONA] retirados. Lee
## map_meta.stats.span_x/span_z; si el JSON es 1.1/1.2 (sin stats), usa el span legado
## de Jordan (rama de compatibilidad, nunca alcanzada por el Jordan empaquetado hoy).
static func _compute_route_formulas(map_meta: Dictionary) -> Dictionary:
	var stats: Dictionary = map_meta.get("stats", {})
	var span_x: float = stats.get("span_x", LEGACY_SPAN_X)
	var span_z: float = stats.get("span_z", LEGACY_SPAN_Z)
	var target_loop_length: float = clampf(LOOP_LENGTH_FACTOR * maxf(span_x, span_z), LOOP_LENGTH_MIN, LOOP_LENGTH_MAX)
	var checkpoint_spacing: float = clampf(target_loop_length / CHECKPOINT_SPACING_DIVISOR, CHECKPOINT_SPACING_MIN, CHECKPOINT_SPACING_MAX)
	return {"target_loop_length": target_loop_length, "checkpoint_spacing": checkpoint_spacing}
```

- [ ] **Step 2: `minimap.gd` — bake resolution from `map_meta.stats`, fixed view radius stays**

Replace the `[TUNEO-ZONA]` block (lines 23-25):
```gdscript
# [TUNEO-ZONA] — calibracion de Jordan; otra ciudad DEBE recalibrar estas dos constantes.
const MINIMAP_VIEW_RADIUS := 150.0   ## radio visible del minimapa (m).
const MINIMAP_BAKE_RES := 1024        ## resolucion del horneado (px).
```
with:
```gdscript
# [ESTRUCTURAL] Fase C-3 (contrato 6): MINIMAP_VIEW_RADIUS es fijo para cualquier ciudad;
# MINIMAP_BAKE_RES se deriva de map_meta.stats (ver _compute_bake_res). Legado (sin stats):
# mismo span de Jordan que time_trial_mode.gd usa para su rama de compatibilidad.
const MINIMAP_VIEW_RADIUS := 150.0   ## radio visible del minimapa (m).
const LEGACY_SPAN_X := 1860.0
const LEGACY_SPAN_Z := 1056.0
```

Add an instance var (near `_world_min`/`_world_span`, around line 40):
```gdscript
var _bake_res: int = 1024
```

In `_ready()` (line 49-54), compute it before anything else uses it:
```gdscript
func _ready() -> void:
	_bake_res = _compute_bake_res()
	print("minimapa: bake_res=%d" % _bake_res)
	_compute_world_bounds()
	_build_display_layout()
	_build_viewport()
	_build_overlay_nodes()
	_bake_roads()


func _compute_bake_res() -> int:
	var stats: Dictionary = _map.map_meta.get("stats", {})
	var span_x: float = stats.get("span_x", LEGACY_SPAN_X)
	var span_z: float = stats.get("span_z", LEGACY_SPAN_Z)
	return 1024 if maxf(span_x, span_z) <= 2000.0 else 2048
```

Replace every remaining `MINIMAP_BAKE_RES` reference in the file (`_build_viewport`, `_world_to_px`, `_draw_roads`'s print) with `_bake_res`.

- [ ] **Step 2: Headless check**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | grep -E "minimapa|ERROR|SCRIPT ERROR"`
Expected: `minimapa: bake_res=1024` (Jordán's real `span_x=1859.9 span_z=1055.9`, both ≤ 2000 → 1024), no errors.

---

### Task 3: `city_library.gd` — local library + settings (new, standalone)

**Files:** Create `godot/scripts/city_library.gd`.

- [ ] **Step 1: Implement**

```gdscript
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
```

- [ ] **Step 2: Headless functional smoke test (no scene needed — `RefCounted`, callable from a throwaway script)**

Run:
```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --script res://scripts/city_library.gd 2>&1 || true
```
This just confirms the file parses as valid GDScript (a `class_name`-only file has no `_ready`/no main, running it via `--script` on a `RefCounted` will error "not runnable" — that error message itself, not a parse error, is the expected/passing signal here). Follow up with the full boot check used in every task:
Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -20`
Expected: same clean boot as before (this file isn't wired into any scene yet, so it can't break anything at this point — this just proves it parses).

---

### Task 4: `city_client.gd` — backend HTTP client (new)

**Files:** Create `godot/scripts/city_client.gd`.

- [ ] **Step 1: Implement**

```gdscript
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
```

- [ ] **Step 2: Headless check**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -20`
Expected: same clean boot (not wired into any scene yet — proves it parses cleanly).

---

### Task 5: `map_loader.gd` — variable path, extent-derived perimeter, derived spawn

**Files:** Modify `godot/scripts/map_loader.gd`.

**This is the highest-risk task in the phase — it changes how the packaged Jordán map loads and where the vehicle spawns.** Verify with the full headless boot AND compare road/building/graph counts against the Task-0 baseline (they must be identical — only the perimeter size and spawn position change).

- [ ] **Step 1: Replace the constants block (lines 1-8) and add legacy/margin constants**

```gdscript
extends Node3D

## Fase C-3: la ruta ya no es fija -- viene de CityLibrary (biblioteca local o
## res://data/map.json si no hay seleccion / el archivo esta corrupto).
const FALLBACK_MAP_PATH := "res://data/map.json"
const PERIMETER_MARGIN := 30.0
const PERIMETER_THICK := 2.0
## Contrato 6: JSON 1.1/1.2 sin `stats` -> extent/span legado de Jordan (nunca alcanzado
## por el Jordan empaquetado hoy, que ya trae stats desde Fase C-1).
const LEGACY_EXTENT := [-560.0, -530.0, 560.0, 530.0]
## [ESTRUCTURAL] Fase R-4: paso de remuestreo para detectar la pendiente máxima al cargar
## (espejo de SLOPE_SAMPLE_STEP en generate_map.py).
const SLOPE_SAMPLE_STEP := 10.0
```

- [ ] **Step 2: Rewrite `_ready()`'s load + vehicle-reference section**

Replace lines 31-51 (from `func _ready()` through `map_meta = data.get("meta", {})`) with:
```gdscript
func _ready() -> void:
	var start_ms := Time.get_ticks_msec()

	var map_path := CityLibrary.get_selected_map_path()
	var data = _load_map_data(map_path)
	if data == null:
		push_warning("MapLoader: %s invalido/corrupto; usando Jordan empaquetado" % map_path)
		map_path = FALLBACK_MAP_PATH
		data = _load_map_data(map_path)
	if data == null:
		push_error("MapLoader: no se pudo cargar ni siquiera %s" % FALLBACK_MAP_PATH)
		return

	var roads: Array = data.get("roads", [])
	var buildings: Array = data.get("buildings", [])
	# v1.1 retrocompatible: controls ausente = lista vacía (map.json v1.0 carga sin errores).
	var controls: Array = data.get("controls", [])
	map_meta = data.get("meta", {})

	_vehicle = get_node("../Vehicle") as VehicleBody3D
	if _vehicle == null:
		push_error("MapLoader: no se encontró Vehicle en ../Vehicle")

	var stats: Dictionary = map_meta.get("stats", {})
	var extent: Array = stats.get("extent_m", LEGACY_EXTENT) if not stats.is_empty() else LEGACY_EXTENT
	print("mapa cargado: %s (zone_id=%s)" % [map_path, str(map_meta.get("zone_id", "n/a"))])
	print("span: %.1f x %.1f m" % [stats.get("span_x", 0.0), stats.get("span_z", 0.0)])
```

Add the loader helper (anywhere at file scope, e.g. right after `_ready()`):
```gdscript
func _load_map_data(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var json_text := file.get_as_text()
	file.close()
	var data = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		return null
	return data
```

- [ ] **Step 3: Perimeter from `extent`, expose the correct bounding-square `play_area_half_extent`**

Replace the `_add_perimeter_walls()` call site (`_add_perimeter_walls()` with no args) with `_add_perimeter_walls(extent)`, and replace the whole function body (old lines 153-184):
```gdscript
func _add_perimeter_walls(extent: Array) -> void:
	var xmin: float = float(extent[0]) - PERIMETER_MARGIN
	var zmin: float = float(extent[1]) - PERIMETER_MARGIN
	var xmax: float = float(extent[2]) + PERIMETER_MARGIN
	var zmax: float = float(extent[3]) + PERIMETER_MARGIN
	# Cuadrado que SIEMPRE contiene el rectangulo real: usado solo por minimap.gd
	# (play_area_half_extent), que asume un area cuadrada centrada en el origen.
	play_area_half_extent = maxf(maxf(absf(xmin), absf(xmax)), maxf(absf(zmin), absf(zmax)))

	var width := xmax - xmin
	var depth := zmax - zmin
	var cx := (xmin + xmax) * 0.5
	var cz := (zmin + zmax) * 0.5

	var max_h := terrain_sampler.max_height
	# DECISION_PENDIENTE: el ESPEC da centro = (max_height + 20) / 2 − 5, pero esa fórmula
	# no reproduce el rango que el propio ESPEC declara como objetivo ("de y=−5 a
	# max_height + 25"): con la fórmula tal cual, el rango real sale [-10, max_height+20].
	# Se prioriza el rango declarado explícitamente (más inequívoco) y se despeja el
	# centro a partir de él: centro = (max_height + 20) / 2 (sin el −5).
	var wall_height := max_h + 30.0
	var wall_center_y := (max_h + 20.0) / 2.0

	var wall_shape_x := BoxShape3D.new()
	wall_shape_x.size = Vector3(PERIMETER_THICK, wall_height, depth)

	var wall_shape_z := BoxShape3D.new()
	wall_shape_z.size = Vector3(width, wall_height, PERIMETER_THICK)

	var configs := [
		{ "name": "WallEast",  "pos": Vector3(xmax, wall_center_y, cz), "shape": wall_shape_x },
		{ "name": "WallWest",  "pos": Vector3(xmin, wall_center_y, cz), "shape": wall_shape_x },
		{ "name": "WallNorth", "pos": Vector3(cx, wall_center_y, zmin), "shape": wall_shape_z },
		{ "name": "WallSouth", "pos": Vector3(cx, wall_center_y, zmax), "shape": wall_shape_z },
	]

	for cfg in configs:
		var body := StaticBody3D.new()
		body.name = cfg["name"]
		body.position = cfg["pos"]
		var col := CollisionShape3D.new()
		col.shape = cfg["shape"]
		body.add_child(col)
		add_child(body)
```

`play_area_half_extent` keeps its existing declared type/name (`var play_area_half_extent: float = PERIMETER_HALF` at the top) — just remove the `PERIMETER_HALF` constant (it no longer exists) and initialize the var to `0.0` instead:
```gdscript
var play_area_half_extent: float = 0.0
```

- [ ] **Step 4: Vehicle spawn via `RouteGenerator.pick_start_node`, deferred (avoids an init-order race with `vehicle.gd`'s own `_ready()`)**

`vehicle.gd`'s `_ready()` treats whatever `global_position.y` currently holds as a small margin above ground and re-snaps to `_ground_height(x,z) + that margin` — it cannot be touched (closed list), so `Map`'s own teleport call must run strictly *after* `Vehicle._ready()` has already fired, or the margin gets added twice (vehicle launched into the sky). `call_deferred` guarantees this regardless of sibling `_ready()` order, matching the existing `_deferred_setup_ui` idiom already in this file.

Right after `graph.build(roads, controls)` / `graph.print_diagnostics()` (existing lines ~90-92), add:
```gdscript
	var spawn := RouteGenerator.pick_start_node(graph)
	if spawn.is_empty():
		push_warning("MapLoader: grafo sin nodos validos para spawn; el vehiculo queda en su posicion de escena")
	else:
		call_deferred("_deferred_position_vehicle", spawn)
```

Add the deferred function next to `_deferred_setup_ui`:
```gdscript
func _deferred_position_vehicle(spawn: Dictionary) -> void:
	if _vehicle == null:
		return
	var pos: Vector2 = spawn["pos"]
	_vehicle.teleport(Vector3(pos.x, 1.0, pos.y), spawn["yaw"])
	print("spawn elegido: nodo en (%.2f, %.2f), yaw=%.2f" % [pos.x, pos.y, spawn["yaw"]])
```

Remove the now-duplicate old `_vehicle` assignment further down (the original lines around "--- Reference to Vehicle for HUD ---"):
```gdscript
	# --- Reference to Vehicle for HUD ---
	_vehicle = get_node("../Vehicle") as VehicleBody3D
	if _vehicle == null:
		push_error("MapLoader: no se encontró Vehicle en ../Vehicle")
```
This whole block is deleted (the assignment now happens once, early, in Step 2).

- [ ] **Step 5: Headless verification against the Task-0 baseline**

Run:
```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tee /tmp/c3_after.log
```
Expected, comparing to the pre-phase baseline captured earlier in this session:
- `terreno 80x53, 8216 tris` — **identical** (terrain unaffected by this change).
- `RoadBuilder: 526 vías` / `BuildingBuilder: 4916 edificios` — **identical**.
- `[TrafficGraph] nodos:1493 aristas:1808 ...` — **identical**.
- NEW lines present: `mapa cargado: res://data/map.json (zone_id=z1_custom_...)`, `span: 1859.9 x 1055.9 m`, `spawn elegido: nodo en (X, Z), yaw=Y`, `vehículo teletransportado a (...)` (this last one is `vehicle.gd`'s own existing print, now firing from the deferred call instead of never firing at all).
- No `SCRIPT ERROR`, no `Invalid get index`, no stack traces.
- If anything mismatches (road/building/graph counts differ from baseline), stop — that means the map load itself broke, not just cosmetic spawn/perimeter changes.

---

### Task 6: `main.tscn` — remove hardcoded Vehicle transform, add `LoadingScreen`

**Files:** Modify `godot/scenes/main.tscn`. Depends on Task 7 existing first (needs `loading_screen.tscn`'s path), so do Task 7 before this step in execution even though it's numbered after here for narrative order — or simply come back to this task after Task 7 is done.

- [ ] **Step 1: Remove the Vehicle transform**

Change:
```
[node name="Vehicle" parent="." instance=ExtResource("4_vehicle")]
transform = Transform3D(0.232733, 0, 0.972541, 0, 1, 0, -0.972541, 0, 0.232733, -0.55, 1, -2.29)
```
to:
```
[node name="Vehicle" parent="." instance=ExtResource("4_vehicle")]
```
(No transform = identity; `map_loader.gd`'s deferred spawn repositions it before the player ever gets control — the menu is shown first with `input_enabled = false` regardless.)

- [ ] **Step 2: Add the `LoadingScreen` instance**

Add an `[ext_resource]` line near the top (after the `8_minimap` resource) and a node near the end (after `GameFlow`, so it draws on top — `CanvasLayer.layer` in the scene itself controls actual draw order regardless of node order, but keeping it last is conventional):
```
[ext_resource type="PackedScene" path="res://scenes/ui/loading_screen.tscn" id="9_loadingscreen"]
```
```
[node name="LoadingScreen" parent="." instance=ExtResource("9_loadingscreen")]
```

- [ ] **Step 3: Headless check**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -30`
Expected: same clean boot as Task 5's result, plus no missing-resource errors for the new `LoadingScreen` node.

---

### Task 7: `loading_screen.tscn` / `loading_screen.gd` (new)

**Files:** Create `godot/scenes/ui/loading_screen.tscn`, `godot/scripts/ui/loading_screen.gd`.

- [ ] **Step 1: `loading_screen.gd`**

```gdscript
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
```

- [ ] **Step 2: `loading_screen.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/loading_screen.gd" id="1_loadingscreen"]

[node name="LoadingScreen" type="CanvasLayer"]
layer = 200
script = ExtResource("1_loadingscreen")

[node name="Panel" type="Panel" parent="."]
anchor_right = 1.0
anchor_bottom = 1.0

[node name="Center" type="CenterContainer" parent="Panel"]
anchor_right = 1.0
anchor_bottom = 1.0

[node name="VBox" type="VBoxContainer" parent="Panel/Center"]
alignment = 1
theme_override_constants/separation = 12
custom_minimum_size = Vector2(360, 0)

[node name="NameLabel" type="Label" parent="Panel/Center/VBox"]
horizontal_alignment = 1
theme_override_font_sizes/font_size = 32
text = "Ciudad"

[node name="StatusLabel" type="Label" parent="Panel/Center/VBox"]
horizontal_alignment = 1
text = "Descargando..."

[node name="FlagsLabel" type="Label" parent="Panel/Center/VBox"]
horizontal_alignment = 1
autowrap_mode = 2

[node name="ProgressBar" type="ProgressBar" parent="Panel/Center/VBox"]
custom_minimum_size = Vector2(0, 24)
max_value = 100.0

[node name="AttributionLabel" type="Label" parent="Panel/Center/VBox"]
horizontal_alignment = 1
autowrap_mode = 2
```

- [ ] **Step 3: Headless check** (after Task 6 wires it into `main.tscn`)

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -30`
Expected: clean boot, no missing-node errors for `Panel/Center/VBox/...` paths (the `@onready` lookups in `loading_screen.gd` must resolve).

---

### Task 8: `game_ui.gd` / `game_ui.tscn` — "Ciudades" button + `CityPanel`

**Files:** Modify both.

- [ ] **Step 1: `game_ui.tscn` — add the button and the `CityPanel` (placeholder controls, default theme)**

Add inside `MenuPanel/Center/VBox`, right after `ModeButtons` and before `ExitButton`:
```
[node name="CitiesButton" type="Button" parent="MenuPanel/Center/VBox"]
text = "Ciudades"
```

Add a new top-level panel (sibling of `MenuPanel`/`PausePanel`/`ResultsPanel`), after `ResultsPanel`:
```
[node name="CityPanel" type="Panel" parent="."]
visible = false
anchor_right = 1.0
anchor_bottom = 1.0

[node name="Margin" type="MarginContainer" parent="CityPanel"]
anchor_right = 1.0
anchor_bottom = 1.0
theme_override_constants/margin_left = 40
theme_override_constants/margin_top = 40
theme_override_constants/margin_right = 40
theme_override_constants/margin_bottom = 40

[node name="VBox" type="VBoxContainer" parent="CityPanel/Margin"]
theme_override_constants/separation = 10

[node name="Title" type="Label" parent="CityPanel/Margin/VBox"]
horizontal_alignment = 1
text = "Ciudades"
theme_override_font_sizes/font_size = 32

[node name="OfflineLabel" type="Label" parent="CityPanel/Margin/VBox"]
visible = false
horizontal_alignment = 1
text = "Backend no disponible: solo biblioteca local"

[node name="SearchRow" type="HBoxContainer" parent="CityPanel/Margin/VBox"]

[node name="SearchField" type="LineEdit" parent="CityPanel/Margin/VBox/SearchRow"]
custom_minimum_size = Vector2(300, 0)
placeholder_text = "Buscar ciudad..."

[node name="SearchButton" type="Button" parent="CityPanel/Margin/VBox/SearchRow"]
text = "Buscar"

[node name="SizeSelect" type="OptionButton" parent="CityPanel/Margin/VBox/SearchRow"]

[node name="CandidatesList" type="VBoxContainer" parent="CityPanel/Margin/VBox"]
theme_override_constants/separation = 4

[node name="LibraryTitle" type="Label" parent="CityPanel/Margin/VBox"]
text = "Biblioteca local"
theme_override_font_sizes/font_size = 20

[node name="LibraryList" type="VBoxContainer" parent="CityPanel/Margin/VBox"]
theme_override_constants/separation = 4

[node name="BakingTitle" type="Label" parent="CityPanel/Margin/VBox"]
text = "Horneandose"
theme_override_font_sizes/font_size = 20

[node name="BakingList" type="VBoxContainer" parent="CityPanel/Margin/VBox"]
theme_override_constants/separation = 4

[node name="CatalogTitle" type="Label" parent="CityPanel/Margin/VBox"]
text = "Catalogo del backend"
theme_override_font_sizes/font_size = 20

[node name="CatalogList" type="VBoxContainer" parent="CityPanel/Margin/VBox"]
theme_override_constants/separation = 4

[node name="BackButton" type="Button" parent="CityPanel/Margin/VBox"]
text = "Volver"

[node name="Footer" type="Label" parent="CityPanel/Margin/VBox"]
horizontal_alignment = 1
text = "Búsqueda: © OpenStreetMap / Nominatim"
```

- [ ] **Step 2: `game_ui.gd` — signals, node refs, and panel logic**

Add new signals (after the existing 5):
```gdscript
signal city_panel_opened
signal city_panel_closed
signal city_search_requested(query: String)
signal city_new_requested(lat: float, lon: float, size: String, name: String)
signal city_local_selected(zone_id: String)
```

Add new `@onready` refs (after the existing results-panel ones):
```gdscript
@onready var _cities_button: Button = $MenuPanel/Center/VBox/CitiesButton
@onready var _city_panel: Panel = $CityPanel
@onready var _offline_label: Label = $CityPanel/Margin/VBox/OfflineLabel
@onready var _search_field: LineEdit = $CityPanel/Margin/VBox/SearchRow/SearchField
@onready var _search_button: Button = $CityPanel/Margin/VBox/SearchRow/SearchButton
@onready var _size_select: OptionButton = $CityPanel/Margin/VBox/SearchRow/SizeSelect
@onready var _candidates_list: VBoxContainer = $CityPanel/Margin/VBox/CandidatesList
@onready var _library_list: VBoxContainer = $CityPanel/Margin/VBox/LibraryList
@onready var _baking_list: VBoxContainer = $CityPanel/Margin/VBox/BakingList
@onready var _catalog_list: VBoxContainer = $CityPanel/Margin/VBox/CatalogList
@onready var _city_back_button: Button = $CityPanel/Margin/VBox/BackButton

var _pending_candidates: Array = []
```

In `_ready()`, after the existing 5 `.connect(...)` lines, add:
```gdscript
	_cities_button.pressed.connect(_on_cities_button_pressed)
	_search_button.pressed.connect(_on_search_pressed)
	_city_back_button.pressed.connect(_on_city_back_pressed)
	for size_id in ["S", "M", "L"]:
		_size_select.add_item(size_id)
	_size_select.select(1)  # M por defecto
```

Add the new handlers + public update API (end of file):
```gdscript
func _on_cities_button_pressed() -> void:
	hide_all()
	_city_panel.visible = true
	city_panel_opened.emit()


func _on_city_back_pressed() -> void:
	_city_panel.visible = false
	_menu_panel.visible = true
	city_panel_closed.emit()


func _on_search_pressed() -> void:
	var query := _search_field.text.strip_edges()
	if query != "":
		city_search_requested.emit(query)


func set_offline(is_offline: bool) -> void:
	_offline_label.visible = is_offline
	_search_button.disabled = is_offline


func show_geocode_results(results: Array) -> void:
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


func show_catalog(entries: Array) -> void:
	for child in _catalog_list.get_children():
		child.queue_free()
	for e in entries:
		var label := Label.new()
		label.text = "%s [%s] %s" % [str(e.get("name", "")), str(e.get("zone_size", "")), str(e.get("flags", []))]
		_catalog_list.add_child(label)
```

`hide_all()` also needs to close `CityPanel` (it's a new mutually-exclusive top-level panel):
```gdscript
func hide_all() -> void:
	_menu_panel.visible = false
	_pause_panel.visible = false
	_results_panel.visible = false
	_city_panel.visible = false
```

- [ ] **Step 2: Headless check**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 3 2>&1 | tail -30`
Expected: clean boot — every `@onready` path in `game_ui.gd` must resolve against the new `game_ui.tscn` structure (a typo here is the single most likely failure point in this task; the error would be `Node not found` at `_ready()`).

---

### Task 9: `game_flow.gd` — wire `CityClient` + `CityPanel` + `LoadingScreen`

**Files:** Modify `godot/scripts/game_flow.gd`.

- [ ] **Step 1: Add the `CityClient` child, `LoadingScreen` export, and city-panel wiring**

Add an export near the top (with the other `@export var ..._path: NodePath` lines):
```gdscript
@export var loading_screen_path: NodePath
```

Add instance vars (near `_minimap`):
```gdscript
var _city_client: CityClient
var _loading_screen: LoadingScreen
var _pending_city_name: String = ""
```

In `_ready()`, after the existing `_game_ui.*.connect(...)` block, add:
```gdscript
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
	_city_client.offline.connect(_on_city_client_offline)

	_game_ui.city_panel_opened.connect(_on_city_panel_opened)
	_game_ui.city_search_requested.connect(_on_city_search_requested)
	_game_ui.city_new_requested.connect(_on_city_new_requested)
	_game_ui.city_local_selected.connect(_on_city_local_selected)
```

Add the handlers (end of file):
```gdscript
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


func _on_city_new_requested(lat: float, lon: float, size: String, name: String) -> void:
	_pending_city_name = name
	_city_client.request_zone(lat, lon, size, name)


func _on_zone_requested(zone_id: String, status: String, queue_position: int) -> void:
	if status == "ready":
		_city_client.download_zone(zone_id)
		return
	_city_client.poll_zone(zone_id)
	_game_ui.show_baking_list([{"zone_id": zone_id, "name": _pending_city_name, "queue_position": queue_position}])


func _on_zone_progress(zone_id: String, stage: String) -> void:
	_game_ui.show_baking_list([{"zone_id": zone_id, "name": _pending_city_name, "stage": stage}])


func _on_zone_ready(zone_id: String, meta_summary: Dictionary) -> void:
	_pending_city_name = str(meta_summary.get("name", _pending_city_name))
	_loading_screen.show_downloading(_pending_city_name, meta_summary.get("stats", {}).get("flags", []))
	_city_client.download_zone(zone_id)


func _on_zone_failed(_zone_id: String, reason: String) -> void:
	print("[ciudades] generacion fallida: %s" % reason)
	_refresh_local_library()


func _on_zone_quota_exceeded(resets_at: String) -> void:
	print("[ciudades] cuota agotada, reinicia %s" % resets_at)


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
```

- [ ] **Step 2: Wire the new export in `main.tscn`'s `GameFlow` node**

Add to the existing `[node name="GameFlow" ...]` block:
```
loading_screen_path = NodePath("../LoadingScreen")
```

- [ ] **Step 3: Full headless boot + manual signal smoke test**

Run: `cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1 | tail -40`
Expected: clean boot, `[flow] INIT -> MENU` still appears, no `Node not found` (this is where a missing `loading_screen_path` wiring or a typo'd `@onready` path in `game_flow.gd` would surface — every `CityClient`/`LoadingScreen` reference is resolved during `_ready()`, which headless boot always executes).

---

### Task 10: Final full-suite regression + human checklist handoff

**No new files.** This closes the phase.

- [ ] **Step 1: Re-run every citygen/backend automated test (nothing in this phase should have touched Python, but confirm no accidental cross-contamination)**

```bash
cd data_pipeline && python -m unittest discover -p "test_*.py"
cd ../backend && python -m unittest discover -p "test_*.py"
```
Expected: `OK` (67 + 28 tests, same counts as end of Fase C-1/C-2).

- [ ] **Step 2: Final headless boot, full diagnostic capture**

```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1
```
Confirm every diagnostic line the phase's spec asks for is present: map path + `zone_id`, span, `spawn elegido`, `minimapa: bake_res=...`. (`loop objetivo`/`spacing` only print once a time-trial actually starts, which a 5-frame headless boot never reaches — that line is verified by the human during the manual checklist below, watching the console while playing.)

- [ ] **Step 3: Hand off the human checklist (backend from Fase C-2 running locally — `cd backend && python -m uvicorn app:app`)**

- F5 → menu → "Ciudades" → search a small municipality → request S → queue/stage shown without freezing the game (drive Jordán meanwhile).
- Once ready: select it → loading screen with bar + attribution → ends up driving in the new city, on a wide central street, with terrain, traffic and props working.
- Time trial in the new city: generates a route and works without touching any constant; the minimap matches the new city.
- Record in the new city + record in Jordán: coexist (different `best_times.cfg` sections); going back to Jordán → everything as before.
- Turn off the backend → "Ciudades" shows the offline notice, the local library still works, zero red errors.
- Cached local city: click-to-driving < 20s. ≥ 60 fps in both cities.

## Self-Review Notes

1. **Spec coverage:** item 1 (city_library/city_client per contract 5, map_loader variable path + schema validation + legacy fallback) → Tasks 3, 4, 5. Item 2 (perimeter from extent_m, derived spawn via extracted `pick_start_node`, structural formulas in time_trial/minimap, remove main.tscn hardcoded spawn) → Tasks 1, 2, 5, 6. Item 3 (CityPanel: search/candidates/size/library/baking/catalog, non-blocking request) → Tasks 8, 9. Item 4 (loading_screen contract, offline mode) → Tasks 7, 9. Diagnostics (map path, zone_id, spans, formulas, spawn key, bake res) → spread across Tasks 5, 2, 9 exactly where each value is computed. Every human checklist bullet → Task 10 Step 3.
2. **Placeholder scan:** none — every step is either complete code or an exact headless command with an expected signal.
3. **Type consistency:** `pick_start_node` return shape (`index`/`pos`/`yaw`) is identical between its definition (Task 1) and its two call sites (`route_generator.gd`'s own `generate()`, Task 1; `map_loader.gd`, Task 5). `CityClient` signal names/argument order match between their definition (Task 4) and every `.connect()` site (Task 9). `CityLibrary` static method names match between definition (Task 3) and all call sites (Tasks 5, 8, 9).
