# Test Strategy — Remote Vehicle Functions, release TCU_GW2_SW_4.12.0

| | |
|---|---|
| **Release under validation** | Gateway `TCU_GW2_SW_4.12.0` · Backend `CVB_API_1.8.3` · Body ECU `BCM4_SW_2.7.1` |
| **Calibrations** | `TCU_GW2_CAL_P4.12.0` (gateway) · `BCM4_CAL_P1.3.0` (Body ECU) |
| **Question to answer** | Can this release be released to vehicle testing? |
| **Author** | Ale Mendez |
| **Date** | 2026-09-18 |

---

## 1. Scope and objective

### In scope

The remote vehicle functions offered to the customer through the cloud API, validated end to end
from the cloud boundary to the physical actuator: **central locking**, **HVAC pre-conditioning**,
**remote charging**, plus the **gateway ↔ Body ECU integration**, **diagnosability** and **ADB
serviceability** that support them. The requirements in `docs/REQUIREMENTS.md` (REQ-API, REQ-LCK,
REQ-CLI, REQ-CHG, REQ-ECU, REQ-NET, REQ-LOG, REQ-ADB) are the acceptance basis.

The supplier's declared known issue **KI-217** is treated as a claim to be verified, not as an
accepted deviation.

### Out of scope

Performance and load beyond the latency budgets stated in the requirements; security beyond the
API-key authentication of REQ-API-001; TLS (the bench is plaintext by design); the real ADB
transport security model; HMI and mobile app behaviour; over-the-air update; any requirement
without an observable interface on this bench.

### Objective

Produce a **defensible release verdict** backed by automated, repeatable evidence, and for each
defect an analysis a supplier can neither dismiss as a test-harness artefact nor attribute to bench
noise.

---

## 2. System under test and observation points

```
  Tester/Robot ──REST :8000──► backend (CLD1) ──HTTP :8081──► ecu-gateway (TCU1) ──gRPC :50051──► body-ecu (BCM4)
       │                        172.28.0.20                    172.28.0.10                        172.28.0.30
       └──────────── adb :5555 ────────────────────────────────────┘
```

The decisive design choice of this strategy: **the interface used to stimulate the system is never
the only interface used to judge it.** Several defects on this build are invisible from the
interface that caused them and appear only when two views are placed side by side.

| Interface | Used as stimulus | Used as oracle | What it is authoritative for |
|---|---|---|---|
| REST API (`:8000`) | yes — every command originates here | partly | the **user's** view: command lifecycle, what the customer is told |
| Body ECU gRPC (`:50051`) | no — read only | **yes, primary** | the **physical truth**: what the car actually did (`docs/API_REFERENCE.md`) |
| ADB / VHAL mirror (`:5555`) | no | yes | the **ECU's** view: what the head unit displays; the command journal and calibration in use |
| DLT logs (3 nodes) | no | yes | causality and timing; `req=` correlation across nodes |
| PCAP (scenario captures) | no | yes | what was **actually transmitted**; missing messages, cancelled streams |

**Why three oracles and not one.** REQ-CLI-004 requires the backend and the Body ECU to agree. On
this build they do not, and the backend reports the value that makes it look correct. A suite that
trusted `/vehicle/status` would have reported the climate domain as fully compliant. The gRPC and
ADB oracles are what break that tie — and the PCAP is what makes the conclusion unarguable.

---

## 3. Risks and test focus

| # | Risk | Likelihood | Impact | Mitigation in this strategy |
|---|---|---|---|---|
| R1 | A command is accepted by the cloud but never executed on the car; the user believes it was | Medium | **High** — user leaves the car charging or unsecured | Command lifecycle asserted to a terminal state (REQ-API-003); command journal read over ADB; REST↔gRPC message accounting in one PCAP |
| R2 | The cloud reports a state the vehicle is not in | Medium | **High** — every downstream decision is wrong, including the tests | Every functional test asserts on all three views; a dedicated REQ-CLI-004 divergence test |
| R3 | An intermittent fault is dismissed as test flakiness | High | Medium — real defect shipped | Campaigns of N samples with a measured rate; no retry-until-green anywhere; wire-level confirmation of the mechanism |
| R4 | Integration timing (gRPC deadline vs actuator travel) too tight | Medium | **High** — state diverges from the reported outcome | 20-cycle campaign; RST_STREAM analysis against the golden capture |
| R5 | Validation gap at the API boundary lets an invalid value reach the vehicle | Medium | Medium | Boundary tests assert the status code **and** the absence of the command in the vehicle journal |
| R6 | A declared "known issue" hides a real defect | Medium | Medium | KI-217 measured over 60+ samples against the REQ-ECU-001 limit rather than accepted |
| R7 | Tests pass because the bench is in its default state | Medium | Medium | Vehicle driven into a non-default state before mirror/consistency comparisons |
| R8 | Assertions contaminated by an earlier run's log lines | High | Medium | All log queries scoped to a `since` mark taken at suite reset |

