# RCA-004: The cloud reports the user's request as if it were vehicle state

| Field | Value |
|---|---|
| Requirement(s) violated | **REQ-CLI-004** (the set point and active state shown by the backend shall equal the Body ECU values once converged) |
| Severity | **S3 — degraded, but aggravating.** It conceals other defects, including RCA-003, and defeats the API as a diagnostic oracle |
| Component suspected | **Backend** `CVB_API_1.8.3`, `GET /vehicle/status` |
| Reproducibility | **Always**, whenever the vehicle's set point differs from the requested one |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |
| Detected by | `Cloud And Body Ecu Agree On The Set Point Once Converged` |
| Related | **RCA-003** — the divergence this defect hides; **RCA-006** — made worse by it |

---

## 1. Observed behaviour

`GET /vehicle/status` reports `climate.target_temp_c` as **the value the user asked for**, not the
value the vehicle is running at. When the two differ, the API reports the request and the difference
is invisible to every consumer of the API.

Requesting 22.5 °C: the API says `22.5`; the vehicle holds `22.0`. Requesting 35 °C (which the API
wrongly accepts — RCA-006): the API says `35.0`; the vehicle clamped to `28.0`.

This is reported separately from RCA-003 because it is a **different component with a different
fix**, and because its consequences are broader: it would conceal *any* climate divergence, not only
the quantisation one. A vehicle that clamps, rejects, degrades or simply fails to apply a set point
will still be reported by the cloud as running at the requested value.

## 2. Reproduction steps

```bash
KEY="X-API-Key: dev-key-001"; BASE=http://localhost:8800
curl -s -X POST -H "$KEY" -H 'Content-Type: application/json' \
     -d '{"target_temp_c": 22.5}' $BASE/climate/start
sleep 12    # well beyond the 10 s REQ-CLI-004 allows for convergence

curl -s -H "$KEY" $BASE/vehicle/status | jq .climate.target_temp_c
#   22.5                                    <- the cloud
grpcurl -plaintext -proto env/proto/vehicle_ecu.proto localhost:50051 \
        vehicle.body.v1.BodyControl/GetBodyState | jq .climate.targetTempRaw
#   44                                      <- the vehicle: 22.0 degC
```

Automated:

```bash
docker compose run --rm toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --test "Cloud And Body Ecu Agree On The Set Point Once Converged" \
  robot/tests/03_e2e/climate_preconditioning.robot
```

## 3. Evidence

### 3.1 REST API against the vehicle, after convergence

The test waits the full 10 s REQ-CLI-004 grants, then compares the three views side by side:

```
backend and Body ECU disagree after convergence:
set point: backend says 22.5 degC, Body ECU holds 22.0 degC (raw 44)
```

The disagreement is stable, not a transient: it persists indefinitely, through any number of state
reports.

### 3.2 The divergence is not a reporting lag

The gateway's state report to the cloud carries the **correct** value. The gateway's VHAL mirror,
read over ADB, matches the Body ECU exactly:

```bash
adb shell cat /data/vendor/vhal/props.json | jq .HVAC_TEMPERATURE_SET
#   22.0          <- the gateway knows the true value
```

and `The Vhal Mirror Matches The Body Ecu In A Non Default State` passes, confirming the gateway's
whole sync path is sound. So the true value **is** transmitted to the cloud on every state report;
the backend receives 22.0 and chooses to display 22.5.

This rules out the gateway, the backbone and any propagation delay. The substitution happens in the
backend, at the moment the status is rendered.

### 3.3 The substitution is visible in the S04 scenario

`S04_api_validation` requests 16.0, 28.0 and then 35.0 °C. The Body ECU clamps the last one:

```
08:10:12.680035Z TCU1 TCU  HVAC DEBUG 0x00D3 temperature encoded temp_c=35.0 raw=70 quantize=floor_integer
08:10:12.723850Z BCM4 BODY HVAC WARN  0x005A target out of range, clamped req=e6af7996-... requested_raw=70 clamped_raw=56
08:10:12.758460Z BCM4 BODY HVAC INFO  0x005B SetClimate done req=e6af7996-... active=True target_raw=56
```

The vehicle is running at raw 56 = **28.0 °C**, and it said so loudly, at `WARN` level. The scenario's
own status poll 7 s later records what the cloud reported:

```
08:10:19.516Z STATUS doors_locked=True hvac=True hvac_set=35.0 chg=IDLE soc=42 seq=6
```

**The cloud reports 35.0 °C while the vehicle runs at 28.0 °C and has logged a range violation.**
A 7 °C discrepancy, invisible at the API. This is the clearest demonstration that the API is
reporting intent rather than state.

### 3.4 The behaviour is deliberate, and documented as such

The backend source documents the design decision in a comment at the point of substitution:

> *"The set point shown to the user is the one the user asked for (source of truth = user intent),
> the vehicle only confirms whether HVAC is running."*

