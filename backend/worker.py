#!/usr/bin/env python3
"""Hilo unico consumidor de la cola de zonas (concurrencia global de
generacion = 1, contrato ESPEC_SESION_CIUDADES2 §4). Ejecuta citygen.generate()
y persiste el resultado via store.py. Nunca porta logica de generacion aqui --
solo orquesta la cola y el logging de transiciones de estado."""
import logging
import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data_pipeline"))
from citygen import ZoneSpec, generate  # noqa: E402

import store  # noqa: E402

logger = logging.getLogger("citygen.worker")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

POLL_INTERVAL_SECONDS = 1.0
# Solo dos categorias de fallo "ambiental" existen en el contrato ademas de las
# de validate.py; una excepcion inesperada en build/package (bug, no red) se
# reporta igual como elevation_unavailable -- no hay categoria dedicada en esta
# fase y encolar-para-siempre violaria "nunca degradar en silencio".
STAGE_FAILURE_REASON = {"osm": "osm_unavailable", "elevation": "elevation_unavailable"}


def _process_zone(db_path: str, cache_dir: str, zones_dir: str, row: dict) -> None:
    zone_id = row["zone_id"]
    zone = ZoneSpec(name=row["name"], size=row["size"], lat=row["lat"], lon=row["lon"])
    out_path = os.path.join(zones_dir, zone_id, "map.json")
    current_stage = "osm"

    def progress(stage):
        nonlocal current_stage
        current_stage = stage
        store.update_zone_stage(db_path, zone_id, stage)
        logger.info("[zone %s] -> generating(%s)", zone_id, stage)

    t0 = time.time()
    logger.info("[zone %s] queued -> generating(osm)", zone_id)
    try:
        result = generate(zone, cache_dir, out_path, progress_cb=progress)
    except Exception:
        elapsed = time.time() - t0
        reason = STAGE_FAILURE_REASON.get(current_stage, "elevation_unavailable")
        logger.exception("[zone %s] fallo inesperado en stage=%s tras %.1fs", zone_id, current_stage, elapsed)
        store.mark_zone_failed(db_path, zone_id, reason)
        return

    elapsed = time.time() - t0
    if not result.ok:
        logger.info("[zone %s] failed (%s) tras %.1fs", zone_id, result.reason, elapsed)
        store.mark_zone_failed(db_path, zone_id, result.reason)
        return

    size_bytes = result.diagnostics.get("size_bytes", 0)
    meta_summary = {"name": zone.name, "zone_size": zone.size, "stats": result.stats}
    store.mark_zone_ready(db_path, zone_id, meta_summary)
    logger.info("[zone %s] ready (%.0f s, %.1f MB)", zone_id, elapsed, size_bytes / (1024 * 1024))


def run_forever(db_path: str, cache_dir: str, zones_dir: str, stop_event: threading.Event) -> None:
    while not stop_event.is_set():
        row = store.next_queued_zone(db_path)
        if row is None:
            stop_event.wait(POLL_INTERVAL_SECONDS)
            continue
        _process_zone(db_path, cache_dir, zones_dir, row)


def start_background_thread(db_path: str, cache_dir: str, zones_dir: str) -> threading.Thread:
    stop_event = threading.Event()
    thread = threading.Thread(
        target=run_forever, args=(db_path, cache_dir, zones_dir, stop_event), daemon=True,
    )
    thread.stop_event = stop_event
    thread.start()
    return thread