Risks R1, R2 and R4 materialised as defects on this release.

---

## 4. Test levels and techniques

| Level | Suite | Purpose | Technique |
|---|---|---|---|
| L0 Smoke | `01_smoke` | Entry criterion: every interface answers | Reachability, version pinning |
| L1 Contract | `02_api` | Cloud interface on its own terms | Auth matrix, schema, latency budget, boundary-value analysis |
| L2 End-to-end | `03_e2e` | Feature behaviour across all three views | Cross-interface state comparison, reliability campaign |
| L3 Diagnostics | `04_diagnostics` | Serviceability and integration health | Log correlation, statistical measurement, mirror consistency |
| L4 Network | `05_network` | Message-flow truth on the backbone | Protocol analysis, golden-trace differential |

**Techniques applied**

- **Boundary-value analysis** on both validated inputs, testing the rejecting side *and* the
  accepting side — a fix that over-corrects and rejects 16.0 °C must fail too.
- **Cross-interface differential.** The core technique. Ask the same question at three interfaces
  and treat disagreement as the defect.
- **Golden-trace differential.** Every network finding is measured identically on
  `traces/reference/`. A clean reference and a dirty build is a software difference, not a method
  difference. This turns "your capture is wrong" into an untenable reply.
- **Statistical measurement over retry.** For anything intermittent, collect a sample, compute a
  rate, assert on the rate once. See §6.
- **Negative-space assertion.** Proving a message is *absent* (no gRPC call, no journal record) is
  as important as proving one is present; it is how a silent drop becomes visible.

---

## 5. Traceability matrix

Every test carries `req:<REQ-id>` tags, so this matrix is regenerable from `results/output.xml`
rather than maintained by hand:

```bash
python tools/traceability.py results/output.xml
```

| Requirement | Test case(s) | Verdict |
|---|---|---|
| REQ-API-001 | Every Protected Endpoint Rejects A Request Without An Api Key; An Invalid Api Key Is Rejected | PASS |
| REQ-API-002 | Command Endpoints Answer Within The Latency Budget With A Well Formed Body | PASS |
| REQ-API-003 | Every Accepted Command Reaches A Terminal State | **FAIL** → RCA-001 |
| REQ-API-004 | An Unknown Request Id Returns Not Found | PASS |
| REQ-API-005 | Vehicle Status Carries The Full Documented Structure; Backend Reports A Vehicle | PASS |
| REQ-API-006 | Openapi Document Covers Every Public Endpoint | PASS |
| REQ-LCK-001 | Lock Command Locks The Doors On Every Interface | PASS |
| REQ-LCK-002 | Unlock Command Unlocks The Doors On Every Interface | PASS |
| REQ-LCK-003 | Twenty Lock Unlock Cycles Complete Without A Single Failure; A Failed Lock Command Leaves The Vehicle State Untouched | **FAIL** → RCA-002 |
| REQ-LCK-004 | Locking Does Not Disturb Climate Or Charging | **FAIL** → RCA-005 |
| REQ-CLI-001 | Preconditioning Starts At A Whole Degree Set Point; Preconditioning Honours A Half Degree Set Point | **FAIL** → RCA-003 |
| REQ-CLI-002 | Climate Set Points Outside/Inside The Allowed Range; A Rejected Climate Set Point Never Reaches The Vehicle | **FAIL** → RCA-006 |
| REQ-CLI-003 | Preconditioning Stops On Every Interface | PASS |
| REQ-CLI-004 | Cloud And Body Ecu Agree On The Set Point Once Converged | **FAIL** → RCA-004 |
| REQ-CHG-001 | Charging Starts And The State Of Charge Rises | PASS |
| REQ-CHG-002 | Charging Stops On Command; The State Of Charge Stops Rising After A Stop Command | **FAIL** → RCA-001 |
| REQ-CHG-003 | Charging Targets Outside/Inside The Allowed Range Are Rejected/Accepted | PASS |
| REQ-CHG-004 | Charging Completes When The Target Is Reached | PASS |
| REQ-ECU-001 | Heartbeat Latency Warnings Stay Within The Accepted Rate; Heartbeats Are Issued On The Specified Period; The Body Ecu Is Supervised As Online; The Declared Known Issue Is Still Declared; The Gateway Supervises The Body Ecu On The Backbone | PASS — see `docs/KI-217-VERIFICATION.md` |
| REQ-ECU-002 | The Gateway Never Discards A Command Without Reporting It; Every Forwarded Command Produces Exactly One Grpc Call; Every Charging Command Reaches The Body Ecu On The Backbone | **FAIL** → RCA-001 |
| REQ-NET-001 | No Door Lock Stream Is Cancelled By The Gateway; The Reference Bench Shows No Cancelled Door Lock Streams | **FAIL** → RCA-002 |
| REQ-LOG-001 | A Remote Command Is Traceable Across All Three Nodes; A Remote Command Is Visible In Logcat On The Gateway | PASS |
| REQ-LOG-002 | Nominal Flows Produce No Errors In The Gateway Log | **FAIL** → RCA-002 |
| REQ-ADB-001 | Gateway Answers Over Adb; Gateway Runs The Release Under Test | PASS |
| REQ-ADB-002 | The Vhal Mirror Matches The Body Ecu In A Non Default State; The Vhal Mirror Follows A Door Lock Change; Dumpsys Vehicle Agrees With The Vhal Property File | PASS |

