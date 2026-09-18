# Exercise Specification - Automation & Validation Engineer

## 1. Context

You join the validation team of a connected-vehicle programme. The vehicle's Telematics/Gateway ECU
(TCU-GW-2, Android Automotive 14) receives remote commands from the cloud backend and forwards them
over the in-vehicle Ethernet backbone to the Body ECU (BCM-4), which owns the door locks, HVAC and
the on-board charger. The vehicle reports its state back to the cloud through the gateway.

A new software release (gateway 4.12.0 / backend 1.8.3 / body ECU 2.7.1) has been delivered. The
programme wants an automated regression suite, a release verdict, and root cause analyses for the
defects found. The bench in this repository is a faithful functional replica of that system.

## 2. Your task

1. **Understand** the system: architecture, interfaces, requirements (`docs/`).
2. **Design** a test strategy: what to test, at which interface, with which oracle, what the risks are.
3. **Automate** it with Robot Framework: modular resources, reusable keywords, variable files, clear
   naming, tags linking tests to requirements.
4. **Execute** and deliver the reports (`report.html`, `log.html`, `output.xml`).
5. **Investigate** at least one defect down to root cause, with evidence from logs, traces and ADB.
6. **Integrate** the suite into a CI pipeline (GitHub Actions recommended; another CI is acceptable if it
   runs the bench and publishes the Robot artefacts).

You are validating, not developing. Do not fix the defects in `env/`.

## 3. Timebox

Approximately **3 to 5 hours** of focused work. Hard cap: submit within 7 days of receiving the
repository. Tell us roughly how long you spent; it is not scored, it helps us calibrate.

Suggested split:

| Phase | Time |
|---|---|
| Bench up, exploration through REST, ADB, logs, traces | 30-45 min |
| Test strategy (short document) | 30 min |
| Robot Framework project and execution | 90-150 min |
| Root cause analysis | 45-60 min |
| CI pipeline, README, packaging | 30 min |

## 4. Deliverables

Deliver a Git repository (zip or link) containing:

| # | Deliverable | Notes |
|---|---|---|
| 1 | Robot Framework project | `tests/`, `resources/`, `variables/`, optional `libraries/` |
| 2 | Test strategy | 1-3 pages, `docs/TEST_STRATEGY.md` (template in `templates/`) |
| 3 | Automated test cases | tagged with requirement ids (`req:REQ-LCK-001` or similar) |
| 4 | Reusable keywords | in resource files, documented |
| 5 | Resource and variable files | no hard-coded addresses in test cases |
| 6 | CI/CD pipeline | `.github/workflows/*.yml` or equivalent, with artefact upload |
| 7 | Execution reports | `report.html`, `log.html`, `output.xml` from a real run against this bench |
| 8 | Root Cause Analysis | at least one defect, `docs/rca/RCA-<n>.md` (template in `templates/`) |
| 9 | SUBMISSION.md | how to run your suite locally and in CI; assumptions; time spent; AI usage note (the bench README stays as is) |

Details and a suggested layout: `docs/DELIVERABLES.md`.

## 5. Observation points you should use

| Interface | How | What it tells you |
|---|---|---|
| REST API | `http://localhost:8000`, header `X-API-Key: dev-key-001`, OpenAPI at `/docs` | user/cloud view, command lifecycle |
| ADB | `adb connect localhost:5555` | ECU view: VHAL properties, `dumpsys vehicle`, `dumpsys telematics`, `logcat`, files under `/data`, calibration under `/vendor/etc` |
| DLT-like logs | `traces/logs/{backend,tcu,body_ecu}.dlt` (also `/data/log/dlt/tcu.dlt` on the ECU) | correlation by `req=<request_id>` across the three nodes |
| gRPC | `localhost:50051`, contract in `env/proto/vehicle_ecu.proto` | physical truth on the Body ECU (`GetBodyState`) |
| PCAP | `traces/pcap/live/` (rotating), `traces/pcap/scenarios/` (scenario runner), `traces/reference/` (golden) | message flow, missing messages, timing |

## 6. What we evaluate

The rubric has 100 points across: test design, automation architecture, Robot Framework quality,
REST API validation, ADB usage, log analysis, PCAP analysis, root cause analysis, CI/CD,
maintainability and use of AI. In practice we ask ourselves:

* Would this suite catch a regression of each defect you found, unattended, in CI?
* Could a colleague extend it in 20 minutes without asking you?
* Is the RCA convincing to a supplier who does not want to accept the bug?
* Did you distinguish flakiness of your own tests from intermittent behaviour of the system?

## 7. Using AI assistants

Allowed and encouraged for anything: exploring the ADB protocol, writing tshark filters, drafting
keywords, summarising logs. Two expectations:

1. **You own the result.** Generated code that does not run against the bench, or assertions that
   check nothing, count against you.
2. **Say how you used it** in `SUBMISSION.md` (two or three sentences are enough). Honest, specific notes
   score better than silence.

## 8. Submission

* Repository archive (`.zip`) or a link to a private repository we can access.
* Include the executed reports; do not rely on us re-running everything.
* Do not include `traces/pcap/live/` (large); do include the PCAPs you reference in your RCA.
* Keep the bench sources (`env/`) unmodified. If you had to change something to make the bench run
  on your machine (ports, platform), describe the change in `SUBMISSION.md`.

Questions about the environment: see `docs/TROUBLESHOOTING.md` first, then contact the recruiter.
