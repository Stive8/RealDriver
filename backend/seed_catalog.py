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

# Mismo criterio que worker.py: una excepcion de red (Overpass/Open Topo Data caidos
# o con timeout, ver citygen.fetch_osm/fetch_elevation) no debe tumbar el lote entero --
# se registra esa ciudad como fallida con la razon del contrato y se sigue con la
# siguiente (reportado: un 504 de Overpass en Annecy crasheo la siembra completa,
# dejando 5 ciudades restantes sin intentar).
STAGE_FAILURE_REASON = {"osm": "osm_unavailable", "elevation": "elevation_unavailable"}


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

        if existing is None:
            store.insert_zone_queued(DB_PATH, resolved.zone_id, entry["lat"], entry["lon"], entry["size"], entry["name"])

        current_stage = "osm"

        def _progress(stage):
            nonlocal current_stage
            current_stage = stage

        try:
            result = generate(zone, CACHE_DIR, out_path, progress_cb=_progress)
        except Exception as exc:
            elapsed = time.time() - t0
            reason = STAGE_FAILURE_REASON.get(current_stage, "elevation_unavailable")
            print(f"[{entry['name']}] FALLO INESPERADO ({elapsed:.0f}s, stage={current_stage}): {exc}")
            store.mark_zone_failed(DB_PATH, resolved.zone_id, reason)
            failed.append((entry["name"], reason))
            continue

        elapsed = time.time() - t0

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
