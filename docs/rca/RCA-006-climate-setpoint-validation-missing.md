# RCA-006: The API accepts any climate set point and forwards it to the vehicle

| Field | Value |
|---|---|
| Requirement(s) violated | **REQ-CLI-002** (values outside [16.0, 28.0] shall be rejected with HTTP 422 and no command shall be forwarded to the vehicle) |
| Severity | **S3 — degraded, with a latent safety edge.** Unvalidated user input reaches an actuator; only the ECU's own clamping prevents harm |
| Component suspected | **Backend** `CVB_API_1.8.3`, `POST /climate/start` request schema |
| Reproducibility | **Always** — 100 %, for every out-of-range value tested |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |
| Detected by | `Climate Set Points Outside The Allowed Range Are Rejected`, `A Rejected Climate Set Point Never Reaches The Vehicle` |
| Related | **RCA-004** — which then reports the unclamped value back to the user |

---

## 1. Observed behaviour

`POST /climate/start` accepts **any** `target_temp_c` with HTTP 200 and forwards it to the vehicle.
There is no range validation at all.

Every value tested was accepted:

| Requested | Expected | Actual |
|---|---|---|
| 15.5 °C | 422 | **200** |
| −5.0 °C | 422 | **200** |
| 28.5 °C | 422 | **200** |
| 35.0 °C | 422 | **200** |
| 100.0 °C | 422 | **200** |

Both clauses of REQ-CLI-002 are violated: the value is not rejected, **and** the command reaches the
vehicle. The requirement's second clause is the one with consequences.

The same boundary tests on `POST /charging/start` (`target_soc_percent` outside [50, 100]) return
**422 correctly**, which localises the fault to the climate endpoint alone rather than to a missing
validation layer.

## 2. Reproduction steps

```bash
KEY="X-API-Key: dev-key-001"; BASE=http://localhost:8800
for t in 15.5 -5.0 28.5 35.0 100.0; do
  printf '%8s -> HTTP %s\n' "$t" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$KEY" \
        -H 'Content-Type: application/json' -d "{\"target_temp_c\": $t}" $BASE/climate/start)"
done
#   15.5 -> HTTP 200 ... 100.0 -> HTTP 200      all should be 422

# and the vehicle received it:
adb -s localhost:5555 shell cat /data/misc/telematics/command_journal.jsonl | tail -2
```

Automated:

```bash
docker compose run --rm toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --suite input_validation robot/tests/02_api
```

## 3. Evidence

### 3.1 REST API

The suite tries every out-of-range value and reports them together rather than stopping at the first,
so the shape of the gap is visible in one run:

```
out-of-range climate set points accepted by the API:
target_temp_c=15.5 -> HTTP 200 (expected 422)
target_temp_c=-5.0 -> HTTP 200 (expected 422)
target_temp_c=28.5 -> HTTP 200 (expected 422)
target_temp_c=35.0 -> HTTP 200 (expected 422)
target_temp_c=100.0 -> HTTP 200 (expected 422)
```

Valid values (16.0, 22.5, 28.0, including both boundaries) are accepted correctly, so the endpoint is
not simply broken — it performs no range check whatsoever.

### 3.2 ADB — the command reached the vehicle and was executed

The status code alone does not establish the requirement's second clause, so the test reads the
vehicle's own journal over ADB. Requesting 35.0 °C:

```json
{"request_id": "bfbc4250-4c36-4c1c-81fc-f0b12fd10ea6", "command": "CLIMATE_START",
 "params": {"target_temp_c": 35.0}, "state": "QUEUED"}
{"request_id": "bfbc4250-4c36-4c1c-81fc-f0b12fd10ea6", "command": "CLIMATE_START",
 "params": {"target_temp_c": 35.0}, "state": "COMPLETED", "reason": "OK", "elapsed_ms": 82}
```

The vehicle did not merely receive the out-of-range command — it **executed it and reported
success**. This is the finding that matters: an unvalidated user-supplied value crossed the cloud
boundary, traversed the telematics link and reached the actuator.

### 3.3 DLT logs — how far the bad value travelled

The `S04_api_validation` scenario drives 16.0, 28.0 and 35.0 °C in sequence. The 35.0 request:

```
08:10:12.680035Z TCU1 TCU  HVAC DEBUG 0x00D3 temperature encoded temp_c=35.0 raw=70 quantize=floor_integer
08:10:12.723850Z BCM4 BODY HVAC WARN  0x005A target out of range, clamped req=e6af7996-... requested_raw=70 clamped_raw=56
08:10:12.758460Z BCM4 BODY HVAC INFO  0x005B SetClimate done req=e6af7996-... active=True target_raw=56
```

The chain is complete: the gateway encoded 35.0 °C into raw 70 without objection and transmitted it;
the **Body ECU** caught the violation and clamped to raw 56 (28.0 °C), logging a `WARN`.

**The last line of defence is the ECU.** Nothing in the cloud or the gateway rejected the value —
the only component that validated the range is the one furthest downstream, which is the wrong place
for it to be the sole check.

The ECU's `WARN` is also the *only* record that anything was wrong. It never reaches the customer:
the command is reported `COMPLETED`/`OK`, and — because of **RCA-004** — the API goes on reporting
`hvac_set=35.0` while the vehicle runs at 28.0 °C:

```
08:10:19.516Z STATUS doors_locked=True hvac=True hvac_set=35.0 chg=IDLE soc=42 seq=6
```

