"""Storage/credential regression checks. All files and HTTP responses are synthetic."""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

BACKEND = Path(__file__).resolve().parents[1] / "backend" / "codex-swap.py"


def auth(account, access="saved", refresh="refresh-old"):
    claims = {"email": account + "@example.test", "https://api.openai.com/auth":
              {"chatgpt_account_id": account, "chatgpt_plan_type": "pro"}}
    segment = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return {"tokens": {"id_token": "header." + segment + ".signature", "account_id": account,
                       "access_token": access, "refresh_token": refresh}}


def configure(module, root):
    module.AUTH = root / "codex" / "auth.json"
    module.DATA = module.ACCOUNTS = root / "slots"
    module.CURRENT_FILE = module.DATA / "current"
    module.LOCK = module.DATA / ".lock"
    module.OPERATION_LOCK = module.DATA / ".operation.lock"
    module.ORDER_FILE = module.DATA / "order"
    module.CACHE_FILE = module.DATA / ".quota-cache.json"
    module.JSON_MODE = module.NO_APP = True
    module.DATA.mkdir(parents=True, exist_ok=True)
    module.AUTH.parent.mkdir(parents=True, exist_ok=True)


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        spec = importlib.util.spec_from_file_location("swap_test_" + uuid.uuid4().hex, BACKEND)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        configure(self.m, self.root)

    def tearDown(self):
        if self.m._LOCK_HANDLE:
            self.m._LOCK_HANDLE.close()
            self.m._LOCK_HANDLE = None
        self.tmp.cleanup()

    def write(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def run_json(self, function, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            function(*args)
        return json.loads(output.getvalue())

    def save(self, name, account, access="saved"):
        self.write(self.m.AUTH, auth(account, access))
        return self.run_json(self.m.cmd_save, name)

    def test_save_refuses_overwriting_a_different_account(self):
        self.save("n1", "A")
        original = self.m.slot_path("n1").read_bytes()
        self.write(self.m.AUTH, auth("B"))
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            self.m.cmd_save("n1")
        self.assertEqual(original, self.m.slot_path("n1").read_bytes())
        self.assertEqual(self.m.read_current(), "n1")

    def test_telemetry_samples_are_not_account_slots(self):
        self.save("n1", "A")
        self.save("n2", "B")
        telemetry=self.m.DATA/'telemetry'
        telemetry.mkdir()
        self.write(telemetry/'samples.json',{'samples':[]})
        self.assertEqual(set(self.m.saved_slot_names()),{'n1','n2'})
        self.assertEqual(self.m.read_current(), "n2")

    def test_switch_retains_latest_live_login_and_uses_target(self):
        self.save("n1", "A")
        self.write(self.m.slot_path("n2"), auth("B"))
        self.write(self.m.AUTH, auth("A", "new-live-access"))
        self.run_json(self.m.cmd_switch, "n2")
        self.assertEqual(self.m.auth_meta(self.m.AUTH)["account_id"], "B")
        self.assertEqual(self.m.load_auth(self.m.slot_path("n1"))["tokens"]["access_token"], "new-live-access")
        self.assertEqual(self.m.read_current(), "n2")
        self.assertEqual(self.m.AUTH.stat().st_mode & 0o777, 0o600)

    def test_add_on_new_machine_preserves_live_login_and_restores_without_auth(self):
        self.write(self.m.AUTH, auth("A"))
        result = self.run_json(self.m.cmd_add, "n1")
        kept = result["kept"]
        self.assertNotEqual(kept, "n1")
        self.assertFalse(self.m.AUTH.exists())
        self.assertEqual(self.m.auth_meta(self.m.slot_path(kept))["account_id"], "A")
        self.run_json(self.m.cmd_switch, kept)
        self.assertEqual(self.m.auth_meta(self.m.AUTH)["account_id"], "A")

    def test_switch_refuses_untagged_live_account_without_changing_saved_logins(self):
        self.save("n1", "A")
        self.write(self.m.slot_path("n2"), auth("B"))
        self.write(self.m.AUTH, auth("C"))
        before = self.m.AUTH.read_bytes()
        saved = self.m.slot_path("n1").read_bytes()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            self.m.cmd_switch("n2")
        self.assertEqual(self.m.AUTH.read_bytes(), before)
        self.assertEqual(self.m.slot_path("n1").read_bytes(), saved)

    def test_failed_quota_keeps_timestamp_and_reports_not_fresh(self):
        self.save("n1", "A")
        cached = {"n1": {"five": 42, "week": 55, "fetched_at": 100}}
        self.m.write_quota_cache(cached)
        self.m.fetch_usage = lambda data: (503, None)
        result = self.run_json(self.m.cmd_quotas, ["n1"])
        self.assertEqual(result["failed"], ["n1"])
        self.assertFalse(result["quotas"][0]["fresh"])
        self.assertEqual(result["quotas"][0]["five"], 42)
        self.assertEqual(self.m.read_quota_cache(), cached)

    def test_server_plan_updates_quota_list_and_live_label_without_rewriting_tokens(self):
        self.save("n1", "A")
        credentials={p:p.read_bytes() for p in [self.m.AUTH,self.m.slot_path("n1")]}
        self.m.fetch_usage=lambda data:(200,{"account_id":"A","plan_type":"free","rate_limit":{
            "primary_window":{"used_percent":0,"limit_window_seconds":2592000,"reset_after_seconds":2592000},
            "secondary_window":None}})
        result=self.run_json(self.m.cmd_quota,"n1")
        self.assertEqual(result["plan"],"free")
        self.assertEqual(result["five_window_seconds"],2592000)
        self.assertIsNone(result["week"])
        state=self.m.list_state()
        self.assertEqual(state["slots"][0]["plan"],"free")
        self.assertEqual(state["live"]["plan"],"free")
        self.assertEqual(self.m.auth_meta(self.m.AUTH)["plan"],"pro")
        self.assertTrue(all(p.read_bytes()==value for p,value in credentials.items()))

    def test_aliases_share_refreshed_plan_and_failed_refresh_preserves_it(self):
        self.save("n1","A")
        self.write(self.m.slot_path("n2"),auth("A"))
        calls=[]
        def fetch(data):
            calls.append(True)
            return 200,{"plan_type":"free","rate_limit":{"primary_window":{
                "used_percent":10,"limit_window_seconds":2592000,"reset_after_seconds":50}}}
        self.m.fetch_usage=fetch
        result=self.run_json(self.m.cmd_quotas,["n1","n2"])
        self.assertEqual(len(calls),1)
        self.assertEqual([row["plan"] for row in result["quotas"]],["free","free"])
        cached=self.m.read_quota_cache()
        self.m.fetch_usage=lambda data:(503,None)
        result=self.run_json(self.m.cmd_quotas,["n1","n2"])
        self.assertEqual(result["failed"],["n1","n2"])
        self.assertEqual([row["plan"] for row in result["quotas"]],["free","free"])
        self.assertEqual(self.m.read_quota_cache(),cached)

    def test_missing_plan_keeps_last_confirmed_plan_only_for_same_account(self):
        self.save("n1","A")
        self.m.write_quota_cache({"n1":{"plan":"free","account_id":"A","five":80,"fetched_at":100}})
        self.m.fetch_usage=lambda data:(200,{"rate_limit":{"primary_window":{
            "used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":60}}})
        result=self.run_json(self.m.cmd_quota,"n1")
        self.assertEqual(result["plan"],"free")
        self.assertEqual(self.m.list_state()["slots"][0]["plan"],"free")
        self.write(self.m.slot_path("n1"),auth("B"))
        self.assertEqual(self.m.list_state()["slots"][0]["plan"],"pro")
        result=self.run_json(self.m.cmd_quota,"n1")
        self.assertIsNone(result["plan"])
        self.assertEqual(self.m.read_quota_cache()["n1"]["account_id"],"B")

    def test_wrong_account_usage_cannot_change_plan_or_quota(self):
        self.save("n1","A")
        cached={"n1":{"plan":"pro","account_id":"A","five":80,"fetched_at":100}}
        self.m.write_quota_cache(cached)
        self.m.fetch_usage=lambda data:(200,{"account_id":"OTHER","plan_type":"free","rate_limit":{
            "primary_window":{"used_percent":100,"limit_window_seconds":2592000}}})
        result=self.run_json(self.m.cmd_quota,"n1")
        self.assertFalse(result["fresh"])
        self.assertEqual(result["plan"],"pro")
        self.assertEqual(self.m.read_quota_cache(),cached)

    def test_plan_and_window_units_are_explicit_not_inferred_from_quota(self):
        self.assertIsNone(self.m.quota_data({"plan_type":True})["plan"])
        self.assertIsNone(self.m.quota_data({"plan_type":" "})["plan"])
        self.assertIsNone(self.m.quota_data({"rate_limit":{"primary_window":{"used_percent":0}}})["plan"])
        for primary,secondary in [(dict(limit_window_seconds=18000),dict(limit_window_seconds=604800)),
                                  (dict(windowDurationMins=300),dict(windowDurationMins=10080))]:
            result=self.m.quota_data({"plan_type":"plus","rate_limit":{
                "primary_window":dict(primary,used_percent=10),"secondary_window":dict(secondary,used_percent=20)}})
            self.assertEqual((result["five_window_seconds"],result["week_window_seconds"]),(18000,604800))
            self.assertEqual((result["five"],result["week"]),(90,80))
        result=self.m.quota_data({"plan_type":"free"})
        self.assertEqual(result["plan"],"free")

    def test_active_token_rotation_updates_live_file_and_aliases_once(self):
        self.save("n1", "A", "live-access")
        self.write(self.m.slot_path("n1"), auth("A", "stale-access"))
        self.write(self.m.slot_path("n2"), auth("A", "stale-alias"))
        calls = []
        payload = {"rate_limit": {"primary_window": {"used_percent": 70, "limit_window_seconds": 18000,
                    "reset_after_seconds": 600}, "secondary_window": {"used_percent": 20,
                    "limit_window_seconds": 604800, "reset_after_seconds": 3600}}}

        def fetch(data):
            access = data["tokens"]["access_token"]
            calls.append(access)
            return (401, None) if access == "live-access" else (200, payload)

        def refresh(data):
            data["tokens"].update(access_token="fresh-access", refresh_token="fresh-refresh")
            return True

        self.m.fetch_usage, self.m.refresh = fetch, refresh
        result = self.run_json(self.m.cmd_quotas, ["n1", "n2"])
        self.assertEqual(calls, ["live-access", "fresh-access"])
        self.assertEqual(result["failed"], [])
        for path in [self.m.AUTH, self.m.slot_path("n1"), self.m.slot_path("n2")]:
            self.assertEqual(self.m.load_auth(path)["tokens"]["refresh_token"], "fresh-refresh")
        self.assertEqual(self.m.read_quota_cache()["n1"]["five"], 30)
        self.assertEqual(self.m.read_quota_cache()["n2"]["five"], 30)

    def test_quota_does_not_overwrite_concurrently_refreshed_desktop_credentials(self):
        self.save("n1", "A", "live-access")
        calls = []

        def fetch(data):
            calls.append(data["tokens"]["access_token"])
            return (401, None) if len(calls) == 1 else (200, {"rate_limit": {
                "primary_window": {"used_percent": 5, "limit_window_seconds": 18000,
                                   "reset_after_seconds": 600}}})

        def refresh(data):
            self.write(self.m.AUTH, auth("A", "desktop-access", "desktop-refresh"))
            data["tokens"].update(access_token="probe-access", refresh_token="probe-refresh")
            return True

        self.m.fetch_usage, self.m.refresh = fetch, refresh
        self.run_json(self.m.cmd_quota, "n1")
        self.assertEqual(calls, ["live-access", "desktop-access"])
        for path in [self.m.AUTH, self.m.slot_path("n1")]:
            self.assertEqual(self.m.load_auth(path)["tokens"]["refresh_token"], "desktop-refresh")

    def test_operation_lock_serializes_separate_backend_processes(self):
        child = r"""
import importlib.util,pathlib,sys,time
spec=importlib.util.spec_from_file_location("backend",sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.DATA=m.ACCOUNTS=pathlib.Path(sys.argv[2]);m.LOCK=m.DATA/".lock";m.OPERATION_LOCK=m.DATA/".operation.lock"
m.acquire_lock();print("acquired",flush=True);time.sleep(float(sys.argv[3]))
"""
        first = subprocess.Popen([sys.executable, "-c", child, str(BACKEND), str(self.m.DATA), "0.8"],
                                 stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(first.stdout.readline().strip(), "acquired")
            started = time.monotonic()
            second = subprocess.run([sys.executable, "-c", child, str(BACKEND), str(self.m.DATA), "0"],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(second.returncode, 0)
            self.assertGreater(time.monotonic() - started, 0.6)
            self.assertEqual(second.stdout.strip(), "acquired")
        finally:
            first.wait(timeout=5)
            first.stdout.close()

    def test_list_marks_missing_live_login_inactive(self):
        self.save("n1", "A")
        self.m.AUTH.unlink()
        state = self.m.list_state()
        self.assertFalse(state["auth_exists"])
        self.assertFalse(state["slots"][0]["active"])

    def test_delete_refuses_current_account_and_order_keeps_all_saved_accounts(self):
        self.save("n1", "A")
        self.write(self.m.slot_path("n2"), auth("B"))
        self.write(self.m.slot_path("n3"), auth("C"))
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            self.m.cmd_delete("n1")
        self.run_json(self.m.cmd_order, ["n3", "n2"])
        self.assertEqual(self.m.ordered_slots(["n1", "n2", "n3"]), ["n3", "n2", "n1"])


if __name__ == "__main__":
    unittest.main()
