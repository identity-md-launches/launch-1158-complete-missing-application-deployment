"""Offline tests for the operator: budgets, the disabled switch, retries and the polling loop."""

import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import importlib.util
import sys

spec = importlib.util.spec_from_file_location("prio_operator", Path(__file__).with_name("operator.py"))
op = importlib.util.module_from_spec(spec)
sys.modules["prio_operator"] = op
spec.loader.exec_module(op)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class PurchaseBackoffTests(unittest.TestCase):
    """PriceLimitAlreadyExceeded: back off until liquidity returns instead of re-sending on a timer."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = op.load_config(Path(self.tmp.name) / "none.json")
        self.cfg["paid_operations_enabled"] = True
        self.cfg["contracts"]["oracle_adapter"] = "0x" + "11" * 20
        self.cfg["contracts"]["fee_treasury"] = "0x" + "22" * 20
        self.budget = op.Budget(self.cfg, Path(self.tmp.name) / "state.json")
        self.backoff = op.Backoff(self.cfg, Path(self.tmp.name) / "backoff.json")
        self.sent = []

    def caller(self, revert_text=None):
        def run(args, cfg, send=False, dry_run=False):
            if send:
                self.sent.append(args)
                return "0xtx"
            if revert_text is not None:
                raise op.subprocess.CalledProcessError(1, ["cast"], output="", stderr=revert_text)
            return "0x"
        return run

    def test_price_limit_revert_arms_backoff_and_doubles(self):
        now = 1_000_000
        text = "Error: server returned an error response: execution reverted, data: \"0x7c9c6e8f...\" PriceLimitAlreadyExceeded"
        out = op.cmd_buy(self.cfg, self.budget, self.backoff, "prio", False, now=lambda: now, caller=self.caller(text))
        self.assertFalse(out["ok"])
        self.assertEqual(out["backoff_seconds"], 3600)
        self.assertEqual(self.sent, [], "nothing is broadcast when the simulation reverts")
        # Inside the window: refused without even simulating.
        out = op.cmd_buy(self.cfg, self.budget, self.backoff, "prio", False, now=lambda: now + 10, caller=self.caller(text))
        self.assertIn("backing off", out["reason"])
        # After the window, still no liquidity: the wait doubles, capped at the maximum.
        out = op.cmd_buy(self.cfg, self.budget, self.backoff, "prio", False, now=lambda: now + 3601, caller=self.caller(text))
        self.assertEqual(out["backoff_seconds"], 7200)
        for _ in range(8):
            now += 100_000
            out = op.cmd_buy(self.cfg, self.budget, self.backoff, "prio", False, now=lambda: now, caller=self.caller(text))
        self.assertEqual(out["backoff_seconds"], 86400)
        # IMD purchases have their own backoff.
        blocked, _ = self.backoff.blocked("imd", now)
        self.assertFalse(blocked)

    def test_success_clears_backoff_and_other_reverts_do_not_arm_it(self):
        now = 1_000_000
        out = op.cmd_buy(self.cfg, self.budget, self.backoff, "imd", False, now=lambda: now, caller=self.caller("Slippage()"))
        self.assertFalse(out["ok"])
        self.assertNotIn("backoff_seconds", out)
        self.assertFalse(self.backoff.blocked("imd", now)[0])
        self.backoff.hit("imd", now)
        now += 90_000
        out = op.cmd_buy(self.cfg, self.budget, self.backoff, "imd", False, now=lambda: now, caller=self.caller())
        self.assertTrue(out["ok"])
        self.assertEqual(len(self.sent), 1)
        self.assertFalse(self.backoff.blocked("imd", now)[0], "a filled purchase resets the streak")

    def test_disabled_switch_and_missing_treasury(self):
        self.cfg["paid_operations_enabled"] = False
        with self.assertRaises(SystemExit):
            op.cmd_buy(self.cfg, self.budget, self.backoff, "prio", True)
        self.cfg["paid_operations_enabled"] = True
        self.cfg["contracts"]["fee_treasury"] = ""
        with self.assertRaises(SystemExit):
            op.cmd_buy(self.cfg, self.budget, self.backoff, "prio", True)


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = op.load_config(Path(self.tmp.name) / "none.json")
        self.budget = op.Budget(self.cfg, Path(self.tmp.name) / "state.json")

    def test_caps_are_enforced(self):
        ok, _ = self.budget.allow(imd_wei=int(1e18))
        self.assertTrue(ok)
        self.budget.record(imd_wei=int(1e18), requests=1)
        ok, why = self.budget.allow(imd_wei=1)
        self.assertFalse(ok)
        self.assertIn("IMD", why)
        ok, why = self.budget.allow(requests=4)
        self.assertFalse(ok)

    def test_disabled_until_configured(self):
        with self.assertRaises(SystemExit):
            op.cmd_request_round(self.cfg, self.budget, 1, dry_run=True)
        self.cfg["paid_operations_enabled"] = True
        with self.assertRaises(SystemExit):
            op.cmd_request_round(self.cfg, self.budget, 1, dry_run=True)
        self.cfg["contracts"]["oracle_adapter"] = "0x" + "11" * 20
        out = op.cmd_request_round(self.cfg, self.budget, 1, dry_run=True)
        self.assertTrue(out["ok"])
        self.assertTrue(out["tx"].startswith("DRY-RUN"))

    def test_request_waits_for_the_commit_boundary(self):
        self.cfg["paid_operations_enabled"] = True
        self.cfg["contracts"]["oracle_adapter"] = "0x" + "11" * 20
        not_before = 1_800_000_000
        words = ["20", "aa", "01", "05", "04", f"{not_before:x}", "e0", "00"]
        raw = "0x" + "".join(w.rjust(64, "0") for w in words)
        with mock.patch.object(op, "cast", side_effect=lambda args, cfg, **kw: raw if not kw.get("send") else "0xtx"):
            self.assertEqual(op.read_not_before(self.cfg, 7), not_before)
            out = op.cmd_request_round(self.cfg, self.budget, 7, dry_run=False, now=lambda: not_before - 1)
            self.assertFalse(out["ok"])
            self.assertIn("still open", out["reason"])
            self.assertEqual(self.budget.state["requests"], 0)
            out = op.cmd_request_round(self.cfg, self.budget, 7, dry_run=False, now=lambda: not_before)
            self.assertTrue(out["ok"])
            self.assertEqual(self.budget.state["requests"], 1)

    def test_relay_dry_run_builds_tuple(self):
        att = {
            "requestId": "0x" + "01" * 32, "chainId": 1, "questionHash": "0x" + "02" * 32, "answerType": 3,
            "answer": "0x" + "00" * 31 + "07", "figure": 0, "fromBlock": 1, "toBlock": 2, "blockHash": "0x" + "03" * 32,
            "panelJobId": "0x" + "04" * 32, "panelSize": 5, "quorum": 4, "agreed": 5, "issuedAt": 1, "expiresAt": 2,
            "signature": "0x" + "ab" * 65,
        }
        f = Path(self.tmp.name) / "a.json"
        f.write_text(json.dumps(att))
        self.cfg["contracts"]["oracle_adapter"] = "0x" + "11" * 20
        out = op.cmd_relay(self.cfg, self.budget, 3, f, dry_run=True)
        self.assertIn("submitAttestation", out["tx"])


class HttpTests(unittest.TestCase):
    def test_retries_then_succeeds(self):
        calls = {"n": 0}

        def opener(req, timeout):
            calls["n"] += 1
            if calls["n"] < 3:
                raise TimeoutError("slow")
            return FakeResponse(b'{"status":"done"}')

        http = op.Http("http://x", retries=3, backoff=0)
        http.opener = opener
        self.assertEqual(http.call("GET", "/v1/requests/1"), {"status": "done"})
        self.assertEqual(calls["n"], 3)

    def test_poll_stops_on_terminal_status(self):
        answers = iter([b'{"status":"pending"}', b'{"status":"done","attestation":{}}'])
        http = op.Http("http://x", retries=1, backoff=0)
        http.opener = lambda req, timeout: FakeResponse(next(answers))
        cfg = op.load_config(Path("/nonexistent"))
        cfg["poll"]["interval_seconds"] = 0
        out = op.cmd_poll(cfg, http, "1", sleeper=lambda s: None)
        self.assertEqual(out["status"], "done")


if __name__ == "__main__":
    unittest.main()
