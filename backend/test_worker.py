#!/usr/bin/env python3
import os
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import store
import worker
from citygen.build import GenResult


def _success_result(zone_id):
    return GenResult(
        ok=True, reason=None,
        stats={
            "span_x": 1500.0, "span_z": 1500.0, "extent_m": [0.0, 0.0, 0.0, 0.0],
            "road_km": 10.0, "n_buildings": 500, "largest_component_pct": 100.0,
            "max_road_slope_pct": 5.0, "flags": [],
        },
        zone_id=zone_id,
        diagnostics={"size_bytes": 12345, "n_roads": 10, "n_controls": 2, "osm_stats": {}, "terrain_stats": {}},
    )


class TestProcessZone(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, "app.db")
        self.zones_dir = os.path.join(self.tmp.name, "zones")
        self.cache_dir = os.path.join(self.tmp.name, "cache")
        store.init_db(self.db_path)
        store.insert_zone_queued(self.db_path, "z1_m_test", 4.0, -74.0, "M", "Test City")

    def tearDown(self):
        self.tmp.cleanup()

    def test_success_marks_zone_ready_with_meta_summary(self):
        row = store.get_zone(self.db_path, "z1_m_test")
        with patch("worker.generate", return_value=_success_result("z1_m_test")):
            worker._process_zone(self.db_path, self.cache_dir, self.zones_dir, row)
        updated = store.get_zone(self.db_path, "z1_m_test")
        self.assertEqual(updated["status"], "ready")
        self.assertIsNotNone(updated["meta_summary_json"])

    def test_gen_result_failure_stores_its_reason(self):
        row = store.get_zone(self.db_path, "z1_m_test")
        fail_result = GenResult(
            ok=False, reason="insufficient_road_data", stats=None, zone_id="z1_m_test", diagnostics={},
        )
        with patch("worker.generate", return_value=fail_result):
            worker._process_zone(self.db_path, self.cache_dir, self.zones_dir, row)
        updated = store.get_zone(self.db_path, "z1_m_test")
        self.assertEqual(updated["status"], "failed")
        self.assertEqual(updated["reason"], "insufficient_road_data")

    def test_exception_before_any_progress_reports_osm_unavailable(self):
        row = store.get_zone(self.db_path, "z1_m_test")
        with patch("worker.generate", side_effect=RuntimeError("network down")):
            worker._process_zone(self.db_path, self.cache_dir, self.zones_dir, row)
        updated = store.get_zone(self.db_path, "z1_m_test")
        self.assertEqual(updated["status"], "failed")
        self.assertEqual(updated["reason"], "osm_unavailable")

    def test_exception_after_elevation_stage_reports_elevation_unavailable(self):
        row = store.get_zone(self.db_path, "z1_m_test")

        def _raise_after_elevation(zone, cache_dir, out_path, progress_cb=None, **kwargs):
            progress_cb("osm")
            progress_cb("elevation")
            raise RuntimeError("opentopodata down")

        with patch("worker.generate", side_effect=_raise_after_elevation):
            worker._process_zone(self.db_path, self.cache_dir, self.zones_dir, row)
        updated = store.get_zone(self.db_path, "z1_m_test")
        self.assertEqual(updated["status"], "failed")
        self.assertEqual(updated["reason"], "elevation_unavailable")


class TestRunForever(unittest.TestCase):
    def test_processes_queued_zones_in_fifo_order_then_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "app.db")
            zones_dir = os.path.join(tmp, "zones")
            cache_dir = os.path.join(tmp, "cache")
            store.init_db(db_path)
            store.insert_zone_queued(db_path, "z1_first", 1.0, 1.0, "S", "First")
            store.insert_zone_queued(db_path, "z1_second", 2.0, 2.0, "S", "Second")

            processed = []

            def _fake_generate(zone, cache_dir_arg, out_path, progress_cb=None, **kwargs):
                processed.append(zone.name)
                return _success_result(zone.name)

            stop_event = threading.Event()
            with patch("worker.generate", side_effect=_fake_generate):
                thread = threading.Thread(
                    target=worker.run_forever, args=(db_path, cache_dir, zones_dir, stop_event),
                )
                thread.start()
                for _ in range(50):
                    if processed == ["First", "Second"]:
                        break
                    time.sleep(0.1)
                stop_event.set()
                thread.join(timeout=5)

            self.assertEqual(processed, ["First", "Second"])
            self.assertFalse(thread.is_alive())


if __name__ == "__main__":
    unittest.main()
