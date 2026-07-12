#!/usr/bin/env python3
import unittest

from citygen import validate


def _road(points):
    return {"points": points}


class TestComputeConnectivity(unittest.TestCase):
    def test_single_connected_road_is_100_percent(self):
        roads = [_road([[0.0, 0.0], [100.0, 0.0], [200.0, 0.0]])]
        road_km, pct = validate.compute_connectivity(roads)
        self.assertAlmostEqual(road_km, 0.2, places=3)
        self.assertAlmostEqual(pct, 100.0, places=3)

    def test_two_disconnected_components_weighted_by_length(self):
        # componente A: 100 m; componente B: 300 m -> A=25%, B=75% -> mayor=75%
        roads = [
            _road([[0.0, 0.0], [100.0, 0.0]]),
            _road([[10000.0, 0.0], [10000.0, 300.0]]),
        ]
        road_km, pct = validate.compute_connectivity(roads)
        self.assertAlmostEqual(road_km, 0.4, places=3)
        self.assertAlmostEqual(pct, 75.0, places=1)

    def test_shared_endpoint_merges_components(self):
        # Dos vias que comparten un nodo (mismo punto fusionado) forman un solo componente.
        roads = [
            _road([[0.0, 0.0], [100.0, 0.0]]),
            _road([[100.0, 0.0], [100.0, 100.0]]),
        ]
        road_km, pct = validate.compute_connectivity(roads)
        self.assertAlmostEqual(pct, 100.0, places=3)

    def test_no_roads_is_zero(self):
        road_km, pct = validate.compute_connectivity([])
        self.assertEqual(road_km, 0.0)
        self.assertEqual(pct, 0.0)


class TestThresholdChecks(unittest.TestCase):
    def test_road_data_below_minimum_fails(self):
        self.assertEqual(validate.check_road_data(2.9), "insufficient_road_data")

    def test_road_data_at_minimum_passes(self):
        self.assertIsNone(validate.check_road_data(3.0))

    def test_connectivity_below_minimum_fails(self):
        self.assertEqual(validate.check_connectivity(59.9), "fragmented_road_graph")

    def test_connectivity_at_minimum_passes(self):
        self.assertIsNone(validate.check_connectivity(60.0))

    def test_building_cap_exceeded_fails(self):
        self.assertEqual(validate.check_building_cap(25001), "zone_too_dense")

    def test_building_cap_at_limit_passes(self):
        self.assertIsNone(validate.check_building_cap(25000))

    def test_file_size_exceeded_fails(self):
        self.assertEqual(validate.check_file_size(13 * 1024 * 1024), "zone_too_dense")

    def test_file_size_at_limit_passes(self):
        self.assertIsNone(validate.check_file_size(12 * 1024 * 1024))


class TestComputeFlags(unittest.TestCase):
    def test_sparse_buildings_flag(self):
        self.assertIn("sparse_buildings", validate.compute_flags(199, 5.0))

    def test_no_sparse_flag_at_threshold(self):
        self.assertNotIn("sparse_buildings", validate.compute_flags(200, 5.0))

    def test_steep_flag(self):
        self.assertIn("steep", validate.compute_flags(1000, 15.1))

    def test_no_steep_flag_at_threshold(self):
        self.assertNotIn("steep", validate.compute_flags(1000, 15.0))

    def test_no_flags_when_normal(self):
        self.assertEqual(validate.compute_flags(1000, 5.0), [])


if __name__ == "__main__":
    unittest.main()