**Coverage: 25 of 25 requirements have at least one automated test.** No requirement is marked
"verified by inspection".

---

## 6. Environment, data and repeatability

### Execution environment

The suite runs **inside the bench's `toolbox` container**, which already carries `adb`, `tshark`,
Robot Framework 7.1 and `grpcio`, and sits on the vehicle network. Consequences that matter:

- no tool installation on the workstation, and CI executes the identical image;
- nodes are addressed by Compose service name, so the suite is immune to host port allocation.
  This workstation publishes the backend on **8800** because another service owns 8000, and that
  fact never enters the suite (see `SUBMISSION.md`);
- gRPC stubs are generated from `env/proto/vehicle_ecu.proto` at run time and never committed, so
  the suite cannot drift from the contract the bench ships.

### Known state

`Suite Setup` calls `POST /bench/reset`, which returns backend records and the Body ECU to factory
state, then waits for a **fresh** state report before any assertion. Suites are order-independent
and re-runnable on a dirty bench.

### Timing constants — all justified, none guessed

| Constant | Value | Source |
|---|---|---|
| Command terminal state | 5 s | REQ-API-003 |
| Vehicle convergence | 10 s | REQ-LCK-001, REQ-CLI-001, REQ-CHG-001 |
| VHAL mirror convergence | 10 s | REQ-ADB-002 |
| State poll period | 5 s | `tcu_cal.json` `state_poll_period_s` |
| Heartbeat period | 2 s | `tcu_cal.json` `heartbeat_period_s` |
| SOC step | 3 s | `body_cal.json` `charging_soc_step_period_s` |

`Wait Until Keyword Succeeds` is used **only** where the underlying value is monotonic for a single
command — `ACCEPTED` → terminal, or a state converging after a command. It is never wrapped around
a value that could legitimately go either way, because that would convert an intermittent defect
into a green test.

### Distinguishing test flakiness from product intermittency

This is the sharpest methodological question on this bench, and it is answered structurally rather
than by judgement:

1. **Measure, then assert.** The lock campaign runs all 20 cycles and asserts on the resulting
   failure count. It reports *12 of 40 commands failed (30 %), reason `ECU_TIMEOUT`* — a rate, with
   a single distinct cause.
2. **Confirm the mechanism independently.** A rate alone could still be the harness. The PCAP shows
   the gateway sending `RST_STREAM` at **602 ms** every time, against a calibrated deadline of
   600 ms. A test harness cannot produce that signature.
3. **Establish the baseline.** The identical measurement on the golden capture returns zero.
4. **Report inconclusive as inconclusive.** The REQ-LCK-003 second-clause test *skips* rather than
   passes if no failure occurs in its sample, because a clean sample proves nothing about what a
   failed command does.

The heartbeat test is the same discipline pointed at a *claim*: 60+ samples, a computed rate, and
the number reported whichever way it lands.

---

## 7. Entry and exit criteria, and the release verdict

