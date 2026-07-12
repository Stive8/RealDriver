#!/usr/bin/env python3
import os
import tempfile
import unittest
from datetime import datetime, timezone

import quotas
import store


class TestCheckAndIncrement(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, "app.db")
        store.init_db(self.db_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_allows_up_to_the_daily_max(self):
        for _ in range(quotas.MAX_COLD_GENERATIONS_PER_DAY):
            result = quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
            self.assertTrue(result["allowed"])

    def test_blocks_once_client_reaches_max(self):
        for _ in range(quotas.MAX_COLD_GENERATIONS_PER_DAY):
            quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        result = quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        self.assertFalse(result["allowed"])
        self.assertIsNotNone(result["resets_at"])

    def test_blocks_once_ip_reaches_max_even_with_new_client_id(self):
        for _ in range(quotas.MAX_COLD_GENERATIONS_PER_DAY):
            quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        result = quotas.check_and_increment(self.db_path, "client-b", "1.2.3.4")
        self.assertFalse(result["allowed"])

    def test_blocked_attempt_does_not_increment_further(self):
        for _ in range(quotas.MAX_COLD_GENERATIONS_PER_DAY):
            quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        self.assertEqual(
            store.get_quota_count(self.db_path, "client", "client-a", today),
            quotas.MAX_COLD_GENERATIONS_PER_DAY,
        )

    def test_different_clients_and_ips_do_not_interfere(self):
        for _ in range(quotas.MAX_COLD_GENERATIONS_PER_DAY):
            quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        result = quotas.check_and_increment(self.db_path, "client-b", "5.6.7.8")
        self.assertTrue(result["allowed"])

    def test_resets_at_is_next_utc_midnight(self):
        for _ in range(quotas.MAX_COLD_GENERATIONS_PER_DAY):
            quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        result = quotas.check_and_increment(self.db_path, "client-a", "1.2.3.4")
        resets_at = datetime.fromisoformat(result["resets_at"].replace("Z", "+00:00"))
        self.assertEqual(resets_at.hour, 0)
        self.assertEqual(resets_at.minute, 0)
        self.assertEqual(resets_at.second, 0)
        self.assertGreater(resets_at, datetime.now(timezone.utc))


if __name__ == "__main__":
    unittest.main()
