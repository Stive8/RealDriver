#!/usr/bin/env python3
import json
import os
import tempfile
import unittest
from unittest.mock import patch, MagicMock

from citygen import fetch_osm


class TestRoadWidth(unittest.TestCase):
    def test_uses_explicit_width_tag_when_present(self):
        self.assertAlmostEqual(fetch_osm.road_width({"width": "8"}), 8.0)

    def test_falls_back_to_highway_type(self):
        self.assertAlmostEqual(fetch_osm.road_width({"highway": "primary"}), 12.0)

    def test_unknown_highway_defaults_to_residential_width(self):
        self.assertAlmostEqual(fetch_osm.road_width({"highway": "bogus"}), 6.0)

    def test_width_is_clamped(self):
        self.assertAlmostEqual(fetch_osm.road_width({"width": "999"}), 20.0)


class TestRoadOneway(unittest.TestCase):
    def test_roundabout_forces_direct(self):
        self.assertEqual(fetch_osm.road_oneway({"junction": "roundabout"}), 1)

    def test_yes_is_direct(self):
        self.assertEqual(fetch_osm.road_oneway({"oneway": "yes"}), 1)

    def test_reverse_is_inverse(self):
        self.assertEqual(fetch_osm.road_oneway({"oneway": "-1"}), -1)

    def test_absent_is_bidirectional(self):
        self.assertEqual(fetch_osm.road_oneway({}), 0)


class TestBuildingHeight(unittest.TestCase):
    def test_uses_height_tag(self):
        self.assertAlmostEqual(fetch_osm.building_height({"height": "10"}, 1), 10.0)

    def test_uses_levels_tag(self):
        self.assertAlmostEqual(fetch_osm.building_height({"building:levels": "2"}, 1), 6.4)

    def test_random_seeded_by_osm_id_is_deterministic(self):
        h1 = fetch_osm.building_height({}, 42)
        h2 = fetch_osm.building_height({}, 42)
        self.assertEqual(h1, h2)


class TestInBbox(unittest.TestCase):
    def setUp(self):
        self.bbox = (4.0, -75.0, 5.0, -74.0)

    def test_point_inside(self):
        self.assertTrue(fetch_osm.in_bbox(4.5, -74.5, self.bbox))

    def test_point_outside(self):
        self.assertFalse(fetch_osm.in_bbox(6.0, -74.5, self.bbox))


class TestBuildRoads(unittest.TestCase):
    def test_discards_ways_without_highway_tag(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"building": "yes"}, "nodes": [1, 2]}]
        stats = {"roads_by_type": {}, "roads_oneway_by_value": {0: 0, 1: 0, -1: 0},
                 "roads_discarded_few_points": 0, "roads_discarded_outside_bbox": 0}
        roads = fetch_osm.build_roads(ways, nodes, bbox, origin, stats)
        self.assertEqual(roads, [])

    def test_builds_road_with_projected_points(self):
        origin = (4.5, -74.5)
        bbox = (4.0, -75.0, 5.0, -74.0)
        nodes = {1: (4.5, -74.5), 2: (4.501, -74.501)}
        ways = [{"tags": {"highway": "residential"}, "nodes": [1, 2]}]
        stats = {"roads_by_type": {}, "roads_oneway_by_value": {0: 0, 1: 0, -1: 0},
                 "roads_discarded_few_points": 0, "roads_discarded_outside_bbox": 0}
        roads = fetch_osm.build_roads(ways, nodes, bbox, origin, stats)
        self.assertEqual(len(roads), 1)
        self.assertEqual(roads[0]["highway"], "residential")
        self.assertEqual(len(roads[0]["points"]), 2)


class TestBuildQuery(unittest.TestCase):
    def test_includes_link_classes(self):
        query = fetch_osm.build_query((4.0, -75.0, 5.0, -74.0))
        for cls in ("motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link"):
            self.assertIn(cls, query)

    def test_includes_water_queries(self):
        query = fetch_osm.build_query((4.0, -75.0, 5.0, -74.0))
        self.assertIn('natural"="water"', query)
        self.assertIn('waterway"~"^(river|stream|canal)$"', query)


class TestRoadWidthLinks(unittest.TestCase):
    def test_link_defaults_to_5m(self):
        self.assertAlmostEqual(fetch_osm.road_width({"highway": "primary_link"}), 5.0)

    def test_link_width_tag_overrides_and_clamps(self):
        self.assertAlmostEqual(fetch_osm.road_width({"highway": "primary_link", "width": "2"}), 3.0)


class TestOsmCache(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.path = os.path.join(self.tmpdir, "overpass_raw.json")
        self.query = "QUERY_A"

    def test_missing_cache_returns_none(self):
        self.assertIsNone(fetch_osm.load_osm_cache(self.path, self.query))

    def test_save_then_load_roundtrip(self):
        fetch_osm.save_osm_cache(self.path, self.query, {"elements": [1, 2]})
        self.assertEqual(fetch_osm.load_osm_cache(self.path, self.query), {"elements": [1, 2]})

    def test_query_mismatch_invalidates_cache(self):
        fetch_osm.save_osm_cache(self.path, self.query, {"elements": [1, 2]})
        self.assertIsNone(fetch_osm.load_osm_cache(self.path, "QUERY_B"))

    def test_old_format_cache_without_query_is_invalid(self):
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"elements": [1, 2]}, f)
        self.assertIsNone(fetch_osm.load_osm_cache(self.path, self.query))


class TestFetch(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.bbox = (4.0, -75.0, 5.0, -74.0)

    def test_uses_cache_when_query_matches(self):
        query = fetch_osm.build_query(self.bbox)
        cache_path = os.path.join(self.tmpdir, "overpass_raw.json")
        fetch_osm.save_osm_cache(cache_path, query, {"elements": ["cached"]})
        with patch("citygen.fetch_osm.requests.post") as mock_post:
            data = fetch_osm.fetch(self.bbox, self.tmpdir, refresh=False)
        mock_post.assert_not_called()
        self.assertEqual(data, {"elements": ["cached"]})

    def test_refetches_when_cache_has_old_format(self):
        cache_path = os.path.join(self.tmpdir, "overpass_raw.json")
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump({"elements": ["old"]}, f)
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"elements": ["fresh"]}
        mock_resp.content = b"x"
        mock_resp.raise_for_status.return_value = None
        with patch("citygen.fetch_osm.requests.post", return_value=mock_resp) as mock_post:
            data = fetch_osm.fetch(self.bbox, self.tmpdir, refresh=False)
        mock_post.assert_called_once()
        self.assertEqual(data, {"elements": ["fresh"]})
        with open(cache_path, "r", encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(saved["query"], fetch_osm.build_query(self.bbox))


if __name__ == "__main__":
    unittest.main()
