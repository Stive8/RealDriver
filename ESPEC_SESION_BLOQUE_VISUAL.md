# ESPEC_SESION_BLOQUE_VISUAL — Contexto fijo para Claude Code (Sonnet 5)

> **Instrucciones de uso (humano):** pega este documento completo al inicio de CADA sesión de Claude Code, seguido de una línea final: "Ejecuta la Fase V-N". No pegues el documento de arquitectura ni el ESPEC_SESION del MVP; este archivo es autosuficiente para implementar el bloque visual.
>
> **Requisito previo:** las 5 fases del MVP (0–5) ya están completas y aceptadas. Este bloque parte de ese proyecto funcional y solo mejora su apariencia y ambiente. No es un proyecto nuevo.

---

## Tu rol y tus límites (Sonnet, lee esto primero)

Eres el implementador. Las decisiones estructurales ya están tomadas y son inamovibles en esta sesión:

1. **No cambies** motor, versión, lenguaje, estructura de carpetas, esquema de `map.json`, sistema de coordenadas, ni el alcance de la fase. Este bloque es **puramente visual/ambiental**: NO toca la generación de datos (`generate_map.py`), NO toca la física del vehículo (`vehicle.gd`), NO toca la lógica de cámara salvo lo que una fase indique explícitamente.
2. **No añadas** features fuera de la fase actual, aunque parezcan fáciles ("ya que estamos" está prohibido). **Explícitamente fuera de este bloque completo:** tráfico con IA o autos en movimiento, relieve/elevación (el mundo sigue plano en y=0), pathfinding, colisión nueva sobre vegetación o autos decorativos, LOD, sonido, modos de juego, UI de ciudades, cualquier cambio al pipeline de Python.
3. Si encuentras una ambigüedad real que bloquea la implementación, elige la opción MÁS SIMPLE que cumpla los criterios de aceptación, y déjala anotada en un comentario `# DECISION_PENDIENTE:` para revisión del arquitecto.
4. **No puedes ver el viewport 3D.** El humano verificará visualmente. Tu obligación: código que compile sin errores, `print()` de diagnóstico en puntos clave (nº de elementos generados, tiempos), y explicar al humano exactamente qué debería ver y cómo comprobarlo.
5. Al terminar la fase: lista de archivos creados/modificados + checklist de aceptación para el humano + commit sugerido.
6. **Rendimiento es criterio de aceptación en todas las fases:** nada de este bloque puede bajar el framerate por debajo de 60 fps en la zona de Jordán. Si una fase lo hace, repórtalo en vez de continuar.

## Stack fijo

- **Godot 4.4.x estable (build estándar, NO .NET). Renderer: Forward+. Lenguaje: GDScript** con tipado estático donde sea razonable.
- 1 unidad Godot = 1 metro. Y=0 es el suelo. Mundo plano (sin elevación).
- Convenciones: snake_case, un script = una responsabilidad, sin autoloads.
- Shaders: usar el lenguaje de shaders de Godot (`.gdshader`), no `VisualShader`. Toon vía `shader_type spatial;` con `light()` custom o rampa de `NdotL` cuantizada.

## Estructura del repo (partir de la existente; añadir solo lo indicado)

```
ciudad-conducible/godot/
├── scenes/     main.tscn · vehicle.tscn · debug_camera.tscn
├── scripts/    map_loader.gd · road_builder.gd · building_builder.gd ·
│               vehicle.gd · camera_rig.gd · debug_camera.gd
│               (+ prop_scatter.gd en Fase V-3)
├── materials/  road.tres · building.tres · ground.tres
└── shaders/    (NUEVA carpeta) toon.gdshader (+ windows.gdshader en V-2)
```

## Contrato de datos (inamovible)

`map.json` NO cambia y NO se regenera en este bloque. Se leen los mismos campos que ya produce el MVP:
- `roads[]`: `id`, `highway`, `width`, `points[]` (metros).
- `buildings[]`: `id`, `height`, `footprint[]` (metros).

Toda decisión visual (color, ventanas, dónde poner árboles) se deriva de estos campos ya existentes. Si una fase necesitara un dato que no está en `map.json`, NO modifiques el pipeline: derívalo geométricamente en Godot o repórtalo como `DECISION_PENDIENTE`.

