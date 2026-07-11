#!/usr/bin/env python3
"""Tests unitarios para las funciones puras nuevas de la Fase R-1 (elevacion).

Uso: python -m unittest test_generate_map -v
No usa pytest (unica dependencia externa del proyecto es `requests`; unittest es stdlib).
Las llamadas de red se mockean con unittest.mock; no requieren conexion a internet.
"""
import json
import math
import os
import tempfile
import unittest
from unittest.mock import patch, MagicMock

import generate_map as gm


class TestProjectDeproject(unittest.TestCase):
    def test_deproject_is_inverse_of_project(self):
        lat, lon = 4.4380 + 0.003, -75.2019 - 0.004
        x, z = gm.project(lat, lon)
        lat2, lon2 = gm.deproject(x, z)
        self.assertAlmostEqual(lat, lat2, places=4)
        self.assertAlmostEqual(lon, lon2, places=4)

    def test_deproject_origin_is_lat0_lon0(self):
        lat, lon = gm.deproject(0.0, 0.0)
        self.assertAlmostEqual(lat, gm.LAT0, places=6)
        self.assertAlmostEqual(lon, gm.LON0, places=6)


class TestComputeGridParams(unittest.TestCase):
    def test_grid_covers_bbox_plus_margin(self):
        bbox = (4.433220, -75.210321, 4.442772, -75.193563)
        params = gm.compute_grid_params(bbox, margin=250.0, cell_size=30.0)
        self.assertEqual(params["cell_size"], 30.0)
        self.assertGreaterEqual(params["nx"], 2)
        self.assertGreaterEqual(params["nz"], 2)
        # El ultimo nodo de la grilla debe caer en o mas alla del bbox expandido.
        last_x = params["origin_x"] + (params["nx"] - 1) * params["cell_size"]
        last_z = params["origin_z"] + (params["nz"] - 1) * params["cell_size"]
        lat_s, lon_o, lat_n, lon_e = bbox
        max_x, _ = gm.project(lat_n, lon_e)
        _, max_z = gm.project(lat_s, lon_e)
        self.assertGreaterEqual(last_x, max_x + 250.0 - 30.0)
        self.assertGreaterEqual(last_z, max_z + 250.0 - 30.0)

    def test_small_bbox_produces_minimal_grid(self):
        # bbox degenerado (un punto): nx/nz deben ser >= 2 igualmente.
        bbox = (4.4380, -75.2019, 4.4380, -75.2019)
        params = gm.compute_grid_params(bbox, margin=30.0, cell_size=30.0)
        self.assertGreaterEqual(params["nx"], 2)
        self.assertGreaterEqual(params["nz"], 2)


class TestHeightAt(unittest.TestCase):
    def _flat_terrain(self, value=5.0):
        return {
            "cell_size": 10.0,
            "nx": 3,
            "nz": 3,
            "origin_x": 0.0,
            "origin_z": 0.0,
            "heights": [value] * 9,
        }

    def test_flat_grid_returns_constant(self):
        terrain = self._flat_terrain(7.5)
        self.assertAlmostEqual(gm.height_at(5.0, 5.0, terrain), 7.5)
        self.assertAlmostEqual(gm.height_at(0.0, 0.0, terrain), 7.5)
        self.assertAlmostEqual(gm.height_at(20.0, 20.0, terrain), 7.5)

    def test_bilinear_interpolation_at_center_of_cell(self):
        # grilla 2x2: (0,0)=0, (1,0)=10, (0,1)=0, (1,1)=10 -> rampa en x
        terrain = {
            "cell_size": 10.0,
            "nx": 2,
            "nz": 2,
            "origin_x": 0.0,
            "origin_z": 0.0,
            "heights": [0.0, 10.0, 0.0, 10.0],
        }
        self.assertAlmostEqual(gm.height_at(5.0, 5.0, terrain), 5.0)
        self.assertAlmostEqual(gm.height_at(0.0, 0.0, terrain), 0.0)
        self.assertAlmostEqual(gm.height_at(9.0, 0.0, terrain), 9.0)
        self.assertAlmostEqual(gm.height_at(2.5, 0.0, terrain), 2.5)
        # En el borde exacto (x = ultimo nodo), el clamp a nx-1.001 del contrato
        # (evita salirse del arreglo) introduce un epsilon conocido, no un bug.
        self.assertAlmostEqual(gm.height_at(10.0, 0.0, terrain), 10.0, delta=0.02)

    def test_out_of_bounds_clamps_to_edge(self):
        terrain = self._flat_terrain(3.0)
        self.assertAlmostEqual(gm.height_at(-100.0, -100.0, terrain), 3.0)
        self.assertAlmostEqual(gm.height_at(1000.0, 1000.0, terrain), 3.0)


