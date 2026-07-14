# Cómo ejecutar — Ciudad Conducible

Guía práctica para correr el proyecto, jugar con otras ciudades (backend local), regenerar los
datos del mapa y exportar el ejecutable. Comandos pensados para **Windows + PowerShell**. Ver
descripción general en [README.md](README.md).

---

## 1. Requisitos

| Herramienta | Versión | Notas |
|---|---|---|
| **Godot** | 4.4.x estable, build estándar (**no** .NET) | Descargar de <https://godotengine.org/download>. |
| **Python** | 3.10 o superior | Para regenerar el mapa o correr el backend; **no** hace falta solo para jugar con Jordán (ya viene empaquetado). |
| `requests` | — | Única dependencia del pipeline: `pip install requests`. |
| `fastapi`, `uvicorn` | — | Solo si vas a correr el backend local para pedir/descargar **otras** ciudades: `pip install -r backend/requirements.txt`. |

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

## 3. Jugar con otras ciudades (backend local)

Por defecto el juego arranca con Jordán, empaquetado en `godot/data/map.json` — esto **no**
requiere backend ni Python. Para buscar, pedir la generación o descargar **cualquier otra
ciudad real** desde el menú "Ciudades", necesitas el backend corriendo localmente:

```powershell
cd ciudad-conducible\backend
pip install -r requirements.txt
python -m uvicorn app:app --port 8000
```

El cliente Godot apunta por defecto a `http://127.0.0.1:8000` (constante `DEFAULT_BACKEND_URL`
en `city_library.gd`; configurable en `user://settings.cfg`, clave `backend_url`). Con el
backend arriba:

1. En el menú principal, abre el panel **"Ciudades"**.
2. Busca una ciudad por nombre (geocodifica vía Nominatim) o pide un punto nuevo (lat/lon +
   tamaño S/M/L).
3. Si la ciudad no existe aún, el backend la encola y la genera (puede tardar 1-2 min según el
   tamaño — barra de progreso real); si ya está lista, se descarga directo.
4. Selecciona cualquier ciudad ya descargada en tu biblioteca local
   (`user://cities/<zone_id>/map.json`) para cargarla sin necesitar el backend de nuevo.

**Cuotas:** 3 generaciones "en frío" por día por cliente/IP (protege la cuota gratuita de
Overpass/Open Topo Data); descargar una ciudad ya lista nunca consume cuota. Si el backend está
apagado o no responde, el panel avisa y solo queda disponible la biblioteca local — Jordán
siempre funciona sin backend.

> Para desplegar el backend en un servidor real (no solo en tu máquina), ver
> [backend/DEPLOY.md](backend/DEPLOY.md) — incluye systemd, reverse proxy, backups y umbrales
> de escalación.

---

## 4. Regenerar el mapa o generar una ciudad nueva (pipeline `citygen`)

Solo si quieres volver a bajar los datos de OSM, regenerar Jordán, o generar una ciudad nueva
**sin pasar por el backend** (p. ej. para inspeccionarla con `--svg` antes de sembrarla). El
`map.json` de Jordán ya está versionado, así que **para jugar no necesitas correr esto**.

```powershell
cd ciudad-conducible\data_pipeline
pip install requests

# Regenerar Jordán con su bbox histórico (usa cache, rápido, sin red) y ver estadísticas:
python generate_map.py --legacy-jordan --stats

# Reconsultar Overpass en vivo para Jordán (ignora cache) — tras cambiar la query:
python generate_map.py --legacy-jordan --refresh --stats

# Generar una ciudad nueva por punto + tamaño (S=1.5km, M=2.5km, L=3.5km de lado):
python generate_map.py --lat 4.60 --lon -74.08 --size M --name "Bogotá" --stats --svg
```

`--legacy-jordan` o `--lat`/`--lon` (+ `--name`) son mutuamente necesarios — el script exige uno
de los dos. El script escribe siempre `data_pipeline/output/map.json`; solo con
`--legacy-jordan` además lo **copia** a `godot/data/map.json` (el que carga el juego por
defecto). Para una ciudad nueva, el `map.json` generado se puede copiar a mano a
`user://cities/<zone_id>/map.json` (mismo mecanismo que usa el backend) o, más simple, pedirla
desde el panel "Ciudades" (§3). `--stats` imprime los conteos reales de la zona: vías por clase,
edificios, agua (áreas/vías excavadas), puentes/túneles/capas, y descartes. `--svg` genera
además `output/preview.svg` (vista cenital) para comparar visualmente contra el mapa real antes
de usarla en Godot.

> Los parámetros de tráfico calibrados para Jordán (marcados `[TUNEO-ZONA]` en
> `traffic_manager.gd`) son fijos para todas las ciudades — no se recalibran por zona; el resto
> de constantes que sí dependen del tamaño de la ciudad (longitud de ruta, minimapa, spawn) se
> derivan por fórmula de `map.json → meta.stats` (Fase C-3), no hace falta tocarlas.

