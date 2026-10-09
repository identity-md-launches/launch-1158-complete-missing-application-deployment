#!/usr/bin/env python3
"""PRISM RIOT server operator.

Budget-limited driver for the IdentityMD paid flows the project uses:

  * ``oracle.request``  - buys a panel answer for an Arena round through the on-chain Intake
                          (via ``OracleAdapter.request``) or through the HTTP door, then polls and
                          relays the signed attestation with ``OracleAdapter.submitAttestation``.
  * ``job.open``        - opens an agent job that proposes challenge content or artwork. Its output
                          is a *proposal file* for the owner to read. It never changes an active
                          round, never signs anything and never touches player funds.
  * ``buy-prio`` / ``buy-imd`` - the treasury's bounded purchases (``FeeTreasury.buyPrio`` /
                          ``buyImd``). Every purchase is simulated first with ``cast call``; when the
                          pool answers ``PriceLimitAlreadyExceeded`` (no liquidity left on the buy
                          side) the operator records a backoff and refuses to broadcast until it has
                          expired, instead of paying gas for a swap that cannot fill. The backoff
                          doubles on every consecutive refusal and resets on the first success.

Everything is capped by ``operator.json``: a spend ceiling per UTC day in IMD and in gas ETH, a
maximum number of requests per day, and a hard switch ``paid_operations_enabled`` that stays off
until the owner has configured the OracleAdapter (see README "After launch") and the treasury has
bought IMD from earned fees. Keys never leave this machine: the signer key is read from the
``OPERATOR_PRIVATE_KEY`` environment variable and only ever handed to ``cast`` as a subprocess.

The HTTP door shape (capabilities / check / quote / payment / poll) follows the published IMD flow;
every path is configurable in ``operator.json`` so an endpoint move needs no code change. Only the
Python standard library is used.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_CONFIG = {
    "paid_operations_enabled": False,
    "rpc_url": "https://ethereum-rpc.publicnode.com",
    "chain_id": 1,
    "api_base": "https://api.imd.fun",
    "paths": {
        "capabilities": "/v1/capabilities",
        "check": "/v1/actions/check",
        "quote": "/v1/actions/quote",
        "request": "/v1/actions/request",
        "status": "/v1/requests/{id}",
    },
    "contracts": {"oracle_adapter": "", "fee_treasury": "", "arena": ""},
    "budget": {
        "imd_per_day": "1000000000000000000",
        "gas_eth_per_day": "20000000000000000",
        "requests_per_day": 4,
        "oracle_price_imd": "500000000000000000",
    },
    "poll": {"interval_seconds": 30, "max_attempts": 120},
    "retries": {"attempts": 3, "backoff_seconds": 5},
    "purchases": {
        "eth_per_buy": "100000000000000000",
        "min_out_bps_of_floor": 10000,
        "price_limit_backoff_seconds": 3600,
        "price_limit_backoff_max_seconds": 86400,
    },
    "state_file": "operator-state.json",
    "proposals_dir": "proposals",
}


class Budget:
    """Per-UTC-day ledger. Every paid step must pass ``allow`` before it runs."""

    def __init__(self, cfg: dict[str, Any], state_path: Path):
        self.cfg = cfg
        self.state_path = state_path
        self.state = {"day": "", "imd_spent": "0", "gas_spent": "0", "requests": 0}
        if state_path.exists():
            self.state.update(json.loads(state_path.read_text()))
        self._roll()

    def _roll(self) -> None:
        today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
        if self.state["day"] != today:
            self.state = {"day": today, "imd_spent": "0", "gas_spent": "0", "requests": 0}
            self.save()

    def allow(self, imd_wei: int = 0, gas_wei: int = 0, requests: int = 0) -> tuple[bool, str]:
        self._roll()
        b = self.cfg["budget"]
        if int(self.state["imd_spent"]) + imd_wei > int(b["imd_per_day"]):
            return False, "IMD daily budget exceeded"
        if int(self.state["gas_spent"]) + gas_wei > int(b["gas_eth_per_day"]):
            return False, "gas daily budget exceeded"
        if self.state["requests"] + requests > int(b["requests_per_day"]):
            return False, "request count per day exceeded"
        return True, "ok"

    def record(self, imd_wei: int = 0, gas_wei: int = 0, requests: int = 0) -> None:
        self.state["imd_spent"] = str(int(self.state["imd_spent"]) + imd_wei)
        self.state["gas_spent"] = str(int(self.state["gas_spent"]) + gas_wei)
        self.state["requests"] += requests
        self.save()

    def save(self) -> None:
        self.state_path.write_text(json.dumps(self.state, indent=2))


@dataclass
class Http:
    base: str
    retries: int = 3
    backoff: float = 5.0
    opener: Any = field(default=None)

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("content-type", "application/json")
        last: Exception | None = None
        for attempt in range(self.retries):
            try:
                opener = self.opener or urllib.request.urlopen
                with opener(req, timeout=30) as resp:
                    return json.loads(resp.read().decode() or "{}")
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:  # retried
                last = exc
                time.sleep(self.backoff * (attempt + 1))
        raise RuntimeError(f"{method} {path} failed after {self.retries} attempts: {last}")


def cast(args: list[str], cfg: dict[str, Any], send: bool = False, dry_run: bool = False) -> str:
    """Runs ``cast``; the key is passed only as a subprocess argument, never logged or written."""
    cmd = ["cast", "send" if send else "call", "--rpc-url", cfg["rpc_url"], *args]
    if dry_run:
        return "DRY-RUN " + " ".join(cmd + (["--private-key", "<key>"] if send else []))
    if send:
        key = os.environ.get("OPERATOR_PRIVATE_KEY")
        if not key:
            raise RuntimeError("OPERATOR_PRIVATE_KEY is not set; refusing to send")
        cmd += ["--private-key", key]
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def require_enabled(cfg: dict[str, Any]) -> None:
    if not cfg.get("paid_operations_enabled"):
        raise SystemExit("paid operations are disabled: configure the OracleAdapter, fund IMD from fees, then enable")
    if not cfg["contracts"].get("oracle_adapter"):
        raise SystemExit("contracts.oracle_adapter is not set")


# ----------------------------------------------------------------------------- purchases

# Uniswap v4 PoolManager / Pool errors a treasury purchase can surface. The first is the "no liquidity in
# the direction of the swap at this price" case the brief names: back off, do not retry on a timer.
PRICE_LIMIT_ALREADY_EXCEEDED = "PriceLimitAlreadyExceeded"
PRICE_LIMIT_SELECTOR = "0x7c9c6e8f"  # bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"))


class Backoff:
    """Persistent per-purchase backoff. ``blocked_until`` is a UTC timestamp; ``streak`` doubles the wait."""

    def __init__(self, cfg: dict[str, Any], state_path: Path):
        self.cfg = cfg["purchases"]
        self.state_path = state_path
        self.state: dict[str, Any] = {}
        if state_path.exists():
            self.state = json.loads(state_path.read_text())

    def blocked(self, kind: str, now: float) -> tuple[bool, int]:
        until = int(self.state.get(kind, {}).get("blocked_until", 0))
        return now < until, until

    def hit(self, kind: str, now: float) -> int:
        entry = self.state.get(kind, {"streak": 0})
        streak = int(entry.get("streak", 0)) + 1
        wait = min(
            int(self.cfg["price_limit_backoff_seconds"]) * (2 ** (streak - 1)),
            int(self.cfg["price_limit_backoff_max_seconds"]),
        )
        self.state[kind] = {"streak": streak, "blocked_until": int(now) + wait, "last_reason": PRICE_LIMIT_ALREADY_EXCEEDED}
        self.save()
        return wait

    def clear(self, kind: str) -> None:
        if kind in self.state:
            del self.state[kind]
            self.save()

    def save(self) -> None:
        self.state_path.write_text(json.dumps(self.state, indent=2))


def is_price_limit_revert(text: str) -> bool:
    t = text or ""
    return PRICE_LIMIT_ALREADY_EXCEEDED in t or PRICE_LIMIT_SELECTOR in t.lower()


def cmd_buy(cfg: dict[str, Any], budget: Budget, backoff: Backoff, kind: str, dry_run: bool, now=time.time, caller=None) -> dict:
    """``FeeTreasury.buyPrio`` / ``buyImd`` from the operator (executor) wallet, simulate-first.

    The contract itself bounds the spend (maxSpendPerSwap, spendPerWindow, price floors); this adds the
    operator's daily gas ledger and the PriceLimitAlreadyExceeded backoff. Nothing is sent when the
    simulation fails for any reason; only the price-limit case arms the backoff, because it means the pool
    has no liquidity to sell into right now and retrying on a timer would only burn gas.
    """
    require_enabled(cfg)
    treasury = cfg["contracts"].get("fee_treasury")
    if not treasury:
        raise SystemExit("contracts.fee_treasury is not set")
    fn = "buyPrio(uint256,uint256)" if kind == "prio" else "buyImd(uint256,uint256)"
    eth_in = str(int(cfg["purchases"]["eth_per_buy"]))
    is_blocked, until = backoff.blocked(kind, now())
    if is_blocked:
        return {"ok": False, "reason": f"backing off after {PRICE_LIMIT_ALREADY_EXCEEDED} until {until}", "blocked_until": until}
    ok, why = budget.allow(gas_wei=int(4e15))
    if not ok:
        return {"ok": False, "reason": why}
    run = caller or cast
    executor = cfg.get("executor_address", "")
    sim_args = [treasury, fn, eth_in, "0"] + (["--from", executor] if executor else [])
    try:
        run(sim_args, cfg, dry_run=dry_run)
    except subprocess.CalledProcessError as exc:
        text = (exc.stderr or "") + (exc.stdout or "")
        if is_price_limit_revert(text):
            wait = backoff.hit(kind, now())
            return {"ok": False, "reason": f"{PRICE_LIMIT_ALREADY_EXCEEDED}: pool has no liquidity for this buy; backing off {wait}s", "backoff_seconds": wait}
        return {"ok": False, "reason": "simulation reverted; nothing sent", "detail": text.strip()[-400:]}
    tx = run([treasury, fn, eth_in, "0"], cfg, send=True, dry_run=dry_run)
    if not dry_run:
        budget.record(gas_wei=int(4e15))
    backoff.clear(kind)
    return {"ok": True, "tx": tx}


# ----------------------------------------------------------------------------- commands


def cmd_capabilities(cfg: dict[str, Any], http: Http, **_: Any) -> dict:
    return http.call("GET", cfg["paths"]["capabilities"])


def cmd_quote(cfg: dict[str, Any], http: Http, action: str, body: dict, **_: Any) -> dict:
    checked = http.call("POST", cfg["paths"]["check"], {"action": action, "body": body})
    if checked.get("ok") is False:
        return {"ok": False, "stage": "check", "detail": checked}
    return http.call("POST", cfg["paths"]["quote"], {"action": action, "body": body})


def read_not_before(cfg: dict[str, Any], round_id: int, caller=None) -> int:
    """The round's commit boundary from ``OracleAdapter.pinned(roundId)``: word 5 of the ABI-encoded tuple
    (offset, questionHash, chainId, minPanel, minQuorum, notBefore, ...)."""
    raw = (caller or cast)([cfg["contracts"]["oracle_adapter"], "pinned(uint256)", str(round_id)], cfg)
    words = raw[2:] if raw.startswith("0x") else raw
    if len(words) < 6 * 64:
        raise RuntimeError("pinned(roundId) returned too little data; is the question pinned?")
    return int(words[5 * 64 : 6 * 64], 16)


def cmd_request_round(cfg: dict[str, Any], budget: Budget, round_id: int, dry_run: bool, now=time.time, **_: Any) -> dict:
    """Pays for a panel answer on chain through ``OracleAdapter.request(roundId)``.

    The adapter itself enforces the owner's on-chain budget and refuses before the round's commit boundary;
    this is the operator's own, tighter cap plus the same timing guard, so no IMD is spent on a reverting call.
    """
    require_enabled(cfg)
    price = int(cfg["budget"]["oracle_price_imd"])  # the Intake's list price; read it with Intake.priceOf
    ok, why = budget.allow(imd_wei=price, gas_wei=int(2e15), requests=1)
    if not ok:
        return {"ok": False, "reason": why}
    if not dry_run:
        not_before = read_not_before(cfg, round_id)
        if int(now()) < not_before:
            return {"ok": False, "reason": f"round {round_id} is still open for commitments until {not_before}"}
    tx = cast([cfg["contracts"]["oracle_adapter"], "request(uint256)", str(round_id)], cfg, send=True, dry_run=dry_run)
    if not dry_run:
        budget.record(imd_wei=price, gas_wei=int(2e15), requests=1)
    return {"ok": True, "tx": tx}


def cmd_poll(cfg: dict[str, Any], http: Http, request_id: str, sleeper=time.sleep, **_: Any) -> dict:
    p = cfg["poll"]
    for _ in range(int(p["max_attempts"])):
        status = http.call("GET", cfg["paths"]["status"].format(id=request_id))
        if status.get("status") in ("done", "refused", "no-agreement", "failed"):
            return status
        sleeper(float(p["interval_seconds"]))
    return {"status": "timeout"}


def cmd_relay(cfg: dict[str, Any], budget: Budget, round_id: int, attestation_file: Path, dry_run: bool, **_: Any) -> dict:
    """Manual result relay: submits a signed attestation JSON to ``OracleAdapter.submitAttestation``."""
    a = json.loads(Path(attestation_file).read_text())
    fields = [
        a["requestId"], str(a["chainId"]), a["questionHash"], str(a["answerType"]), a["answer"], str(a["figure"]),
        str(a["fromBlock"]), str(a["toBlock"]), a["blockHash"], a["panelJobId"], str(a["panelSize"]),
        str(a["quorum"]), str(a["agreed"]), str(a["issuedAt"]), str(a["expiresAt"]),
    ]
    tuple_arg = "(" + ",".join(fields) + ")"
    ok, why = budget.allow(gas_wei=int(3e15))
    if not ok:
        return {"ok": False, "reason": why}
    sig = (
        "submitAttestation(uint256,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,"
        "uint16,uint16,uint16,uint64,uint64),bytes)"
    )
    tx = cast([cfg["contracts"]["oracle_adapter"], sig, str(round_id), tuple_arg, a["signature"]], cfg, send=True, dry_run=dry_run)
    if not dry_run:
        budget.record(gas_wei=int(3e15))
    return {"ok": True, "tx": tx}


def cmd_propose(cfg: dict[str, Any], http: Http, budget: Budget, brief: str, dry_run: bool, **_: Any) -> dict:
    """Opens a ``job.open`` for challenge content or artwork and stores the proposal for owner review."""
    require_enabled(cfg)
    body = {"v": 1, "kind": "job.open", "brief": brief, "deliverable": "proposal-only"}
    quote = cmd_quote(cfg, http, "job.open", body)
    price = int(quote.get("price", "0") or 0)
    ok, why = budget.allow(imd_wei=price, requests=1)
    if not ok:
        return {"ok": False, "reason": why, "quote": quote}
    if dry_run:
        return {"ok": True, "dry_run": True, "quote": quote}
    opened = http.call("POST", cfg["paths"]["request"], {"action": "job.open", "body": body, "payment": quote.get("payment")})
    budget.record(imd_wei=price, requests=1)
    out_dir = Path(cfg["proposals_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{opened.get('id', int(time.time()))}.json").write_text(json.dumps(opened, indent=2))
    return {"ok": True, "opened": opened, "note": "proposal only; the owner decides whether to use it"}


def load_config(path: Path) -> dict[str, Any]:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if path.exists():
        user = json.loads(path.read_text())
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    return cfg


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="operator.json")
    ap.add_argument("--dry-run", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("capabilities")
    q = sub.add_parser("quote")
    q.add_argument("action")
    q.add_argument("body_json")
    r = sub.add_parser("request-round")
    r.add_argument("round_id", type=int)
    p = sub.add_parser("poll")
    p.add_argument("request_id")
    rl = sub.add_parser("relay")
    rl.add_argument("round_id", type=int)
    rl.add_argument("attestation_file")
    pr = sub.add_parser("propose")
    pr.add_argument("brief")
    sub.add_parser("buy-prio")
    sub.add_parser("buy-imd")
    a = ap.parse_args(argv)

    cfg = load_config(Path(a.config))
    http = Http(cfg["api_base"], int(cfg["retries"]["attempts"]), float(cfg["retries"]["backoff_seconds"]))
    budget = Budget(cfg, Path(cfg["state_file"]))
    backoff = Backoff(cfg, Path(cfg["state_file"]).with_name("operator-backoff.json"))
    if a.cmd in ("buy-prio", "buy-imd"):
        out = cmd_buy(cfg, budget, backoff, "prio" if a.cmd == "buy-prio" else "imd", a.dry_run)
    elif a.cmd == "capabilities":
        out = cmd_capabilities(cfg, http)
    elif a.cmd == "quote":
        out = cmd_quote(cfg, http, a.action, json.loads(a.body_json))
    elif a.cmd == "request-round":
        out = cmd_request_round(cfg, budget, a.round_id, a.dry_run)
    elif a.cmd == "poll":
        out = cmd_poll(cfg, http, a.request_id)
    elif a.cmd == "relay":
        out = cmd_relay(cfg, budget, a.round_id, Path(a.attestation_file), a.dry_run)
    else:
        out = cmd_propose(cfg, http, budget, a.brief, a.dry_run)
    print(json.dumps(out, indent=2))
    return 0 if out.get("ok", True) else 1


if __name__ == "__main__":
    sys.exit(main())