**Entry criteria** — all met: bench starts with `docker compose up -d --wait`; `01_smoke` green;
the release under test confirmed over ADB (`ro.oem.tcu.sw_version = TCU_GW2_SW_4.12.0`).

**Exit criteria for release**

| # | Criterion | Status |
|---|---|---|
| E1 | Every requirement has at least one automated test | **Met** (25/25) |
| E2 | No open defect of severity S1 or S2 | **Not met** — two S2 |
| E3 | No open defect affecting a safety- or security-relevant function | **Not met** — RCA-002 |
| E4 | All S3 defects accepted in writing by the programme | Not assessed — programme decision |
| E5 | Suite runs unattended in CI and publishes its artefacts | **Met** |

### Verdict: **DO NOT RELEASE** to vehicle testing

Three findings independently justify this, and all three are reproducible and evidenced at four
interfaces:

1. **RCA-001 — remote charging cannot be stopped (S2).** `POST /charging/stop` is discarded inside
   the gateway. The command never reaches a terminal state, so the app shows it as pending forever,
   and the vehicle keeps charging. Measured: SOC continued 44 % → 46 % over the 8 s after the stop.
   A charging session the customer cannot stop is a functional loss with thermal and energy-billing
   consequences.
2. **RCA-002 — central locking reports failures it did not have, and moves the doors anyway (S2).**
   30 % of lock/unlock commands return `FAILED`/`ECU_TIMEOUT` while the doors actuate regardless.
   The customer is told the car did not lock when it did, or that it did not unlock when it did.
   **This one is security-relevant**: the cloud's belief about whether the vehicle is secured is
   wrong 30 % of the time.
3. **RCA-004 — the cloud reports the user's request as if it were vehicle state (S3, but
   aggravating).** This is what allowed RCA-003 to remain invisible from the API, and it means the
   backend cannot be trusted as an oracle for the climate domain in the field either.

**Recommended gate for re-submission:** fixes for RCA-001 and RCA-002, a re-run of the full suite,
and specifically green results on `Every Accepted Command Reaches A Terminal State`, `Twenty Lock
Unlock Cycles Complete Without A Single Failure`, `A Failed Lock Command Leaves The Vehicle State
Untouched` and `No Door Lock Stream Is Cancelled By The Gateway`.

**Not a defect:** KI-217 is confirmed as declared. Measured at **6.56 % of heartbeats above
100 ms over 61 samples**, against the 10 % REQ-ECU-001 permits. The supplier's assessment is
supported by evidence — see `docs/KI-217-VERIFICATION.md`. It is retained as a watch item because
the margin to the limit is only 3.4 points.

---

## 8. CI/CD

`.github/workflows/validation.yml` runs on every push and pull request, with no manual step and no
self-hosted runner:

1. build and start the bench (`docker compose up -d --build --wait`);
2. wait for the first vehicle state report — the health checks prove the HTTP endpoints are up, not
   that the vehicle is reporting;
3. capture the four end-to-end scenarios (`scenario-runner`, label `ci`);
4. run the full suite in the `toolbox` container;
5. **always** upload `report.html`, `log.html`, `output.xml`, `xunit.xml`, the three `.dlt` logs and
   the scenario PCAPs — the artefacts an RCA quotes;
6. tear the bench down.

The pipeline is **red on this release, and that is the correct result**: the suite detects open
defects. `docs/DELIVERABLES.md` states this explicitly. The step summary says so on every run, so a
red badge is never mistaken for a broken pipeline.

---

## 9. Use of AI assistance

Claude (Opus 5) was used throughout, as the assessment invites. Specifically: drafting the Robot
resource and library scaffolding, `tshark` field syntax for HTTP/2 frame filtering, and the prose of
these documents.

What was **not** delegated: every defect in this strategy was found by running the suite against the
bench and reading the output, not by reading `env/`. The sources were consulted only *after* a
symptom was observed, to name the parameter behind it — the order matters and is visible in the
commit history. Every number quoted here comes from an executed run whose artefacts are in
`results/`. Two AI-introduced defects were caught by running the suite and are fixed in the
history: Robot `Log` arguments separated by accidental double spaces, and a `Should Be Empty`
message whose inline expression broke the parser. The AI-generated first drafts of the RST_STREAM
analysis also over-counted cancellations by attributing the Body ECU's answering reset to the
gateway; that was corrected after reading the frames.

See `SUBMISSION.md` for the full note.
