# Fase C-4 — Pre-siembra, cumplimiento, validación de diversidad y export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. This phase is mostly ops/docs/integration-testing, not new pure logic — TDD applies only to Task 1's file-parsing function; the rest is real-backend runs and headless Godot verification.

**Goal:** Turn the finished pipeline (C-1) + backend (C-2) + client (C-3) into something demo-ready: a pre-seeded catalog of ~10 real cities, a deployment runbook with documented (not implemented) escalation thresholds, a verified ODbL compliance surface, a validation pass across 3 contrasting real cities, and an exported `.exe` proven to work outside the editor.

**Architecture:** `backend/seed_catalog.py` calls `citygen.generate()` directly (not through the public HTTP API) so seeding never burns player quota, but still writes into the exact same `backend/storage/{app.db,zones/}` the running backend serves from — so `/v1/catalog` picks up seeded cities with zero backend code changes. `DEPLOY.md` is pure documentation. The validation matrix and `.exe` export are executed and verified for real (Godot 4.4 headless + export templates are available in this environment), not just written up.

**Tech Stack:** Same as C-1/C-2 (Python stdlib + `requests`, `citygen`, backend's `store.py`). No new dependencies. Godot 4.4 `--headless --export-release` for the `.exe`.

## Global Constraints

- `citygen/` stays stdlib + `requests` only; `seed_catalog.py` lives in `backend/` and may only reuse what's already there (`store.py`) plus `citygen` — no new pip packages.
- One implementation of generation logic: `seed_catalog.py` calls `citygen.generate()`, never reimplements it.
- Seeding must respect "concurrency of generation = 1" — sequential, one zone at a time, same as `worker.py`.
- Seeding must be idempotent: a zone_id already `ready` in the backend DB is skipped, never regenerated (mirrors the whole block's core principle).
- `DEPLOY.md`'s "Escalación" section is **documentation only** — thresholds and options, zero implementation: Overpass mirror via Geofabrik extracts (>~200 cold gens/day), Open Topo Data self-host or AWS Terrain Tiles migration (>~900 elevation calls/day), the `terrain` contract stays intact regardless.
- Explicitly out of scope for this entire block (not just C-4): multiplayer, accounts, payments, LOD, world streaming, procedural infill for sparse zones, self-hosted mirrors as *code*.
- The 3-city validation matrix and the seed list are choices normally left to "the human" per spec — picked here pragmatically (diverse real cities, sizes chosen to keep generation time reasonable) and called out clearly in the final report so they can be swapped before any real production seeding.

## File Structure

```
backend/
├── seed_catalog.py       # NEW: batch seeder, citygen.generate() direct, writes to backend/storage
├── seed_cities.txt        # NEW: "name;lat;lon;size" per line, ~10 real cities
├── test_seed_catalog.py    # NEW: unit tests for the seed-file parser (the only pure logic here)
└── DEPLOY.md              # NEW: VPS deploy runbook + escalation thresholds + legal "antes de lanzar" checklist
```

No Godot files change in this phase — the three ODbL attribution surfaces (menu, CityPanel footer, loading screen) were already added in Fase C-3 and are verified present in Task 3, not re-implemented.

## Interfaces summary

- `seed_catalog.parse_seed_file(path: str) -> list[dict]` — each dict: `{name, lat, lon, size}`. Raises `ValueError` with the exact line number on a malformed line.
- `seed_catalog.seed(seed_file: str = DEFAULT_SEED_FILE) -> dict` — returns `{"sown": int, "failed": list[tuple[str, str]], "total_bytes": int}`, and prints the exact diagnostic line the spec requires: `"%d sembradas, %d fallidas (razones), %d MB totales"`.

---

### Task 1: `backend/seed_catalog.py` + `backend/seed_cities.txt`

**Files:**
- Create: `backend/seed_catalog.py`
- Create: `backend/seed_cities.txt`
- Test: `backend/test_seed_catalog.py`

**Interfaces:** see summary above. Consumes `citygen.ZoneSpec`, `citygen.generate`, `citygen.zones.resolve` (Fase C-1, unchanged by the concurrent water-feature work — verified: `citygen/__init__.py` still exports exactly `ZoneSpec, GenResult, generate`), and `store.init_db/get_zone/insert_zone_queued/mark_zone_ready/mark_zone_failed` (Fase C-2, unchanged).

- [ ] **Step 1: Write the failing test for the parser (the only pure/testable logic in this task)**

`backend/test_seed_catalog.py`:
```python
#!/usr/bin/env python3
import os
import tempfile
import unittest

import seed_catalog


class TestParseSeedFile(unittest.TestCase):
    def test_parses_valid_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "seed.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("Girardot;4.3057;-74.8087;S\nCartagena;10.3910;-75.4794;M\n")
            entries = seed_catalog.parse_seed_file(path)
        self.assertEqual(entries, [
            {"name": "Girardot", "lat": 4.3057, "lon": -74.8087, "size": "S"},
            {"name": "Cartagena", "lat": 10.3910, "lon": -75.4794, "size": "M"},
        ])

    def test_skips_blank_lines_and_comments(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "seed.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("# comentario\n\nGirardot;4.3057;-74.8087;S\n   \n")
            entries = seed_catalog.parse_seed_file(path)
        self.assertEqual(len(entries), 1)

    def test_malformed_line_raises_with_line_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "seed.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("Girardot;4.3057;-74.8087;S\nMalformada;solo_dos_campos\n")
            with self.assertRaises(ValueError) as ctx:
                seed_catalog.parse_seed_file(path)
        self.assertIn(":2:", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && python -m unittest test_seed_catalog -v`
Expected: `ModuleNotFoundError: No module named 'seed_catalog'`.

- [ ] **Step 3: Implement `backend/seed_catalog.py`**

```python
#!/usr/bin/env python3
"""Siembra en lote un catalogo inicial de ciudades (Fase C-4). Invoca citygen.generate()
DIRECTO (no pasa por /v1/zones), asi la siembra nunca consume la cuota diaria del
jugador -- pero escribe en el MISMO backend/storage que el backend real sirve, asi
que las ciudades sembradas aparecen en /v1/catalog sin tocar app.py/worker.py.
Respeta la cola: una zona a la vez (concurrencia de generacion = 1, igual que worker.py).
Idempotente: una zona_id ya 'ready' en la base se omite, nunca se regenera.

Uso: python seed_catalog.py [ruta/a/seed_cities.txt]  (default: seed_cities.txt junto a este script)
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data_pipeline"))
from citygen import ZoneSpec, generate  # noqa: E402
from citygen.zones import resolve  # noqa: E402

import store  # noqa: E402

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
STORAGE_DIR = os.path.join(BACKEND_DIR, "storage")
DB_PATH = os.path.join(STORAGE_DIR, "app.db")
CACHE_DIR = os.path.join(STORAGE_DIR, "cache")
ZONES_DIR = os.path.join(STORAGE_DIR, "zones")
DEFAULT_SEED_FILE = os.path.join(BACKEND_DIR, "seed_cities.txt")


def parse_seed_file(path: str) -> list:
    entries = []
    with open(path, "r", encoding="utf-8") as f:
        for line_no, raw_line in enumerate(f, start=1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(";")]
            if len(parts) != 4:
                raise ValueError(
                    f"{path}:{line_no}: se esperaban 4 campos 'nombre;lat;lon;size', vino {parts!r}"
                )
            name, lat, lon, size = parts
            entries.append({"name": name, "lat": float(lat), "lon": float(lon), "size": size})
    return entries


def seed(seed_file: str = DEFAULT_SEED_FILE) -> dict:
    os.makedirs(ZONES_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)
    store.init_db(DB_PATH)

    entries = parse_seed_file(seed_file)
    sown = 0
    failed = []
    total_bytes = 0

    for entry in entries:
        zone = ZoneSpec(name=entry["name"], size=entry["size"], lat=entry["lat"], lon=entry["lon"])
        resolved = resolve(zone)
        existing = store.get_zone(DB_PATH, resolved.zone_id)
        if existing is not None and existing["status"] == "ready":
            print(f"[{entry['name']}] ya lista ({resolved.zone_id}), se omite")
            sown += 1
            continue

        print(f"[{entry['name']}] generando ({resolved.zone_id})...")
        out_path = os.path.join(ZONES_DIR, resolved.zone_id, "map.json")
        t0 = time.time()
        result = generate(zone, CACHE_DIR, out_path)
        elapsed = time.time() - t0

        if existing is None:
            store.insert_zone_queued(DB_PATH, resolved.zone_id, entry["lat"], entry["lon"], entry["size"], entry["name"])

        if not result.ok:
            print(f"[{entry['name']}] FALLO ({elapsed:.0f}s): {result.reason}")
            store.mark_zone_failed(DB_PATH, resolved.zone_id, result.reason)
            failed.append((entry["name"], result.reason))
            continue

        size_bytes = result.diagnostics.get("size_bytes", 0)
        meta_summary = {"name": entry["name"], "zone_size": entry["size"], "stats": result.stats}
        store.mark_zone_ready(DB_PATH, resolved.zone_id, meta_summary)
        total_bytes += size_bytes
        sown += 1
        print(f"[{entry['name']}] listo ({elapsed:.0f}s, {size_bytes / (1024 * 1024):.1f} MB)")

    reasons = ", ".join(f"{name}:{reason}" for name, reason in failed) if failed else "ninguna"
    print(f"{sown} sembradas, {len(failed)} fallidas ({reasons}), {total_bytes / (1024 * 1024):.1f} MB totales")
    return {"sown": sown, "failed": failed, "total_bytes": total_bytes}


if __name__ == "__main__":
    seed(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SEED_FILE)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && python -m unittest test_seed_catalog -v`
Expected: `OK` (3 tests pass).

- [ ] **Step 5: Write `backend/seed_cities.txt`**

Ten real cities picked for geographic/profile diversity (small towns, one steep/mountain city, one likely-sparse-data remote city, sizes mixed S/M to keep total seeding time reasonable — the human can freely edit this file before any real production seeding):

```
# nombre;lat;lon;size -- catalogo de prueba C-4 (10 ciudades, perfiles variados)
Girardot, Colombia;4.3057;-74.8087;S
Popayan, Colombia;2.4448;-76.6147;S
Cartagena, Colombia;10.3910;-75.4794;M
Ronda, Espana;36.7213;-5.1636;S
Annecy, Francia;45.8992;6.1294;M
Bath, Reino Unido;51.3811;-2.3590;S
Cusco, Peru;-13.5320;-71.9675;S
Salzburgo, Austria;47.8095;13.0550;S
Ushuaia, Argentina;-54.8019;-68.3030;S
Reykjavik, Islandia;64.1466;-21.9426;S
```

- [ ] **Step 6: Commit**

```bash
git add backend/seed_catalog.py backend/seed_cities.txt backend/test_seed_catalog.py
git commit -m "feat(c-4): backend.seed_catalog - siembra en lote sin consumir cuota"
```

---

### Task 2: `backend/DEPLOY.md`

**Files:** Create `backend/DEPLOY.md`.

- [ ] **Step 1: Write the full deployment + escalation + legal-checklist document**

```markdown
# DEPLOY.md — Backend "panadería" en un VPS pequeño

## Requisitos
- VPS pequeño (1 vCPU / 1-2 GB RAM alcanza: la generación es CPU-ligera, el cuello
  de botella real es la latencia de red hacia Overpass/Open Topo Data).
- Python 3.10+, `pip install -r requirements.txt` (fastapi, uvicorn, requests).
- Puerto interno para uvicorn (ej. 8000) detrás de un reverse proxy (nginx/caddy)
  que termine TLS y exponga el dominio público.

## Variables de entorno (documentales — el código actual las lee con defaults;
## si se despliega tal cual, editar las constantes en `app.py` antes de arrancar)
| Variable | Dónde | Descripción |
|---|---|---|
| Puerto de uvicorn | flag `--port` al arrancar | interno, detrás del reverse proxy |
| Ruta de storage | `backend/storage/` (relativa al repo) | mover a un disco con espacio si crece mucho |
| Contacto del User-Agent | `app.py`, constante `USER_AGENT` | **reemplazar el placeholder actual antes de cualquier despliegue real** — Nominatim y Overpass exigen un User-Agent identificable con contacto real (email o URL) |

## systemd (ejemplo, `/etc/systemd/system/ciudad-conducible-backend.service`)
```ini
[Unit]
Description=Ciudad Conducible - backend panaderia
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/ciudad-conducible/backend
ExecStart=/opt/ciudad-conducible/backend/.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ciudad-conducible-backend
```

## Reverse proxy (ejemplo nginx, TLS vía certbot aparte)
```nginx
server {
    listen 443 ssl;
    server_name ciudades.tudominio.com;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```
El juego apunta a este dominio vía `settings.cfg` (`backend_url`, ver `city_library.gd`).

## Copia de seguridad
Todo el estado vive en `backend/storage/`:
- `app.db` (+ `-wal`/`-shm` si están presentes) — estado de zonas, cuotas, cache de geocode.
- `zones/<zone_id>/map.json` — los archivos servidos.
- `cache/<zone_id>/{overpass_raw.json,elevation_raw.json}` — cache cruda del pipeline (recuperable re-generando, pero ahorra tiempo/cuota de red conservarla).

Backup mínimo: `tar czf backup-$(date +%F).tar.gz backend/storage/` en un cron diario,
subido a almacenamiento externo. Restaurar = detener el servicio, reemplazar
`backend/storage/`, reiniciar — `app.db` es la única fuente de verdad del estado;
los archivos `zones/` deben coincidir con lo que `app.db` cree que existe.

## Escalación (SOLO documentación — nada de esto está implementado; se activa por
## umbral medido, no por ansiedad, y sin romper el contrato `terrain` en ningún caso)

| Señal | Umbral orientativo | Opción de escalación |
|---|---|---|
| Generaciones frías por día | > ~200/día | Mirror propio de Overpass usando extractos regionales de Geofabrik (evita depender del Overpass público, que raciona por IP/carga). Requiere disco (los extractos de un país pesan GBs) y mantenimiento de actualizaciones periódicas. |
| Llamadas a Open Topo Data por día | > ~900/día | (a) Self-host de Open Topo Data (imagen Docker oficial + los datasets SRTM/mapzen que se usan hoy), o (b) migrar el fetcher a AWS Terrain Tiles. En ambos casos el contrato `terrain` (grilla, `height_at`, schema del JSON) debe quedar INTACTO — el cambio es solo de dónde vienen las elevaciones crudas, `citygen.fetch_elevation` es el único punto que se tocaría. |

Ninguna de las dos escalaciones cambia el contrato `map.json` ni el cliente Godot.

## Antes de lanzar (checklist legal ODbL — tareas del HUMANO, no automatizables)

El código ya deja las superficies de atribución listas (verificado en Fase C-4):
menú principal, panel "Ciudades" (línea de pie de página), y pantalla de carga
muestran atribución a OpenStreetMap; la búsqueda atribuye a Nominatim por separado.
Lo que sigue es responsabilidad del humano, no algo que un agente pueda verificar
por ti — revisar contra las guías oficiales de la OSMF antes de cualquier lanzamiento
público:

- [ ] Confirmar que el texto de atribución cumple la [guía oficial de atribución de OSMF](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines) (visibilidad, no ambigüedad sobre qué datos son de OSM).
- [ ] Decidir y documentar si el producto distribuye una "Derived Database" o una "Produced Work" bajo ODbL, y si aplica la cláusula share-alike a algo que se distribuya (el juego en sí, si empaqueta `map.json`s, podría considerarse una Produced Work — confirmar con la guía de la OSMF, no asumir).
- [ ] Verificar el User-Agent real (contacto) configurado en `app.py`/`citygen` antes de cualquier tráfico a Nominatim/Overpass en producción — los términos de uso de ambos servicios lo exigen.
- [ ] Revisar el throttle de Nominatim (1 req/s) contra su [política de uso](https://operations.osmfoundation.org/policies/nominatim/) vigente al momento del lanzamiento (puede cambiar).
- [ ] Si se usa el Overpass público en producción con tráfico real, revisar su [política de uso justo](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances) — es la razón detrás del umbral de escalación de arriba.
- [ ] Confirmar que ningún tiempo récord ni dato de usuario se mezcla con los datos de OSM de forma que oscurezca cuál es cuál (separación de datos propios vs. de terceros).
```

- [ ] **Step 2: Commit**

```bash
git add backend/DEPLOY.md
git commit -m "docs(c-4): DEPLOY.md - runbook VPS, umbrales de escalacion, checklist legal ODbL"
```

---

### Task 3: Verify ODbL attribution surfaces (no code change — confirms Fase C-3 already satisfies this)

**Files:** none modified. Read-only verification.

- [ ] **Step 1: Confirm the three required attribution surfaces are present**

Run:
```bash
grep -n "OpenStreetMap\|Nominatim\|ODbL" godot/scenes/ui/game_ui.tscn godot/scripts/ui/loading_screen.gd
```
Expected: three matches — menu (`game_ui.tscn` MenuPanel "Attribution" label), CityPanel footer (`game_ui.tscn` "Búsqueda: © OpenStreetMap / Nominatim"), and loading screen (`loading_screen.gd` `ATTRIBUTION` constant). All three were added in Fase C-3 (contract 5) and are untouched by the concurrent water-feature work (different files entirely). No action needed beyond confirming — this satisfies spec item 3's UI requirement; the legal-checklist half of item 3 lives in `DEPLOY.md` (Task 2).

---

### Task 4: Run the real seeding + 3-city validation matrix

**Files:** none created — this runs Task 1's script for real against the live backend storage and records results.

- [ ] **Step 1: Ensure the backend's `storage/` is in a clean, known state, then run the seeder**

Run:
```bash
cd backend && python seed_catalog.py
```
Expected: one `[nombre] generando (...)` / `[nombre] listo (Ns, X.X MB)` (or `FALLO`) line per city in `seed_cities.txt`, ending with the exact diagnostic line `"N sembradas, M fallidas (...), X.X MB totales"`. This makes real Overpass + Open Topo Data calls sequentially — expect several minutes total (run in background, check back).

- [ ] **Step 2: Confirm the catalog reflects the seeded cities**

Start the backend if not already running (`cd backend && python -m uvicorn app:app`), then:
```bash
curl -s http://127.0.0.1:8000/v1/catalog
```
Expected: a JSON array with every city from `seed_cities.txt` that ended `ready` (name, zone_size, flags per city — flags reveal which ones came back `sparse_buildings` and/or `steep`).

- [ ] **Step 3: Pick 3 contrasting cities from the seeded set for the validation matrix and confirm each headlessly**

Selection guided by the spec ("una densa europea en M, una con datos pobres, una empinada") mapped onto the actual `flags` observed in Step 2's catalog output (pick whichever seeded cities actually landed in each bucket — don't force it if the real data disagrees with the a-priori guess):
- Dense European (M): Cartagena or Annecy (whichever has no `sparse_buildings`/`steep` flags and the higher `n_buildings`).
- Sparse-data: whichever of Ushuaia/Reykjavik/Cusco actually got the `sparse_buildings` flag.
- Steep: whichever of Cusco/Ronda/Salzburgo actually got the `steep` flag.

For each of the 3, download it into the local library and boot the game headlessly with it selected (same technique used to verify Girardot in Fase C-3):
```bash
curl -s http://127.0.0.1:8000/v1/zones/<zone_id>/map.json -o /tmp/<zone_id>.json
# copy into user://cities/<zone_id>/map.json (Godot's user:// on this machine resolves to
# %APPDATA%\Godot\app_userdata\Ciudad Conducible\cities\<zone_id>\map.json), set selected_zone
# in settings.cfg to <zone_id>, then:
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --quit-after 5
```
Expected per city: clean boot, `mapa cargado: .../<zone_id>/map.json`, plausible `span`/road/building counts, `spawn elegido` printed, no `SCRIPT ERROR`. Record pass/fail + flags for each of the 3 against the spec's checklist:
- Dense: loads without error (fps/smoothness itself is a human-only check — headless can't measure it).
- Sparse-data: flag `sparse_buildings` visible in its `meta_summary`/catalog entry, OR — if it was actually rejected — the exact rejection reason (`insufficient_road_data`/`fragmented_road_graph`) printed by the seeder in Step 1.
- Steep: flag `steep` visible; drives on the same global vehicle physics (no per-city tuning exists anywhere in the codebase to check — confirmed structurally in Fase C-3).

Reset `settings.cfg`'s `selected_zone` back to empty afterward (same cleanup as Fase C-3) so the human's own session starts at Jordán.

---

### Task 5: Export the `.exe` and smoke-test it outside the editor

**Files:** none tracked — build output (`RealDriver.exe` and its `.pck`) is a local artifact, not committed (matches `export_presets.cfg`'s existing `export_path="RealDriver.exe"`; add the export output directory to `.gitignore` if the export writes inside `godot/`).

- [ ] **Step 1: Confirm export templates are installed for 4.4.stable**

Run: `find "/c/Users/Brayhan/AppData/Roaming/Godot/export_templates" -maxdepth 1`
Expected: a `4.4.stable` directory (already confirmed present in this environment).

- [ ] **Step 2: Export the release build**

Run:
```bash
cd godot && "/c/Users/Brayhan/AppData/Local/Programs/Godot/Godot_v4.4-stable_win64_console.exe" --headless --path . --export-release "Windows Desktop" ../dist/RealDriver.exe
```
Expected: no errors, `../dist/RealDriver.exe` (+ `.pck`) created.

- [ ] **Step 3: Add the export output to `.gitignore`**

Add to `.gitignore`:
```
# Export de C-4 (artefacto local, no se commitea)
/dist/
```

- [ ] **Step 4: Smoke-test the exported binary outside the editor**

With the backend running locally and a city already downloaded into `user://cities/` from Task 4 (or Fase C-3's Girardot), launch the exported `.exe` directly (not through the editor) and drive the end-to-end loop: menu → Ciudades → select the local city → confirm it loads and drives, matching the spec's final checklist item. This step is inherently interactive/visual — hand off to the human with exact instructions (see final report), since there's no headless equivalent for "does the exported build actually render and respond to input."

- [ ] **Step 5: Commit the gitignore change (the .exe itself is never committed)**

```bash
git add .gitignore
git commit -m "chore(c-4): gitignore /dist/ (artefacto de export local)"
```

## Self-Review Notes

1. **Spec coverage:** item 1 (seed_catalog.py + seed_cities.txt, respects queue, batch against citygen direct) → Task 1. Item 2 (DEPLOY.md: VPS deploy, escalation thresholds, doc-only) → Task 2. Item 3 (ODbL: three UI surfaces + legal "antes de lanzar" checklist referencing D4-style guidance) → Task 3 (UI, already done in C-3) + Task 2 (legal checklist). Item 4 (3-city validation matrix, opposite profiles) → Task 4 Step 3. Item 5 (export .exe, end-to-end outside editor) → Task 5. Diagnostic format (`"%d sembradas, %d fallidas (razones), %d MB totales"`) → `seed_catalog.seed()`'s final print, verified against the literal spec string. Every human checklist bullet → Task 4 (catalog/flags) + Task 5 Step 4 (exe end-to-end, fps).
2. **Placeholder scan:** none — every step has runnable code, exact commands, or is explicitly marked as requiring human interaction (with precise instructions for what to do) rather than left vague.
3. **Type consistency:** `seed_catalog.seed()`'s return dict keys (`sown`, `failed`, `total_bytes`) match what Task 1's test file exercises implicitly via the parser (the test only covers `parse_seed_file`, which is the one pure-logic surface — `seed()` itself is verified by running it for real in Task 4, not mocked, since its whole job is orchestrating real network calls that TDD-mocking would defeat the purpose of testing here).
