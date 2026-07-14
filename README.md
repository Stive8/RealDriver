# Ciudad Conducible

Demo conducible de ciudades **reales**, generadas a partir de datos de OpenStreetMap y
renderizadas con estética *low-poly / cel-shading* en Godot. Manejas un coche por las calles
reales de un barrio, con tráfico vehicular gobernado por IA cinemática (seguimiento en carril,
intersecciones con reglas, semáforos, puentes/vías elevadas y reacción al jugador).

> **Zona empaquetada por defecto:** Jordán, Ibagué, Tolima, Colombia — un *bounding box*
> exportado directamente de openstreetmap.org. Toda la geometría (calles, edificios, agua,
> puentes, sentidos de circulación, semáforos) se deriva de datos OSM reales; **nada** está
> incrustado a mano en el código. Desde el bloque de ciudades (C-1–C-4) el juego ya no está
> atado a Jordán: cualquier ciudad se puede pedir, generar y jugar desde el menú "Ciudades"
> (backend propio + biblioteca local, ver más abajo).

Para instrucciones de ejecución, pipeline de datos, backend y exportación del `.exe`, ver
**[COMO_EJECUTAR.md](COMO_EJECUTAR.md)**. Para desplegar el backend en un VPS, ver
**[backend/DEPLOY.md](backend/DEPLOY.md)**.

---

## Qué hace

- **Pipeline offline (Python, `citygen`):** consulta la Overpass API de OSM y Open Topo Data
  (elevación), limpia y proyecta la geometría a coordenadas planas (1 unidad = 1 metro), calcula
  el terreno, excava el lecho de ríos/lagos, y emite un `map.json` versionado y validado
  (conectividad, densidad, tamaño de archivo). Funciona para **cualquier** punto del planeta, no
  solo Jordán.
- **Backend propio (`backend/`, FastAPI):** convierte el pipeline en un servicio compartido tipo
  "panadería": un jugador pide una ciudad (búsqueda de texto vía Nominatim o punto + tamaño), un
  worker la genera una sola vez y queda servida desde disco para siempre. Cola FIFO, cuotas
  diarias por cliente/IP, catálogo de ciudades ya listas.
- **Cliente con biblioteca de ciudades (Godot):** panel "Ciudades" para buscar, pedir la
  generación de una ciudad nueva o cargar una ya descargada localmente; pantalla de carga con
  progreso real y atribución. El mundo (perímetro, spawn, longitud de ruta, resolución del
  minimapa) se adapta a la ciudad cargada por fórmula, no por constantes fijas de Jordán.
- **Construcción en carga (Godot):** al abrir la escena, se generan por código las mallas de
  calles, edificios, **agua** (lagos/ríos) y **puentes/vías elevadas** (con rampas de
  aproximación y colisión independiente), el contorno *toon*, los props decorativos (árboles y
  autos estacionados) y el grafo de navegación del tráfico.
- **Conducción:** un `VehicleBody3D` con físicas de coche, cámara en tercera persona con
  `SpringArm3D`, y HUD de velocidad.
- **Tráfico con IA:** hasta 80 agentes cinemáticos que circulan por el grafo respetando
  sentidos únicos, mantienen distancia en fila, negocian intersecciones (prioridad por rango,
  FIFO en empate, semáforos por fases), **respetan capas** (una vía elevada y la calle que cruza
  por debajo no se ceden el paso entre sí) y **reaccionan al jugador** (frenan y esperan; nunca
  esquivan volanteando).

## Tecnologías

| Componente | Tecnología |
|---|---|
| Motor | **Godot 4.4.x** estable (build estándar, **no** .NET) · Renderer **Forward+** |
| Lenguaje del juego | **GDScript** (tipado estático donde es razonable) |
| Pipeline de datos | **Python 3.10+**, única dependencia externa: `requests` |
| Backend | **FastAPI** + **uvicorn** sobre **SQLite** (estado de zonas/cuotas), un solo hilo *worker* |
| Fuente de datos | **OpenStreetMap** vía **Overpass API** (geometría) y **Nominatim** (búsqueda de ciudades), ambas gratuitas · elevación vía **Open Topo Data** |
| Estilo visual | Shaders *toon* propios (`toon.gdshader`, `toon_car.gdshader`), contorno por
  *inverted hull*, mallas generadas proceduralmente (`ArrayMesh` / `SurfaceTool`) |

