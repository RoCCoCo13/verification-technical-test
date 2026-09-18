"""
Scenario runner: executes end-to-end remote-command scenarios against the
backend while capturing packets from the gateway's network namespace, so each
PCAP contains all three legs (client->backend REST, backend->TCU HTTP,
TCU->Body ECU gRPC).

Output: /traces/pcap/scenarios/<run_id>/<scenario>.pcap  + run_summary.json
Usage : python run_scenarios.py [--label NAME] [--only S01,S03]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

import requests

BACKEND = os.environ.get("BACKEND_URL", "http://backend:8000")
API_KEY = os.environ.get("VEHICLE_API_KEY", "dev-key-001")
OUT_ROOT = os.environ.get("SCENARIO_OUT", "/traces/pcap/scenarios")
H = {"X-API-Key": API_KEY}
events: list[dict] = []


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def ev(kind: str, **data):
    e = {"t": now(), "kind": kind, **data}
    events.append(e)
    print(f"  {e['t']} {kind:<10} " + " ".join(f"{k}={v}" for k, v in data.items()), flush=True)


def post(path: str, body: dict | None = None):
    r = requests.post(f"{BACKEND}{path}", json=body, headers=H, timeout=5)
    data = r.json() if r.content else {}
    ev("REST", method="POST", path=path, http=r.status_code, request_id=data.get("request_id"), status=data.get("status"))
    return data


def status():
    r = requests.get(f"{BACKEND}/vehicle/status", headers=H, timeout=5).json()
    ev("STATUS", doors_locked=r["doors"]["locked"], hvac=r["climate"]["active"], hvac_set=r["climate"]["target_temp_c"],
       chg=r["charging"]["state"], soc=r["charging"]["soc_percent"], seq=r["connectivity"]["state_seq"])
    return r


def command(req_id: str):
    r = requests.get(f"{BACKEND}/vehicle/commands/{req_id}", headers=H, timeout=5).json()
    ev("COMMAND", request_id=req_id, status=r["status"], reason=r.get("reason"), elapsed_ms=r.get("elapsed_ms"))
    return r


def wait_terminal(req_id: str, timeout: float = 6.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = requests.get(f"{BACKEND}/vehicle/commands/{req_id}", headers=H, timeout=5).json()
        if r["status"] != "ACCEPTED":
            return command(req_id)
        time.sleep(0.25)
    return command(req_id)


class Capture:
    def __init__(self, path: str):
        self.path = path
        self.proc = None

    def __enter__(self):
        self.proc = subprocess.Popen(["tcpdump", "-i", "any", "-nn", "-U", "-s", "0", "-Z", "root", "-w", self.path, "tcp and not port 5555"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        time.sleep(1.0)  # let tcpdump attach
        return self

    def __exit__(self, *exc):
        time.sleep(1.5)  # flush trailing ACKs
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def reset():
    r = requests.post(f"{BACKEND}/bench/reset", headers=H, timeout=10)
    ev("RESET", http=r.status_code)
    time.sleep(1.0)


# ------------------------------------------------------------------ scenarios
def s01_lock_unlock_cycles(n: int = 5):
    """Central locking: n unlock/lock cycles with command lifecycle polling."""
    for i in range(n):
        for path in ("/vehicle/unlock", "/vehicle/lock"):
            d = post(path)
            wait_terminal(d["request_id"])
            time.sleep(0.5)
    time.sleep(5.5)
    status()


def s02_climate_preconditioning():
    """HVAC pre-conditioning session with a half-degree set point, then the user unlocks the car."""
    d = post("/climate/start", {"target_temp_c": 22.5})
    wait_terminal(d["request_id"])
    time.sleep(6)
    status()
    d = post("/vehicle/unlock")
    wait_terminal(d["request_id"])
    time.sleep(6)
    status()
    d = post("/climate/stop")
    wait_terminal(d["request_id"])
    time.sleep(2)


def s03_charging_session():
    """Start charging towards 60 %, observe SOC, stop, observe again."""
    d = post("/charging/start", {"target_soc_percent": 60})
    wait_terminal(d["request_id"])
    time.sleep(7)
    status()
    d = post("/charging/stop")
    wait_terminal(d["request_id"])
    time.sleep(7)
    status()
    time.sleep(5)
    status()


def s04_api_validation():
    """Contract checks: authentication and input boundaries."""
    r = requests.post(f"{BACKEND}/vehicle/lock", timeout=5)
    ev("REST", method="POST", path="/vehicle/lock", http=r.status_code, note="no api key")
    r = requests.get(f"{BACKEND}/vehicle/commands/does-not-exist", headers=H, timeout=5)
    ev("REST", method="GET", path="/vehicle/commands/does-not-exist", http=r.status_code)
    for temp in (16.0, 28.0, 35.0):
        d = post("/climate/start", {"target_temp_c": temp})
        if d.get("request_id"):
            wait_terminal(d["request_id"])
        time.sleep(0.5)
    time.sleep(6)
    status()
    post("/climate/stop")
    time.sleep(1)


SCENARIOS = {
    "S01_lock_unlock_cycles": s01_lock_unlock_cycles,
    "S02_climate_preconditioning": s02_climate_preconditioning,
    "S03_charging_session": s03_charging_session,
    "S04_api_validation": s04_api_validation,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default=os.environ.get("SCENARIO_LABEL") or datetime.now().strftime("%Y%m%d_%H%M%S"))
    ap.add_argument("--only", default=os.environ.get("SCENARIO_ONLY", ""))
    args = ap.parse_args()
    out = os.path.join(OUT_ROOT, args.label)
    os.makedirs(out, exist_ok=True)
    selected = [s for s in SCENARIOS if not args.only or s.split("_")[0] in args.only.split(",")]
    summary = {"label": args.label, "backend": BACKEND, "started": now(), "scenarios": {}}
    for _ in range(30):
        try:
            requests.get(f"{BACKEND}/health", timeout=2).raise_for_status()
            break
        except Exception:
            time.sleep(1)
    for name in selected:
        print(f"\n=== {name} ===", flush=True)
        events.clear()
        reset()
        pcap = os.path.join(out, f"{name}.pcap")
        t0 = now()
        with Capture(pcap):
            SCENARIOS[name]()
        summary["scenarios"][name] = {"pcap": pcap, "started": t0, "finished": now(), "doc": SCENARIOS[name].__doc__,
                                      "events": list(events)}
    summary["finished"] = now()
    with open(os.path.join(out, "run_summary.json"), "w") as fh:
        json.dump(summary, fh, indent=2)
    print(f"\nrun summary: {out}/run_summary.json")


if __name__ == "__main__":
    sys.exit(main())
