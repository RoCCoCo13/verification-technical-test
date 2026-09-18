# Automation & Validation Engineer - Technical Assessment

Welcome. This repository contains a **complete, local, automotive validation bench**: an Android
Automotive-style gateway ECU you reach over ADB, a cloud backend with a REST API, and a Body ECU
connected over the in-vehicle network (gRPC). Your job is the job: validate the release, automate
the validation with Robot Framework, find what is wrong, and explain it with evidence.

Everything runs on your machine with one command. No hardware, no accounts, no VPN.

> Start with this file, then read `docs/EXERCISE_SPECIFICATION.md`. Budget: **3 to 5 hours**.
> AI assistants (Claude, ChatGPT, Copilot, ...) are explicitly allowed and expected. We evaluate
> engineering quality, not memorisation.

---

## 1. What you need on your computer

| Tool | Version | Why |
|---|---|---|
| Docker Desktop / Docker Engine + Compose v2 | any recent | runs the bench |
| `adb` (Android platform tools) | any recent | talk to the gateway ECU (optional: a container with adb is provided) |
| Python 3.10+ | | Robot Framework |
| Wireshark / `tshark` | optional | analyse PCAP traces (a container with tshark is provided) |
| Git | | you will deliver a repository |

Ports used on `localhost`: **8000** (backend REST), **5555** (ADB), **50051** (Body ECU gRPC), **8081**
(telematics receiver). Change them in `.env` (copy `.env.example`) if they clash.

## 2. Start the bench

```bash
docker compose up -d --build --wait      # first start builds the images (2-4 min)
docker compose ps                        # 5 containers: ecu-gateway, backend, body-ecu, capture-tcu, capture-cloud
```

Quick checks:

```bash
# REST
curl -s -H "X-API-Key: dev-key-001" http://localhost:8000/vehicle/status | python3 -m json.tool
# OpenAPI UI: open http://localhost:8000/docs in your browser

# ADB
adb connect localhost:5555
adb -s localhost:5555 shell getprop ro.product.model        # -> TCU-GW-2
adb -s localhost:5555 shell dumpsys vehicle
adb -s localhost:5555 logcat -d TelematicsSvc:I '*:S'
adb -s localhost:5555 pull /data/log/dlt/tcu.dlt

# Logs on the host (DLT-like text, see docs/LOG_FORMAT.md)
tail -f traces/logs/tcu.dlt

# Network captures (rotating, from two vantage points)
ls traces/pcap/live/
```

No `adb` installed? Use the tester container. It has adb, tshark, Robot Framework and sits **inside the
vehicle network**, so `localhost` there means the container itself. Use the service names instead:

| From your host | From inside the toolbox |
|---|---|
| `http://localhost:8000` | `http://backend:8000` |
| `adb connect localhost:5555` | `adb connect ecu-gateway:5555` (done automatically at start; `adb shell` works directly) |
| `localhost:50051` (gRPC) | `body-ecu:50051` |
| `traces/` | `/traces` (and the whole bundle at `/work`) |

```bash
docker compose run --rm toolbox            # interactive shell, prints the addresses above and connects adb
adb shell getprop ro.product.model         # inside the container
adb shell dumpsys vehicle
curl -s -H "X-API-Key: dev-key-001" http://backend:8000/vehicle/status | jq
```

Scenario captures (one clean PCAP per scenario, plus a JSON timeline of what was sent):

```bash
docker compose run --rm scenario-runner    # -> traces/pcap/scenarios/<timestamp>/
```

Reset everything to factory state at any time: `curl -X POST -H "X-API-Key: dev-key-001" http://localhost:8000/bench/reset`
(or `make reset`). Stop: `docker compose down`.

> Always run `docker compose down` **before** deleting, moving or re-extracting this folder. Containers keep
> bind mounts into it, and Docker Desktop refuses to start the bench again until they are removed (see
> `docs/TROUBLESHOOTING.md`, first row).

## 3. The exercise in one paragraph

Release **TCU_GW2_SW_4.12.0** of the gateway software, together with backend **CVB_API_1.8.3** and
Body ECU **BCM4_SW_2.7.1**, is proposed for vehicle testing. The requirements are in
`docs/REQUIREMENTS.md`. Design a test strategy, implement it in Robot Framework, run it in a CI
pipeline, and write a root cause analysis for at least one defect you find. The system contains
real defects. Some are visible from the REST API alone, some only when you compare what the cloud
says with what the ECU does, and some only in logs or network traces.

Full details, deliverables and the submission checklist: **`docs/EXERCISE_SPECIFICATION.md`**.

## 4. Documentation map

| File | Content |
|---|---|
| `docs/EXERCISE_SPECIFICATION.md` | task, deliverables, timebox, rules, submission |
| `docs/REQUIREMENTS.md` | the requirements you validate against (REQ-xxx) |
| `docs/ARCHITECTURE.md` | system diagram, containers, network, data flows |
| `docs/API_REFERENCE.md` | REST API summary (live docs at /docs) |
| `docs/ADB_GUIDE.md` | what you can do on the gateway ECU over ADB |
| `docs/LOG_FORMAT.md` | DLT-like log format and correlation ids |
| `docs/NETWORK_TRACES.md` | PCAP vantage points, how to decode gRPC, reference traces |
| `docs/DELIVERABLES.md` | exact list of artefacts, naming, repository layout suggestion |
| `docs/TROUBLESHOOTING.md` | common environment problems |
| `templates/` | RCA and test strategy templates (optional to use) |
| `starter/` | optional Robot Framework skeleton |
| `traces/reference/` | golden PCAPs from a validated bench (healthy behaviour) |
| `traces/samples/` | captures from this build, in case you cannot capture yourself |

## 5. Rules

* You may read the source code in `env/`. It is part of the system under test, like firmware
  you would receive from a supplier. **But**: your RCA must be built from observable evidence
  (API responses, logs, traces, ADB inspection). "I read the code and found the typo" scores low;
  "the trace shows the REST call, the TCU log shows the drop, the ECU never received it, here is
  the calibration parameter involved" scores high.
* Do not modify the bench (`env/`, `docker-compose.yml`) unless you document why in your submission.
  Fixing the defects is not the task; finding and proving them is.
* Timebox yourself. A smaller, clean, well-argued delivery beats a large unfinished one.