**Convenciones fijas del proyecto:** 1 unidad Godot = 1 metro, Y=0 = suelo, mundo plano,
`snake_case`, un script = una responsabilidad, sin *autoloads*.

## Estado del proyecto

Todos los bloques definidos hasta la fecha están implementados y verificados:

- **MVP (Fases 0–5):** pipeline de datos, carga, calles, edificios, props, vehículo + cámara.
- **Bloque visual (V-1–V-4):** cel-shading, contornos, ventanas, niebla/atmósfera.
- **Bloque de tráfico (T-0–T-4):** grafo de navegación, agentes, población y anillos,
  intersecciones con reglas, e interacción con el jugador. **Bloque cerrado.**
- **Bloque de ciudades (C-1–C-4):** `citygen` como librería reusable para cualquier zona del
  mundo, backend propio ("panadería" con cola/cuotas/catálogo), cliente Godot con biblioteca de
  ciudades y descarga dinámica, catálogo pre-sembrado de 10 ciudades reales de perfiles
  contrastantes, `DEPLOY.md` (runbook de despliegue) y `.exe` exportado y verificado fuera del
  editor. **Bloque cerrado.**
- **Retrofit de agua (W-1–W-4):** el pipeline extrae agua (`natural=water`, ríos/canales/
  arroyos) y excava el terreno bajo ella; el cliente renderiza lagos/ríos y construye puentes/
  vías elevadas con tablero, rampas de aproximación y colisión propia; el grafo de tráfico
  resuelve la altura por nodo (`node_y_resuelta`) y evita que vías de distinta capa (p. ej. un
  puente y la calle que cruza por debajo) se traten como una intersección compartida.
  **Bloque cerrado.**

Ampliaciones que quedan como sesiones futuras (tocan estructura): peatones, IA reactiva
avanzada (persecuciones), multicarril con `lanes`, cruces con simultaneidad, *pathfinding* con
destino (A*), animación/colisión de agua, multijugador, cuentas/pagos.

> ⚠️ **Pendiente antes de cualquier despliegue o lanzamiento público real** (no bloquea jugar en
> local ni seguir desarrollando): reemplazar el `USER_AGENT` placeholder de `backend/app.py` por
> un contacto real, y repasar el checklist legal ODbL/Nominatim/Overpass. Ambos documentados en
> [backend/DEPLOY.md](backend/DEPLOY.md).

## Ajustar la cantidad de vehículos

La densidad de tráfico se controla con **dos constantes** en
[`godot/scripts/traffic_manager.gd`](godot/scripts/traffic_manager.gd), en el bloque
`[TUNEO-ZONA]`:

| Línea | Constante | Valor actual | Efecto |
|---|---|---|---|
| **93** | `MAX_AGENTS` | `80` | Techo duro de autos simultáneos. El *pool* de cuerpos se dimensiona solo a este número al arrancar. |
| **94** | `DENSITY_DIVISOR` | `30.0` | Objetivo de población = `min(MAX_AGENTS, metros_de_vía_en_radio_B / DENSITY_DIVISOR)`. **Menor** divisor = más densidad. |

La población real es el **mínimo** de esos dos términos, así que para subir el número **conviene
tocar ambos**: si solo subes `MAX_AGENTS` pero la densidad (metros de vía cerca del jugador /
`DENSITY_DIVISOR`) queda por debajo, no se llenará el techo.

```gdscript
# godot/scripts/traffic_manager.gd
const MAX_AGENTS := 80          # línea 93  → sube esto para más autos
const DENSITY_DIVISOR := 30.0   # línea 94  → baja esto para que la densidad alcance el techo
```

