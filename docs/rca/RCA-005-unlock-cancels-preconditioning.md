# RCA-005: Unlocking the doors silently cancels active pre-conditioning

| Field | Value |
|---|---|
| Requirement(s) violated | **REQ-LCK-004** (lock/unlock shall not modify the climate or charging state) |
| Severity | **S3 — function degraded.** The primary use case of pre-conditioning is defeated by the action that normally accompanies it |
| Component suspected | **Body ECU calibration** `BCM4_CAL_P1.3.0`, parameter `hvac_reset_on_door_unlock` |
| Reproducibility | **Always** — 100 %, whenever the doors are unlocked while pre-conditioning is active |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |
| Detected by | `Locking Does Not Disturb Climate Or Charging` |

---

## 1. Observed behaviour

Unlocking the doors while pre-conditioning is running **turns the HVAC off**. No error is reported:
the unlock command completes normally and the climate simply stops.

The scenario this breaks is the one the feature exists for. A customer pre-conditions the cabin from
the app on a cold morning, walks to the car, unlocks it — and the heating switches off at the moment
they open the door. The feature works right up until it is used.

Charging is unaffected; only the climate domain is disturbed.

## 2. Reproduction steps

```bash
KEY="X-API-Key: dev-key-001"; BASE=http://localhost:8800
curl -s -X POST -H "$KEY" -H 'Content-Type: application/json' \
     -d '{"target_temp_c": 22.0}' $BASE/climate/start
sleep 3
grpcurl -plaintext -proto env/proto/vehicle_ecu.proto localhost:50051 \
        vehicle.body.v1.BodyControl/GetBodyState | jq .climate.active
#   true
curl -s -X POST -H "$KEY" $BASE/vehicle/unlock
sleep 3
grpcurl -plaintext -proto env/proto/vehicle_ecu.proto localhost:50051 \
        vehicle.body.v1.BodyControl/GetBodyState | jq .climate.active
#   false        <- pre-conditioning cancelled by the unlock
```

Automated:

```bash
docker compose run --rm toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --test "Locking Does Not Disturb Climate Or Charging" \
  robot/tests/03_e2e/central_locking.robot
```

## 3. Evidence

### 3.1 State comparison across the lock/unlock pair

The test starts pre-conditioning *and* charging first — so there is something to disturb — captures
the full Body ECU state, performs an unlock followed by a lock, and compares:

```
Body ECU state changed where it should not have: ['climate_active: True -> False']
```

Exactly one field moved. `climate_target_raw`, `charging_state` and `target_soc_percent` are all
unchanged, which localises the effect precisely: it is the HVAC *running* flag, not the set point,
and charging is untouched.

### 3.2 DLT log — the Body ECU states the cause itself

The Body ECU logs the cancellation, its trigger, **and the calibration parameter responsible**, on
one line (`evidence/RCA-005-climate-reset-on-unlock.log`):

```
08:02:25.030520Z BCM4 BODY HVAC INFO  0x0170 pre-conditioning ended req=09c2328b-2a7e-47b5-b849-63cbc6c9c0d3 reason=door_unlock cal=hvac_reset_on_door_unlock
```

Three facts in one line, all from the ECU's own log:

- **what happened** — pre-conditioning ended;
- **why** — `reason=door_unlock`;
- **on whose authority** — `cal=hvac_reset_on_door_unlock`.

The line carries the `request_id` of the *unlock* command, which ties the climate change to that
specific door command rather than to anything happening in parallel.

Note the level: **`INFO`**. The ECU does not consider this an error, so nothing upstream is alerted,
and the cancellation never surfaces as a fault anywhere.

### 3.3 The command that caused it reports success

The unlock command completes normally and says nothing about the climate:

```
TCU1 TCU  CMD  INFO  command finished req=09c2328b-... command=UNLOCK result=COMPLETED reason=OK
```

The backend's state report then propagates `climate.active: false` to the cloud as if the user had
stopped pre-conditioning themselves. From the API alone, the cancellation is indistinguishable from
a normal stop — there is no field, flag or event indicating that the vehicle ended it.

## 4. Analysis

1. Pre-conditioning is active and the Body ECU holds `climate_active = true` — *observed*,
   `GetBodyState` before the unlock.
2. An `UNLOCK` command is dispatched and reaches the Body ECU — *observed*, gateway `GRPC` line and
   `BCM4 LOCK` line, same `request_id`.
3. While actuating the unlock, the Body ECU also clears the climate active flag, because
   `hvac_reset_on_door_unlock` is enabled — *observed*, the ECU's own log names the parameter.