class TestFillNulls(unittest.TestCase):
    def test_no_nulls_returns_unchanged(self):
        heights = [1.0, 2.0, 3.0, 4.0]
        filled, count = gm.fill_nulls(heights, nx=2, nz=2)
        self.assertEqual(filled, heights)
        self.assertEqual(count, 0)

    def test_fills_with_nearest_valid_ring(self):
        # grilla 3x3, fila-mayor; index = j*3+i
        # j=0: [1, None, 3]
        # j=1: [None, None, None]
        # j=2: [7, None, 9]
        heights = [1.0, None, 3.0, None, None, None, 7.0, None, 9.0]
        filled, count = gm.fill_nulls(heights, nx=3, nz=3)
        self.assertEqual(count, 5)
        self.assertNotIn(None, filled)
        # centro (1,1) equidistante de las 4 esquinas; debe tomar alguna valida (no None)
        center = filled[1 * 3 + 1]
        self.assertIn(center, [1.0, 3.0, 7.0, 9.0])
        # (1,0) esta a distancia 1 de (0,0)=1.0 y de (2,0)=3.0 -> ambas a igual distancia (ring radius 1)
        self.assertIn(filled[0 * 3 + 1], [1.0, 3.0])

    def test_all_null_raises(self):
        heights = [None] * 4
        with self.assertRaises(ValueError):
            gm.fill_nulls(heights, nx=2, nz=2)


class TestSmoothHeights(unittest.TestCase):
    def test_zero_passes_returns_unchanged(self):
        heights = [1.0, 2.0, 3.0, 4.0]
        result = gm.smooth_heights(heights, nx=2, nz=2, passes=0)
        self.assertEqual(result, heights)

    def test_flat_grid_stays_flat(self):
        heights = [5.0] * 9
        result = gm.smooth_heights(heights, nx=3, nz=3, passes=1)
        for h in result:
            self.assertAlmostEqual(h, 5.0)

    def test_single_spike_is_smoothed_down(self):
        # grilla 3x3 con un pico en el centro
        heights = [0.0, 0.0, 0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0]
        result = gm.smooth_heights(heights, nx=3, nz=3, passes=1)
        center = result[1 * 3 + 1]
        self.assertLess(center, 9.0)
        self.assertGreater(center, 0.0)


class TestResamplePolyline(unittest.TestCase):
    def test_short_polyline_unchanged(self):
        points = [(0.0, 0.0), (5.0, 0.0)]
        result = gm.resample_polyline(points, step=10.0)
        self.assertEqual(result[0], (0.0, 0.0))
        self.assertEqual(result[-1], (5.0, 0.0))

    def test_straight_line_resampled_every_step(self):
        points = [(0.0, 0.0), (100.0, 0.0)]
        result = gm.resample_polyline(points, step=10.0)
        self.assertEqual(result[0], (0.0, 0.0))
        self.assertEqual(result[-1], (100.0, 0.0))
        # puntos intermedios deben avanzar ~10m en x
        for k in range(len(result) - 1):
            dx = result[k + 1][0] - result[k][0]
            self.assertGreater(dx, 0.0)
            self.assertLessEqual(dx, 10.001)


class TestRoadSlopeStats(unittest.TestCase):
    def test_flat_terrain_zero_slope(self):
        terrain = {
            "cell_size": 10.0, "nx": 20, "nz": 2,
            "origin_x": 0.0, "origin_z": 0.0,
            "heights": [0.0] * 40,
        }
        points = [[0.0, 5.0], [100.0, 5.0]]
        slope = gm.road_slope_stats(points, terrain)
        self.assertAlmostEqual(slope, 0.0)

    def test_ramp_terrain_detects_known_slope(self):
        # rampa: sube 1m cada 10m en x -> 10% de pendiente
        nx, nz = 20, 2
        heights = []
        for j in range(nz):
            for i in range(nx):
                heights.append(float(i))
        terrain = {
            "cell_size": 10.0, "nx": nx, "nz": nz,
            "origin_x": 0.0, "origin_z": 0.0,
            "heights": heights,
        }
        points = [[0.0, 5.0], [100.0, 5.0]]
        slope = gm.road_slope_stats(points, terrain)
        self.assertAlmostEqual(slope, 10.0, delta=0.5)


