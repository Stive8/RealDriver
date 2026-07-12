"""Grilla de terreno y elevacion (bloque de relieve R-1..R-5, sin cambios de
algoritmo -- solo bbox/origin/cache_dir parametrizados en vez de constantes de modulo)."""
import json
import math
import os
import time

import requests

from . import zones

OPENTOPODATA_URL = "https://api.opentopodata.org/v1/srtm30m,mapzen"
ELEVATION_DATASET = "srtm30m,mapzen"
ELEVATION_PROVIDER = "opentopodata.org"
GRID_CELL = 30.0
ELEVATION_BATCH_SIZE = 100
ELEVATION_BATCH_PAUSE = 1.2
ELEVATION_RETRIES = 3
ELEVATION_BACKOFF = (2, 4, 8)
SLOPE_SAMPLE_STEP = 10.0  # paso de re-muestreo de vias para --stats (pendiente maxima)
# --- [ESTRUCTURAL] Fase R-5: kernel de suavizado condicional ---
SMOOTH_DELTA_MAX = 0.5  # m; desnivel real (> esto) entre un nodo y su promedio 3x3: se preserva intacto
GRID_MARGIN = 250.0  # m, expansion de la grilla de terreno mas alla del bbox
SMOOTH_PASSES = 1  # pasadas de suavizado condicional sobre la grilla de elevacion
TERRAIN_EXAGGERATION = 1.0  # clamp [1.0, 1.3]; percepcion de pendiente en juego vs. sitio real
USER_AGENT = "ciudad-conducible-dev/0.1"


def compute_grid_params(bbox, origin, margin: float, cell_size: float) -> dict:
    """Deriva la grilla de terreno que cubre `bbox` expandido `margin` m por lado.

    Contrato R-1: origin_x/z = min proyectado del bbox expandido; nx/nz cubren
    hasta el borde opuesto expandido con un nodo extra (ceil(ancho/cell)+1).
    """
    lat_s, lon_o, lat_n, lon_e = bbox
    corners = [(lat_s, lon_o), (lat_s, lon_e), (lat_n, lon_o), (lat_n, lon_e)]
    projected = [zones.project(lat, lon, origin) for lat, lon in corners]
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

    gx = zones.clamp((x - origin_x) / cell_size, 0.0, nx - 1.001)
    gz = zones.clamp((z - origin_z) / cell_size, 0.0, nz - 1.001)
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


def fetch_elevations(grid_points, grid_params: dict, bbox, cache_dir: str, refresh_elevation: bool):
    """Orquesta la consulta de elevaciones para todos los puntos de la grilla, con cache.

    Retorna (elevaciones, num_lotes) donde num_lotes es None si se uso la cache.
    """
    cache_path = os.path.join(cache_dir, "elevation_raw.json")
    cached = None if refresh_elevation else load_elevation_cache(cache_path, bbox, grid_params)
    if cached is not None:
        print(f"Usando cache de elevacion: {cache_path}")
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

    save_elevation_cache(cache_path, bbox, grid_params, all_elevations)
    return all_elevations, num_batches


def build_terrain(bbox, origin, cache_dir: str, refresh_elevation: bool):
    """Construye la seccion `terrain` completa (grilla + elevaciones + post-proceso)."""
    grid_params = compute_grid_params(bbox, origin, GRID_MARGIN, GRID_CELL)
    nx, nz = grid_params["nx"], grid_params["nz"]
    origin_x, origin_z, cell_size = grid_params["origin_x"], grid_params["origin_z"], grid_params["cell_size"]

    grid_points = []
    for j in range(nz):
        for i in range(nx):
            x = origin_x + i * cell_size
            z = origin_z + j * cell_size
            grid_points.append(zones.deproject(x, z, origin))

    raw_elevations, num_batches = fetch_elevations(grid_points, grid_params, bbox, cache_dir, refresh_elevation)
    filled, nulls_filled = fill_nulls(raw_elevations, nx, nz)

    max_grade_before_smooth = max_adjacent_grade(filled, nx, nz, cell_size)
    smoothed, nodes_preserved = smooth_heights(filled, nx, nz, SMOOTH_PASSES, SMOOTH_DELTA_MAX)
    max_grade_after_smooth = max_adjacent_grade(smoothed, nx, nz, cell_size)

    raw_min = min(smoothed)
    raw_max = max(smoothed)

    # Palanca de percepcion (R-5): amplifica el relieve alrededor del punto mas bajo de la
    # grilla, DESPUES de suavizar y ANTES de restar base_elevation/redondear. min(exagerado)
    # == raw_min siempre (el nodo minimo tiene h-raw_min=0), asi que base_elevation no cambia.
    exaggeration = zones.clamp(TERRAIN_EXAGGERATION, 1.0, 1.3)
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
