# RCA-002: Central locking reports failures it did not have — and moves the doors anyway

| Field | Value |
|---|---|
| Requirement(s) violated | **REQ-LCK-003** (0 failures over 20 cycles; a `FAILED` command shall not have changed the state), **REQ-NET-001** (no `SetDoorLock` stream cancelled by the gateway), **REQ-LOG-002** (no `ERROR` in a nominal flow) |
| Severity | **S2 — function degraded, security-relevant.** The cloud's belief about whether the vehicle is locked is wrong on 27–43 % of commands, depending on the sample |
| Component suspected | **Gateway calibration** `TCU_GW2_CAL_P4.12.0`, parameter `door_lock_ack_timeout_ms` |
| Reproducibility | **Intermittent, high rate** — 17 of 40 commands (42.5 %) in the delivered 20-cycle campaign; 30 % and 27.5 % in two earlier runs; deterministic in mechanism |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |
| Detected by | `Twenty Lock Unlock Cycles Complete Without A Single Failure`, `A Failed Lock Command Leaves The Vehicle State Untouched`, `No Door Lock Stream Is Cancelled By The Gateway`, `Nominal Flows Produce No Errors In The Gateway Log` |

---

## 1. Observed behaviour

Roughly a third of lock and unlock commands are reported to the customer as **`FAILED`** with reason
`ECU_TIMEOUT` — **while the doors actually actuate**.

The user experience is the dangerous part. The app says *"could not lock your car"*; the car is
locked. Or the app says *"could not unlock"*; the car is now unlocked and standing open to whoever
is next to it. In both directions, the state the cloud believes and the state of the vehicle are
opposite, and the customer acts on the wrong one.

Measured over a 20-cycle campaign (40 commands): **17 `FAILED`, all with reason `ECU_TIMEOUT`,
a 42.5 % failure rate**, against a requirement of **zero**. Three independent campaigns gave
42.5 %, 30 % and 27.5 % — the rate varies with the sample, the mechanism does not.

## 2. Reproduction steps

```bash
docker compose run --rm toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --test "Twenty Lock Unlock Cycles Complete Without A Single Failure" \
  robot/tests/03_e2e/central_locking.robot
```

Or by hand — repeat 5–10 times, roughly a third will fail:

```bash
KEY="X-API-Key: dev-key-001"; BASE=http://localhost:8800
RID=$(curl -s -X POST -H "$KEY" $BASE/vehicle/lock | jq -r .request_id)
sleep 3
curl -s -H "$KEY" $BASE/vehicle/commands/$RID | jq '{status, reason, elapsed_ms}'
#  { "status": "FAILED", "reason": "ECU_TIMEOUT", "elapsed_ms": 607 }
curl -s -H "$KEY" $BASE/vehicle/status | jq .doors
#  { "locked": true }        <- the "failed" command locked the car
```

Note `elapsed_ms` clustering just above **600**. That number is the whole case.

## 3. Evidence

### 3.1 REST API — the rate, and the contradiction

The 20-cycle campaign returns a single distinct failure reason:

```
17 of 40 lock/unlock commands failed (42.5 %), reasons ['ECU_TIMEOUT']; REQ-LCK-003 allows 0
```

One reason, not a scatter, which already argues for one mechanism rather than bench noise.

The second clause of REQ-LCK-003 is violated in the same campaign. The test captures the Body ECU
door state immediately before a command, waits for the actuator to settle, and reads it again:

```
command fd132d0d-25b9-4155-be20-e8caca9eacb4 was reported FAILED (ECU_TIMEOUT)
but the Body ECU door state changed from True to False
```

**The command the customer was told had failed is the command that unlocked the car.**

### 3.2 ADB — the calibrated deadline against the actuator specification

```bash
adb shell cat /vendor/etc/calibration/tcu_cal.json
```
```json
"calibration_id": "TCU_GW2_CAL_P4.12.0",
"door_lock_ack_timeout_ms": 600,          <-- gRPC deadline for SetDoorLock
"hvac_ack_timeout_ms": 1500,
"charging_ack_timeout_ms": 1500
```

