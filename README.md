# Ciudad Conducible

Demo conducible de una ciudad **real**, generada a partir de datos de OpenStreetMap y
renderizada con estética *low-poly / cel-shading* en Godot. Manejas un coche por las calles
reales de un barrio, con tráfico vehicular gobernado por IA cinemática (seguimiento en carril,
intersecciones con reglas y reacción al jugador).

> **Zona del MVP:** Jordán, Ibagué, Tolima, Colombia — un *bounding box* exportado
> directamente de openstreetmap.org. Toda la geometría (calles, edificios, sentidos de
> circulación, semáforos) se deriva de datos OSM reales de esa zona; **nada** está incrustado a
> mano en el código.

Para instrucciones de ejecución, pipeline de datos y exportación del `.exe`, ver
**[COMO_EJECUTAR.md](COMO_EJECUTAR.md)**.

---

## Qué hace

- **Pipeline offline (Python):** consulta la Overpass API de OSM, limpia y proyecta la
  geometría a coordenadas planas (1 unidad = 1 metro), y emite un `map.json` versionado.
- **Construcción en carga (Godot):** al abrir la escena, se generan por código las mallas de
  calles y edificios, el contorno *toon*, los props decorativos (árboles y autos estacionados)
  y el grafo de navegación del tráfico.
- **Conducción:** un `VehicleBody3D` con físicas de coche, cámara en tercera persona con
  `SpringArm3D`, y HUD de velocidad.
- **Tráfico con IA:** hasta 40 agentes cinemáticos que circulan por el grafo respetando
  sentidos únicos, mantienen distancia en fila, negocian intersecciones (prioridad por rango,
  FIFO en empate, semáforos por fases) y **reaccionan al jugador** (frenan y esperan; nunca
  esquivan volanteando).

## Tecnologías

| Componente | Tecnología |
|---|---|
| Motor | **Godot 4.4.x** estable (build estándar, **no** .NET) · Renderer **Forward+** |
| Lenguaje del juego | **GDScript** (tipado estático donde es razonable) |
| Pipeline de datos | **Python 3.10+**, única dependencia externa: `requests` |
| Fuente de datos | **OpenStreetMap** vía **Overpass API** (gratuita) |
| Estilo visual | Shaders *toon* propios (`toon.gdshader`, `toon_car.gdshader`), contorno por
  *inverted hull*, mallas generadas proceduralmente (`ArrayMesh` / `SurfaceTool`) |

**Convenciones fijas del proyecto:** 1 unidad Godot = 1 metro, Y=0 = suelo, mundo plano,
`snake_case`, un script = una responsabilidad, sin *autoloads*.

## Estado del proyecto

Todos los bloques definidos están implementados y verificados:

- **MVP (Fases 0–5):** pipeline de datos, carga, calles, edificios, props, vehículo + cámara.
- **Bloque visual (V-1–V-4):** cel-shading, contornos, ventanas, niebla/atmósfera.
- **Bloque de tráfico (T-0–T-4):** grafo de navegación, agentes, población y anillos,
  intersecciones con reglas, e interacción con el jugador. **Bloque cerrado.**

> ⚠️ **Único paso humano pendiente:** re-exportar el `.exe` de Windows. Requiere instalar las
> *export templates* de Godot 4.4 (no vienen con el proyecto). Ver
> [COMO_EJECUTAR.md → Exportar el ejecutable](COMO_EJECUTAR.md#exportar-el-ejecutable-windows).

Ampliaciones que quedan como sesiones futuras (tocan estructura): peatones, IA reactiva
avanzada (persecuciones), multicarril con `lanes`, cruces con simultaneidad y *pathfinding* con
destino (A*).

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
> más espaciado, (2) reducir `MAX_AGENTS`. Verifica con la [prueba headless](COMO_EJECUTAR.md#4-prueba-headless-verificar-sin-ventana)
> o en el editor tras cada cambio.

## Estructura del repositorio

```
ciudad-conducible/
├── README.md                     · este archivo
├── COMO_EJECUTAR.md              · ejecución, pipeline y exportación
├── ARQUITECTURA_Y_HOJA_DE_RUTA.md· decisión estructural y hoja de ruta (referencia)
├── ESPEC_SESION_BLOQUE_VISUAL.md · especificación del bloque visual (referencia)
│
├── data_pipeline/                · pipeline offline OSM → map.json
│   ├── generate_map.py           · script único (fetch + limpieza + proyección)
│   ├── cache/overpass_raw.json   · respuesta cruda de Overpass (cacheada)
│   └── output/                   · map.json + preview.svg generados
│
└── godot/                        · proyecto Godot 4.4
    ├── project.godot             · configuración (input, capas de física, etc.)
    ├── export_presets.cfg        · preset "Windows Desktop" → RealDriver.exe
    ├── data/map.json             · mapa que carga el juego (copiado por el pipeline)
    ├── scenes/                   · main.tscn · vehicle.tscn · traffic_car.tscn · debug_camera.tscn
    ├── scripts/                  · lógica GDScript (ver abajo)
    ├── shaders/                  · toon · toon_car · outline · windows
    └── materials/                · .tres que referencian los shaders
```

### Scripts principales (`godot/scripts/`)

| Script | Responsabilidad |
|---|---|
| `map_loader.gd` | Carga `map.json`, construye calles/edificios/props, instancia grafo y tráfico, HUD y splash con atribución OSM. |
| `road_builder.gd` / `building_builder.gd` | Generan las mallas de calzada y edificios (con contorno *toon*). |
| `prop_scatter.gd` | Árboles y autos estacionados decorativos vía `MultiMesh`. |
| `vehicle.gd` | Físicas del coche del jugador (`VehicleBody3D`). |
| `camera_rig.gd` | Seguimiento suavizado de la cámara en tercera persona. |
| `debug_camera.gd` | Cámara libre de inspección (vuelo con WASD + ratón). |
| `traffic_graph.gd` | Construye el grafo de navegación desde `roads` (nodos, aristas, intersecciones, terminales) y clasifica el controlador de cada cruce. |
| `traffic_manager.gd` | Gestor cinemático del tráfico: pool de agentes, integración, FSM, seguimiento, spawn/despawn, anillos A/B, sensor del jugador. |
| `intersection_controller.gd` | Un controlador por intersección: prioridad por rango / FIFO / semáforo, con reservas de disco interior. |

## Datos y esquema (`map.json`, v1.1)

Generado por el pipeline y versionado en el repo. Campos:

- `meta`: fuente, licencia (ODbL 1.0), atribución, `bbox`, `origin` (lat/lon), `schema_version`.
- `roads[]`: `id`, `highway` (clase OSM), `width`, **`oneway`** (`1` orden de `points`, `-1`
  inverso, `0` bidireccional), `points[]` (polilínea proyectada).
- `buildings[]`: `id`, `height`, `footprint[]` (polígono cerrado).
- `controls[]`: nodos de control OSM (`signals` / `stop` / `give_way`) con su posición.

El pipeline es **offline por diseño**: se corre una vez, produce `map.json`, y Godot solo lo
lee. Así el rendimiento en tiempo de juego no depende de la generación, y el JSON es inspeccionable a ojo.

## Créditos y licencia de datos

Datos del mapa **© OpenStreetMap contributors**, bajo la **Open Database License (ODbL) 1.0**.
La atribución se muestra en la pantalla inicial del juego (splash) y se conserva en
`map.json → meta`. Cualquier build o captura debe mantener esta atribución visible.
