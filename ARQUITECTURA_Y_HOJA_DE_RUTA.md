# Arquitectura y Hoja de Ruta — MVP "Ciudad Real Conducible"

**Rol de este documento:** decisión estructural final. El implementador (Claude Sonnet 5 vía Claude Code) NO toma decisiones de arquitectura; ejecuta lo aquí definido. Cualquier ambigüedad detectada durante implementación se resuelve consultando este documento; si no está cubierta, se anota como pregunta para el arquitecto, no se improvisa.

**Perfil del desarrollador humano:** sabe programar (general), cero experiencia previa en Unity/Unreal/Godot y en desarrollo de juegos. Revisa manualmente cada fase en el editor. Las estimaciones de tiempo asumen este perfil.

---

## 1. Decisión de motor: Godot 4.4 (GDScript)

### Justificación

| Criterio | Godot 4.4 | Unity 6 | Unreal 5 |
|---|---|---|---|
| Formato de escenas/assets | Texto plano legible (`.tscn`, `.tres`) — un agente de IA puede crear escenas completas por texto | YAML con GUIDs generados por el editor; frágil para edición por agentes | Binario (`.uasset`); Blueprints visuales, inviable para agente de texto |
| Costo | $0, licencia MIT, sin regalías nunca | Gratis bajo $200k ingresos/año, pero licencia sujeta a cambios (historial reciente lo demuestra) | 5% regalías sobre $1M+ (irrelevante al inicio, pero motor pesadísimo) |
| Publicar en Steam | Exportar binario Windows + subir con Steamworks. Trivial. GodotSteam (plugin gratuito) solo si luego quieres logros/overlay | Igual de viable | Igual de viable |
| Curva para principiante total | La más suave de las tres; GDScript es tipo Python | Media; C# + editor complejo | La más dura |
| Adecuación a low-poly/cel-shading | Excelente; shaders en lenguaje de texto propio, simple | Excelente pero sobredimensionado | Orientado a fotorrealismo; pelearías contra el motor |
| Generación procedural de mallas | API directa (`ArrayMesh`, `SurfaceTool`, `Geometry2D`) | Buena (`Mesh` API) | Posible pero más ceremonia (C++) |
| Conocimiento del motor en modelos de IA | Bueno y creciente (Godot 4 ya está bien representado) | El mayor | Bueno en C++, pobre en Blueprints |

**Riesgo aceptado:** Unity tiene más tutoriales y más presencia en datos de entrenamiento de los modelos. Se acepta porque la ventaja de "todo es texto" de Godot es estructuralmente decisiva para un flujo donde Sonnet no puede ver el viewport: en Godot, Sonnet puede escribir la escena entera, y tu verificación visual en el editor es el único paso humano. En Unity, muchos pasos requerirían que TÚ hicieras clics en el editor siguiendo instrucciones, multiplicando errores.

