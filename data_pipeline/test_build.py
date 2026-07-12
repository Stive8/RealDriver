#!/usr/bin/env python3
import json
import os
import tempfile
import unittest
from unittest.mock import patch

from citygen import build
from citygen.zones import ZoneSpec


def _flat_terrain(nx=4, nz=4, cell=30.0):
    return (
        {"cell_size": cell, "nx": nx, "nz": nz, "origin_x": -1300.0, "origin_z": -1300.0,
         "base_elevation": 900.0, "heights": [0.0] * (nx * nz)},
        {"num_points": nx * nz, "num_batches": 1, "nulls_filled": 0,
         "elevation_min_abs": 900.0, "elevation_max_abs": 900.0,
         "elevation_min_rel": 0.0, "elevation_max_rel": 0.0,
         "max_grade_before_smooth": 0.0, "max_grade_after_smooth": 0.0,
         "nodes_preserved": 0, "nodes_preserved_pct": 0.0, "exaggeration": 1.0},
    )


def _grid_way(way_id, node_ids, tags):
    return {"type": "way", "id": way_id, "nodes": node_ids, "tags": tags}


def _dense_grid_raw():
    """Una via larga y recta con suficiente longitud/densidad para pasar los techos."""
    elements = []
    node_id = 1
    node_ids = []
    # 400 nodos separados 10 m => 4 km de via, ampliamente sobre el minimo de 3 km.
    for i in range(400):
        elements.append({"type": "node", "id": node_id, "lat": 4.4380, "lon": -75.2019 + i * 0.0001})
        node_ids.append(node_id)
        node_id += 1
    elements.append(_grid_way(1, node_ids, {"highway": "residential"}))
    return {"elements": elements}


class TestGenerateFailures(unittest.TestCase):
    def test_insufficient_road_data_fails(self):
        raw = {"elements": [
            {"type": "node", "id": 1, "lat": 4.438, "lon": -75.202},
            {"type": "node", "id": 2, "lat": 4.4381, "lon": -75.2021},
            {"type": "way", "id": 1, "nodes": [1, 2], "tags": {"highway": "residential"}},
        ]}
        zone = ZoneSpec(name="Rural", size="S", lat=4.90, lon=-74.60)
        with tempfile.TemporaryDirectory() as tmp:
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()):
                result = build.generate(zone, tmp, os.path.join(tmp, "map.json"))
        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "insufficient_road_data")
        self.assertFalse(os.path.isfile(os.path.join(tmp, "map.json")))


class TestGenerateSuccess(unittest.TestCase):
    def test_successful_generation_writes_v1_4_meta(self):
        raw = _dense_grid_raw()
        zone = ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = os.path.join(tmp, "map.json")
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()):
                result = build.generate(zone, tmp, out_path)
            self.assertTrue(result.ok, result.reason)
            with open(out_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        self.assertEqual(data["meta"]["schema_version"], "1.4")
        self.assertEqual(data["meta"]["zone_size"], "M")
        self.assertIn("zone_id", data["meta"])
        self.assertIn("stats", data["meta"])
        self.assertIn("flags", data["meta"]["stats"])
        self.assertEqual(result.zone_id, data["meta"]["zone_id"])

    def test_sparse_buildings_flag_set_when_few_buildings(self):
        raw = _dense_grid_raw()
        zone = ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        with tempfile.TemporaryDirectory() as tmp:
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()):
                result = build.generate(zone, tmp, os.path.join(tmp, "map.json"))
        self.assertIn("sparse_buildings", result.stats["flags"])


class TestBuildMeta(unittest.TestCase):
    def test_schema_version_1_4_with_stats(self):
        from citygen.zones import ResolvedZone
        resolved = ResolvedZone(
            zone_id="z1_M_4_4380_m75_2020", cache_key="z1_M_4_4380_m75_2020",
            bbox=(4.0, -75.0, 5.0, -74.0), origin=(4.438, -75.202), size="M", name="Test",
        )
        stats = {"span_x": 2500.0, "span_z": 2500.0, "extent_m": [-1250.0, -1250.0, 1250.0, 1250.0],
                 "road_km": 41.2, "n_buildings": 8342, "largest_component_pct": 97.4,
                 "max_road_slope_pct": 6.1, "flags": []}
        meta = build.build_meta(resolved, stats)
        self.assertEqual(meta["schema_version"], "1.4")
        self.assertEqual(meta["name"], "Test")
        self.assertEqual(meta["zone_id"], "z1_M_4_4380_m75_2020")
        self.assertEqual(meta["zone_size"], "M")
        self.assertEqual(meta["stats"], stats)
        self.assertEqual(meta["bbox"], list(resolved.bbox))
        self.assertEqual(meta["origin"], {"lat": 4.438, "lon": -75.202})


def _dense_grid_raw_with_water():
    raw = _dense_grid_raw()
    elements = raw["elements"]
    water_nodes = [
        {"type": "node", "id": 9001, "lat": 4.4390, "lon": -75.2019},
        {"type": "node", "id": 9002, "lat": 4.4390, "lon": -75.2018},
        {"type": "node", "id": 9003, "lat": 4.4391, "lon": -75.2018},
        {"type": "node", "id": 9004, "lat": 4.4391, "lon": -75.2019},
    ]
    elements.extend(water_nodes)
    elements.append(_grid_way(9101, [9001, 9002, 9003, 9004, 9001], {"natural": "water"}))
    river_nodes = [
        {"type": "node", "id": 9201, "lat": 4.4395, "lon": -75.2019},
        {"type": "node", "id": 9202, "lat": 4.4395, "lon": -75.2010},
    ]
    elements.extend(river_nodes)
    elements.append(_grid_way(9102, [9201, 9202], {"waterway": "river"}))
    return {"elements": elements}


class TestWaterIntegration(unittest.TestCase):
    def test_water_sections_and_stats_present(self):
        raw = _dense_grid_raw_with_water()
        zone = ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = os.path.join(tmp, "map.json")
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()):
                result = build.generate(zone, tmp, out_path)
            self.assertTrue(result.ok, result.reason)
            with open(out_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        self.assertEqual(len(data["water_areas"]), 1)
        self.assertEqual(len(data["water_ways"]), 1)
        self.assertEqual(data["meta"]["stats"]["n_water_areas"], 1)
        self.assertEqual(data["meta"]["stats"]["n_water_ways"], 1)
        self.assertEqual(data["water_ways"][0]["kind"], "river")

    def test_build_terrain_receives_water_features(self):
        raw = _dense_grid_raw_with_water()
        zone = ZoneSpec(name="Test City", size="M", lat=4.4380, lon=-75.2019)
        with tempfile.TemporaryDirectory() as tmp:
            with patch("citygen.build.fetch_osm.fetch", return_value=raw), \
                 patch("citygen.build.fetch_elevation.build_terrain", return_value=_flat_terrain()) as mock_terrain:
                build.generate(zone, tmp, os.path.join(tmp, "map.json"))
            _, kwargs = mock_terrain.call_args
            self.assertEqual(len(kwargs["water_areas"]), 1)
            self.assertEqual(len(kwargs["water_ways"]), 1)


if __name__ == "__main__":
    unittest.main()
