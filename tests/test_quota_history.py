"""Real SQLite history boundary checks, using synthetic accounts and HTTP only."""
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

from test_backend import BACKEND, auth, configure


class QuotaHistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        spec = importlib.util.spec_from_file_location("history_backend", BACKEND)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        configure(self.m, self.root)
        self.path = self.m.DATA / "quota-history.sqlite3"
        self.slot = self.m.DATA / "one.json"
        self.slot.write_text(json.dumps(auth("A")))
        self.meta = self.m.auth_meta(self.slot)

    def tearDown(self):
        if self.m._LOCK_HANDLE:
            self.m._LOCK_HANDLE.close()
        self.tmp.cleanup()

    def entry(self, stamp=None, five=70, **extra):
        return dict(account_id="A", fetched_at=stamp or time.time(), plan="pro", five=five,
                    week=50, five_window_seconds=18000, week_window_seconds=604800,
                    five_reset_at=2000000000, week_reset_at=2000500000, **extra)

    def rows(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            return db.execute("SELECT account,sampled_at,plan,five,week,five_seconds,week_seconds,five_reset,week_reset FROM observations ORDER BY sampled_at").fetchall()

    def test_success_records_exact_percent_windows_and_timestamp_privately(self):
        entry = self.entry()
        self.assertTrue(self.m.record_quota_history(self.meta, entry))
        row = self.rows()[0]
        self.assertEqual(row[1:], (entry["fetched_at"], "pro", 70, 50, 18000, 604800, 2000000000, 2000500000))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.meta["email"].encode(), self.path.read_bytes())

    def test_identity_distinguishes_workspace_and_user_but_not_plan(self):
        identity = self.m.quota_history_id(self.meta)
        self.assertEqual(len(identity), 64)
        self.assertEqual(identity, self.m.quota_history_id(dict(self.meta, plan="free")))
        self.assertNotEqual(identity, self.m.quota_history_id(dict(self.meta, account_id="TEAM")))
        self.assertNotEqual(identity, self.m.quota_history_id(dict(self.meta, email="OTHER@example.test")))
        self.assertIsNone(self.m.quota_history_id(dict(self.meta, account_id="?")))

    def test_failed_refresh_and_opening_cached_list_do_not_create_history(self):
        self.m.write_quota_cache({"one": self.entry()})
        self.m.fetch_usage = lambda _: (503, None)
        self.m.fetch_quotas_into_cache(["one"])
        self.m.list_state()
        self.assertFalse(self.path.exists())

    def test_aliases_make_one_request_and_one_observation(self):
        (self.m.DATA / "alias.json").write_text(self.slot.read_text())
        calls = []
        def fetch(_):
            calls.append(1)
            return 200, {"plan_type": "pro", "rate_limit": {"primary_window": {
                "used_percent": 30, "limit_window_seconds": 18000, "reset_after_seconds": 1000}}}
        self.m.fetch_usage = fetch
        self.m.fetch_quotas_into_cache(["one", "alias"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(self.rows()), 1)

    def test_unchanged_success_keeps_observation_time_and_duplicate_is_deduplicated(self):
        now = time.time()
        for stamp in [now - 300, now, now]:
            self.m.record_quota_history(self.meta, self.entry(stamp))
        self.assertEqual(len(self.rows()), 2)
        self.assertEqual(self.rows()[1][1] - self.rows()[0][1], 300)

    def test_workspace_members_use_their_own_tokens_and_history(self):
        original = auth("A", access="saved-user")
        another = auth("A", access="other-user")
        import base64
        claims = {"email": "other@example.test", "https://api.openai.com/auth": {"chatgpt_account_id": "A", "chatgpt_plan_type": "team"}}
        encoded = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        another["tokens"]["id_token"] = "header." + encoded + ".signature"
        self.slot.write_text(json.dumps(original))
        self.m.AUTH.write_text(json.dumps(another))
        (self.m.DATA / "other.json").write_text(json.dumps(another))
        seen = []
        def fetch(data):
            token = data["tokens"]["access_token"]
            seen.append(token)
            return 200, {"rate_limit": {"primary_window": {"used_percent": 30 if token == "saved-user" else 80}}}
        self.m.fetch_usage = fetch
        self.m.fetch_quotas_into_cache(["one", "other"])
        self.assertCountEqual(seen, ["saved-user", "other-user"])
        self.assertEqual(len(set(row[0] for row in self.rows())), 2)
        self.assertEqual(self.m.load_auth(self.slot)["tokens"]["access_token"], "saved-user")

    def test_same_slot_new_account_has_separate_history(self):
        now = time.time()
        self.m.record_quota_history(self.meta, self.entry(now - 5))
        new_meta = dict(self.meta, account_id="B")
        self.m.record_quota_history(new_meta, dict(self.entry(now), account_id="B"))
        self.assertEqual(len(set(row[0] for row in self.rows())), 2)

    def test_invalid_or_mismatched_results_are_not_samples(self):
        for value in [True, -1, 101, float("nan")]:
            entry = dict(self.entry(five=value), week=None)
            self.assertFalse(self.m.record_quota_history(self.meta, entry))
        self.assertFalse(self.m.record_quota_history(self.meta, dict(self.entry(), account_id="B")))
        self.assertFalse(self.path.exists())

    def test_thirty_day_retention_runs_hourly_with_indexed_storage(self):
        now = time.time()
        self.m.record_quota_history(self.meta, self.entry(now))
        with closing(sqlite3.connect(self.path)) as db, db:
            row = self.rows()[0]
            db.execute("INSERT INTO observations VALUES (?,?,?,?,?,?,?,?,?)", (row[0], now - 31 * 86400) + row[2:])
            db.execute("UPDATE maintenance SET value=?", (now - 4000,))
        self.m.record_quota_history(self.meta, self.entry(now + 1))
        self.assertEqual(len(self.rows()), 2)
        self.assertTrue(all(row[1] >= now - 30 * 86400 for row in self.rows()))
        with closing(sqlite3.connect(self.path)) as db, db:
            query = str(db.execute("EXPLAIN QUERY PLAN SELECT * FROM observations WHERE account=? AND sampled_at>?", ("x", 0)).fetchall())
        self.assertIn("PRIMARY KEY", query)

    def test_history_failure_does_not_break_successful_quota_cache(self):
        self.path.mkdir()
        self.m.fetch_usage = lambda _: (200, {"rate_limit": {"primary_window": {"used_percent": 30}}})
        failures = []
        cache = self.m.fetch_quotas_into_cache(["one"], failures)
        self.assertEqual(failures, [])
        self.assertEqual(cache["one"]["five"], 70)

    def test_schema_and_account_history_read_are_absent_from_local_list_path(self):
        self.m.record_quota_history(self.meta, self.entry())
        before = self.path.read_bytes(), self.path.stat().st_mtime_ns
        with patch.object(self.m.sqlite3, "connect", side_effect=AssertionError("cached list opened history")):
            self.m.list_state()
        self.assertEqual(before, (self.path.read_bytes(), self.path.stat().st_mtime_ns))


if __name__ == "__main__":
    unittest.main()
