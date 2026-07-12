#!/usr/bin/env python3
import os
import tempfile
import unittest
from unittest.mock import patch, MagicMock

from citygen import fetch_elevation as fe


class TestComputeGridParams(unittest.TestCase):
    def test_grid_covers_bbox_plus_margin(self):
        bbox = (4.433220, -75.210321, 4.442772, -75.193563)
        origin = (4.4380, -75.2019)
        params = fe.compute_grid_params(bbox, origin, margin=250.0, cell_size=30.0)
        self.assertEqual(params["cell_size"], 30.0)
        self.assertGreaterEqual(params["nx"], 2)
        self.assertGreaterEqual(params["nz"], 2)

    def test_small_bbox_produces_minimal_grid(self):
        bbox = (4.4380, -75.2019, 4.4380, -75.2019)
        origin = (4.4380, -75.2019)
        params = fe.compute_grid_params(bbox, origin, margin=30.0, cell_size=30.0)
        self.assertGreaterEqual(params["nx"], 2)
        self.assertGreaterEqual(params["nz"], 2)


class TestHeightAt(unittest.TestCase):
    def _flat_terrain(self, value=5.0):
        return {"cell_size": 10.0, "nx": 3, "nz": 3, "origin_x": 0.0, "origin_z": 0.0,
                "heights": [value] * 9}

    def test_flat_grid_returns_constant(self):
        terrain = self._flat_terrain(7.5)
        self.assertAlmostEqual(fe.height_at(5.0, 5.0, terrain), 7.5)

    def test_bilinear_interpolation_at_center_of_cell(self):
        terrain = {"cell_size": 10.0, "nx": 2, "nz": 2, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": [0.0, 10.0, 0.0, 10.0]}
        self.assertAlmostEqual(fe.height_at(5.0, 5.0, terrain), 5.0)
        self.assertAlmostEqual(fe.height_at(2.5, 0.0, terrain), 2.5)

    def test_out_of_bounds_clamps_to_edge(self):
        terrain = self._flat_terrain(3.0)
        self.assertAlmostEqual(fe.height_at(-100.0, -100.0, terrain), 3.0)
        self.assertAlmostEqual(fe.height_at(1000.0, 1000.0, terrain), 3.0)


class TestFillNulls(unittest.TestCase):
    def test_no_nulls_returns_unchanged(self):
        heights = [1.0, 2.0, 3.0, 4.0]
        filled, count = fe.fill_nulls(heights, nx=2, nz=2)
        self.assertEqual(filled, heights)
        self.assertEqual(count, 0)

    def test_fills_with_nearest_valid_ring(self):
        heights = [1.0, None, 3.0, None, None, None, 7.0, None, 9.0]
        filled, count = fe.fill_nulls(heights, nx=3, nz=3)
        self.assertEqual(count, 5)
        self.assertNotIn(None, filled)

    def test_all_null_raises(self):
        with self.assertRaises(ValueError):
            fe.fill_nulls([None] * 4, nx=2, nz=2)


class TestSmoothHeights(unittest.TestCase):
    def test_zero_passes_returns_unchanged(self):
        heights = [1.0, 2.0, 3.0, 4.0]
        result, preserved = fe.smooth_heights(heights, nx=2, nz=2, passes=0, delta_max=1.0)
        self.assertEqual(result, heights)
        self.assertEqual(preserved, 0)

    def test_large_spike_beyond_delta_is_preserved(self):
        heights = [0.0, 0.0, 0.0, 0.0, 10.0, 0.0, 0.0, 0.0, 0.0]
        result, preserved = fe.smooth_heights(heights, nx=3, nz=3, passes=1, delta_max=1.0)
        self.assertEqual(result[1 * 3 + 1], 10.0)
        self.assertEqual(preserved, 5)


class TestResamplePolyline(unittest.TestCase):
    def test_straight_line_resampled_every_step(self):
        points = [(0.0, 0.0), (100.0, 0.0)]
        result = fe.resample_polyline(points, step=10.0)
        self.assertEqual(result[0], (0.0, 0.0))
        self.assertEqual(result[-1], (100.0, 0.0))


class TestRoadSlopeStats(unittest.TestCase):
    def test_ramp_terrain_detects_known_slope(self):
        nx, nz = 20, 2
        heights = [float(i) for j in range(nz) for i in range(nx)]
        terrain = {"cell_size": 10.0, "nx": nx, "nz": nz, "origin_x": 0.0, "origin_z": 0.0,
                   "heights": heights}
        points = [[0.0, 5.0], [100.0, 5.0]]
        slope = fe.road_slope_stats(points, terrain)
        self.assertAlmostEqual(slope, 10.0, delta=0.5)


class TestElevationCache(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.path = os.path.join(self.tmpdir, "elevation_raw.json")
        self.bbox = (1.0, 2.0, 3.0, 4.0)
        self.grid_params = {"cell_size": 30.0, "nx": 5, "nz": 5, "origin_x": 0.0, "origin_z": 0.0}

    def test_missing_cache_returns_none(self):
        self.assertIsNone(fe.load_elevation_cache(self.path, self.bbox, self.grid_params))

    def test_save_then_load_roundtrip(self):
        elevations = [1.0, 2.0, None, 4.0]
        fe.save_elevation_cache(self.path, self.bbox, self.grid_params, elevations)
        loaded = fe.load_elevation_cache(self.path, self.bbox, self.grid_params)
        self.assertEqual(loaded, elevations)

    def test_bbox_mismatch_invalidates_cache(self):
        fe.save_elevation_cache(self.path, self.bbox, self.grid_params, [1.0])
        self.assertIsNone(fe.load_elevation_cache(self.path, (9.0, 9.0, 9.0, 9.0), self.grid_params))


def _mock_response(status_code, json_body):
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = json_body
    resp.raise_for_status.side_effect = Exception(f"HTTP {status_code}") if status_code >= 400 else None
    return resp


class TestFetchElevationBatch(unittest.TestCase):
    def test_success_returns_elevations_in_order(self):
        body = {"status": "OK", "results": [{"elevation": 100.0}, {"elevation": 200.0}]}
        with patch.object(fe.requests, "get", return_value=_mock_response(200, body)):
            result = fe.fetch_elevation_batch([(1.0, 2.0), (3.0, 4.0)])
        self.assertEqual(result, [100.0, 200.0])

    @patch("citygen.fetch_elevation.time.sleep", return_value=None)
    def test_raises_after_exhausting_retries(self, mock_sleep):
        fail_resp = _mock_response(500, {})
        with patch.object(fe.requests, "get", return_value=fail_resp):
            with self.assertRaises(RuntimeError):
                fe.fetch_elevation_batch([(1.0, 2.0)], retries=3, backoff=(2, 4, 8))
        self.assertEqual(mock_sleep.call_count, 3)


class TestExcavateWater(unittest.TestCase):
    def setUp(self):
        self.nx, self.nz, self.cell = 5, 5, 10.0
        self.origin_x, self.origin_z = 0.0, 0.0
        self.heights = [100.0] * (self.nx * self.nz)

    def test_area_depresses_only_interior_node(self):
        water_areas = [{"id": 0, "footprint": [[15.0, 15.0], [25.0, 15.0], [25.0, 25.0], [15.0, 25.0], [15.0, 15.0]]}]
        result, n_excavated, delta_outside = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, water_areas, [])
        idx = 2 * self.nx + 2  # nodo (20, 20)
        self.assertAlmostEqual(result[idx], 100.0 - fe.WATER_DEPRESS)
        self.assertEqual(n_excavated, 1)
        self.assertEqual(delta_outside, 0.0)

    def test_way_depresses_nodes_within_half_width_and_gradient(self):
        water_ways = [{"id": 0, "kind": "river", "width": 6.0, "points": [[0.0, 40.0], [40.0, 40.0]]}]
        result, n_excavated, delta_outside = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, [], water_ways)
        row_on_axis = [result[4 * self.nx + i] for i in range(self.nx)]  # z=40 -> j=4, dist=0
        self.assertTrue(all(abs(h - (100.0 - fe.WATER_DEPRESS)) < 1e-9 for h in row_on_axis))
        # fila z=30 (dist=10, dentro del degradado half_width..half_width+cell_size) tambien se toca.
        self.assertEqual(n_excavated, 10)
        self.assertEqual(delta_outside, 0.0)

    def test_way_gradient_zone_partial_depression(self):
        water_ways = [{"id": 0, "kind": "river", "width": 6.0, "points": [[0.0, 40.0], [40.0, 40.0]]}]
        result, _, _ = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, [], water_ways)
        idx = 3 * self.nx + 2  # nodo (20, 30): distancia 10 a la via, half_width=3
        expected_depress = fe.WATER_DEPRESS * (1.0 - (10.0 - 3.0) / self.cell)
        self.assertAlmostEqual(result[idx], 100.0 - expected_depress, places=4)

    def test_no_water_leaves_grid_unchanged(self):
        result, n_excavated, delta_outside = fe.excavate_water(
            self.heights, self.nx, self.nz, self.cell, self.origin_x, self.origin_z, [], [])
        self.assertEqual(result, self.heights)
        self.assertEqual(n_excavated, 0)
        self.assertEqual(delta_outside, 0.0)


if __name__ == "__main__":
    unittest.main()