This matters for how the finding should be handled: it is **not an oversight, it is a design choice
that contradicts a requirement**. REQ-CLI-004 states the backend value *shall equal* the Body ECU
value once converged. The supplier will likely defend this as intended behaviour, so the RCA must
argue the requirement, not the code — which is what §4 does.

I cite the comment here only to establish intent. The defect itself is established entirely from the
observed values in §3.1–§3.3.

## 4. Analysis

1. The gateway reports the vehicle's true set point to the cloud on every state report — *observed*,
   VHAL mirror matches the ECU and the mirror is the source of the report.
2. `GET /vehicle/status` returns the user's last requested value instead, whenever pre-conditioning
   is active — *observed*, 22.5 vs 22.0, and 35.0 vs 28.0.
3. Consumers of the API therefore cannot detect any divergence between request and reality —
   *observed*, RCA-003 is completely invisible from the REST interface.

**Proven:** all three, from interface observations alone.

**The argument against "working as intended".** Three points, in order of strength:

1. **REQ-CLI-004 is explicit and unconditional**: *"The set point and active state shown by the
   backend shall equal the Body ECU values at all times once the state has converged (10 s)."* There
   is no exception for user intent. The requirement exists precisely to prevent this.
2. **It makes the product undiagnosable.** The API is the only interface a customer, a call centre
   or a fleet operator has. A field engineer cannot reach the gRPC backbone. If the cloud always
   echoes the request, no remote diagnosis of a climate fault is possible at all.
3. **It is inconsistent within the same response.** `climate.active` and `charging.*` *are* reported
   from the vehicle; only `target_temp_c` is substituted. A client has no way to know which fields of
   the object mean "requested" and which mean "actual". If user intent genuinely needs to be shown,
   it belongs in a separate field (`requested_temp_c`) alongside the reported one — which would
   satisfy both the UX goal and the requirement.

**Excluded by evidence:** gateway fault (mirror is correct and matches the ECU); propagation delay
(persists far beyond the 10 s budget, across many reports); Body ECU fault (it holds and reports its
value correctly, and logs the clamp).

## 5. Root cause

The backend's `GET /vehicle/status` substitutes the user's last requested climate set point for the
value reported by the vehicle whenever pre-conditioning is active. The vehicle's true set point is
received by the backend on every state report and then discarded at render time, so the API reports
intent where the requirement requires reported state.

## 6. Impact

| Area | Impact |
|---|---|
| **Masking** | Conceals RCA-003 entirely, and would conceal any future climate divergence — clamping, rejection, partial application, ECU fault. This is the dominant impact. |
| **Diagnosability** | The only interface available in the field cannot reveal a climate discrepancy, so faults will be closed as "not reproducible". |
| **Validation** | Any test suite that trusts `/vehicle/status` reports the climate domain as compliant when it is not. This defect defeats test strategies, not just users. |
| **Customer** | The app shows a set point the car is not running at, with a discrepancy as large as 7 °C (35.0 vs 28.0 observed). |
| **Contract** | Clients cannot tell which fields of `climate` are reported and which are requested. |

**Not affected:** `climate.active`, doors and charging, which are reported from the vehicle.

## 7. Recommendation

### Fix

1. **Report the vehicle's value in `climate.target_temp_c`.** This is what REQ-CLI-004 requires.
2. **If showing user intent is a genuine product requirement, add a separate field** — e.g.
   `climate.requested_temp_c` — and update the API documentation and REQ-CLI-004 so the two concepts
   are distinguishable by clients. Do not overload one field with both meanings.
3. **Raise this with the product owner, not only with the supplier.** The comment in the backend
   shows a deliberate decision, so the requirement and the design intent are in genuine conflict and
   someone has to resolve which one is authoritative. Filing it only as a code defect will get it
   closed as "by design".

### Regression tests that will catch it

| Test | Suite | Catches |
|---|---|---|
| `Cloud And Body Ecu Agree On The Set Point Once Converged` | `03_e2e/climate_preconditioning.robot` | the divergence, after the full convergence window |
| `Preconditioning Honours A Half Degree Set Point` | `03_e2e/climate_preconditioning.robot` | asserts against the ECU, so it cannot be satisfied by the API |

More broadly, this defect is the reason the whole suite uses the **Body ECU as its primary oracle**
rather than the REST API. That design choice, documented in `docs/TEST_STRATEGY.md` §2, is what made
both this defect and RCA-003 visible at all.

### Verification steps after the fix

1. Request 22.5 °C; confirm `/vehicle/status` reports the value the ECU holds.
2. With RCA-003 still open, the API must now show **22.0** — that is the correct behaviour, and it
   makes RCA-003 visible from the API, which is the point.
3. Request 35 °C (until RCA-006 is fixed); confirm the API reports the clamped **28.0**, not 35.0.
4. Confirm `climate.active` is unchanged in behaviour.
