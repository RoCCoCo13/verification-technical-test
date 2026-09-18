"""Bench addresses seen from the **host**, for running the suite outside Docker.

    robot --variablefile robot/variables/bench_local.py --outputdir results robot/tests

Requires ``adb``, ``tshark`` and the Python packages in requirements.txt on the
host. ``bench_toolbox.py`` needs none of that and is the supported path; this
file exists so the suite can be driven from an IDE during development.

``BACKEND_PORT`` defaults to 8800 rather than the bench default 8000: on this
workstation another service already owns 8000, so ``.env`` publishes the bench
backend on 8800 (see SUBMISSION.md). Override it if your host is free on 8000.
"""
import os

_BACKEND_PORT = os.environ.get("BACKEND_PORT", "8800")

# --- interfaces under test ---------------------------------------------------
BACKEND_URL = os.environ.get("BACKEND_URL", f"http://localhost:{_BACKEND_PORT}")
API_KEY = os.environ.get("VEHICLE_API_KEY", "dev-key-001")
ADB_SERIAL = os.environ.get("ADB_SERIAL", f"127.0.0.1:{os.environ.get('ADB_PORT', '5555')}")
BODY_ECU_ADDR = os.environ.get("BODY_ECU_ADDR", f"127.0.0.1:{os.environ.get('BODY_GRPC_PORT', '50051')}")

# --- artefacts ---------------------------------------------------------------
TRACES_DIR = os.environ.get("TRACES_DIR", "traces")
LOGS_DIR = os.environ.get("LOGS_DIR", f"{TRACES_DIR}/logs")
PROTO_PATH = os.environ.get("PROTO_PATH", "env/proto/vehicle_ecu.proto")

SCENARIO_DIR = os.environ.get("SCENARIO_DIR", f"{TRACES_DIR}/pcap/scenarios/ci")
FALLBACK_SCENARIO_DIR = os.environ.get("FALLBACK_SCENARIO_DIR", f"{TRACES_DIR}/samples")
REFERENCE_DIR = os.environ.get("REFERENCE_DIR", f"{TRACES_DIR}/reference")
