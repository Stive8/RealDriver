#!/usr/bin/env python3
import os
import sqlite3
import tempfile
import unittest

import store


class TestInitDb(unittest.TestCase):
    def test_creates_all_tables(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "app.db")
            store.init_db(db_path)
            conn = sqlite3.connect(db_path)
            names = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            conn.close()
        self.assertEqual(names, {"zones", "quotas", "geocode_cache"})

    def test_requeues_stuck_generating_zones(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "app.db")
            store.init_db(db_path)
            store.insert_zone_queued(db_path, "z1_stuck", 4.0, -74.0, "S", "Stuck")
            store.update_zone_stage(db_path, "z1_stuck", "elevation")
            # Simula un reinicio del proceso: init_db se llama de nuevo al arrancar.
            store.init_db(db_path)
            row = store.get_zone(db_path, "z1_stuck")
        self.assertEqual(row["status"], "queued")
        self.assertIsNone(row["stage"])


class TestZoneCrud(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, "app.db")
        store.init_db(self.db_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_get_missing_zone_returns_none(self):
        self.assertIsNone(store.get_zone(self.db_path, "does_not_exist"))

    def test_insert_then_get_zone_queued(self):
        store.insert_zone_queued(self.db_path, "z1_a", 4.5, -74.5, "M", "Zona A")
        row = store.get_zone(self.db_path, "z1_a")
        self.assertEqual(row["status"], "queued")
        self.assertEqual(row["lat"], 4.5)
        self.assertEqual(row["lon"], -74.5)
        self.assertEqual(row["size"], "M")
        self.assertEqual(row["name"], "Zona A")

    def test_queue_position_is_fifo_by_insertion_order(self):
        store.insert_zone_queued(self.db_path, "z1_first", 1.0, 1.0, "S", "First")
        store.insert_zone_queued(self.db_path, "z1_second", 2.0, 2.0, "S", "Second")
        store.insert_zone_queued(self.db_path, "z1_third", 3.0, 3.0, "S", "Third")
        self.assertEqual(store.get_queue_position(self.db_path, "z1_first"), 1)
        self.assertEqual(store.get_queue_position(self.db_path, "z1_second"), 2)
        self.assertEqual(store.get_queue_position(self.db_path, "z1_third"), 3)

    def test_next_queued_zone_is_the_oldest(self):
        store.insert_zone_queued(self.db_path, "z1_first", 1.0, 1.0, "S", "First")
        store.insert_zone_queued(self.db_path, "z1_second", 2.0, 2.0, "S", "Second")
        row = store.next_queued_zone(self.db_path)
        self.assertEqual(row["zone_id"], "z1_first")

    def test_next_queued_zone_none_when_empty(self):
        self.assertIsNone(store.next_queued_zone(self.db_path))

    def test_update_zone_stage_sets_generating(self):
        store.insert_zone_queued(self.db_path, "z1_a", 1.0, 1.0, "S", "A")
        store.update_zone_stage(self.db_path, "z1_a", "osm")
        row = store.get_zone(self.db_path, "z1_a")
        self.assertEqual(row["status"], "generating")
        self.assertEqual(row["stage"], "osm")

    def test_mark_zone_ready_stores_meta_summary(self):
        store.insert_zone_queued(self.db_path, "z1_a", 1.0, 1.0, "S", "A")
        summary = {"name": "A", "zone_size": "S", "stats": {"flags": ["steep"]}}
        store.mark_zone_ready(self.db_path, "z1_a", summary)
        row = store.get_zone(self.db_path, "z1_a")
        self.assertEqual(row["status"], "ready")
        self.assertIsNone(row["stage"])

    def test_mark_zone_failed_stores_reason(self):
        store.insert_zone_queued(self.db_path, "z1_a", 1.0, 1.0, "S", "A")
        store.mark_zone_failed(self.db_path, "z1_a", "insufficient_road_data")
        row = store.get_zone(self.db_path, "z1_a")
        self.assertEqual(row["status"], "failed")
        self.assertEqual(row["reason"], "insufficient_road_data")

    def test_list_catalog_only_includes_ready_with_flags(self):
        store.insert_zone_queued(self.db_path, "z1_ready", 1.0, 1.0, "M", "Ready City")
        store.mark_zone_ready(self.db_path, "z1_ready", {
            "name": "Ready City", "zone_size": "M", "stats": {"flags": ["sparse_buildings"]},
        })
        store.insert_zone_queued(self.db_path, "z1_pending", 2.0, 2.0, "S", "Pending City")
        catalog = store.list_catalog(self.db_path)
        self.assertEqual(catalog, [{
            "zone_id": "z1_ready", "name": "Ready City", "zone_size": "M",
            "flags": ["sparse_buildings"],
        }])


class TestQuotas(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, "app.db")
        store.init_db(self.db_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_count_zero_when_absent(self):
        self.assertEqual(store.get_quota_count(self.db_path, "client", "abc", "2026-07-11"), 0)

    def test_increment_then_count(self):
        store.increment_quota(self.db_path, "client", "abc", "2026-07-11")
        store.increment_quota(self.db_path, "client", "abc", "2026-07-11")
        self.assertEqual(store.get_quota_count(self.db_path, "client", "abc", "2026-07-11"), 2)

    def test_counts_are_isolated_by_kind_and_date(self):
        store.increment_quota(self.db_path, "client", "abc", "2026-07-11")
        store.increment_quota(self.db_path, "ip", "abc", "2026-07-11")
        store.increment_quota(self.db_path, "client", "abc", "2026-07-12")
        self.assertEqual(store.get_quota_count(self.db_path, "client", "abc", "2026-07-11"), 1)
        self.assertEqual(store.get_quota_count(self.db_path, "ip", "abc", "2026-07-11"), 1)
        self.assertEqual(store.get_quota_count(self.db_path, "client", "abc", "2026-07-12"), 1)


class TestGeocodeCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, "app.db")
        store.init_db(self.db_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_query_returns_none(self):
        self.assertIsNone(store.get_geocode_cache(self.db_path, "Girardot"))

    def test_save_then_get_roundtrip(self):
        results = [{"name": "Girardot, Colombia", "lat": 4.3, "lon": -74.8}]
        store.save_geocode_cache(self.db_path, "Girardot", results)
        self.assertEqual(store.get_geocode_cache(self.db_path, "Girardot"), results)

    def test_save_overwrites_previous_value(self):
        store.save_geocode_cache(self.db_path, "Girardot", [{"name": "old", "lat": 0.0, "lon": 0.0}])
        store.save_geocode_cache(self.db_path, "Girardot", [{"name": "new", "lat": 1.0, "lon": 1.0}])
        cached = store.get_geocode_cache(self.db_path, "Girardot")
        self.assertEqual(cached[0]["name"], "new")


if __name__ == "__main__":
    unittest.main()
