# Cómo ejecutar — Ciudad Conducible

Guía práctica para correr el proyecto, regenerar los datos del mapa y exportar el ejecutable.
Comandos pensados para **Windows + PowerShell**. Ver descripción general en
[README.md](README.md).

---

## 1. Requisitos

| Herramienta | Versión | Notas |
|---|---|---|
| **Godot** | 4.4.x estable, build estándar (**no** .NET) | Descargar de <https://godotengine.org/download>. |
| **Python** | 3.10 o superior | Solo para regenerar el mapa; **no** hace falta para jugar. |
| `requests` | — | Única dependencia Python: `pip install requests`. |

En esta máquina el editor de Godot está en:

```
%LOCALAPPDATA%\Programs\Godot\Godot_v4.4-stable_win64.exe          (con ventana)
%LOCALAPPDATA%\Programs\Godot\Godot_v4.4-stable_win64_console.exe  (imprime en consola)
```

> El `.exe` con sufijo `_console` es el mismo editor pero vuelca `print()`/errores a la
> terminal: úsalo para las pruebas *headless* de abajo.

---

## 2. Jugar (desde el editor)

1. Abre Godot y **importa** el proyecto: `Importar` → selecciona
   `ciudad-conducible/godot/project.godot`.
2. Pulsa **F5** (o el botón ▶ *Reproducir*). La primera vez tarda unos segundos en
   construir las mallas de calles y edificios.
3. Aparece la pantalla inicial con la atribución de OpenStreetMap. Pulsa **cualquier tecla**
   para empezar a conducir.

### Controles

**Coche (jugador):**

| Acción | Teclas |
|---|---|
| Acelerar | `W` / `↑` |
| Frenar / marcha atrás | `S` / `↓` |
| Girar izquierda | `A` / `←` |
| Girar derecha | `D` / `→` |
| Freno de mano | `Espacio` |
| Reiniciar posición | `R` |

**Depuración:**

| Acción | Tecla |
|---|---|
| Overlay del grafo de tráfico (aristas, sentidos, tipo de cada cruce) | `G` |

**Cámara libre de inspección** (`debug_camera`, para revisar la ciudad sin conducir): clic
derecho para capturar el ratón y mirar, `WASD` para desplazarte, `Q`/`E` para bajar/subir,
rueda del ratón para cambiar la velocidad, `Esc` para liberar el ratón.

---

## 3. Regenerar el mapa (pipeline de datos)

Solo si quieres volver a bajar los datos de OSM o cambiar la zona. El `map.json` ya está
versionado, así que **para jugar no necesitas correr esto**.

```powershell
cd ciudad-conducible\data_pipeline
pip install requests

# Usa la respuesta cacheada de Overpass (rápido, sin red) y muestra estadísticas:
python generate_map.py --stats

# Reconsulta Overpass en vivo (ignora la cache) — necesario tras cambiar la query o la zona:
python generate_map.py --refresh --stats

# Genera además output/preview.svg (vista cenital de calles y edificios):
python generate_map.py --svg
```

El script escribe `data_pipeline/output/map.json` y lo **copia** a `godot/data/map.json`
(que es el que carga el juego). `--stats` imprime los conteos reales de la zona: vías por
clase, distribución de sentidos (`oneway`), número de semáforos/stops, y descartes.

> **Cambiar de ciudad:** ajusta `BBOX`, `LAT0` y `LON0` al inicio de `generate_map.py` con un
> *bounding box* nuevo de openstreetmap.org y corre `--refresh`. Los parámetros de tráfico
> calibrados para la zona actual (marcados `[TUNEO-ZONA]` en `traffic_manager.gd`) deberían
> recalibrarse para otra densidad.

---

## 4. Prueba headless (verificar sin ventana)

Útil para confirmar que el proyecto compila y la simulación corre sin errores, sin abrir el
editor. `--quit-after N` cierra tras `N` *frames* (a 60 fps, 300 ≈ 5 s):

```powershell
cd ciudad-conducible\godot
& "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 720
```

Deberías ver en consola los conteos del grafo (`[TrafficGraph] ...`), la población de tráfico
(`[TrafficManager] activos 40 ...`) y **ningún** `ERROR:`/`SCRIPT ERROR:`.