class TestElevationCache(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.path = os.path.join(self.tmpdir, "elevation_raw.json")
        self.bbox = (1.0, 2.0, 3.0, 4.0)
        self.grid_params = {"cell_size": 30.0, "nx": 5, "nz": 5, "origin_x": 0.0, "origin_z": 0.0}

    def test_missing_cache_returns_none(self):
        self.assertIsNone(gm.load_elevation_cache(self.path, self.bbox, self.grid_params))

    def test_save_then_load_roundtrip(self):
        elevations = [1.0, 2.0, None, 4.0]
        gm.save_elevation_cache(self.path, self.bbox, self.grid_params, elevations)
        loaded = gm.load_elevation_cache(self.path, self.bbox, self.grid_params)
        self.assertEqual(loaded, elevations)

    def test_bbox_mismatch_invalidates_cache(self):
        gm.save_elevation_cache(self.path, self.bbox, self.grid_params, [1.0])
        other_bbox = (9.0, 9.0, 9.0, 9.0)
        self.assertIsNone(gm.load_elevation_cache(self.path, other_bbox, self.grid_params))

    def test_grid_mismatch_invalidates_cache(self):
        gm.save_elevation_cache(self.path, self.bbox, self.grid_params, [1.0])
        other_grid = dict(self.grid_params, nx=999)
        self.assertIsNone(gm.load_elevation_cache(self.path, self.bbox, other_grid))


def _mock_response(status_code, json_body):
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = json_body
    if status_code >= 400:
        resp.raise_for_status.side_effect = Exception(f"HTTP {status_code}")
    else:
        resp.raise_for_status.side_effect = None
    return resp


class TestFetchElevationBatch(unittest.TestCase):
    def test_success_returns_elevations_in_order(self):
        body = {"status": "OK", "results": [{"elevation": 100.0}, {"elevation": 200.0}]}
        with patch.object(gm.requests, "get", return_value=_mock_response(200, body)) as mock_get:
            result = gm.fetch_elevation_batch([(1.0, 2.0), (3.0, 4.0)])
        self.assertEqual(result, [100.0, 200.0])
        mock_get.assert_called_once()

    def test_null_elevation_preserved(self):
        body = {"status": "OK", "results": [{"elevation": None}]}
        with patch.object(gm.requests, "get", return_value=_mock_response(200, body)):
            result = gm.fetch_elevation_batch([(1.0, 2.0)])
        self.assertEqual(result, [None])

    @patch("generate_map.time.sleep", return_value=None)
    def test_retries_on_429_then_succeeds(self, mock_sleep):
        fail_resp = _mock_response(429, {})
        ok_body = {"status": "OK", "results": [{"elevation": 50.0}]}
        ok_resp = _mock_response(200, ok_body)
        with patch.object(gm.requests, "get", side_effect=[fail_resp, ok_resp]):
            result = gm.fetch_elevation_batch([(1.0, 2.0)])
        self.assertEqual(result, [50.0])
        mock_sleep.assert_called_once_with(2)

    @patch("generate_map.time.sleep", return_value=None)
    def test_raises_after_exhausting_retries(self, mock_sleep):
        fail_resp = _mock_response(500, {})
        with patch.object(gm.requests, "get", return_value=fail_resp):
            with self.assertRaises(RuntimeError):
                gm.fetch_elevation_batch([(1.0, 2.0)], retries=3, backoff=(2, 4, 8))
        self.assertEqual(mock_sleep.call_count, 3)


class TestBuildMeta(unittest.TestCase):
    def test_schema_version_is_1_2_with_elevation_source(self):
        meta = gm.build_meta()
        self.assertEqual(meta["schema_version"], "1.2")
        self.assertEqual(meta["elevation_source"]["dataset"], "srtm30m,mapzen")
        self.assertEqual(meta["elevation_source"]["provider"], "opentopodata.org")
        self.assertIn("fetched_at", meta["elevation_source"])


if __name__ == "__main__":
    unittest.main()
