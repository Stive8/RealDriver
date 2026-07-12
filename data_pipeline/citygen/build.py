"""Orquestacion de la generacion completa de una zona: fetch + terrain + stats +
validacion + escritura de map.json. Unico punto de entrada publico de citygen
(usado por generate_map.py y, en C-2, por el worker del backend)."""
import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone

from . import fetch_elevation, fetch_osm, svg_preview, validate, zones

SCHEMA_VERSION = "1.4"


@dataclass
class GenResult:
    ok: bool
    reason: str
    stats: dict
    zone_id: str
    diagnostics: dict = field(default_factory=dict)


def build_meta(resolved: "zones.ResolvedZone", stats: dict) -> dict:
    generated_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return {
        "source": "OpenStreetMap",
        "license": "ODbL 1.0",
        "attribution": "© OpenStreetMap contributors",
        "bbox": list(resolved.bbox),
        "origin": {"lat": resolved.origin[0], "lon": resolved.origin[1]},
        "generated_at": generated_at,
        "schema_version": SCHEMA_VERSION,
        "elevation_source": {
            "dataset": fetch_elevation.ELEVATION_DATASET,
            "provider": fetch_elevation.ELEVATION_PROVIDER,
            "fetched_at": generated_at,
        },
        "name": resolved.name,
        "zone_id": resolved.zone_id,
        "zone_size": resolved.size,
        "stats": stats,
    }


def _extent_and_span(bbox, origin):
    lat_s, lon_o, lat_n, lon_e = bbox
    corners = [(lat_s, lon_o), (lat_s, lon_e), (lat_n, lon_o), (lat_n, lon_e)]
    projected = [zones.project(lat, lon, origin) for lat, lon in corners]
    xs = [p[0] for p in projected]
    zs = [p[1] for p in projected]
    extent = [min(xs), min(zs), max(xs), max(zs)]
    span_x = extent[2] - extent[0]
    span_z = extent[3] - extent[1]
    return extent, span_x, span_z


def generate(zone: "zones.ZoneSpec", cache_dir: str, out_path: str, progress_cb=None,
             refresh: bool = False, refresh_elevation: bool = False, svg_path: str = None) -> GenResult:
    def report(stage):
        if progress_cb is not None:
            progress_cb(stage)

    resolved = zones.resolve(zone)
    zone_cache_dir = os.path.join(cache_dir, resolved.cache_key)

    report("osm")
    raw = fetch_osm.fetch(resolved.bbox, zone_cache_dir, refresh)
    nodes, ways = fetch_osm.index_elements(raw)

    osm_stats = {
        "roads_by_type": {}, "roads_oneway_by_value": {0: 0, 1: 0, -1: 0}, "controls_by_type": {},
        "roads_discarded_few_points": 0, "roads_discarded_outside_bbox": 0,
        "buildings_discarded_not_closed": 0, "buildings_discarded_few_points": 0,
        "buildings_discarded_few_vertices": 0, "buildings_discarded_outside_bbox": 0,
        "n_bridges": 0, "n_tunnels": 0, "n_layered": 0, "n_links": 0,
        "water_areas_discarded_not_closed": 0, "water_areas_discarded_few_points": 0,
        "water_areas_discarded_few_vertices": 0, "water_areas_discarded_outside_bbox": 0,
        "water_ways_discarded_few_points": 0, "water_ways_discarded_outside_bbox": 0,
    }
    roads = fetch_osm.build_roads(ways, nodes, resolved.bbox, resolved.origin, osm_stats)
    buildings = fetch_osm.build_buildings(ways, nodes, resolved.bbox, resolved.origin, osm_stats)
    controls = fetch_osm.build_controls(raw, resolved.bbox, resolved.origin, osm_stats)
    water_areas = fetch_osm.build_water_areas(ways, nodes, resolved.bbox, resolved.origin, osm_stats)
    water_ways = fetch_osm.build_water_ways(ways, nodes, resolved.bbox, resolved.origin, osm_stats)

    road_km, largest_component_pct = validate.compute_connectivity(roads)

    reason = validate.check_road_data(road_km) or validate.check_connectivity(largest_component_pct)
    if reason is not None:
        return GenResult(ok=False, reason=reason, stats=None, zone_id=resolved.zone_id)

    reason = validate.check_building_cap(len(buildings))
    if reason is not None:
        return GenResult(ok=False, reason=reason, stats=None, zone_id=resolved.zone_id)

    report("elevation")
    terrain, terrain_stats = fetch_elevation.build_terrain(
        resolved.bbox, resolved.origin, zone_cache_dir, refresh_elevation,
        water_areas=water_areas, water_ways=water_ways,
    )

    report("build")
    max_road_slope_pct = 0.0
    for road in roads:
        slope = fetch_elevation.road_slope_stats(road["points"], terrain)
        if slope > max_road_slope_pct:
            max_road_slope_pct = slope

    extent, span_x, span_z = _extent_and_span(resolved.bbox, resolved.origin)
    flags = validate.compute_flags(len(buildings), max_road_slope_pct)
    stats = {
        "span_x": round(span_x, 1), "span_z": round(span_z, 1),
        "extent_m": [round(v, 1) for v in extent],
        "road_km": round(road_km, 1), "n_buildings": len(buildings),
        "largest_component_pct": round(largest_component_pct, 1),
        "max_road_slope_pct": round(max_road_slope_pct, 1), "flags": flags,
        "n_bridges": osm_stats["n_bridges"], "n_tunnels": osm_stats["n_tunnels"],
        "n_layered": osm_stats["n_layered"], "n_links": osm_stats["n_links"],
        "n_water_areas": len(water_areas), "n_water_ways": len(water_ways),
    }

    meta = build_meta(resolved, stats)
    map_data = {
        "meta": meta, "roads": roads, "buildings": buildings, "controls": controls,
        "water_areas": water_areas, "water_ways": water_ways, "terrain": terrain,
    }
    serialized = json.dumps(map_data, ensure_ascii=False, separators=(",", ":"))
    size_bytes = len(serialized.encode("utf-8"))

    reason = validate.check_file_size(size_bytes)
    if reason is not None:
        return GenResult(ok=False, reason=reason, stats=stats, zone_id=resolved.zone_id)

    report("package")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(serialized)

    if svg_path is not None:
        svg_preview.generate_svg(roads, buildings, water_areas, water_ways, terrain, svg_path)

    diagnostics = {
        "osm_stats": osm_stats, "terrain_stats": terrain_stats,
        "size_bytes": size_bytes, "n_roads": len(roads), "n_controls": len(controls),
    }
    return GenResult(ok=True, reason=None, stats=stats, zone_id=resolved.zone_id, diagnostics=diagnostics)