---

## 5. Exportar el ejecutable (Windows)

El proyecto ya trae el preset **"Windows Desktop"** (`export_presets.cfg`), que produce
`RealDriver.exe`.

> **Estado en esta máquina (2026-07-10):**
> - ✅ Las *export templates* `4.4.stable` **ya están instaladas** (en
>   `%APPDATA%\Godot\export_templates\4.4.stable`).
> - ✅ Se corrigió un **BOM UTF-8** al inicio de `export_presets.cfg` que impedía que Godot
>   leyera el preset (el `ConfigFile` ahora lo parsea sin error).
> - ⚠️ Aun así, la exportación **por línea de comandos falla** con `Invalid export preset name`
>   (lista de presets vacía). Es un *bug* de la CLI *headless* de Godot 4.4: el comando de
>   export se dispara en `_fs_changed` **antes** de que el subsistema de exportación cargue los
>   presets. No es un problema del proyecto. **Solución: exportar desde el editor (Opción A).**

### Opción A — desde el editor (recomendada y fiable)

1. Abre el proyecto en Godot.
2. (Solo si en otra máquina faltan) **Editor → Administrar plantillas de exportación →
   Descargar e instalar** (versión `4.4.stable`).
3. Menú **Proyecto → Exportar…** → selecciona el preset **"Windows Desktop"** →
   **Exportar proyecto** → guarda `RealDriver.exe`.

   El editor carga el subsistema de exportación por completo antes de exportar, así que **no
   sufre el bug de la CLI** descrito arriba.

### Opción B — instalar plantillas por línea de comandos

```powershell
$ver  = "4.4.stable"
$dest = "$env:APPDATA\Godot\export_templates\$ver"
New-Item -ItemType Directory -Force $dest | Out-Null

# Descargar el paquete oficial de plantillas (.tpz es un zip):
$tpz = "$env:TEMP\godot_templates.zip"
Invoke-WebRequest `
  "https://github.com/godotengine/godot/releases/download/4.4-stable/Godot_v4.4-stable_export_templates.tpz" `
  -OutFile $tpz

# Descomprimir y copiar el contenido de la carpeta `templates/` al directorio de versión:
Expand-Archive $tpz "$env:TEMP\godot_templates" -Force
Copy-Item "$env:TEMP\godot_templates\templates\*" $dest -Recurse -Force
```

Tras instalarlas, se **intentaría** exportar por CLI así:

```powershell
cd ciudad-conducible\godot
& "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.4-stable_win64_console.exe" `
  --headless --path . --export-release "Windows Desktop" RealDriver.exe
```

> ⚠️ En Godot 4.4 esto **falla** con `Invalid export preset name` (lista vacía) aunque las
> plantillas estén instaladas y `export_presets.cfg` sea válido, por el bug de la CLI headless
> descrito arriba. **Usa la Opción A (editor).** La instalación de plantillas por CLI de esta
> Opción B sigue siendo útil para máquinas sin interfaz, pero la exportación en sí requiere el
> editor.

### Verificación del build

- El `.exe` corre **fuera del editor** a ≥ 60 fps con el tráfico activo.
- La **atribución de OpenStreetMap** sigue visible en la pantalla inicial.
- El estilo visual (cel-shading, contornos, niebla) se ve igual que en el editor.

---

## 6. Problemas comunes

| Síntoma | Causa / solución |
|---|---|
| `Invalid export preset name` al exportar por CLI | Bug de la CLI headless de Godot 4.4 (presets no cargados al disparar el export). Exporta desde el **editor** — ver §5, Opción A. Comprueba también que `export_presets.cfg` no tenga BOM. |
| El pipeline no conecta a Overpass | Servidor ocupado; el script reintenta con un endpoint alterno. Vuelve a correr, o usa la cache sin `--refresh`. |
| Al jugar no hay mapa / errores de `map.json` | Regenera con el pipeline (§3) o verifica que exista `godot/data/map.json`. |
| Un `class_name` nuevo no compila en headless | Abre una vez el proyecto en el editor (o corre `--editor --quit-after N`) para poblar la caché de clases globales, luego reintenta headless. |
