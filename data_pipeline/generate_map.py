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
    return {
        "source": "OpenStreetMap",
        "license": "ODbL 1.0",
        "attribution": "© OpenStreetMap contributors",
        "bbox": list(BBOX),
        "origin": {"lat": LAT0, "lon": LON0},
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "schema_version": "1.1",
    }


def print_stats(roads, controls, buildings, stats):
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


def generate_svg(roads, buildings, path):
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

    # v1.1: campos nuevos opcionales y retrocompatibles. buildings sin cambios.
    map_data = {
        "meta": build_meta(),
        "roads": roads,
        "buildings": buildings,
        "controls": controls,
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
        print_stats(roads, controls, buildings, stats)

    if args.svg:
        generate_svg(roads, buildings, OUTPUT_SVG_PATH)


if __name__ == "__main__":
    main()