The gateway allows the Body ECU **600 ms** to acknowledge a door actuation. REQ-LCK-003 states
plainly: *"Body ECU door actuation takes up to 1 s"*. The deadline is set below the actuation time
the requirement itself specifies.

The Body ECU announces its actuation time on every command, so the spread is measurable without
any access to the ECU's internals:

```bash
grep -o "actuation_ms=[0-9]*" traces/logs/body_ecu.dlt | cut -d= -f2 | sort -n
#   n=11  min=270  mean=442  max=749
```

Observed actuation times span **270–749 ms**, straddling the 600 ms deadline. Every actuation above
600 ms produces a `FAILED` command, so the failure rate is simply the fraction of the actuation
distribution lying above the deadline — which is why the measured rate stays in the same band
(27.5–42.5 % across three campaigns) rather than being erratic. The rate is a direct consequence of the calibrated value, and
it will change with that value alone.

Note the other two domains are calibrated at 1500 ms and neither shows this failure mode, which
isolates the fault to this one parameter rather than to gRPC or to the backbone.

### 3.3 DLT logs

The complete chain for one `FAILED` unlock, `req=13e161f6-2b2f-474e-ad43-0445cc484bea`, merged
across the gateway and the Body ECU in time order (full excerpt:
`evidence/RCA-002-failed-unlock-chain.log`):

```
08:09:01.332890Z TCU1 TCU  GRPC INFO  0x000B SetDoorLock -> req=13e161f6-... deadline_ms=600 peer=body-ecu:50051
08:09:01.345192Z BCM4 BODY LOCK INFO  0x0007 SetDoorLock received req=13e161f6-... action=UNLOCK actuation_ms=749
08:09:01.946997Z BCM4 BODY LOCK WARN  0x0008 requester cancelled the stream, actuation continues req=13e161f6-... action=UNLOCK
08:09:01.952923Z TCU1 TCU  GRPC ERROR 0x000C SetDoorLock failed req=13e161f6-... grpc_code=DEADLINE_EXCEEDED elapsed_ms=620 detail=Deadline Exceeded
08:09:01.970136Z TCU1 TCU  CMD  ERROR 0x000D command finished req=13e161f6-... command=UNLOCK result=FAILED reason=ECU_TIMEOUT elapsed_ms=637
08:09:01.998350Z TCU1 TCU  CLD  DEBUG 0x000E result reported to backend req=13e161f6-... http=204
08:09:02.106467Z BCM4 BODY LOCK INFO  0x000A SetDoorLock done req=13e161f6-... doors_locked=False elapsed_ms=761
```

This is the entire defect in seven lines, and the order is what matters:

- the ECU announces up front that this actuation will take **749 ms**, against a **600 ms** deadline;
- at **+620 ms** the gateway gives up and the ECU logs that it was cancelled but is continuing;
- at **+637 ms** the customer is told the unlock **FAILED**, and the cloud is updated to say so;
- at **+761 ms** — *after* the failure was reported — the doors finish unlocking (`doors_locked=False`).

The car was unlocked 124 ms after the cloud recorded that it had not been.

These `ERROR` entries also violate **REQ-LOG-002** independently — a nominal lock flow, with no
provocation, produces two `ERROR`-level entries in the gateway log:

```
gateway logged 12 ERROR entries during a nominal flow:
2026-09-18T08:40:08.282387Z TCU1 TCU  GRPC ERROR 0x137E SetDoorLock failed req=a861b905-... grpc_code=DEADLINE_EXCEEDED elapsed_ms=621 detail=Deadline Exceeded
2026-09-18T08:40:08.296114Z TCU1 TCU  CMD  ERROR 0x137F command finished req=a861b905-... command=UNLOCK result=FAILED reason=ECU_TIMEOUT ...
(10 further ERROR lines of the same two kinds)
```

