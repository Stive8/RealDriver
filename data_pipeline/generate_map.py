#!/usr/bin/env python3
"""CLI de desarrollo sobre citygen: genera map.json para Jordan (legado) o
para cualquier zona nueva (centro + tamano).

Uso:
  python generate_map.py --legacy-jordan [--refresh] [--refresh-elevation] [--stats] [--svg]
  python generate_map.py --lat 4.60 --lon -74.08 --size M --name "Bogota" [--refresh] [--stats] [--svg]
"""
import argparse
import os
import shutil
import time

from citygen import ZoneSpec, generate

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(SCRIPT_DIR, "cache")
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "output")
OUTPUT_JSON_PATH = os.path.join(OUTPUT_DIR, "map.json")
OUTPUT_SVG_PATH = os.path.join(OUTPUT_DIR, "preview.svg")
GODOT_DATA_PATH = os.path.join(SCRIPT_DIR, "..", "godot", "data", "map.json")

# Bbox/origen historicos de Jordan (ESPEC_SESION.md original); se mantienen
# intactos para no huerfanar los tiempos record ya guardados.
LEGACY_BBOX = (4.433220, -75.210321, 4.442772, -75.193563)
LEGACY_ORIGIN = (4.4380, -75.2019)


def _print_stage(stage: str):
    print(f"[{stage}] ...")


def main():
    parser = argparse.ArgumentParser(description="Genera map.json via citygen.")
    parser.add_argument("--legacy-jordan", action="store_true", help="Regenera Jordan con su bbox/origen historicos.")
    parser.add_argument("--lat", type=float, help="Latitud del centro de la zona nueva.")
    parser.add_argument("--lon", type=float, help="Longitud del centro de la zona nueva.")
    parser.add_argument("--size", choices=["S", "M", "L"], default="M", help="Tamano de zona (default M).")
    parser.add_argument("--name", default="", help="Nombre de presentacion de la zona.")
    parser.add_argument("--refresh", action="store_true", help="Ignora la cache de Overpass.")
    parser.add_argument("--refresh-elevation", action="store_true", help="Ignora la cache de elevacion.")
    parser.add_argument("--stats", action="store_true", help="Imprime estadisticas del mapa generado.")
    parser.add_argument("--svg", action="store_true", help="Genera output/preview.svg.")
    args = parser.parse_args()

    if args.legacy_jordan:
        zone = ZoneSpec(name="Jordán, Ibagué", size="custom", bbox=LEGACY_BBOX, origin=LEGACY_ORIGIN)
    elif args.lat is not None and args.lon is not None:
        if not args.name:
            parser.error("--name es requerido junto con --lat/--lon")
        zone = ZoneSpec(name=args.name, size=args.size, lat=args.lat, lon=args.lon)
    else:
        parser.error("Debe especificar --legacy-jordan o --lat/--lon (+ --size/--name)")

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    svg_path = OUTPUT_SVG_PATH if args.svg else None

    t0 = time.time()
    result = generate(
        zone, CACHE_DIR, OUTPUT_JSON_PATH, progress_cb=_print_stage,
        refresh=args.refresh, refresh_elevation=args.refresh_elevation, svg_path=svg_path,
    )
    elapsed = time.time() - t0

    if not result.ok:
        print(f"FALLO ({elapsed:.1f}s): {result.reason}")
        raise SystemExit(1)

    print(f"map.json escrito en {elapsed:.1f}s: zone_id={result.zone_id}")
    print(
        "  vias=%d edificios=%d controles=%d road_km=%.1f componente_mayor=%.1f%% "
        "pendiente_max=%.1f%% flags=%s"
        % (
            result.diagnostics["n_roads"], result.stats["n_buildings"], result.diagnostics["n_controls"],
            result.stats["road_km"], result.stats["largest_component_pct"],
            result.stats["max_road_slope_pct"], result.stats["flags"],
        )
    )

    if args.legacy_jordan:
        os.makedirs(os.path.dirname(GODOT_DATA_PATH), exist_ok=True)
        shutil.copyfile(OUTPUT_JSON_PATH, GODOT_DATA_PATH)
        print(f"Copiado a {GODOT_DATA_PATH}")

    if args.stats:
        ts = result.diagnostics["terrain_stats"]
        os_ = result.diagnostics["osm_stats"]
        print("--- stats ---")
        print(f"tamano map.json: {result.diagnostics['size_bytes']} bytes")
        print(f"elevacion: {ts['elevation_min_abs']:.1f}-{ts['elevation_max_abs']:.1f} msnm")
        print(f"pendiente celdas adyacentes: {ts['max_grade_before_smooth']:.1f}% -> {ts['max_grade_after_smooth']:.1f}%")
        print(f"descartes vias: pocos_puntos={os_['roads_discarded_few_points']} fuera_bbox={os_['roads_discarded_outside_bbox']}")
        print(
            f"descartes edificios: no_cerrado={os_['buildings_discarded_not_closed']} "
            f"pocos_puntos={os_['buildings_discarded_few_points']} "
            f"pocos_vertices={os_['buildings_discarded_few_vertices']} "
            f"fuera_bbox={os_['buildings_discarded_outside_bbox']}"
        )
        print(
            f"agua: areas={result.stats['n_water_areas']} vias={result.stats['n_water_ways']} "
            f"nodos_excavados={ts['water_excavated_nodes']} "
            f"delta_max_fuera_de_zona={ts['water_excavated_delta_outside']:.4f}m"
        )
        print(
            f"descartes agua: areas(no_cerrado={os_['water_areas_discarded_not_closed']} "
            f"pocos_puntos={os_['water_areas_discarded_few_points']} "
            f"pocos_vertices={os_['water_areas_discarded_few_vertices']} "
            f"fuera_bbox={os_['water_areas_discarded_outside_bbox']}) "
            f"vias(pocos_puntos={os_['water_ways_discarded_few_points']} "
            f"fuera_bbox={os_['water_ways_discarded_outside_bbox']})"
        )
        print(
            f"puentes={result.stats['n_bridges']} tuneles={result.stats['n_tunnels']} "
            f"con_layer={result.stats['n_layered']} ramales(*_link)={result.stats['n_links']}"
        )


if __name__ == "__main__":
    main()