### Pre-sembrar un catálogo de ciudades

`backend/seed_catalog.py` genera en lote una lista de ciudades **directo** contra `citygen`
(sin pasar por `/v1/zones`, así nunca consume la cuota diaria de un jugador) y las deja listas
en el mismo `backend/storage/` que sirve el backend:

```powershell
cd ciudad-conducible\backend
python seed_catalog.py                      # usa seed_cities.txt (10 ciudades de ejemplo)
python seed_catalog.py ruta\a\otra_lista.txt # o una lista propia: nombre;lat;lon;S|M|L por línea
```

Es idempotente: una zona ya `ready` se omite. Útil antes de un despliegue, para que el catálogo
no arranque vacío.

---

## 5. Prueba headless (verificar sin ventana)

Útil para confirmar que el proyecto compila y la simulación corre sin errores, sin abrir el
editor. `--quit-after N` cierra tras `N` *frames* (a 60 fps, 300 ≈ 5 s):

```powershell
cd ciudad-conducible\godot
& "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 720
```

Deberías ver en consola los conteos del grafo (`[TrafficGraph] ...`), la población de tráfico
(`[TrafficManager] activos N ...`, hasta `MAX_AGENTS`) y **ningún** `ERROR:`/`SCRIPT ERROR:`.

---

## 6. Exportar el ejecutable (Windows)

El proyecto ya trae el preset **"Windows Desktop"** (`export_presets.cfg`), que produce
`RealDriver.exe`. Verificado de punta a punta en la Fase C-4: exporta por línea de comandos y
corre fuera del editor con Vulkan.

> **Estado verificado (2026-07-13):**
> - Las *export templates* `4.4.stable` deben estar instaladas (en
>   `%APPDATA%\Godot\export_templates\4.4.stable`) — ver más abajo si faltan.
> - `export_presets.cfg` no debe tener BOM UTF-8 al inicio (ya corregido en el repo) y su
>   `platform` debe ser exactamente `"Windows Desktop"`, **no** `"windows"` — con ese valor mal
>   puesto, tanto el editor como la CLI headless fallaban con `Invalid export preset name`
>   (lista de presets vacía). No era un bug de Godot: era el preset del repo mal configurado, ya
>   corregido en la Fase C-4. Si el error reaparece tras editar el preset a mano, es lo primero
>   a revisar.

### Opción A — por línea de comandos (headless, recomendada para automatizar)

```powershell
cd ciudad-conducible\godot
& "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.4-stable_win64_console.exe" `
  --headless --path . --export-release "Windows Desktop" ..\dist\RealDriver.exe
```

`dist/` está en `.gitignore` — el `.exe` exportado es un artefacto local, nunca se commitea.

### Opción B — desde el editor

1. Abre el proyecto en Godot.
2. (Solo si en otra máquina faltan) **Editor → Administrar plantillas de exportación →
   Descargar e instalar** (versión `4.4.stable`).
3. Menú **Proyecto → Exportar…** → selecciona el preset **"Windows Desktop"** →
   **Exportar proyecto** → guarda `RealDriver.exe`.

### Instalar las export templates por línea de comandos (si faltan)

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

### Verificación del build

- El `.exe` corre **fuera del editor** a ≥ 60 fps con el tráfico activo.
- La **atribución de OpenStreetMap** sigue visible en la pantalla inicial.
- El estilo visual (cel-shading, contornos, niebla) se ve igual que en el editor.
- Con el backend corriendo (§3) y una ciudad ya descargada en `user://cities/`, el flujo menú →
  Ciudades → seleccionar ciudad local también funciona fuera del editor.

---

## 7. Problemas comunes

| Síntoma | Causa / solución |
|---|---|
| `Invalid export preset name` al exportar (CLI o editor) | `export_presets.cfg` con BOM UTF-8, o `platform` distinto de `"Windows Desktop"` exacto. Ver §6. |
| El panel "Ciudades" dice que no hay conexión / offline | El backend no está corriendo o `backend_url` en `user://settings.cfg` apunta mal. Arranca el backend (§3) o usa solo la biblioteca local. |
| `429` / cuota agotada al pedir una ciudad nueva | Límite de 3 generaciones en frío/día por cliente o IP (`backend/quotas.py`). Espera al reinicio diario (UTC) o descarga una ciudad ya `ready` (no consume cuota). |
| El pipeline no conecta a Overpass | Servidor ocupado; el script reintenta con un endpoint alterno. Vuelve a correr, o usa la cache sin `--refresh`. |
| Al jugar no hay mapa / errores de `map.json` | Regenera Jordán con el pipeline (§4) o verifica que exista `godot/data/map.json`; para otra ciudad, revisa `user://cities/<zone_id>/map.json`. |
| Un `class_name` nuevo no compila en headless | Abre una vez el proyecto en el editor (o corre `--editor --quit-after N`) para poblar la caché de clases globales, luego reintenta headless. |
