"""Fetch de vias/edificios/controles desde Overpass y su proyeccion a metros."""
import json
import os
import random
import time

import requests

from . import zones

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OVERPASS_FALLBACK_URL = "https://overpass.kumi.systems/api/interpreter"
USER_AGENT = "ciudad-conducible-dev/0.1"

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
    "motorway_link": 5.0,
    "trunk_link": 5.0,
    "primary_link": 5.0,
    "secondary_link": 5.0,
    "tertiary_link": 5.0,
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


def build_query(bbox: tuple) -> str:
    lat_s, lon_o, lat_n, lon_e = bbox
    bbox_str = f"{lat_s:.6f},{lon_o:.6f},{lat_n:.6f},{lon_e:.6f}"
    return f"""[out:json][timeout:90];
(
  way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|service|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"]({bbox_str});
  way["building"]({bbox_str});
  way["natural"="water"]({bbox_str});
  way["waterway"~"^(river|stream|canal)$"]({bbox_str});
);
out body;
>;
out body qt;
"""


def fetch(bbox: tuple, cache_dir: str, refresh: bool) -> dict:
    cache_path = os.path.join(cache_dir, "overpass_raw.json")
    query = build_query(bbox)
    if not refresh:
        cached = load_osm_cache(cache_path, query)
        if cached is not None:
            print(f"Usando cache: {cache_path}")
            return cached

    os.makedirs(cache_dir, exist_ok=True)
    headers = {"User-Agent": USER_AGENT}
    last_error = None
    for url in (OVERPASS_URL, OVERPASS_FALLBACK_URL):
        try:
            print(f"Consultando Overpass: {url}")
            t0 = time.time()
            resp = requests.post(url, data={"data": query}, headers=headers, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            print(f"  respuesta en {time.time() - t0:.1f}s, {len(resp.content)} bytes")
            save_osm_cache(cache_path, query, data)
            return data
        except Exception as exc:
            last_error = exc
            print(f"  fallo ({url}): {exc}")
    raise RuntimeError(f"No se pudo consultar Overpass en ningun endpoint: {last_error}")


def load_osm_cache(path: str, query: str):
    """Retorna la respuesta cacheada si la query coincide con la guardada; si no, None
    (imprime el motivo -- cache ausente, corrupta, formato viejo sin query registrada, o
    query distinta -- para nunca generar en silencio con datos de una query vieja)."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            cache = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"  cache invalida ({exc}): re-consultando")
        return None
    if not isinstance(cache, dict) or "query" not in cache or "response" not in cache:
        print("  cache en formato viejo (sin query registrada): re-consultando")
        return None
    if cache["query"] != query:
        print("  cache invalidada: la query cambio respecto a la guardada; re-consultando")
        return None
    return cache["response"]


def save_osm_cache(path: str, query: str, data: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"query": query, "response": data}, f)


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


def in_bbox(lat: float, lon: float, bbox: tuple) -> bool:
    lat_s, lon_o, lat_n, lon_e = bbox
    return lat_s <= lat <= lat_n and lon_o <= lon <= lon_e


def any_point_in_bbox(points, bbox: tuple) -> bool:
    return any(in_bbox(lat, lon, bbox) for lat, lon in points)


def road_width(tags: dict) -> float:
    width_tag = tags.get("width")
    if width_tag is not None:
        try:
            return zones.clamp(float(str(width_tag).split()[0]), *WIDTH_CLAMP)
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
            return round(zones.clamp(float(str(height_tag).split()[0]), *HEIGHT_CLAMP), 2)
        except (ValueError, TypeError):
            pass
    levels_tag = tags.get("building:levels")
    if levels_tag is not None:
        try:
            return round(zones.clamp(float(levels_tag) * LEVEL_HEIGHT, *HEIGHT_CLAMP), 2)
        except (ValueError, TypeError):
            pass
    # Semilla = id crudo de OSM (no el id secuencial de salida): asi la
    # altura "aleatoria" de un edificio no cambia si un --refresh futuro
    # agrega o quita otros edificios y corre la numeracion secuencial.
    rng = random.Random(osm_way_id)
    return round(rng.uniform(*HEIGHT_RANDOM_RANGE), 2)


def build_roads(ways, nodes, bbox, origin, stats):
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
        if not any_point_in_bbox(points, bbox):
            stats["roads_discarded_outside_bbox"] += 1
            continue
        projected = [zones.project(lat, lon, origin) for lat, lon in points]
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


def build_controls(raw: dict, bbox: tuple, origin: tuple, stats: dict):
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
        if not in_bbox(lat, lon, bbox):
            continue
        x, z = zones.project(lat, lon, origin)
        controls.append({"type": ctype, "pos": [x, z]})
        stats["controls_by_type"][ctype] = stats["controls_by_type"].get(ctype, 0) + 1
    return controls


def build_buildings(ways, nodes, bbox, origin, stats):
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
        if not any_point_in_bbox(points, bbox):
            stats["buildings_discarded_outside_bbox"] += 1
            continue
        # El ultimo punto duplica al primero (way cerrado); se cuenta el
        # vertice real (len - 1). El duplicado se conserva en el footprint:
        # building_builder.gd (Fase 3) es responsable de quitarlo.
        effective_vertices = len(points) - 1
        if effective_vertices < 3:
            stats["buildings_discarded_few_vertices"] += 1
            continue
        projected = [zones.project(lat, lon, origin) for lat, lon in points]
        buildings.append({
            "id": next_id,
            "height": building_height(tags, way["id"]),
            "footprint": [[x, z] for x, z in projected],
        })
        next_id += 1
    return buildings
