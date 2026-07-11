#!/usr/bin/env python3
"""Genera godot/data/map.json a partir de datos de OpenStreetMap (Overpass).

Uso: python generate_map.py [--refresh] [--stats] [--svg]
"""
import argparse
import json
import math
import os
import random
import shutil
import time
from datetime import datetime, timezone

import requests

# --- Constantes fijas (ver ESPEC_SESION.md, contrato inamovible) ---
BBOX = (4.433220, -75.210321, 4.442772, -75.193563)  # lat_s, lon_o, lat_n, lon_e
LAT0 = 4.4380
LON0 = -75.2019

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OVERPASS_FALLBACK_URL = "https://overpass.kumi.systems/api/interpreter"
USER_AGENT = "ciudad-conducible-dev/0.1"

QUERY = """[out:json][timeout:90];
(
  way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|service|living_street)$"](4.433220,-75.210321,4.442772,-75.193563);
  way["building"](4.433220,-75.210321,4.442772,-75.193563);
);
out body;
>;
out body qt;
"""

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_PATH = os.path.join(SCRIPT_DIR, "cache", "overpass_raw.json")
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "output")
OUTPUT_JSON_PATH = os.path.join(OUTPUT_DIR, "map.json")
OUTPUT_SVG_PATH = os.path.join(OUTPUT_DIR, "preview.svg")
GODOT_DATA_PATH = os.path.join(SCRIPT_DIR, "..", "godot", "data", "map.json")

ROAD_WIDTHS = {
    "motorway": 14.0,
    "trunk": 14.0,
    "primary": 12.0,
    "secondary": 9.0,
    "tertiary": 8.0,
    "residential": 6.0,
    "unclassified": 6.0,
    "living_street": 5.0,
    "service": 4.0,
}
# Contrato v1.1 (ESPEC_SESION_TRAFICO, Fase T-0): tag OSM highway del nodo -> type de control.
CONTROL_TYPES = {
    "traffic_signals": "signals",
    "stop": "stop",
    "give_way": "give_way",
}
WIDTH_CLAMP = (3.0, 20.0)
HEIGHT_CLAMP = (3.0, 60.0)
HEIGHT_RANDOM_RANGE = (5.0, 12.0)
LEVEL_HEIGHT = 3.2

# --- [ESTRUCTURAL] Elevacion de terreno (ESPEC_SESION_RELIEVE, Fase R-1) ---
# Validas para cualquier ciudad; ver contrato de map.json "terrain" (schema 1.2).
OPENTOPODATA_URL = "https://api.opentopodata.org/v1/srtm30m,mapzen"
ELEVATION_DATASET = "srtm30m,mapzen"
ELEVATION_PROVIDER = "opentopodata.org"
GRID_CELL = 30.0
ELEVATION_BATCH_SIZE = 100
ELEVATION_BATCH_PAUSE = 1.2
ELEVATION_RETRIES = 3
ELEVATION_BACKOFF = (2, 4, 8)
SLOPE_SAMPLE_STEP = 10.0  # paso de re-muestreo de vias para --stats (pendiente maxima)
# --- [ESTRUCTURAL] Fase R-5: kernel de suavizado condicional (ver ESPEC_SESION_RELIEVE_R5) ---
SMOOTH_DELTA_MAX = 0.5  # m; desnivel real (> esto) entre un nodo y su promedio 3x3: se preserva intacto

# --- [TUNEO-ZONA] Calibracion de Jordan; otra ciudad DEBE recalibrarlos ---
GRID_MARGIN = 250.0  # m, expansion de la grilla de terreno mas alla del bbox
SMOOTH_PASSES = 1  # pasadas de suavizado condicional sobre la grilla de elevacion
TERRAIN_EXAGGERATION = 1.0  # clamp [1.0, 1.3]; percepcion de pendiente en juego vs. sitio real