---

## FASES (implementar solo la solicitada)

### FASE V-1 — Toon shader global
**Objetivo:** dar identidad caricaturesca coherente a todo el mundo con un sombreado en escalones, sin cambiar geometría.

- Crear `shaders/toon.gdshader` (`shader_type spatial;`): iluminación difusa cuantizada en **3 escalones** (sombra / medio / luz) a partir del producto `NdotL` de la `DirectionalLight3D` existente; borde de escalón suave (`smoothstep` estrecho, no duro, para evitar aliasing). Respetar el `ALBEDO` entrante (para que funcione tanto con color liso como con vertex colors). Specular apagado o mínimo. Sin outline en esta fase (el contorno negro se evalúa aparte más abajo).
- Aplicar el shader a los tres materiales existentes creando variantes que lo usen: `building.tres`, `road.tres`, `ground.tres` deben pasar a usar `toon.gdshader` conservando su albedo/vertex-color actuales. `building.tres` debe mantener `vertex_color_use_as_albedo` equivalente dentro del shader (leer `COLOR`).
- Parámetros expуestos como uniforms con defaults sensatos: `shadow_tint` (color, default un gris-azulado suave), `steps` fijo en 3 (no exponer como editable arbitrario), `light_boost` (float, default 1.0).
- **Outline (opcional dentro de esta fase, solo si lo anterior quedó aceptado):** contorno negro fino por método de "inverted hull" en un segundo pase SOLO sobre edificios, grosor ~0.03 m. Si complica o baja fps, omitir y anotarlo — el toon sin outline ya cumple el objetivo.

**Diagnóstico:** `print` del nº de materiales migrados al shader.
**Checklist humano (F5 + debug_camera):**
- Todo el mundo (suelo, calles, edificios) tiene sombreado en bandas claras, no degradado liso.
- Las caras de los edificios que miran al sol se ven claramente más claras que las opuestas, en escalones.
- Los colores de edificios de la Fase 3 (la paleta de 4 tonos) siguen distinguiéndose.
- ≥ 60 fps. Sin materiales rosados/errores de shader (que saldrían como magenta).

### FASE V-2 — Fachadas de edificios (color por altura + ventanas fingidas)
**Objetivo:** que los bloques dejen de leerse como cajas lisas y parezcan edificios, sin geometría nueva.

- **Color por altura:** en `building_builder.gd`, además del índice `id % 4` actual, modular el color base según `height`: edificios bajos (< 12 m) → paleta cálida residencial existente; medios (12–28 m) → tonos neutros; altos (> 28 m) → grises/azulados tipo oficina/vidrio. Mantener determinismo (mismo edificio → mismo color siempre). Seguir usando vertex colors; NO añadir materiales por-edificio.
- **Ventanas fingidas por shader:** crear `shaders/windows.gdshader` que dibuje una grilla regular de ventanas sobre las **paredes** (no la tapa) usando coordenadas de mundo o UV procedural: filas cada ~3.2 m (un piso), columnas cada ~2.5 m. Ventana = rectángulo más oscuro/reflectante dentro de la celda, con margen. La grilla debe alinearse a y=0 para que las filas coincidan con "pisos" plausibles. Combinar con el toon de V-1 (las ventanas respetan el mismo sombreado en escalones).
- Aplicar `windows.gdshader` solo a las paredes de edificios. La tapa superior conserva el material toon liso.
- Uniforms: `window_color`, `frame_ratio` (margen de la celda), `floor_height` (default 3.2). Defaults que se vean bien sin tocar nada.

**Diagnóstico:** `print` de rangos de altura encontrados (min/max/nº por franja).
**Checklist humano:**
- Los edificios altos se ven visiblemente distintos (más "oficina") que los bajos residenciales.
- Las paredes muestran una grilla de ventanas regular y alineada horizontalmente; no flotan ni se cortan raro en las esquinas.
- Las ventanas siguen el mismo estilo toon (no rompen la coherencia de V-1).
- Manzanas siguen reconocibles; ≥ 60 fps.

