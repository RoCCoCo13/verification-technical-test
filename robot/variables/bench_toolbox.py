"""Bench addresses seen from **inside** the vehicle network (toolbox container).

This is the default execution environment for the suite, locally and in CI::

    docker compose run --rm toolbox \
        robot --variablefile robot/variables/bench_toolbox.py --outputdir results robot/tests

Inside the toolbox, ``localhost`` is the container itself, so every node is
addressed by its Docker Compose service name (docs/ARCHITECTURE.md section 2).
Because published host ports are irrelevant here, this file is also immune to
host port clashes -- the reason the backend is published on 8800 on this
workstation does not leak into the suite.

Every value can still be overridden by an environment variable, so the same
file serves a CI runner with a different topology.
"""
import os

# --- interfaces under test ---------------------------------------------------
BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend:8000")
API_KEY = os.environ.get("VEHICLE_API_KEY", "dev-key-001")
ADB_SERIAL = os.environ.get("ADB_SERIAL", "ecu-gateway:5555")
BODY_ECU_ADDR = os.environ.get("BODY_ECU_ADDR", "body-ecu:50051")

# --- artefacts ---------------------------------------------------------------
TRACES_DIR = os.environ.get("TRACES_DIR", "/traces")
LOGS_DIR = os.environ.get("LOGS_DIR", f"{TRACES_DIR}/logs")
PROTO_PATH = os.environ.get("PROTO_PATH", "/work/env/proto/vehicle_ecu.proto")

# Scenario capture analysed by the 05_network suite. The CI pipeline runs the
# scenario-runner with SCENARIO_LABEL=ci before Robot; when no fresh capture is
# available the suite falls back to traces/samples/ and says so in the report.
SCENARIO_DIR = os.environ.get("SCENARIO_DIR", f"{TRACES_DIR}/pcap/scenarios/ci")
FALLBACK_SCENARIO_DIR = os.environ.get("FALLBACK_SCENARIO_DIR", f"{TRACES_DIR}/samples")
REFERENCE_DIR = os.environ.get("REFERENCE_DIR", f"{TRACES_DIR}/reference")