ELEVATION_CACHE_PATH = os.path.join(SCRIPT_DIR, "cache", "elevation_raw.json")


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def fetch_overpass(refresh: bool) -> dict:
    if not refresh and os.path.isfile(CACHE_PATH):
        print(f"Usando cache: {CACHE_PATH}")
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)

    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    headers = {"User-Agent": USER_AGENT}
    last_error = None
    for url in (OVERPASS_URL, OVERPASS_FALLBACK_URL):
        try:
            print(f"Consultando Overpass: {url}")
            t0 = time.time()
            resp = requests.post(url, data={"data": QUERY}, headers=headers, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            print(f"  respuesta en {time.time() - t0:.1f}s, {len(resp.content)} bytes")
            with open(CACHE_PATH, "w", encoding="utf-8") as f:
                json.dump(data, f)
            return data
        except Exception as exc:
            last_error = exc
            print(f"  fallo ({url}): {exc}")
    raise RuntimeError(f"No se pudo consultar Overpass en ningun endpoint: {last_error}")


def index_elements(raw: dict):
    nodes = {}
    ways = []
    for el in raw.get("elements", []):
        if el["type"] == "node":
            nodes[el["id"]] = (el["lat"], el["lon"])
        elif el["type"] == "way":
            ways.append(el)
    return nodes, ways


def way_points(way: dict, nodes: dict):
    points = []
    for node_id in way.get("nodes", []):
        latlon = nodes.get(node_id)
        if latlon is not None:
            points.append(latlon)
    return points


def in_bbox(lat: float, lon: float) -> bool:
    lat_s, lon_o, lat_n, lon_e = BBOX
    return lat_s <= lat <= lat_n and lon_o <= lon <= lon_e


def any_point_in_bbox(points) -> bool:
    return any(in_bbox(lat, lon) for lat, lon in points)


def project(lat: float, lon: float):
    x = (lon - LON0) * 111320.0 * math.cos(math.radians(LAT0))
    z = -(lat - LAT0) * 110540.0
    return round(x, 2), round(z, 2)


def deproject(x: float, z: float):
    """Inversa exacta de project(): mundo (x, z) -> (lat, lon)."""
    lon = LON0 + x / (111320.0 * math.cos(math.radians(LAT0)))
    lat = LAT0 - z / 110540.0
    return lat, lon


def compute_grid_params(bbox, margin: float, cell_size: float) -> dict:
    """Deriva la grilla de terreno que cubre `bbox` expandido `margin` m por lado.

    Contrato R-1: origin_x/z = min proyectado del bbox expandido; nx/nz cubren
    hasta el borde opuesto expandido con un nodo extra (ceil(ancho/cell)+1).
    """
    lat_s, lon_o, lat_n, lon_e = bbox
    corners = [(lat_s, lon_o), (lat_s, lon_e), (lat_n, lon_o), (lat_n, lon_e)]
    projected = [project(lat, lon) for lat, lon in corners]
    xs = [p[0] for p in projected]
    zs = [p[1] for p in projected]
    origin_x = round(min(xs) - margin, 2)
    origin_z = round(min(zs) - margin, 2)
    width = (max(xs) + margin) - origin_x
    height = (max(zs) + margin) - origin_z
    nx = math.ceil(width / cell_size) + 1
    nz = math.ceil(height / cell_size) + 1
    return {
        "cell_size": cell_size,
        "nx": nx,
        "nz": nz,
        "origin_x": origin_x,
        "origin_z": origin_z,
    }


def height_at(x: float, z: float, terrain: dict) -> float:
    """Espejo Python EXACTO de TerrainSampler.height_at() en GDScript (ver ESPEC)."""
    cell_size = terrain["cell_size"]
    nx = terrain["nx"]
    nz = terrain["nz"]
    origin_x = terrain["origin_x"]
    origin_z = terrain["origin_z"]
    heights = terrain["heights"]

    gx = clamp((x - origin_x) / cell_size, 0.0, nx - 1.001)
    gz = clamp((z - origin_z) / cell_size, 0.0, nz - 1.001)
    i = int(math.floor(gx))
    j = int(math.floor(gz))
    fx = gx - i
    fz = gz - j

    h00 = heights[j * nx + i]
    h10 = heights[j * nx + i + 1]
    h01 = heights[(j + 1) * nx + i]
    h11 = heights[(j + 1) * nx + i + 1]
    top = h00 + (h10 - h00) * fx
    bottom = h01 + (h11 - h01) * fx
    return top + (bottom - top) * fz


def _ring_cells(i: int, j: int, radius: int, nx: int, nz: int):
    cells = []
    for di in range(-radius, radius + 1):
        for dj in range(-radius, radius + 1):
            if max(abs(di), abs(dj)) != radius:
                continue
            ci, cj = i + di, j + dj
            if 0 <= ci < nx and 0 <= cj < nz:
                cells.append((ci, cj))
    return cells


def fill_nulls(heights, nx: int, nz: int):
    """Rellena huecos (None) con el valor valido mas cercano (busqueda por anillos crecientes).

    Retorna (heights_rellenos, cantidad_rellenada). Los rellenos siempre citan un
    valor original valido (nunca otro relleno), para no propagar aproximaciones.
    """
    filled = list(heights)
    valid_coords = {(i, j) for j in range(nz) for i in range(nx) if filled[j * nx + i] is not None}
    count_filled = 0
    max_radius = max(nx, nz)

    for j in range(nz):
        for i in range(nx):
            idx = j * nx + i
            if filled[idx] is not None:
                continue
            best = None
            best_dist2 = None
            for radius in range(1, max_radius + 1):
                for (ci, cj) in _ring_cells(i, j, radius, nx, nz):
                    if (ci, cj) not in valid_coords:
                        continue
                    dist2 = (ci - i) ** 2 + (cj - j) ** 2
                    if best_dist2 is None or dist2 < best_dist2:
                        best_dist2 = dist2
                        best = (ci, cj)
                if best is not None:
                    break
            if best is None:
                raise ValueError("No hay ningun valor de elevacion valido en toda la grilla")
            filled[idx] = filled[best[1] * nx + best[0]]
            count_filled += 1

    return filled, count_filled


def _clamped_height(heights, nx: int, nz: int, i: int, j: int) -> float:
    ci = 0 if i < 0 else (nx - 1 if i >= nx else i)
    cj = 0 if j < 0 else (nz - 1 if j >= nz else j)
    return heights[cj * nx + ci]


def _weighted_average_3x3(heights, nx: int, nz: int, i: int, j: int) -> float:
    """Promedio ponderado 3x3 (pesos 1-2-1 por eje: centro 4, aristas 2, esquinas 1; /16, bordes: clamp)."""
    total = 0.0
    for dj, wj in ((-1, 1.0), (0, 2.0), (1, 1.0)):
        for di, wi in ((-1, 1.0), (0, 2.0), (1, 1.0)):
            total += _clamped_height(heights, nx, nz, i + di, j + dj) * wi * wj
    return total / 16.0


def max_adjacent_grade(heights, nx: int, nz: int, cell_size: float) -> float:
    """Pendiente maxima (%) entre celdas ADYACENTES de la grilla (horizontal o vertical)."""
    worst = 0.0
    for j in range(nz):
        for i in range(nx):
            idx = j * nx + i
            h = heights[idx]
            if i + 1 < nx:
                worst = max(worst, abs(heights[idx + 1] - h) / cell_size * 100.0)
            if j + 1 < nz:
                worst = max(worst, abs(heights[idx + nx] - h) / cell_size * 100.0)
    return worst


def smooth_heights(heights, nx: int, nz: int, passes: int, delta_max: float):
    """`passes` pasadas de kernel 3x3 ponderado 1-2-1 (ver `_weighted_average_3x3`) que
    preserva intacto cualquier nodo cuyo promedio difiera de su valor actual en mas de
    `delta_max` (desnivel real, no ruido sub-metrico). Cada pasada se aplica en bloque
    sobre una copia (nunca in-place): el orden de recorrido no puede sesgar el resultado.

    Retorna (heights_suavizados, nodos_preservados_en_la_ultima_pasada).
    """
    current = list(heights)
    preserved = 0
    for _ in range(passes):
        new_heights = [0.0] * len(current)
        preserved = 0
        for j in range(nz):
            for i in range(nx):
                idx = j * nx + i
                m = _weighted_average_3x3(current, nx, nz, i, j)
                if abs(m - current[idx]) <= delta_max:
                    new_heights[idx] = m
                else:
                    new_heights[idx] = current[idx]
                    preserved += 1
        current = new_heights
    return current, preserved


def resample_polyline(points, step: float):
    """Re-muestrea una polilinea 2D cada `step` m (interpolacion lineal), conservando extremos."""
    points = [tuple(p) for p in points]
    if len(points) < 2:
        return points

    cum = [0.0]
    for k in range(len(points) - 1):
        x0, z0 = points[k]
        x1, z1 = points[k + 1]
        cum.append(cum[-1] + math.hypot(x1 - x0, z1 - z0))
    total = cum[-1]
    if total <= 0.0:
        return [points[0]]

    result = []
    seg_idx = 0
    d = 0.0
    while d <= total:
        while seg_idx < len(points) - 2 and cum[seg_idx + 1] < d:
            seg_idx += 1
        x0, z0 = points[seg_idx]
        x1, z1 = points[seg_idx + 1]
        seg_len = cum[seg_idx + 1] - cum[seg_idx]
        t = 0.0 if seg_len <= 0.0 else (d - cum[seg_idx]) / seg_len
        result.append((x0 + (x1 - x0) * t, z0 + (z1 - z0) * t))
        d += step

    if result[-1] != points[-1]:
        result.append(points[-1])
    return result


def road_slope_stats(points, terrain: dict) -> float:
    """Pendiente maxima (%) de una via: re-muestrea cada SLOPE_SAMPLE_STEP m y compara alturas."""
    resampled = resample_polyline(points, SLOPE_SAMPLE_STEP)
    max_slope = 0.0
    for k in range(len(resampled) - 1):
        x0, z0 = resampled[k]
        x1, z1 = resampled[k + 1]
        horiz = math.hypot(x1 - x0, z1 - z0)
        if horiz < 0.01:
            continue
        h0 = height_at(x0, z0, terrain)
        h1 = height_at(x1, z1, terrain)
        slope = abs(h1 - h0) / horiz * 100.0
        if slope > max_slope:
            max_slope = slope
    return max_slope


def load_elevation_cache(path: str, bbox, grid_params: dict):
    """Retorna la lista de elevaciones cacheadas si bbox y grid coinciden; si no, None."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            cache = json.load(f)
    except (json.JSONDecodeError, OSError):
        return None
    if list(cache.get("bbox", [])) != list(bbox):
        return None
    if cache.get("grid") != grid_params:
        return None
    return cache.get("elevations")


def save_elevation_cache(path: str, bbox, grid_params: dict, elevations) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cache = {"bbox": list(bbox), "grid": grid_params, "elevations": elevations}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cache, f)


def fetch_elevation_batch(locations, retries: int = ELEVATION_RETRIES, backoff=ELEVATION_BACKOFF):
    """Consulta un lote (<=100 puntos) a Open Topo Data. Reintenta ante 429/5xx/errores de red."""
    locations_param = "|".join(f"{lat:.6f},{lon:.6f}" for lat, lon in locations)
    url = f"{OPENTOPODATA_URL}?locations={locations_param}&interpolation=bilinear"
    headers = {"User-Agent": USER_AGENT}
    last_error = None
    for attempt in range(retries + 1):
        try:
            resp = requests.get(url, headers=headers, timeout=60)
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"HTTP {resp.status_code}")
            resp.raise_for_status()
            data = resp.json()
            if data.get("status") != "OK":
                raise RuntimeError(f"status API: {data.get('status')}")
            return [r.get("elevation") for r in data["results"]]
        except Exception as exc:
            last_error = exc
            if attempt < retries:
                wait = backoff[min(attempt, len(backoff) - 1)]
                print(f"  lote elevacion fallo (intento {attempt + 1}/{retries + 1}): {exc}; reintento en {wait}s")
                time.sleep(wait)
    raise RuntimeError(f"Lote de elevacion fallo tras {retries} reintentos: {last_error}")


def fetch_elevations(grid_points, grid_params: dict, bbox, refresh_elevation: bool):
    """Orquesta la consulta de elevaciones para todos los puntos de la grilla, con cache.

    Retorna (elevaciones, num_lotes) donde num_lotes es None si se uso la cache.
    """
    cached = None if refresh_elevation else load_elevation_cache(ELEVATION_CACHE_PATH, bbox, grid_params)
    if cached is not None:
        print(f"Usando cache de elevacion: {ELEVATION_CACHE_PATH}")
        return cached, None

    num_batches = math.ceil(len(grid_points) / ELEVATION_BATCH_SIZE)
    all_elevations = []
    for batch_idx in range(num_batches):
        start = batch_idx * ELEVATION_BATCH_SIZE
        batch = grid_points[start:start + ELEVATION_BATCH_SIZE]
        print(f"  lote elevacion {batch_idx + 1}/{num_batches} ({len(batch)} puntos)")
        all_elevations.extend(fetch_elevation_batch(batch))
        if batch_idx < num_batches - 1:
            time.sleep(ELEVATION_BATCH_PAUSE)

    save_elevation_cache(ELEVATION_CACHE_PATH, bbox, grid_params, all_elevations)
    return all_elevations, num_batches


def build_terrain(bbox, refresh_elevation: bool):
    """Construye la seccion `terrain` completa (grilla + elevaciones + post-proceso)."""
    grid_params = compute_grid_params(bbox, GRID_MARGIN, GRID_CELL)
    nx, nz = grid_params["nx"], grid_params["nz"]
    origin_x, origin_z, cell_size = grid_params["origin_x"], grid_params["origin_z"], grid_params["cell_size"]

    grid_points = []
    for j in range(nz):
        for i in range(nx):
            x = origin_x + i * cell_size
            z = origin_z + j * cell_size
            grid_points.append(deproject(x, z))

    raw_elevations, num_batches = fetch_elevations(grid_points, grid_params, bbox, refresh_elevation)
    filled, nulls_filled = fill_nulls(raw_elevations, nx, nz)

    max_grade_before_smooth = max_adjacent_grade(filled, nx, nz, cell_size)
    smoothed, nodes_preserved = smooth_heights(filled, nx, nz, SMOOTH_PASSES, SMOOTH_DELTA_MAX)
    max_grade_after_smooth = max_adjacent_grade(smoothed, nx, nz, cell_size)

    raw_min = min(smoothed)
    raw_max = max(smoothed)

    # Palanca de percepcion (R-5): amplifica el relieve alrededor del punto mas bajo de la
    # grilla, DESPUES de suavizar y ANTES de restar base_elevation/redondear. min(exagerado)
    # == raw_min siempre (el nodo minimo tiene h-raw_min=0), asi que base_elevation no cambia.
    exaggeration = clamp(TERRAIN_EXAGGERATION, 1.0, 1.3)
    exaggerated = [raw_min + (h - raw_min) * exaggeration for h in smoothed]

    base_elevation = round(raw_min, 1)
    heights_relative = [round(h - raw_min, 2) for h in exaggerated]

    terrain = {
        "cell_size": cell_size,
        "nx": nx,
        "nz": nz,
        "origin_x": origin_x,
        "origin_z": origin_z,
        "base_elevation": base_elevation,
        "heights": heights_relative,
    }
    terrain_stats = {
        "num_points": len(grid_points),
        "num_batches": num_batches,
        "nulls_filled": nulls_filled,
        "elevation_min_abs": raw_min,
        "elevation_max_abs": raw_max,
        "elevation_min_rel": 0.0,
        "elevation_max_rel": max(heights_relative),
        "max_grade_before_smooth": max_grade_before_smooth,
        "max_grade_after_smooth": max_grade_after_smooth,
        "nodes_preserved": nodes_preserved,
        "nodes_preserved_pct": (100.0 * nodes_preserved / len(smoothed)) if smoothed else 0.0,
        "exaggeration": exaggeration,
    }
    return terrain, terrain_stats


def road_width(tags: dict) -> float:
    width_tag = tags.get("width")
    if width_tag is not None:
        try:
            return clamp(float(str(width_tag).split()[0]), *WIDTH_CLAMP)
        except (ValueError, TypeError):
            pass
    return ROAD_WIDTHS.get(tags.get("highway", ""), ROAD_WIDTHS["residential"])


def road_oneway(tags: dict) -> int:
    """Deriva el campo oneway v1.1: 1 = orden de points, -1 = inverso, 0 = bidireccional.

    junction=roundabout fuerza 1 aunque no exista tag oneway (contrato T-0).
    """
    if tags.get("junction") == "roundabout":
        return 1
    val = str(tags.get("oneway", "")).strip().lower()
    if val in ("yes", "1", "true"):
        return 1
    if val in ("-1", "reverse"):
        return -1
    return 0


def building_height(tags: dict, osm_way_id: int) -> float:
    height_tag = tags.get("height")
    if height_tag is not None:
        try:
            return round(clamp(float(str(height_tag).split()[0]), *HEIGHT_CLAMP), 2)
        except (ValueError, TypeError):
            pass
    levels_tag = tags.get("building:levels")
    if levels_tag is not None:
        try:
            return round(clamp(float(levels_tag) * LEVEL_HEIGHT, *HEIGHT_CLAMP), 2)
        except (ValueError, TypeError):
            pass
    # Semilla = id crudo de OSM (no el id secuencial de salida): asi la
    # altura "aleatoria" de un edificio no cambia si un --refresh futuro
    # agrega o quita otros edificios y corre la numeracion secuencial.
    rng = random.Random(osm_way_id)
    return round(rng.uniform(*HEIGHT_RANDOM_RANGE), 2)


def build_roads(ways, nodes, stats):
    roads = []
    next_id = 0
    for way in ways:
        tags = way.get("tags", {})
        highway = tags.get("highway")
        if not highway:
            continue
        points = way_points(way, nodes)
        if len(points) < 2:
            stats["roads_discarded_few_points"] += 1
            continue
        if not any_point_in_bbox(points):
            stats["roads_discarded_outside_bbox"] += 1
            continue
        projected = [project(lat, lon) for lat, lon in points]
        oneway = road_oneway(tags)
        roads.append({
            "id": next_id,
            "highway": highway,
            "width": road_width(tags),
            "oneway": oneway,
            "points": [[x, z] for x, z in projected],
        })
        stats["roads_by_type"][highway] = stats["roads_by_type"].get(highway, 0) + 1
        stats["roads_oneway_by_value"][oneway] += 1
        next_id += 1
    return roads


def build_controls(raw: dict, stats: dict):
    """Nodos de control (v1.1): highway in {traffic_signals, stop, give_way} dentro del bbox.

    Requiere `out body qt;` en la recursion para que los nodos traigan sus tags.
    En Python solo se emite la lista; la vinculacion al grafo y el conteo de
    descartes por no-vinculacion (< 5 m a un nodo) es responsabilidad de Godot (T-0).
    """
    controls = []
    for el in raw.get("elements", []):
        if el.get("type") != "node":
            continue
        tags = el.get("tags") or {}
        ctype = CONTROL_TYPES.get(tags.get("highway", ""))
        if ctype is None:
            continue
        lat, lon = el["lat"], el["lon"]
        if not in_bbox(lat, lon):
            continue
        x, z = project(lat, lon)
        controls.append({"type": ctype, "pos": [x, z]})
        stats["controls_by_type"][ctype] = stats["controls_by_type"].get(ctype, 0) + 1
    return controls


def build_buildings(ways, nodes, stats):
    buildings = []
    next_id = 0
    for way in ways:
        tags = way.get("tags", {})
        if "building" not in tags:
            continue
        node_ids = way.get("nodes", [])
        if len(node_ids) < 2 or node_ids[0] != node_ids[-1]:
            stats["buildings_discarded_not_closed"] += 1
            continue
        points = way_points(way, nodes)
        if len(points) < 2:
            stats["buildings_discarded_few_points"] += 1
            continue
        if not any_point_in_bbox(points):
            stats["buildings_discarded_outside_bbox"] += 1
            continue
        # El ultimo punto duplica al primero (way cerrado); se cuenta el
        # vertice real (len - 1). El duplicado se conserva en el footprint:
        # building_builder.gd (Fase 3) es responsable de quitarlo.
        effective_vertices = len(points) - 1
        if effective_vertices < 3:
            stats["buildings_discarded_few_vertices"] += 1
            continue
        projected = [project(lat, lon) for lat, lon in points]
        buildings.append({
            "id": next_id,
            "height": building_height(tags, way["id"]),
            "footprint": [[x, z] for x, z in projected],
        })
        next_id += 1
    return buildings


def build_meta() -> dict:
    generated_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return {
        "source": "OpenStreetMap",
        "license": "ODbL 1.0",
        "attribution": "© OpenStreetMap contributors",
        "bbox": list(BBOX),
        "origin": {"lat": LAT0, "lon": LON0},
        "generated_at": generated_at,
        "schema_version": "1.2",
        "elevation_source": {
            "dataset": ELEVATION_DATASET,
            "provider": ELEVATION_PROVIDER,
            "fetched_at": generated_at,
        },
    }


def print_stats(roads, controls, buildings, stats, terrain_stats, steepest_road):
    size_bytes = os.path.getsize(OUTPUT_JSON_PATH)
    total_roads = len(roads)
    print("--- stats ---")
    print("Vias por tipo:")
    for highway, count in sorted(stats["roads_by_type"].items()):
        print(f"  {highway}: {count}")
    print(f"Total vias: {total_roads}")
    # v1.1: distribucion de oneway (contrato T-0). % sobre el total de vias.
    ow = stats["roads_oneway_by_value"]
    def pct(n):
        return (100.0 * n / total_roads) if total_roads else 0.0
    print("Oneway (sentido):")
    print(f"  bidireccional (0): {ow[0]} ({pct(ow[0]):.1f}%)")
    print(f"  directo (1):       {ow[1]} ({pct(ow[1]):.1f}%)")
    print(f"  inverso (-1):      {ow[-1]} ({pct(ow[-1]):.1f}%)")
    # v1.1: controles emitidos por tipo. La vinculacion/descartes se reportan en Godot.
    total_controls = len(controls)
    cbt = stats["controls_by_type"]
    print("Controles (nodos OSM emitidos):")
    print(f"  signals:  {cbt.get('signals', 0)}")
    print(f"  stop:     {cbt.get('stop', 0)}")
    print(f"  give_way: {cbt.get('give_way', 0)}")
    print(f"  total emitido: {total_controls}")
    print(f"Total edificios: {len(buildings)}")
    print("Descartes:")
    print(f"  vias <2 puntos: {stats['roads_discarded_few_points']}")
    print(f"  vias fuera de bbox: {stats['roads_discarded_outside_bbox']}")
    print(f"  edificios no cerrados: {stats['buildings_discarded_not_closed']}")
    print(f"  edificios con nodos faltantes: {stats['buildings_discarded_few_points']}")
    print(f"  edificios <3 vertices: {stats['buildings_discarded_few_vertices']}")
    print(f"  edificios fuera de bbox: {stats['buildings_discarded_outside_bbox']}")
    print(f"Tamano map.json: {size_bytes} bytes ({size_bytes / 1024:.1f} KB)")

    print("Elevacion:")
    print(
        "  absoluta: %.1f - %.1f msnm (rango %.1f m)"
        % (
            terrain_stats["elevation_min_abs"],
            terrain_stats["elevation_max_abs"],
            terrain_stats["elevation_max_abs"] - terrain_stats["elevation_min_abs"],
        )
    )
    print(
        "  relativa: %.2f - %.2f m"
        % (terrain_stats["elevation_min_rel"], terrain_stats["elevation_max_rel"])
    )
    print(f"  nulls rellenados: {terrain_stats['nulls_filled']}")
    if terrain_stats["num_batches"] is None:
        print("  lotes de elevacion consultados: cache")
    else:
        print(f"  lotes de elevacion consultados: {terrain_stats['num_batches']}")
    print(
        "  pendiente max. entre celdas adyacentes: %.1f%% antes de suavizar -> %.1f%% despues (kernel condicional, delta_max=%.1f m)"
        % (terrain_stats["max_grade_before_smooth"], terrain_stats["max_grade_after_smooth"], SMOOTH_DELTA_MAX)
    )
    print(
        "  nodos preservados (desnivel real, no tocados por el suavizado): %d/%d (%.1f%%)"
        % (
            terrain_stats["nodes_preserved"],
            terrain_stats["num_points"],
            terrain_stats["nodes_preserved_pct"],
        )
    )
    print(f"  exageracion de relieve aplicada: x{terrain_stats['exaggeration']:.2f}")
    steepest_id, steepest_slope = steepest_road
    print(f"  pendiente maxima de via: {steepest_slope:.1f}% (via id {steepest_id})")


def _append_hillshade(parts, terrain: dict):
    heights = terrain["heights"]
    nx, nz = terrain["nx"], terrain["nz"]
    cell = terrain["cell_size"]
    origin_x, origin_z = terrain["origin_x"], terrain["origin_z"]
    max_h = max(heights) if heights else 0.0
    for j in range(nz - 1):
        for i in range(nx - 1):
            h_avg = (
                heights[j * nx + i]
                + heights[j * nx + i + 1]
                + heights[(j + 1) * nx + i]
                + heights[(j + 1) * nx + i + 1]
            ) / 4.0
            gray = int(round(255 * (h_avg / max_h))) if max_h > 0 else 180
            gray = max(0, min(255, gray))
            x = origin_x + i * cell
            z = origin_z + j * cell
            parts.append(
                f'<rect x="{x:.2f}" y="{z:.2f}" width="{cell:.2f}" height="{cell:.2f}" '
                f'fill="rgb({gray},{gray},{gray})" opacity="0.5" />'
            )


def generate_svg(roads, buildings, terrain, path):
    all_x = []
    all_z = []
    for road in roads:
        for x, z in road["points"]:
            all_x.append(x)
            all_z.append(z)
    for b in buildings:
        for x, z in b["footprint"]:
            all_x.append(x)
            all_z.append(z)
    # Incluir la extension de la grilla de terreno para que el hillshade no se recorte.
    all_x.append(terrain["origin_x"])
    all_x.append(terrain["origin_x"] + (terrain["nx"] - 1) * terrain["cell_size"])
    all_z.append(terrain["origin_z"])
    all_z.append(terrain["origin_z"] + (terrain["nz"] - 1) * terrain["cell_size"])

    if not all_x:
        print("Sin datos para preview.svg")
        return

    margin = 10.0
    min_x, max_x = min(all_x) - margin, max(all_x) + margin
    min_z, max_z = min(all_z) - margin, max(all_z) + margin
    width = max_x - min_x
    height = max_z - min_z

    # La formula de proyeccion ya deja z negativo hacia el norte, asi que
    # usar z directamente como coordenada svg-y coloca el norte arriba.
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{min_x:.2f} {min_z:.2f} {width:.2f} {height:.2f}">',
        f'<rect x="{min_x:.2f}" y="{min_z:.2f}" width="{width:.2f}" height="{height:.2f}" fill="#f0f0f0" />',
    ]

    _append_hillshade(parts, terrain)

    for b in buildings:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in b["footprint"])
        parts.append(f'<polygon points="{pts}" fill="#999999" stroke="none" />')

    for road in roads:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in road["points"])
        stroke_width = max(road["width"] * 0.5, 0.5)
        parts.append(
            f'<polyline points="{pts}" fill="none" stroke="#000000" '
            f'stroke-width="{stroke_width:.2f}" stroke-linecap="round" stroke-linejoin="round" />'
        )

    parts.append("</svg>")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print(f"preview.svg escrito: {path}")


def main():
    parser = argparse.ArgumentParser(description="Genera map.json desde OpenStreetMap (Overpass).")
    parser.add_argument("--refresh", action="store_true", help="Ignora la cache y vuelve a consultar Overpass.")
    parser.add_argument(
        "--refresh-elevation", action="store_true",
        help="Ignora la cache de elevacion y vuelve a consultar Open Topo Data.",
    )
    parser.add_argument("--stats", action="store_true", help="Imprime estadisticas del mapa generado.")
    parser.add_argument("--svg", action="store_true", help="Genera output/preview.svg.")
    args = parser.parse_args()

    t_start = time.time()
    raw = fetch_overpass(args.refresh)
    nodes, ways = index_elements(raw)
    print(f"{len(nodes)} nodos indexados, {len(ways)} ways a clasificar")

    stats = {
        "roads_by_type": {},
        "roads_oneway_by_value": {0: 0, 1: 0, -1: 0},
        "controls_by_type": {},
        "roads_discarded_few_points": 0,
        "roads_discarded_outside_bbox": 0,
        "buildings_discarded_not_closed": 0,
        "buildings_discarded_few_points": 0,
        "buildings_discarded_few_vertices": 0,
        "buildings_discarded_outside_bbox": 0,
    }

    roads = build_roads(ways, nodes, stats)
    buildings = build_buildings(ways, nodes, stats)
    controls = build_controls(raw, stats)

    t_terrain_start = time.time()
    terrain, terrain_stats = build_terrain(BBOX, args.refresh_elevation)
    terrain_elapsed = time.time() - t_terrain_start

    steepest_road_id = None
    steepest_slope = 0.0
    for road in roads:
        slope = road_slope_stats(road["points"], terrain)
        if slope > steepest_slope:
            steepest_slope = slope
            steepest_road_id = road["id"]

    batches_desc = "usando cache" if terrain_stats["num_batches"] is None else f"{terrain_stats['num_batches']} lotes"
    print(
        "terreno %dx%d (%d puntos, %s), elevacion %.1f-%.1f msnm (rango %.1f m), "
        "%d nulls rellenados, pendiente maxima %.1f%% (via id %s), %d ms"
        % (
            terrain["nx"], terrain["nz"], terrain_stats["num_points"], batches_desc,
            terrain_stats["elevation_min_abs"], terrain_stats["elevation_max_abs"],
            terrain_stats["elevation_max_rel"], terrain_stats["nulls_filled"],
            steepest_slope, str(steepest_road_id), int(terrain_elapsed * 1000),
        )
    )

    # v1.2: terrain es aditivo; roads/buildings/controls conservan su forma v1.1.
    map_data = {
        "meta": build_meta(),
        "roads": roads,
        "buildings": buildings,
        "controls": controls,
        "terrain": terrain,
    }

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(map_data, f, ensure_ascii=False, separators=(",", ":"))

    os.makedirs(os.path.dirname(GODOT_DATA_PATH), exist_ok=True)
    shutil.copyfile(OUTPUT_JSON_PATH, GODOT_DATA_PATH)

    elapsed = time.time() - t_start
    print(f"map.json escrito: {len(roads)} vias, {len(buildings)} edificios, {len(controls)} controles ({elapsed:.1f}s)")
    print(f"Copiado a {GODOT_DATA_PATH}")

    if args.stats:
        print_stats(roads, controls, buildings, stats, terrain_stats, (steepest_road_id, steepest_slope))

    if args.svg:
        generate_svg(roads, buildings, terrain, OUTPUT_SVG_PATH)


if __name__ == "__main__":
    main()