### FASE V-3 — Vegetación y autos decorativos (props estáticos)
**Objetivo:** sensación de "lugar habitado" sembrando objetos low-poly. **Todo es decorativo y SIN colisión** (el jugador y la cámara los atraviesan; se acepta explícitamente).

- Crear `scripts/prop_scatter.gd` (`class_name PropScatter`, método estático `scatter(roads: Array, buildings: Array) -> Node3D`) que devuelve un `Node3D` con todos los props como hijos, instanciado desde `map_loader.gd` después de calles y edificios.
- **Árboles:** modelo low-poly mínimo generado por código (tronco = `CylinderMesh` corto marrón; copa = 1–2 `SphereMesh` o `PrismMesh` verdes facetados) o una escena `tree.tscn` simple. Sembrarlos de forma **determinista** (`random.Random` sembrado con un hash de la posición, no aleatorio en cada arranque) a lo largo de los bordes de vías `residential`/`living_street`, separados ~15–20 m, con un pequeño offset lateral fuera de la calzada. NO dentro de huellas de edificios (descartar posiciones que caigan dentro de un footprint).
- **Autos estacionados:** cajas low-poly con ruedas simplificadas (reusar proporciones de la carrocería del `vehicle.tscn`, sin física), color de una paleta fija por hash de posición. Colocarlos paralelos y pegados al borde de algunas vías (1 de cada ~4 tramos, determinista). Nunca sobre la calzada central ni encima de un árbol.
- Combinar todos los árboles del mismo tipo en el menor nº de mallas posible (usar `MultiMeshInstance3D` para árboles y otro para autos) para no matar el framerate. Esto es obligatorio, no opcional.
- Todo usa el `toon.gdshader` de V-1 para mantener coherencia.

**Diagnóstico:** `print("%d árboles, %d autos decorativos, %d ms" % [...])`.
**Checklist humano:**
- Hay árboles a los lados de las calles residenciales, sin invadir la calzada ni aparecer dentro de edificios.
- Hay autos estacionados en algunas orillas, plausibles, sin flotar ni encimarse.
- Todo comparte el estilo toon; nada se ve fuera de lugar respecto a V-1/V-2.
- La carga sigue < 10 s y se mantiene ≥ 60 fps (aquí es donde más riesgo hay: si baja, reportar y revisar el uso de MultiMesh antes de seguir).

### FASE V-4 — Ambiente y pulido final
**Objetivo:** cerrar el look con luz y aire, y dejar el bloque listo para exportar.

- **Cielo y luz:** ajustar el `WorldEnvironment` existente: un `ProceduralSkyMaterial` con horizonte cálido suave (media mañana), color de sol coherente con la `DirectionalLight3D`. Añadir niebla de distancia sutil (`fog_enabled`, densidad baja) para dar profundidad y disimular el borde del mundo. Sin ciclo día/noche (fuera de alcance).
- **Ambient / GI barato:** subir la iluminación ambiental para que las caras en sombra no queden negras planas; que la sombra del toon tenga color, no negro puro. Nada de `VoxelGI`/`SDFGI` (caros); basta ambient del environment.
- **Color grading suave:** ligera saturación/contraste vía `Environment` (`adjustment_enabled`) para reforzar el look caricaturesco. Sutil, no exagerado.
- **Re-exportar:** regenerar el `.exe` de prueba (preset Windows Desktop ya existente de la Fase 5) e incluir la nueva carpeta `shaders/` en el export. Verificar que la atribución OSM de la Fase 5 sigue visible.

**Checklist humano:**
- El conjunto se ve como una escena coherente y "con vida", no como piezas sueltas.
- Las sombras tienen color, no son manchas negras.
- La niebla suaviza el borde del mundo sin tapar la conducción cercana.
- El `.exe` corre fuera del editor, muestra la atribución OSM, y se mantiene ≥ 60 fps.

---

## Nota de cierre para el humano

Este bloque es puramente estético: si al terminar V-4 el juego se ve como querías, el siguiente salto natural (tráfico con IA, un modo contrarreloj, o relieve real) ya NO es "una fase más" sobre este documento — cada uno de esos toca estructura y merece su propia sesión de arquitectura con el modelo más capaz antes de volver a Sonnet.