4. The unlock is reported `COMPLETED`/`OK`; the climate change is never attributed to it —
   *observed*, command record and state report.

**Proven:** all four steps.

**Assessed — is this legitimate behaviour?** A door-triggered HVAC cut-off is a plausible real
feature: on many vehicles, pre-conditioning ends when the driver enters, because the climate system
hands over to normal cabin control. Two things make it a defect **here** rather than a feature:

1. **REQ-LCK-004 forbids it unconditionally**: *"Lock/unlock shall not modify the climate or charging
   state."* If the coupling is intended, the requirement is wrong and must be changed first — the
   conflict has to be resolved explicitly, not left implicit in a calibration.
2. **The trigger is wrong even on its own terms.** The cancellation is bound to the *remote unlock
   command*, not to a door actually opening or to the driver being present. A user who unlocks the
   car from the app while still indoors — which the remote unlock feature exists to allow — loses
   pre-conditioning without ever approaching the vehicle. A handover-on-entry feature should key on
   door-open or occupancy, not on the lock actuator.

I therefore report it as a defect against the stated requirement, while flagging clearly that the
resolution may be a requirement change rather than a calibration change. That decision belongs to
the programme, not to validation.

**Excluded by evidence:** gateway fault (it sends only `SetDoorLock`; no `SetClimate` accompanies the
unlock, confirmed in the backbone capture); coincidental timing (the ECU log ties the climate change
to the unlock's `request_id`); user action (no climate command was issued).

## 5. Root cause

In Body ECU calibration `BCM4_CAL_P1.3.0`, `hvac_reset_on_door_unlock` is enabled. The Body ECU
therefore clears the HVAC active flag as a side effect of servicing an `UNLOCK` actuation, coupling
two domains that REQ-LCK-004 requires to stay independent — and keying the behaviour on the remote
unlock command rather than on a door actually being opened.

## 6. Impact

| Area | Impact |
|---|---|
| **Function** | Pre-conditioning is cancelled by the action that normally precedes entering the car, defeating the feature's main use case. |
| **Customer** | Remote unlock from indoors silently ends pre-conditioning; the customer returns to a cabin that stopped conditioning when they unlocked it. |
| **Silence** | Logged at `INFO`, reported as a normal state change; indistinguishable at the API from a user-initiated stop. No diagnostic trail for support. |
| **Cross-domain coupling** | Two independent domains are coupled inside the ECU, which is a maintainability and validation risk beyond this instance. |
| **Energy** | On an EV, pre-conditioning while plugged in uses grid power; cancelling it early shifts that load to the battery during driving. |

**Not affected:** charging, the set point value itself, and the lock function.

## 7. Recommendation

### Fix — decide the requirement first

1. **If REQ-LCK-004 stands:** disable `hvac_reset_on_door_unlock` in the Body ECU calibration.
   A calibration change, no code change.
2. **If the coupling is genuinely wanted:** amend REQ-LCK-004 to state the exception explicitly,
   **and** re-trigger it on door-open or occupancy rather than on the remote unlock command, so a
   user unlocking from the app does not lose pre-conditioning. Then update the expected result of
   `Locking Does Not Disturb Climate Or Charging` to match the amended requirement.
3. **Either way, make it observable.** A vehicle-initiated end to pre-conditioning should be
   distinguishable at the API from a user-initiated one (a `reason` field on the climate state, or
   an event), so support can explain it and the customer is not left guessing.

This is the one finding in this campaign whose correct resolution may be a **requirement change**
rather than a software change. It is reported as a defect because validation is against the
requirements as written.

### Regression test that will catch it

| Test | Suite | Catches |
|---|---|---|
| `Locking Does Not Disturb Climate Or Charging` | `03_e2e/central_locking.robot` | any cross-domain side effect of lock/unlock |

The test deliberately starts **both** climate and charging before the lock/unlock pair, and compares
four fields. A version that ran with both domains idle would pass regardless — the precondition is
the test.

### Verification steps after the fix

1. Start pre-conditioning, unlock, wait 10 s; confirm `climate.active` is still `true` on the Body
   ECU, in the VHAL mirror and at `/vehicle/status`.
2. Confirm no `pre-conditioning ended ... reason=door_unlock` line appears in the Body ECU log.
3. Re-run the test; it shall pass.
4. If option 2 was chosen, confirm the amended trigger: a remote unlock shall **not** end
   pre-conditioning, while a door-open event shall.