> **Valores originales:** `MAX_AGENTS = 40` y `DENSITY_DIVISOR = 60.0`. La configuración actual
> **duplica** ambos efectos (techo ×2, densidad ×2).
>
> **Rendimiento:** el criterio del proyecto es ≥ 60 fps. Cuantos más agentes, más coste de
> simulación; si al subirlos baja de 60 fps, la degradación prevista es (1) *tick* del Anillo B
> más espaciado, (2) reducir `MAX_AGENTS`. Verifica con la [prueba headless](COMO_EJECUTAR.md#5-prueba-headless-verificar-sin-ventana)
> o en el editor tras cada cambio.

## Estructura del repositorio

```
ciudad-conducible/
├── README.md                     · este archivo
├── COMO_EJECUTAR.md              · ejecución, pipeline, backend y exportación
├── ARQUITECTURA_Y_HOJA_DE_RUTA.md· decisión estructural y hoja de ruta (referencia, MVP original)
├── ESPEC_SESION_BLOQUE_VISUAL.md · especificación del bloque visual (referencia)
├── docs/superpowers/plans/       · planes de implementación de cada fase (histórico, referencia)
│
├── data_pipeline/                · pipeline offline OSM → map.json, empaquetado como librería
│   ├── citygen/                  · librería reusable: zonas, fetch OSM/elevación, validación, build
│   │   ├── zones.py              · canonicalización de zonas (zone_id, bbox, proyección)
│   │   ├── fetch_osm.py          · query Overpass (vías, edificios, controles, agua)
│   │   ├── fetch_elevation.py    · grilla de terreno (Open Topo Data) + excavación bajo agua
│   │   ├── validate.py           · umbrales de conectividad/densidad/tamaño, flags
│   │   ├── build.py              · orquesta generate() y arma el meta v1.4
│   │   └── svg_preview.py        · vista cenital SVG
│   ├── generate_map.py           · CLI fina sobre citygen (Jordán legacy o cualquier zona)
│   ├── cache/                    · respuestas crudas cacheadas por zona (auto-invalida por query)
│   └── output/                   · map.json + preview.svg generados
│
├── backend/                      · servicio FastAPI ("panadería") — genera y sirve ciudades
│   ├── app.py                    · rutas v1 (geocode, zones, catálogo) + arranque del worker
│   ├── worker.py                 · hilo único que drena la cola y llama a citygen.generate
│   ├── store.py                  · esquema SQLite + CRUD (zonas, cuotas, cache de geocode)
│   ├── quotas.py                 · límite diario de generaciones frías por cliente/IP
│   ├── seed_catalog.py           · siembra en lote de un catálogo inicial (sin consumir cuota)
│   ├── seed_cities.txt           · lista de ciudades a pre-sembrar
│   ├── DEPLOY.md                 · runbook de despliegue VPS, escalación, checklist legal ODbL
│   └── storage/                  · (gitignored) app.db + cache + zones/<zone_id>/map.json
│
└── godot/                        · proyecto Godot 4.4
    ├── project.godot             · configuración (input, capas de física, etc.)
    ├── export_presets.cfg        · preset "Windows Desktop" → RealDriver.exe
    ├── data/map.json             · mapa empaquetado por defecto (Jordán; copiado por el pipeline)
    ├── scenes/                   · main.tscn · vehicle.tscn · traffic_car.tscn · debug_camera.tscn · ui/
    ├── scripts/                  · lógica GDScript (ver abajo)
    ├── shaders/                  · toon · toon_car · outline · windows
    └── materials/                · .tres que referencian los shaders (incluye water, road_deck_underside)
```

### Scripts principales (`godot/scripts/`)

| Script | Responsabilidad |
|---|---|
| `map_loader.gd` | Carga el `map.json` seleccionado (biblioteca de ciudades o `res://data/map.json` por defecto), construye calles/edificios/agua/props, instancia grafo y tráfico, HUD y splash con atribución OSM. |
| `road_builder.gd` / `building_builder.gd` | Generan las mallas de calzada (incl. puentes/vías elevadas con tablero y colisión propia) y edificios (con contorno *toon*). |
| `ribbon_util.gd` | Geometría compartida de "cinta" (offsets perpendiculares + *miter-join*) usada por calles y agua. |
| `water_builder.gd` | Genera las mallas de lagos/ríos (`water_areas`/`water_ways`) a partir del `map.json`. |
| `prop_scatter.gd` | Árboles y autos estacionados decorativos vía `MultiMesh`. |
| `vehicle.gd` | Físicas del coche del jugador (`VehicleBody3D`). |
| `camera_rig.gd` | Seguimiento suavizado de la cámara en tercera persona. |
| `debug_camera.gd` | Cámara libre de inspección (vuelo con WASD + ratón). |
| `traffic_graph.gd` | Construye el grafo de navegación desde `roads` (nodos, aristas, intersecciones, terminales), resuelve la altura por nodo sobre vías elevadas (`node_y_resuelta`) y clasifica cada cruce respetando la capa (`capa_efectiva`). |
| `traffic_manager.gd` | Gestor cinemático del tráfico: pool de agentes, integración, FSM, seguimiento, spawn/despawn, anillos A/B, sensor del jugador. |
| `intersection_controller.gd` | Un controlador por intersección: prioridad por rango / FIFO / semáforo, con reservas de disco interior. |
| `city_library.gd` | Biblioteca local de ciudades descargadas (`user://cities/`), selección persistida en `settings.cfg`. |
| `city_client.gd` | Cliente HTTP del backend: geocodifica, pide/consulta/descarga zonas, reporta progreso. |
| `game_flow.gd` / `ui/game_ui.gd` / `ui/loading_screen.gd` | Flujo del juego, panel "Ciudades" (buscar/pedir/seleccionar) y pantalla de carga con progreso real. |
| `modes/time_trial/route_generator.gd` + `time_trial_mode.gd` | Generan la ruta de contrarreloj y sus checkpoints, adaptados al tamaño real de la ciudad cargada. |
| `minimap/minimap.gd` | Minimapa, con resolución de *bake* adaptada al tamaño de la ciudad. |
| `best_times.gd` | Persistencia de mejores tiempos. |

## Datos y esquema (`map.json`, v1.4)

Generado por el pipeline (`citygen`) y versionado en el repo para la zona empaquetada por
defecto (Jordán); cualquier otra ciudad se genera bajo demanda vía el backend y se guarda en la
biblioteca local del cliente, con el mismo esquema. Campos:

- `meta`: fuente, licencia (ODbL 1.0), atribución, `bbox`, `origin` (lat/lon), `schema_version`,
  `name`, `zone_id`, `zone_size`, `elevation_source`, y `stats` (`span_x/z`, `extent_m`,
  `road_km`, `n_buildings`, `largest_component_pct`, `max_road_slope_pct`, `flags` —
  `sparse_buildings` / `steep` —, `n_bridges`, `n_tunnels`, `n_layered`, `n_links`,
  `n_water_areas`, `n_water_ways`).
- `roads[]`: `id`, `highway` (clase OSM, incluye `*_link`), `width`, **`oneway`** (`1` orden de
  `points`, `-1` inverso, `0` bidireccional), `points[]` (polilínea proyectada), y
  opcionalmente `layer` (entero, capa OSM) y `deck` (`"bridge"` | `"tunnel"`).
- `buildings[]`: `id`, `height`, `footprint[]` (polígono cerrado).
- `controls[]`: nodos de control OSM (`signals` / `stop` / `give_way`) con su posición.
- `water_areas[]`: `id`, `footprint[]` (lagos/embalses, polígono cerrado).
- `water_ways[]`: `id`, `kind`, `width`, `points[]` (ríos/canales/arroyos, polilínea).
- `terrain`: grilla de elevación (usada por `TerrainSampler`/`TerrainBuilder`); el agua excava
  esta grilla en el pipeline, antes de que Godot la vea.

El pipeline es **offline por diseño**: se corre una vez por zona (vía CLI o backend), produce un
`map.json`, y Godot solo lo lee. Así el rendimiento en tiempo de juego no depende de la
generación, y el JSON es inspeccionable a ojo. La validación (`citygen/validate.py`) rechaza con
una causa explícita cualquier zona con muy poca vía, un grafo fragmentado o demasiados
edificios — nunca degrada en silencio.

## Créditos y licencia de datos

Datos del mapa **© OpenStreetMap contributors**, bajo la **Open Database License (ODbL) 1.0**.
La atribución se muestra en la pantalla inicial del juego (splash), en el menú principal y en el
pie del panel "Ciudades" (que además atribuye la búsqueda a **Nominatim**), y se conserva en
`map.json → meta`. Cualquier build o captura debe mantener esta atribución visible. Antes de
cualquier lanzamiento público real, repasar el checklist legal en
[backend/DEPLOY.md](backend/DEPLOY.md).