### 3.4 Network trace

`traces/pcap/scenarios/ci/S04_api_validation.pcap` contains the three `POST /climate/start` requests,
all answered `200`, and the corresponding `SetClimate` calls on the backbone carrying the
unvalidated values. The out-of-range request is on the in-vehicle network, not stopped at the cloud
boundary.

The same capture confirms the auth and 404 checks behave correctly (`401` and `404` as expected), so
the API's error handling is functional in general — the climate range check specifically is absent.

## 4. Analysis

1. `POST /climate/start` accepts any float for `target_temp_c` — *observed*, five out-of-range values
   all returning 200.
2. The backend forwards the value unchanged to the gateway — *observed*, the vehicle's journal
   records `params: {"target_temp_c": 35.0}`.
3. The gateway encodes and transmits it without a range check — *observed*, `temp_c=35.0 raw=70`.
4. The Body ECU clamps it to its legal maximum and warns — *observed*, `clamped_raw=56`.
5. The command is reported successful, and the cloud continues to display the requested value —
   *observed*, `COMPLETED`/`OK` and `hvac_set=35.0`.

**Proven:** all five steps, at three interfaces.

**Assessed — why this is more than cosmetic.** On this bench the outcome is benign because the ECU
clamps. But the defence in depth is inverted: validation is documented as an API responsibility
(REQ-CLI-002 places it there explicitly, *"rejected at the API … and no command shall be forwarded"*),
and it is being performed only by the actuator's own firmware. Any ECU variant, market calibration or
future component that trusts its input — reasonably, since the cloud is supposed to have validated
it — receives an arbitrary user-supplied value. The requirement exists to stop the value at the
boundary; on this build nothing does.

The narrow scope is itself evidence: `charging/start` validates its range correctly in the same API
version, so this is a specific gap in one endpoint's schema, not an architectural absence.

**Hypothesis, stated as such:** the backend exposes a compatibility switch for a legacy climate
request schema without range constraints, and the unconstrained variant appears to be the one
active on this build. I have not verified the deployed configuration beyond its observable
behaviour, and the defect stands on the observed responses regardless of the mechanism.

**Excluded by evidence:** gateway fault (it is not specified to validate, and forwards faithfully);
Body ECU fault (it validated correctly and warned — it is the only component that did); client fault
(the requests are well-formed JSON with a valid numeric field).

## 5. Root cause

The `POST /climate/start` request schema in backend `CVB_API_1.8.3` carries no range constraint on
`target_temp_c`, so FastAPI's validation layer never rejects an out-of-range value and the backend
forwards it to the vehicle. The equivalent constraint **is** present on `POST /charging/start`, which
validates correctly, so the gap is specific to the climate endpoint's schema.

## 6. Impact

| Area | Impact |
|---|---|
| **Defence in depth** | Unvalidated user input crosses the cloud boundary and the telematics link to an actuator. The only range check is in the ECU, the furthest component from the user. |
| **Requirement** | REQ-CLI-002 is violated in both clauses: no rejection, and the command is forwarded. |
| **Customer** | An out-of-range request is silently clamped; combined with RCA-004 the app reports 35 °C while the car runs at 28 °C. The customer is never told their request was altered. |
| **Latent risk** | A different ECU variant, or a future component that trusts the cloud to have validated, would act on the raw value. |
| **API contract** | `/openapi.json` does not advertise the documented 16.0–28.0 range for this endpoint, so client-side validation built from the schema will be equally permissive. |

**Not affected:** `charging/start`, which validates correctly; authentication and 404 handling.

## 7. Recommendation

### Fix

1. **Apply the documented range constraint to `target_temp_c`** (16.0–28.0) in the `/climate/start`
   request schema, matching the constraint already present on `target_soc_percent`. This also fixes
   the published OpenAPI document, so clients generated from it validate correctly too.
2. **If a legacy compatibility mode is deliberately in use**, confirm which configuration is deployed
   and ensure the unvalidated variant cannot be enabled in production. A compatibility switch that
   silently disables input validation should fail closed, not open.
3. **Add a range check at the gateway as well.** REQ-CLI-002 makes the API responsible, but a single
   point of validation between the internet and an actuator is thin. The gateway already decodes the
   value and is the last component that could reject it before the backbone.
4. **Surface the clamp.** The Body ECU's `WARN` should propagate to the command result rather than
   being reported as `COMPLETED`/`OK`, so a clamped request is visible to the user and to support.

### Regression tests that will catch it

| Test | Suite | Catches |
|---|---|---|
| `Climate Set Points Outside The Allowed Range Are Rejected` | `02_api/input_validation.robot` | the missing 422, reporting every offending value |
| `A Rejected Climate Set Point Never Reaches The Vehicle` | `02_api/input_validation.robot` | the second clause, from the vehicle's own journal |
| `Climate Set Points Inside The Allowed Range Are Accepted` | `02_api/input_validation.robot` | an over-correcting fix that rejects the valid boundaries |

The third exists to protect the fix: a schema that rejects 16.0 or 28.0 would satisfy the first two
tests and still be wrong.

### Verification steps after the fix

1. All five out-of-range values return **422**; 16.0, 22.5 and 28.0 still return 200.
2. The vehicle journal shows **no** `CLIMATE_START` record for a rejected request.
3. `/openapi.json` advertises the range for `target_temp_c`.
4. Re-run the `input_validation` suite; all tests shall pass.