Twelve `ERROR` entries across five passes of the documented happy paths, with no fault injected of
any kind.

### 3.4 Network trace — the decisive evidence

Capture: `traces/pcap/scenarios/ci/S01_lock_unlock_cycles.pcap`.

```bash
tshark -r S01_lock_unlock_cycles.pcap -d tcp.port==50051,http2 -Y "http2.type==3" \
       -T fields -e frame.number -e frame.time_relative -e ip.src -e http2.streamid
```

Correlating each `RST_STREAM` back to the call that opened the stream:

```
the gateway cancelled 2 of 10 SetDoorLock streams with RST_STREAM:
  SetDoorLock stream 11: opened frame   26 at t= 0.539s, RST_STREAM from 172.28.0.10 frame   77 at t= 1.149s, 609.6 ms after the request
  SetDoorLock stream 61: opened frame 1154 at t=11.041s, RST_STREAM from 172.28.0.10 frame 1201 at t=11.644s, 602.9 ms after the request
```

An earlier capture of the same scenario showed 5 of 10, every one in the same narrow band:

```
  602.2 ms · 602.4 ms · 602.2 ms · 602.6 ms · 602.6 ms
```

**Every cancellation occurs 602–610 ms after the request, against a calibrated deadline of 600 ms.**
The reset always comes from `172.28.0.10`, the gateway. This is not a distribution that a flaky test
or a noisy bench can produce: it is a fixed timer firing.

The same measurement on the golden capture `traces/reference/S01_lock_unlock_cycles.pcap`, recorded
by the validation team on an accepted bench with the same scenario at the same vantage point,
returns **zero cancelled streams**. The difference is in the software under test, not in the method
of measurement.

## 4. Analysis

Causal chain, every link observed at two or more interfaces:

1. The gateway issues `SetDoorLock` with a deadline of 600 ms taken from
   `door_lock_ack_timeout_ms` — *observed*, `GRPC` log line prints `deadline_ms=600`, and the
   calibration is readable over ADB.
2. The Body ECU begins actuating; travel time is drawn from the 250–800 ms range — *observed*,
   `BCM4 LOCK` log prints `actuation_ms` per command.
3. Whenever travel exceeds 600 ms the deadline fires. The gateway sends `RST_STREAM` and reports
   `DEADLINE_EXCEEDED` — *observed*, at 602–610 ms in the capture and in the gateway log.
4. The gateway maps this to `FAILED`/`ECU_TIMEOUT` and reports it to the cloud — *observed*,
   `CMD ERROR` line and the REST command record.
5. **The Body ECU completes the actuation regardless**, because a physical actuator cannot be
   recalled once the relay is driven — *observed*, `requester cancelled the stream, actuation
   continues`, and the door state changes.
6. Cloud and vehicle now disagree — *observed*, `FAILED` command record against a changed
   `doors_locked`.

**Proven:** every step, at the API, over ADB, in two logs and on the wire.

**Assessed, not assumed — which component is at fault.** The Body ECU's behaviour in step 5 is
*correct*: shielding an actuation against client cancellation is what a real actuator does, and
aborting a half-travelled door latch would be worse. The defect is not that the ECU finishes the
job; it is that the gateway stops waiting before the specified worst case. The requirement agrees:
REQ-NET-001 says deadlines *"shall accommodate the Body ECU actuation times"*, placing the
obligation on the gateway.

**Excluded by evidence:** Body ECU fault (it completes every actuation successfully and logs it);
network fault (same capture shows healthy HTTP/2, no retransmission, and the ECU's response
arriving); test-harness flakiness (the 602 ms clustering, the golden-trace control, and the fact
that the failure is visible in the supplier's *own* logs); load or contention (`hvac` and `charging`
calls share the same channel at 1500 ms and never time out).

## 5. Root cause

