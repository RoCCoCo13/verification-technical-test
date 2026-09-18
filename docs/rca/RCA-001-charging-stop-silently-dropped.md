# RCA-001: Remote charging cannot be stopped — `CHARGING_STOP` is discarded by the gateway

| Field | Value |
|---|---|
| Requirement(s) violated | **REQ-CHG-002** (charging shall stop within 10 s), **REQ-API-003** (every accepted command shall reach a terminal state within 5 s), **REQ-ECU-002** (no command shall be dropped silently) |
| Severity | **S2 — function lost** (remote charging control is unavailable; the vehicle continues to charge against the user's explicit instruction) |
| Component suspected | **Gateway calibration** `TCU_GW2_CAL_P4.12.0` (primary) + **gateway application** `TCU_GW2_SW_4.12.0` (contributing) |
| Reproducibility | **Always** — 100 %, every `POST /charging/stop` observed across every run |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |
| Detected by | `Charging Stops On Command`, `The State Of Charge Stops Rising After A Stop Command`, `Every Accepted Command Reaches A Terminal State`, `The Gateway Never Discards A Command Without Reporting It`, `Every Charging Command Reaches The Body Ecu On The Backbone` |

---

## 1. Observed behaviour

A customer starts a charging session from the app and then stops it. The app reports the stop as
**still in progress, indefinitely**, and **the car keeps charging**.

Concretely:

- `POST /charging/stop` returns HTTP 200 with `status: ACCEPTED`, as designed.
- `GET /vehicle/commands/{request_id}` returns `ACCEPTED` **forever**. It never becomes `COMPLETED`
  or `FAILED`, so the app has nothing to display and no error to show.
- `GET /vehicle/status` continues to report `charging.state: CHARGING` and a rising `soc_percent`.
- The Body ECU continues to charge. Measured: **SOC rose from 44 % to 46 % in the 8 s following the
  stop command**, and the charger stays on until the target SOC is reached or the bench is reset.

The user is given no indication that anything went wrong. This is worse than a visible failure:
there is nothing to retry and nothing to report.

## 2. Reproduction steps

```bash
KEY="X-API-Key: dev-key-001"
BASE=http://localhost:8800          # 8000 on a default bench; see SUBMISSION.md

curl -s -X POST -H "$KEY" -H 'Content-Type: application/json' \
     -d '{"target_soc_percent": 80}' $BASE/charging/start
sleep 5
RID=$(curl -s -X POST -H "$KEY" $BASE/charging/stop | jq -r .request_id)
sleep 10
curl -s -H "$KEY" $BASE/vehicle/commands/$RID | jq '{status, reason, completed_at}'
#   { "status": "ACCEPTED", "reason": null, "completed_at": null }   <- never terminal
curl -s -H "$KEY" $BASE/vehicle/status | jq .charging
#   { "state": "CHARGING", "soc_percent": 47, ... }                 <- still charging
```

Automated equivalent:

```bash
docker compose run --rm toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --test "Charging Stops On Command" robot/tests/03_e2e/remote_charging.robot
```

Request id used throughout this analysis: **`557ffd01-8e40-42ba-a07a-54b070aa24e3`**
(2026-09-18T08:09:48Z), the `/charging/stop` issued by scenario `S03_charging_session`. A
`CHARGING_START` from the same scenario, `41f9f602-d3d4-4f63-95f2-ee4a914b27df`, is the control.

Both ids appear in the DLT logs **and** in `traces/pcap/scenarios/ci/S03_charging_session.pcap`, so
every section below describes the same two commands seen from a different interface.

## 3. Evidence

### 3.1 REST API

The command is accepted by the vehicle and then never resolves:

```json
{ "request_id": "557ffd01-8e40-42ba-a07a-54b070aa24e3", "command": "CHARGING_STOP",
  "status": "ACCEPTED", "reason": null, "completed_at": null, "elapsed_ms": null,
  "tcu_ack": { "result": "QUEUED", "queue_depth": 1, "tcu_sw": "TCU_GW2_SW_4.12.0" } }
```

Note `tcu_ack.result = "QUEUED"`: **the vehicle told the cloud it had accepted the command.** The
cloud's view is therefore not merely incomplete, it is actively misleading — it holds a positive
acknowledgement for work that was already discarded when the acknowledgement was sent.

The backend access log shows the scenario runner polling this id **24 times**, every one answered
`200` with `ACCEPTED`, until it gave up.

### 3.2 ADB — command journal and calibration

The vehicle's own journal records the command as **`DROPPED`**:

```bash
adb shell cat /data/misc/telematics/command_journal.jsonl | grep 557ffd01
```
```json
{"request_id": "557ffd01-...", "command": "CHARGING_STOP", "params": {}, "received_at": 1789718988.9951267, "state": "QUEUED"}
{"request_id": "557ffd01-...", "command": "CHARGING_STOP", "params": {}, "received_at": 1789718988.9951267, "state": "DROPPED"}
```

So the vehicle knows it discarded the command. The cloud was never told. That asymmetry is the
defect in REQ-ECU-002.

The calibration in use names the cause:

```bash
adb shell cat /vendor/etc/calibration/tcu_cal.json
```
```json
"calibration_id": "TCU_GW2_CAL_P4.12.0",
"command_map": {
    "LOCK": "door_lock",
    "UNLOCK": "door_unlock",
    "CLIMATE_START": "hvac_start",
    "CLIMATE_STOP": "hvac_stop",
    "CHARGING_START": "charge_start",
    "CHARGE_STOP": "charge_stop"          <-- key is CHARGE_STOP
}
```

Five of the six keys match the command names the backend emits. The sixth does not:
the backend sends **`CHARGING_STOP`**, the map is keyed **`CHARGE_STOP`**. The handler function
(`charge_stop`) exists and is reachable — only the key that would select it is misspelled.

That the backend's vocabulary is `CHARGING_STOP` is independently fixed by the API contract, not
by my assumption: `/openapi.json` declares the command enum, and `CLIMATE_START`/`CLIMATE_STOP`/
`CHARGING_START` all follow the same `<DOMAIN>_<VERB>` convention and all resolve correctly.

### 3.3 DLT logs — all three nodes, time ordered

Full excerpt: `evidence/RCA-001-correlated-trace.log`. The defective command:

```
08:09:48.950828Z CLD1 API  CMD  INFO  0x00A2 dispatching to vehicle req=557ffd01-... command=CHARGING_STOP tcu=http://ecu-gateway:8081
08:09:48.987082Z TCU1 TCU  CMD  INFO  0x00A4 remote command received req=557ffd01-... command=CHARGING_STOP params={}
08:09:48.996025Z TCU1 TCU  CMD  WARN  0x00A5 no handler for command, dropping req=557ffd01-... command=CHARGING_STOP known=CHARGE_STOP,CHARGING_START,CLIMATE_START,CLIMATE_STOP,LOCK,UNLOCK
08:09:48.998570Z CLD1 API  CMD  INFO  0x00A3 accepted by tcu req=557ffd01-... tcu_result=QUEUED queue_depth=1
                                    ... and nothing further, on any node, ever.
```

The gateway's own `WARN` prints the mismatch in one line: it was asked for `CHARGING_STOP`, and it
lists `CHARGE_STOP` among the keys it knows. **8.9 ms** elapse between reception and the drop.

Three absences are as important as what is present, and all are within the same window:

- **no `TCU1 GRPC` line** — the gateway never attempted a call to the Body ECU;
- **no `BCM4 BODY CHG` line** — the Body ECU never heard of the command;
- **no `TCU1 CLD ... result reported to backend` and no `CLD1 TLM command result`** — the cloud was
  never told the outcome, which is why the record stays `ACCEPTED`.

Compare the control (`CHARGING_START`, same scenario, 7.4 s earlier), where all four are present:

```
08:09:41.592023Z TCU1 TCU  CMD  INFO  0x0095 remote command received req=41f9f602-... command=CHARGING_START params={"target_soc_percent":60}
08:09:41.598138Z TCU1 TCU  GRPC INFO  0x0096 SetCharging -> req=41f9f602-... deadline_ms=1500 peer=body-ecu:50051
08:09:41.604071Z BCM4 BODY CHG  INFO  0x003E SetCharging received req=41f9f602-... action=CHARGING_START target_soc=60
08:09:41.661207Z BCM4 BODY CHG  INFO  0x003F SetCharging done req=41f9f602-... state=CHARGING soc=42
08:09:41.667164Z TCU1 TCU  GRPC INFO  0x0098 SetCharging <- req=41f9f602-... result=OK detail=charging started elapsed_ms=69
08:09:41.672625Z TCU1 TCU  CMD  INFO  0x0099 command finished req=41f9f602-... command=CHARGING_START result=COMPLETED reason=OK elapsed_ms=74
08:09:41.686067Z TCU1 TCU  CLD  DEBUG 0x009A result reported to backend req=41f9f602-... http=204
```

Two commands, the same domain, the same scenario, 7.4 s apart: one traverses the whole chain in
74 ms, the other stops dead at the gateway's dispatch table. This rules out the backbone, the Body
ECU, the network and any timing effect.

### 3.4 Network trace

Capture: `traces/pcap/scenarios/ci/S03_charging_session.pcap`, taken inside the gateway's network
namespace, so the cloud→gateway leg and the gateway→ECU backbone are in **one file at one vantage
point**.

The gateway embeds the backend `request_id` in the gRPC payload and sends it uncompressed
(`docs/NETWORK_TRACES.md`), so each command can be located on the wire **individually** rather than
by counting calls per method. That matters here: a namespace capture records everything the gateway
does, so a count would only be meaningful while the capture has the bench to itself, whereas a
per-id correlation holds regardless.

The control command is on the backbone:

```bash
tshark -r S03_charging_session.pcap -d tcp.port==50051,http2        -Y 'frame contains "41f9f602-d3d4-4f63-95f2-ee4a914b27df" and tcp.dstport==50051'        -T fields -e frame.number -e ip.src -e ip.dst
#   20   172.28.0.10   172.28.0.30        <- CHARGING_START reaches the Body ECU
```

The stop command is not:

```bash
tshark -r S03_charging_session.pcap -d tcp.port==50051,http2        -Y 'frame contains "557ffd01-8e40-42ba-a07a-54b070aa24e3" and tcp.dstport==50051'        -T fields -e frame.number -e ip.src -e ip.dst
#   (no output)                            <- CHARGING_STOP never reaches the backbone
```

The same id **is** present in the capture on ports 8000 and 8081, so the command demonstrably
travelled from the tester to the backend and from the backend to the gateway. It stops there. The
`SetCharging` for the stop is not late, not retried and not failed — it was never sent.

The identical measurement on the golden capture `traces/reference/S03_charging_session.pcap`,
recorded by the validation team on a bench they accepted, finds **every** charging command of that
scenario on the backbone. The expectation is therefore established by the reference, not assumed.

Automated as `Every Charging Command Reaches The Body Ecu On The Backbone` and its control
`The Reference Bench Forwards Every Charging Command`.

## 4. Analysis

The causal chain is complete and every link is observed:

1. The backend dispatches the command with `command: "CHARGING_STOP"` — *observed*, `CLD1 CMD` log
   and the HTTP body on the wire.
2. The gateway receives it and journals it `QUEUED`, answering `QUEUED` to the backend — *observed*,
   `TCU1 CMD` log, journal, and the HTTP 200 the backend records.
3. The gateway worker looks `CHARGING_STOP` up in `command_map` and finds nothing, because the
   calibration is keyed `CHARGE_STOP` — *observed*, the `WARN` line prints both the lookup key and
   the available keys.
4. Having no handler, the worker journals `DROPPED` and moves to the next queue item **without
   reporting any result to the cloud** — *observed*, journal state plus the absence of any
   `CLD`/`TLM` result line for this id.
5. The backend therefore holds the record at `ACCEPTED` indefinitely — *observed*, 28 polls, all
   `ACCEPTED`.
6. The Body ECU is never asked to stop, so the charger keeps running — *observed*, no `BCM4` line,
   no `SetCharging` on the wire, and the SOC continues to rise.

**Proven:** every step above, at two or more independent interfaces.

**Hypothesis (not required for the conclusion):** the key was introduced as a typo when remote
charging was added in this release — the release notes list "Remote charging control
(CHARGING_START / CHARGING_STOP) over telematics" as **new**, and `CHARGING_START`, added at the
same time, is spelled correctly. This is consistent with the evidence but is not needed to
establish the fault, and I have not seen the change history.

**Two separate faults are present**, and fixing only the first would leave the system unsafe:

- **The mapping is wrong.** This breaks charging stop specifically.
- **The gateway drops an unmappable command silently.** This is a design fault independent of the
  typo: *any* future command the calibration does not map — a new feature, a rollback to an older
  calibration, a market variant — will hang in the cloud in exactly the same way. REQ-ECU-002
  requires such a command to be reported `FAILED` with a reason. The gateway has the reason in hand
  (it logs it) and does not send it.

**Excluded by evidence:** Body ECU fault (never contacted, and it serves `CHARGING_START` correctly
in the same second); network fault (the whole exchange is in one capture, no retransmissions, and
the `POST /telematics/command` succeeds with HTTP 200); backend fault (it dispatches the documented
enum value and correctly holds a record awaiting a callback that never arrives); race or timing
(the drop is deterministic, 4.4 ms after reception, on 100 % of attempts).

## 5. Root cause

**Primary.** In gateway calibration `TCU_GW2_CAL_P4.12.0`, the `command_map` entry for stopping a
charging session is keyed **`CHARGE_STOP`** while the backend API contract emits **`CHARGING_STOP`**.
The lookup fails and the command is never dispatched to its (existing, correct) `charge_stop` handler.

**Contributing.** The gateway command worker treats an unmapped command as a discard: it journals
`DROPPED` and continues without invoking the result callback, so the cloud is never informed and the
command never reaches a terminal state. This violates REQ-ECU-002 independently of the mapping error
and would mask any future mapping defect in the same way.

## 6. Impact

| Area | Impact |
|---|---|
| **Function** | Remote charging stop is completely unavailable. The only ways to stop a session are reaching the target SOC or physically unplugging. |
| **Customer** | The app hangs on "in progress" with no error and no retry path. The customer believes they stopped charging and did not. |
| **Energy / cost** | The vehicle charges to its target regardless of the user's instruction — direct cost impact on tariff-based or shared charging, and it defeats any charge-scheduling feature built on this endpoint. |
| **Thermal / battery** | Unintended continued charging; the user cannot intervene remotely. |
| **Diagnosability** | A command stuck at `ACCEPTED` is indistinguishable at the API from a vehicle that is offline, so support will mis-triage this as a connectivity fault. |
| **Latent scope** | The contributing cause affects *all* commands, not just charging. Any unmapped command hangs the same way, silently. |
| **Data integrity** | `store.commands` accumulates records that never reach a terminal state — an unbounded set of permanently-pending commands. |

**Not affected:** `CHARGING_START` and the four other commands map correctly and complete normally;
the Body ECU charger model, the VHAL mirror and the backbone are all sound.

## 7. Recommendation

### Fix

1. **Primary** — correct the `command_map` key in `tcu_cal.json` from `CHARGE_STOP` to
   `CHARGING_STOP`. A calibration change; no application code needed.
2. **Contributing** — make the gateway worker report a terminal result when no handler is found:
   `FAILED` with a distinct reason (e.g. `UNSUPPORTED_COMMAND`), through the same
   `report_result()` path every other outcome uses. The command must not be able to leave the
   worker without the cloud learning its fate.
3. **Preventive** — validate the calibration against the API command enum at gateway start-up, and
   log `ERROR` (or refuse to start) if the two vocabularies disagree. The information needed to
   catch this at boot is already present on both sides; nothing today compares them.

### Regression tests that will catch it

All exist and are in CI today:

| Test | Suite | Catches |
|---|---|---|
| `Charging Stops On Command` | `03_e2e/remote_charging.robot` | the functional loss, at all three interfaces |
| `The State Of Charge Stops Rising After A Stop Command` | `03_e2e/remote_charging.robot` | the physical consequence |
| `Every Accepted Command Reaches A Terminal State` | `02_api/api_contract.robot` | the hung lifecycle, for **all six** commands |
| `The Gateway Never Discards A Command Without Reporting It` | `04_diagnostics/log_correlation.robot` | the contributing cause specifically |
| `Every Charging Command Reaches The Body Ecu On The Backbone` | `05_network/backbone_traces.robot` | the missing message on the wire |

The third and fourth are the ones that matter for recurrence: they are written against *any*
command, not against charging, so they would also catch a future mapping defect on a different
endpoint — including one introduced by a calibration rollback.

### Verification steps after the fix

1. Confirm the calibration over ADB: `adb shell cat /vendor/etc/calibration/tcu_cal.json` shows
   `"CHARGING_STOP": "charge_stop"`.
2. Run the five tests above; all shall pass.
3. Confirm on the wire that S03 now carries 2 `SetCharging` calls, matching `traces/reference/`.
4. Regression-check the contributing fix directly: inject an unknown command and confirm the cloud
   receives `FAILED` with a reason inside the REQ-API-003 budget, rather than a hang.
