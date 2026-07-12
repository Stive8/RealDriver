#!/usr/bin/env python3
"""Backend "panaderia": API HTTP sobre citygen (contrato v1, ESPEC_SESION_CIUDADES2
§4). `uvicorn app:app` corrido desde backend/ levanta la API, crea las carpetas
de storage, inicializa la base y arranca el hilo worker -- nada mas que hacer."""
import json
import os
import sys
import threading
import time
from contextlib import asynccontextmanager

import requests
from fastapi import FastAPI, Header, Query, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data_pipeline"))
from citygen.zones import ZoneSpec, resolve  # noqa: E402

import quotas  # noqa: E402
import store  # noqa: E402
import worker  # noqa: E402

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
STORAGE_DIR = os.path.join(BACKEND_DIR, "storage")
DB_PATH = os.path.join(STORAGE_DIR, "app.db")
CACHE_DIR = os.path.join(STORAGE_DIR, "cache")
ZONES_DIR = os.path.join(STORAGE_DIR, "zones")

NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
# DECISION_PENDIENTE: contacto de placeholder. Reemplazar antes de cualquier
# despliegue real (ver checklist ODbL/Nominatim en DEPLOY.md, Fase C-4).
USER_AGENT = "ciudad-conducible-dev/0.1 (contacto: reemplazar-antes-de-desplegar@ejemplo.com)"
NOMINATIM_MIN_INTERVAL = 1.0

_nominatim_lock = threading.Lock()
_last_nominatim_call = 0.0


@asynccontextmanager
async def lifespan(app: FastAPI):
    os.makedirs(ZONES_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)
    store.init_db(DB_PATH)
    worker.start_background_thread(DB_PATH, CACHE_DIR, ZONES_DIR)
    yield


app = FastAPI(lifespan=lifespan)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    t0 = time.time()
    response = await call_next(request)
    print(f"{request.method} {request.url.path} -> {response.status_code} ({(time.time() - t0) * 1000:.0f} ms)")
    return response


class ZoneRequest(BaseModel):
    lat: float
    lon: float
    size: str
    name: str | None = None


def _geocode_nominatim(q: str) -> list:
    global _last_nominatim_call
    with _nominatim_lock:
        wait = NOMINATIM_MIN_INTERVAL - (time.time() - _last_nominatim_call)
        if wait > 0:
            time.sleep(wait)
        resp = requests.get(
            NOMINATIM_URL, params={"q": q, "format": "json", "limit": 5},
            headers={"User-Agent": USER_AGENT}, timeout=15,
        )
        _last_nominatim_call = time.time()
    resp.raise_for_status()
    return [
        {"name": item["display_name"], "lat": float(item["lat"]), "lon": float(item["lon"])}
        for item in resp.json()
    ]


@app.get("/v1/geocode")
def geocode(q: str = Query(...)):
    cached = store.get_geocode_cache(DB_PATH, q)
    if cached is not None:
        print(f"geocode '{q}': cache hit")
        return cached
    print(f"geocode '{q}': consultando Nominatim")
    results = _geocode_nominatim(q)
    store.save_geocode_cache(DB_PATH, q, results)
    return results


def _zone_status_response(row: dict) -> dict:
    status = row["status"]
    if status == "queued":
        return {
            "zone_id": row["zone_id"], "status": "queued",
            "queue_position": store.get_queue_position(DB_PATH, row["zone_id"]),
        }
    if status == "generating":
        return {"zone_id": row["zone_id"], "status": "generating", "stage": row["stage"]}
    if status == "ready":
        return {"zone_id": row["zone_id"], "status": "ready"}
    return {"zone_id": row["zone_id"], "status": "failed", "reason": row["reason"]}


@app.post("/v1/zones")
def post_zone(body: ZoneRequest, request: Request, x_client_id: str = Header(...)):
    name = body.name or f"{body.lat:.4f}, {body.lon:.4f}"
    try:
        resolved = resolve(ZoneSpec(name=name, size=body.size, lat=body.lat, lon=body.lon))
    except ValueError as exc:
        return JSONResponse(status_code=400, content={"reason": "invalid_request", "detail": str(exc)})
    zone_id = resolved.zone_id

    existing = store.get_zone(DB_PATH, zone_id)
    if existing is not None:
        return _zone_status_response(existing)

    quota = quotas.check_and_increment(DB_PATH, x_client_id, request.client.host)
    if not quota["allowed"]:
        return JSONResponse(status_code=429, content={"reason": "quota", "resets_at": quota["resets_at"]})

    store.insert_zone_queued(DB_PATH, zone_id, body.lat, body.lon, body.size, name)
    queue_position = store.get_queue_position(DB_PATH, zone_id)
    return {"zone_id": zone_id, "status": "queued", "queue_position": queue_position}


@app.get("/v1/zones/{zone_id}")
def get_zone_status(zone_id: str):
    row = store.get_zone(DB_PATH, zone_id)
    if row is None:
        return JSONResponse(status_code=404, content={"reason": "not_found"})
    response = _zone_status_response(row)
    if row["status"] == "ready":
        response["meta_summary"] = json.loads(row["meta_summary_json"])
    return response


@app.get("/v1/zones/{zone_id}/map.json")
def get_zone_map(zone_id: str):
    row = store.get_zone(DB_PATH, zone_id)
    if row is None or row["status"] != "ready":
        return JSONResponse(status_code=404, content={"reason": "not_ready"})
    path = os.path.join(ZONES_DIR, zone_id, "map.json")
    return FileResponse(path, media_type="application/json")


@app.get("/v1/catalog")
def get_catalog():
    return store.list_catalog(DB_PATH)