In gateway calibration `TCU_GW2_CAL_P4.12.0`, `door_lock_ack_timeout_ms` is set to **600 ms**, below
the Body ECU's specified worst-case door actuation time of **1 s** (REQ-LCK-003) and below its
observed range of 250–800 ms. Any actuation longer than 600 ms is cancelled by the gateway and
reported to the cloud as `FAILED`/`ECU_TIMEOUT`, while the Body ECU — correctly — completes the
actuation, leaving the cloud's view of the vehicle contradicting the vehicle.

## 6. Impact

| Area | Impact |
|---|---|
| **Security** | The cloud's record of whether the vehicle is locked is wrong on roughly a third of commands (27–43 % measured). A user told "unlock failed" walks away from an unlocked car. This is the most serious consequence. |
| **Customer** | ~1 in 3 lock/unlock operations reports a failure that did not happen. Users will retry, doubling the actuations and the chance of leaving the car in the state they did not intend. |
| **Function** | The doors do actuate, so the physical function works — which makes the defect harder to notice in manual testing and easier to dismiss as "the app being slow". |
| **Fleet / telematics** | Any downstream system consuming command outcomes (service history, insurance telematics, fleet dashboards, "is my car locked" widgets) receives a false-failure rate of roughly a third. |
| **Diagnosability** | Nominal operation floods the gateway log with `ERROR` entries (REQ-LOG-002), so real errors are buried in expected ones. |
| **Retry logic** | Any automatic retry built on this outcome will actuate the doors a second time, potentially reversing the user's intent. |

**Not affected:** climate and charging, whose deadlines are 1500 ms.

## 7. Recommendation

### Fix

1. **Raise `door_lock_ack_timeout_ms` above the specified worst case.** REQ-LCK-003 specifies up to
   1 s of actuation; a deadline of **1500 ms** matches the other two domains and leaves margin for
   transport. A calibration change; no application code needed.
2. **Derive the deadline from the actuator specification rather than setting it independently.** The
   two values live in different calibration files owned by different suppliers, with nothing
   enforcing the relationship. Ask the gateway supplier to document the dependency and, ideally, to
   check it at start-up.
3. **Review the semantics of a timeout on a physical actuation.** Even with a correct deadline, a
   timeout still means "unknown", not "failed" — the actuator may have completed. Reporting
   `ECU_TIMEOUT` as `FAILED` asserts something the gateway cannot know. It should either resolve the
   real state with `GetBodyState` before reporting, or report an indeterminate outcome. **Without
   this change, the same cloud/vehicle divergence returns whenever a deadline is exceeded for any
   other reason.**

### Regression tests that will catch it

| Test | Suite | Catches |
|---|---|---|
| `Twenty Lock Unlock Cycles Complete Without A Single Failure` | `03_e2e/central_locking.robot` | the failure rate, measured over a real campaign |
| `A Failed Lock Command Leaves The Vehicle State Untouched` | `03_e2e/central_locking.robot` | the cloud/vehicle divergence — the dangerous clause |
| `No Door Lock Stream Is Cancelled By The Gateway` | `05_network/backbone_traces.robot` | the mechanism on the wire, with the timing |
| `Nominal Flows Produce No Errors In The Gateway Log` | `04_diagnostics/log_correlation.robot` | the log pollution |

The second is the one to keep if only one survives: it is the only test that checks the *consistency*
between the reported outcome and the physical state, and it is therefore the only one that would
still fail if recommendation 1 were applied without recommendation 3.

### Verification steps after the fix

1. `adb shell cat /vendor/etc/calibration/tcu_cal.json` shows the raised deadline.
2. Run the 20-cycle campaign: **0 of 40** commands `FAILED`.
3. Re-capture S01 and confirm **zero** gateway-originated `RST_STREAM` on `SetDoorLock`, matching
   `traces/reference/`.
4. Confirm the gateway log is free of `ERROR` entries during a nominal flow.
5. For recommendation 3, verify by injecting an artificial delay above the new deadline and
   confirming the cloud's final view matches the Body ECU's actual door state.