**Versión fijada:** Godot 4.4.x estable (descarga estándar, NO la versión .NET; usaremos GDScript puro para eliminar toolchain de C#). Renderer: **Forward+**.

**Lenguaje fijado:** GDScript. Razón: cero fricción de compilación, tipado opcional suficiente, y es el camino más documentado en Godot 4.

---

## 2. Decisión de pipeline de datos: custom (Overpass → JSON → Godot). Cesium descartado.

### Por qué NO Cesium (ni para Unity ni hipotéticamente)

1. **Problema equivocado:** Cesium hace streaming de 3D Tiles fotorrealistas con precisión geodésica global. Tu objetivo es una zona pequeña, estilizada, low-poly, generada una vez. No necesitas streaming ni globo terráqueo ni ECEF.
2. **Costo recurrente:** Cesium ion gratuito es solo para uso no comercial/evaluación; el tier comercial parte de ~149 USD/mes. Incompatible con "juego barato en Steam" y con tu restricción explícita de costos recurrentes.
3. **Estilo visual:** los tiles de Cesium (fotogrametría/OSM Buildings texturizado) pelean contra el cel-shading. Tendrías que re-procesar su salida, perdiendo la ventaja del plugin.
4. **Reutilización:** tu documento de concepto dice que el motor de generación ES el producto. Un pipeline propio sobre datos crudos de OSM es ese activo; Cesium sería una dependencia alquilada.

### Arquitectura del pipeline elegido

```
[Overpass API (OSM)] --HTTP--> [Python: fetch + limpieza + proyección]
                                        |
                                        v
                              [map.json  (esquema fijo, ver §5)]
                                        |
                                        v
[Godot: MapLoader.gd] -> [RoadBuilder.gd] + [BuildingBuilder.gd] -> escena jugable
```

**Decisión clave: la generación es OFFLINE (pre-generada), no en tiempo real.**
- El script Python se ejecuta una vez, produce `map.json`, y ese archivo se versiona en el repo.
- Godot construye las mallas al cargar la escena (en `_ready()`, unos segundos), no durante el gameplay.
- Razón: elimina de raíz los riesgos de rendimiento de generación en runtime, hace el pipeline 100% depurable (puedes inspeccionar el JSON con los ojos), y la visión de "escribe una ciudad y se genera" es una capa de UI futura sobre este mismo pipeline, no un requisito del MVP.

**Dependencias Python:** solo `requests`. Prohibido usar `osmnx` u otras librerías pesadas en el MVP (evita horas de instalación/depuración de geopandas para un principiante).

**Costo total del stack:** $0 recurrente. Overpass API pública es gratuita (con etiqueta de uso responsable, ver riesgos). Único costo del proyecto: $100 únicos de Steam Direct cuando publiques.

---

## 3. Zona geográfica del MVP (fijada)

**Jordán, Ibagué, Tolima, Colombia.**

> **Corrección (revisión post-entrega):** la zona original de este documento (Teusaquillo, Bogotá) se basó en una suposición incorrecta sobre la ubicación del desarrollador, inferida de la zona horaria y nunca confirmada. El desarrollador vive en Ibagué. Zona corregida a partir de un bbox exportado directamente de openstreetmap.org.

```
Bounding box (lat_sur, lon_oeste, lat_norte, lon_este):
  4.433220, -75.210321, 4.442772, -75.193563
```

- Dimensiones reales: ≈ 1.06 km (norte-sur) × 1.86 km (este-oeste) ≈ **1.96 km²**. Es más grande y menos cuadrada que la zona original de referencia (1.1×1.1 km ≈ 1.2 km²) — sigue siendo manejable sin chunking, pero es razonable esperar más edificios/vías que el rango original estimado en §6.3, y las estimaciones de horas de §8 deben leerse hacia el extremo "realista", no el "optimista". Si se prefiere una huella más cercana a la original, se puede recortar el borde este (acortar `lon_este`) antes de la Fase 1; no es obligatorio.
- **Terreno: pendiente de confirmar por el desarrollador.** Ibagué está en el piedemonte de la Cordillera Central y tiene relieve marcado en general; la asunción de "mundo plano en y=0" (§ siguiente) solo es válida si esta zona específica de Jordán es razonablemente plana. Verificar con vista de calle/terreno (Google Maps u otro) antes de la Fase 1. Si hay pendiente notable, avisar al arquitecto antes de escribir el pipeline: la simplificación de mundo plano tendría que reconsiderarse o aceptarse como una distorsión visual conocida.
- Cuadrícula vial regular con avenidas y calles residenciales (barrio planeado por etapas) → buen banco de pruebas de anchos de vía.
- Densamente mapeado en OSM (confirmado visualmente por el desarrollador en openstreetmap.org antes de fijar esta zona).
- El desarrollador vive en Ibagué: puede validar "reconocibilidad" de primera mano, que es exactamente la hipótesis del proyecto.

---

## 4. Sistema de coordenadas (fijado, sin ambigüedad)

- **Proyección:** plano tangente local equirectangular centrado en el centro del bbox. Para ~1 km la distorsión es < 0.01%, irrelevante.
- Constantes: `lat0 = 4.4380`, `lon0 = -75.2019` (centro del bbox).
- Fórmulas (aplicadas en Python, Godot recibe metros ya proyectados):
  ```
  x =  (lon - lon0) * 111320.0 * cos(radians(lat0))    # metros, este = +x
  z = -(lat - lat0) * 110540.0                          # metros, norte = -z
  ```
  El signo negativo en z es deliberado: en Godot, -Z es "adelante/norte" en convención estándar, y así el mapa no queda espejado visto desde arriba con la cámara por defecto.
- **Unidad del motor:** 1 unidad Godot = 1 metro. Siempre.
- **Y:** 0 = suelo. Calles se dibujan a y=0.05 (evita z-fighting con el plano del suelo). Edificios nacen en y=0.
- Con ±550 m de extensión máxima, precisión float32 sobra. No se necesita origin-shifting en el MVP.

---

## 5. Esquema del archivo intermedio `map.json` (contrato fijo entre Python y Godot)

```json
{
  "meta": {
    "source": "OpenStreetMap",
    "license": "ODbL 1.0",
    "attribution": "© OpenStreetMap contributors",
    "bbox": [4.433220, -75.210321, 4.442772, -75.193563],
    "origin": {"lat": 4.4380, "lon": -75.2019},
    "generated_at": "ISO-8601"
  },
  "roads": [
    {
      "id": 123456,
      "highway": "residential",
      "width": 6.0,
      "points": [[x1, z1], [x2, z2], ...]
    }
  ],
  "buildings": [
    {
      "id": 789012,
      "height": 9.6,
      "footprint": [[x1, z1], [x2, z2], ...]
    }
  ]
}
```

Reglas de producción del JSON (las aplica Python; Godot confía ciegamente en el JSON):

- **Vías incluidas** (tag `highway`): `motorway, trunk, primary, secondary, tertiary, residential, unclassified, service, living_street`. Todo lo demás (peatonales, ciclorrutas, footway, path, steps) se EXCLUYE en el MVP.
- **Ancho por tipo** (metros, calzada completa): motorway/trunk 14, primary 12, secondary 9, tertiary 8, residential 6, unclassified 6, living_street 5, service 4. Si OSM trae tag `width` numérico, se usa ese valor con tope [3, 20].
- **Altura de edificios:** si hay tag `height` numérico → usarlo (tope [3, 60]). Si no, `building:levels * 3.2`. Si tampoco, altura pseudoaleatoria determinista en [5, 12] sembrada con el id de OSM (`seed = id`), para que dos generaciones den el mismo resultado.
- **Huellas:** solo ways cerrados de `building=*`. Multipolígonos con agujeros (relaciones) se EXCLUYEN en el MVP (son <5% en esta zona). Huellas con menos de 3 vértices o auto-intersecciones evidentes se descartan silenciosamente con un contador en el log.
- **Recorte:** geometría se recorta suavemente: se incluye cualquier vía/edificio con al menos un punto dentro del bbox (sin clipping geométrico duro en el MVP; que sobresalga un poco del borde es aceptable).
- Coordenadas ya proyectadas a metros (§4), redondeadas a 2 decimales (centímetros) para mantener el JSON pequeño.

---

## 6. Riesgos técnicos y mitigaciones (decididas)

### 6.1 Conversión de coordenadas
Riesgo casi eliminado por diseño: proyección local plana sobre 1 km², mundo plano, 1 unidad = 1 m, fórmulas fijadas en §4 implementadas UNA sola vez en Python. Godot nunca ve lat/lon. Prueba de sanidad obligatoria en Fase 1: la distancia entre dos esquinas conocidas medida en el JSON debe coincidir ±2% con la medida en Google Maps.

### 6.2 Calidad y consistencia de datos OSM
- Alturas faltantes → regla determinista de §5 (nunca "inventar" en Godot; todo se resuelve en Python donde es inspeccionable).
- Geometría defectuosa (huellas degeneradas, vías de 1 punto) → descarte silencioso con contadores reportados al final del script (`descartados: N edificios, M vías`), para detectar si la zona tiene un problema masivo.
- Overpass API pública: tiene límites de cortesía (no SLA). Mitigación: el script guarda la **respuesta cruda en caché** (`data_pipeline/cache/overpass_raw.json`) y solo re-consulta si se pasa `--refresh`. En la práctica consultarás Overpass 2 o 3 veces en todo el proyecto. Endpoints alternativos si el principal falla: `overpass-api.de`, `overpass.kumi.systems`.

### 6.3 Rendimiento de generación y render
- Pre-generado offline (decisión de §2) elimina el riesgo de runtime en la ingesta.
- Construcción de mallas en `_ready()`: para ~1.2 km² esperamos del orden de 1.500–3.000 edificios y 300–600 segmentos de vía. Decisión: **una malla combinada por categoría** — todos los edificios en un solo `ArrayMesh` (una surface, un material), todas las calles en otro. Resultado: ~2–4 draw calls para toda la ciudad. Si la construcción en `_ready()` supera 10 s, se cachea la malla generada como `.res` (optimización de Fase 5, no antes).
- Colisiones: trimesh estático generado desde las mismas mallas (`create_trimesh_shape()`). Estático + un solo vehículo dinámico = carga trivial para el motor de física.

### 6.4 Licencia ODbL (OpenStreetMap) para uso comercial
- Vender el juego en Steam usando datos OSM está permitido. Obligación mínima e innegociable: atribución visible **"© OpenStreetMap contributors"** (a) en los créditos del juego, (b) en la página de Steam, y (c) en pantalla o menú accesible desde el mapa. Se implementa desde el MVP (Fase 5) para que nunca se olvide.
- El mundo 3D generado se considera generalmente "produced work" bajo ODbL (basta atribución). PERO el `map.json` que se distribuye dentro del juego es una base de datos derivada: la posición conservadora y simple es publicar el esquema y declarar que los datos extraídos están disponibles bajo ODbL (una línea en los créditos y un archivo `OSM_LICENSE.txt` junto al ejecutable). Costo: cero. Nota: esto es criterio de ingeniería informado, no asesoría legal; antes del lanzamiento comercial real conviene releer la guía oficial de la OSM Foundation.

### 6.5 Riesgo de flujo de trabajo (Sonnet no ve el viewport)
Mitigación estructural: cada fase termina con criterios de aceptación **visuales y binarios** que verifica el humano (§8), y el proyecto incluye desde Fase 0 una escena de depuración con cámara aérea libre (`debug_camera.tscn`) para que puedas inspeccionar el mapa completo sin necesitar el vehículo.

---

## 7. Estructura del repositorio (fijada)

```
ciudad-conducible/
├── ARQUITECTURA_Y_HOJA_DE_RUTA.md      (este documento)
├── ESPEC_SESION.md                      (se pega al inicio de cada sesión de Claude Code)
├── data_pipeline/
│   ├── generate_map.py        # único script: fetch (con caché) + limpieza + proyección + map.json
│   ├── cache/overpass_raw.json
│   └── output/map.json
└── godot/
    ├── project.godot
    ├── data/map.json          # copia del output del pipeline
    ├── scenes/
    │   ├── main.tscn          # escena raíz: suelo + MapLoader + vehículo + cámara
    │   ├── vehicle.tscn       # VehicleBody3D completo
    │   └── debug_camera.tscn  # cámara aérea libre (WASD+ratón) para inspección
    ├── scripts/
    │   ├── map_loader.gd      # lee JSON, orquesta builders, añade nodos a escena
    │   ├── road_builder.gd    # polilíneas -> cinta plana (ArrayMesh)
    │   ├── building_builder.gd# huellas -> prismas extruidos (ArrayMesh)
    │   ├── vehicle.gd         # control arcade sobre VehicleBody3D
    │   ├── camera_rig.gd      # tercera persona con SpringArm3D
    │   └── debug_camera.gd
    └── materials/
        ├── road.tres          # gris oscuro plano
        ├── building.tres      # paleta plana (3-4 tonos por hash del id)
        └── ground.tres        # verde-gris plano
```

Convenciones fijas: GDScript con tipado estático donde sea razonable (`var x: float`), nombres snake_case, un script = una responsabilidad, nada de autoloads salvo necesidad justificada (en el MVP: ninguno).

---

## 8. Hoja de ruta por fases

Formato de estimación: **horas de trabajo tuyo** (sesiones con Claude Code + verificación en editor), asumiendo principiante total en Godot con buena capacidad de programación general. Primera columna optimista si todo fluye; segunda, realista con tropiezos de aprendizaje.

### Fase 0 — Entorno y esqueleto (2–4 h | 4–8 h)
**Objetivo:** proyecto Godot abre, corre, y muestra un mundo vacío navegable.
**Crear:** `project.godot` (Forward+, ventana 1280×720), `main.tscn` (luz direccional, WorldEnvironment con cielo simple, suelo: `PlaneMesh` 1400×1400 m con `StaticBody3D` + `BoxShape3D` fino, material `ground.tres`), `debug_camera.tscn` + `debug_camera.gd` (vuelo libre: WASD + ratón + rueda para velocidad).
**Aceptación (tú, en editor):** F5 ejecuta sin errores; ves un plano verde-gris hasta el horizonte con cielo; vuelas con WASD/ratón fluidamente; consola sin errores rojos.
**Además:** instalar Godot 4.4, crear repo git, primer commit.

### Fase 1 — Pipeline de datos (3–5 h | 6–10 h)
**Objetivo:** `map.json` válido y verificado de la zona de Jordán, Ibagué.
**Crear:** `data_pipeline/generate_map.py` completo según §4 y §5, con caché y flags `--refresh` y `--stats`. La query Overpass exacta está en ESPEC_SESION.md.
**Aceptación (tú, en terminal):** el script corre y reporta estadísticas (nº vías por tipo, nº edificios, nº descartados); `map.json` existe y pesa entre 0.5 y 10 MB; abres el JSON y las coordenadas están en rango ±600; **prueba de sanidad:** eliges dos intersecciones que conozcas, calculas su distancia con los puntos del JSON y coincide ±2% con Google Maps.
**Bonus de verificación (muy recomendado, +30 min):** el script genera también `preview.svg` con las vías dibujadas en 2D — comparas visualmente contra el mapa real antes de tocar Godot.

### Fase 2 — Generación de calles (4–6 h | 8–14 h)
**Objetivo:** la red vial completa renderizada en 3D.
**Crear:** `map_loader.gd` (parsea JSON en `_ready()`, invoca builders), `road_builder.gd`: por cada vía, genera una cinta plana a y=0.05: para cada segmento de la polilínea, calcula el vector perpendicular en el plano XZ y desplaza ±width/2; en vértices interiores usa la bisectriz de los dos segmentos (miter simple, con tope de longitud 3× el semiancho para evitar puntas en giros cerrados). Intersecciones: **solapamiento simple** de cintas con el mismo material — decisión deliberada del MVP, visualmente aceptable en cel-flat, sin geometría de cruces. Todo en un `ArrayMesh` único con `SurfaceTool`, material `road.tres`.
**Aceptación (tú, con debug_camera):** vista aérea reconociblemente igual al mapa real de Jordán, Ibagué (compárala lado a lado con openstreetmap.org); avenidas visiblemente más anchas que calles residenciales; sin "mariposas" ni triángulos disparados al infinito; carga de escena < 10 s; ≥ 60 fps volando.

### Fase 3 — Edificios (3–5 h | 6–12 h)
**Objetivo:** manzanas llenas de bloques low-poly.
**Crear:** `building_builder.gd`: por cada huella, triangula el polígono con `Geometry2D.triangulate_polygon()` para la tapa superior, extruye paredes verticales de y=0 a y=height. Normales correctas (paredes hacia fuera: verificar orientación del polígono con área con signo y revertir si es horaria). Color por edificio: paleta fija de 4 tonos planos elegidos con `id % 4` (vía vertex colors en la malla única, un solo material).
**Aceptación (tú):** las manzanas se ven llenas y las calles despejadas (los edificios NO invaden las calzadas — si lo hacen masivamente, hay bug de proyección); alturas variadas plausibles (2–15 pisos); sin paredes negras/invertidas al rodearlos con la cámara; sigues ≥ 60 fps; siluetas de manzanas reconocibles vs. el mapa real.

### Fase 4 — Vehículo y cámara (4–6 h | 8–16 h)
**Objetivo:** conducir con sensación arcade digna.
**Crear:** `vehicle.tscn` con `VehicleBody3D` + 4 `VehicleWheel3D` + carrocería `BoxMesh` (4.2×1.6×1.8 m aprox.) — parámetros iniciales exactos fijados en ESPEC_SESION.md (masa 1200, engine_force hasta 2500, brake 40, steering máx 0.55 rad con reducción a alta velocidad, suspensión: travel 0.25, stiffness 45, damping 4.5). `vehicle.gd`: acelerar/frenar/reversa/girar con `Input` (WASD + flechas), freno de mano en Espacio, R reposiciona el coche derecho. `camera_rig.gd`: `SpringArm3D` (largo 6 m, pitch −12°) que sigue al vehículo con `lerp` de posición y rotación yaw suavizada.
**Aceptación (tú, jugando):** aceleras, frenas, giras y el coche responde en < 100 ms percibidos; puedes tomar una esquina de 90° a velocidad media sin volcar; la cámara nunca se mete dentro de edificios (el SpringArm colisiona y acorta); si vuelcas, R te recupera; conduces 3 minutos por la zona y "se siente como un juego", no como una demo técnica rota. Este criterio es subjetivo a propósito: ES la hipótesis del proyecto.
**Nota de contingencia (decidida ya):** si tras ajustar los parámetros dados el `VehicleBody3D` se siente incontrolable, la alternativa aprobada es un coche arcade por raycasts (RigidBody3D + 4 raycasts de suspensión). No se decide en sesión: se me consulta (al arquitecto) antes de cambiar de enfoque.

### Fase 5 — Colisiones, atribución y pulido (3–5 h | 6–10 h)
**Objetivo:** demo cerrada y honesta.
**Crear/modificar:** colisión trimesh para edificios (desde la malla combinada, `StaticBody3D` + `ConcavePolygonShape3D`); muros invisibles en el perímetro del bbox (4 `BoxShape3D`); pantalla de inicio mínima con título y texto "Datos del mapa © OpenStreetMap contributors (ODbL)"; `OSM_LICENSE.txt` en el proyecto; HUD mínimo (velocidad en km/h, un `Label`); toon shading básico opcional si el tiempo alcanza: material con banding de luz en 2–3 escalones vía shader simple (si no alcanza, los colores planos actuales ya cumplen el estilo).
**Aceptación (tú):** chocas contra cualquier edificio y el coche se detiene sin atravesarlo ni salir despedido; no puedes salir del área jugable; la atribución OSM es visible sin buscarla; export a Windows (`.exe`) corre en tu máquina fuera del editor a ≥ 60 fps; un amigo que conozca Jordán reconoce dónde está en < 1 minuto conduciendo.

### Total estimado (honesto, para tu perfil)
- **Optimista:** ~20–30 horas de tu trabajo.
- **Realista:** ~40–70 horas. A ritmo de 8–10 h/semana: **5–8 semanas**.
- El mayor consumidor de tiempo imprevisto para un principiante no será el código (lo escribe Sonnet) sino: aprender a moverte por el editor de Godot (resérvale 2–3 h de tutorial básico antes de Fase 0), interpretar errores de consola, y el tuning de la Fase 4 (la sensación de conducción se ajusta iterando, no se escribe bien a la primera).

---

## 9. Qué queda explícitamente FUERA del MVP (no negociable en sesiones)

Elevación/relieve, vegetación, mobiliario urbano, señalización, aceras como geometría separada, intersecciones modeladas, texturas, ciclo día/noche, tráfico, peatones, sonido (más allá de opcional motor básico), UI de selección de ciudad, multipolígonos de edificios, optimizaciones LOD/chunking, GodotSteam. Si Sonnet propone añadir cualquiera de estos "ya que estamos", la respuesta es no.
