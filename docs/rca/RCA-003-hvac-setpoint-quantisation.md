# RCA-003: HVAC set point loses its 0.5 °C resolution between the cloud and the ECU

| Field | Value |
|---|---|
| Requirement(s) violated | **REQ-CLI-001** (pre-conditioning shall start at the requested set point with 0.5 degC resolution) |
| Severity | **S3 — function degraded.** Every half-degree set point is silently rounded down |
| Component suspected | **Gateway calibration** `TCU_GW2_CAL_P4.12.0`, parameter `hvac_temp_quantize` |
| Reproducibility | **Always** — 100 % for any set point with a .5 fraction |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |
| Detected by | `Preconditioning Honours A Half Degree Set Point` |
| Related | **RCA-004** — the cloud hides this divergence, which is why it is invisible from the API |

---

## 1. Observed behaviour

A customer asks for **22.5 °C**. The vehicle pre-conditions to **22.0 °C**. No error is raised
anywhere: the command completes `COMPLETED`/`OK`, and the app continues to display 22.5 °C.

The loss is always downward (`22.5 → 22.0`, `23.5 → 23.0`), so the error is a systematic −0.5 °C
bias on half-degree requests, not rounding noise.

Whole-degree set points are unaffected — `Preconditioning Starts At A Whole Degree Set Point` passes
— which is why the defect survives casual testing.

## 2. Reproduction steps

```bash
KEY="X-API-Key: dev-key-001"; BASE=http://localhost:8800
curl -s -X POST -H "$KEY" -H 'Content-Type: application/json' \
     -d '{"target_temp_c": 22.5}' $BASE/climate/start
sleep 3
# Ask the vehicle, not the cloud:
grpcurl -plaintext -proto env/proto/vehicle_ecu.proto localhost:50051 \
        vehicle.body.v1.BodyControl/GetBodyState | jq .climate
#   { "active": true, "targetTempRaw": 44, ... }     <- 44 = 22.0 degC, not 45
adb -s localhost:5555 shell cat /data/vendor/vhal/props.json | jq .HVAC_TEMPERATURE_SET
#   22.0
```

Automated:

```bash
docker compose run --rm toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --test "Preconditioning Honours A Half Degree Set Point" \
  robot/tests/03_e2e/climate_preconditioning.robot
```

Request id used below: **`6f3e5a6c-ffbe-4426-8909-9494bb7bdba7`**, the `/climate/start` at 22.5 °C
issued by scenario `S02_climate_preconditioning`.

## 3. Evidence

### 3.1 The contract being violated

`env/proto/vehicle_ecu.proto`, the interface contract between the gateway and the Body ECU, defines
the encoding unambiguously:

```protobuf
// Target cabin temperature encoded as raw signal: 0.5 degC per LSB, offset 0.
// 44 -> 22.0 degC, 45 -> 22.5 degC. Valid range 32..56 (16.0..28.0 degC).
int32 target_temp_raw = 3;
```

**22.5 °C is raw 45.** This is the expected value, fixed by the contract, not by my assumption — the
test computes it from the contract rather than hard-coding it.

### 3.2 DLT logs — the exact point of loss

The gateway logs the conversion, including the rule it applied:

```
08:09:22.446942Z TCU1 TCU  CMD  INFO  0x0068 remote command received req=6f3e5a6c-... command=CLIMATE_START params={"target_temp_c":22.5}
08:09:22.457606Z TCU1 TCU  HVAC DEBUG 0x0069 temperature encoded temp_c=22.5 raw=44 quantize=floor_integer
08:09:22.472850Z TCU1 TCU  GRPC INFO  0x006A SetClimate -> req=6f3e5a6c-... deadline_ms=1500 peer=body-ecu:50051
08:09:22.481171Z BCM4 BODY HVAC INFO  0x002D SetClimate received req=6f3e5a6c-... action=CLIMATE_START target_raw=44
08:09:22.542762Z BCM4 BODY HVAC INFO  0x002E SetClimate done req=6f3e5a6c-... active=True target_raw=44
08:09:22.565034Z TCU1 TCU  CMD  INFO  0x006C command finished req=6f3e5a6c-... command=CLIMATE_START result=COMPLETED reason=OK elapsed_ms=107
```

One line contains the whole defect:

```
temperature encoded temp_c=22.5 raw=44 quantize=floor_integer
```

The gateway received **22.5**, produced raw **44**, and names the rule it used: `floor_integer`.
Correct per the contract would be `45`. The value is already wrong when it leaves the gateway — the
Body ECU receives `target_raw=44` and stores it faithfully, so the ECU is behaving correctly.

The command nevertheless completes `COMPLETED`/`OK`, so nothing downstream ever learns that the
request was not honoured.

### 3.3 ADB — the calibration, and the mirror

```bash
adb shell cat /vendor/etc/calibration/tcu_cal.json
```
```json
"hvac_temp_scale": 2,
"hvac_temp_quantize": "floor_integer"      <-- multiplies whole degrees only
```

`hvac_temp_scale: 2` is correct — 2 LSB per °C is exactly the contract's 0.5 °C per LSB. The fault is
`hvac_temp_quantize: "floor_integer"`, which truncates the temperature to a whole number *before*
applying the scale: `int(22.5) * 2 = 44` instead of `round(22.5 * 2) = 45`. The scale is right and
the quantisation throws away exactly the resolution the scale exists to provide.

The gateway's VHAL mirror agrees with the ECU, confirming the mirror is sound and the loss is
upstream of it:

```bash
adb shell cat /data/vendor/vhal/props.json
#   "HVAC_TEMPERATURE_SET": 22.0
```

### 3.4 Network trace

The `SetClimate` call for this request is on the backbone carrying the already-truncated value
(`traces/pcap/scenarios/ci/S02_climate_preconditioning.pcap`); the gateway's own `GRPC` line records
the ECU's acknowledgement echoing it back:

```
SetClimate <- req=6f3e5a6c-... result=OK detail=hvac on target_raw=44 elapsed_ms=77
```

The value on the wire is 44. There is no later correction.

## 4. Analysis

1. The backend forwards the user's request unchanged as `target_temp_c: 22.5` — *observed*, gateway
   `CMD` line quotes `params={"target_temp_c":22.5}`.
2. The gateway encodes it with the `floor_integer` rule from its calibration, producing raw 44
   instead of 45 — *observed*, the `HVAC` log line states input, output and rule together.
3. The truncated value is sent to the Body ECU and stored — *observed*, `BCM4 HVAC` lines and the
   backbone capture.
4. The command is reported `COMPLETED`/`OK`, so the deviation is never surfaced — *observed*,
   `CMD`/`TLM` lines and the REST record.

**Proven:** all four steps, at three interfaces.

**Assessed:** the Body ECU is not at fault — it accepts raw 44 as a legal in-range value (32..56) and
stores it correctly. The backend is not at fault for the *truncation* — it forwards 22.5 unchanged.
The defect is entirely in the gateway's encoding step. (The backend *is* at fault for concealing the
result; that is **RCA-004**, and the two must be fixed independently.)

**Hypothesis, stated as such:** the name `floor_integer` and the code comment describing it as
"legacy CAN matrix behaviour: integer degrees only" suggest the rule was carried over from an older
platform whose signal had 1 °C resolution. The calibration offers `round_half`, which would produce
45. I have not seen the change history and do not claim this as fact — the defect stands on the
observed encoding regardless.

## 5. Root cause

In gateway calibration `TCU_GW2_CAL_P4.12.0`, `hvac_temp_quantize` is set to `floor_integer`, which
truncates the requested temperature to whole degrees before applying the 2 LSB/°C scale. Any set
point with a half-degree fraction is therefore transmitted 0.5 °C below the request, in violation of
the 0.5 °C resolution required by REQ-CLI-001 and defined in `vehicle_ecu.proto`.

## 6. Impact

| Area | Impact |
|---|---|
| **Function** | Half the addressable set points are unreachable. The 0.5 °C resolution advertised at the API and defined in the ECU contract does not exist in practice. |
| **Customer** | The cabin is consistently 0.5 °C cooler than requested, and the app shows the requested value, so the customer has no way to discover why. |
| **Systematic bias** | The error is always downward, so it does not average out over repeated use. |
| **Detectability** | Invisible from the REST API because of RCA-004. Only a cross-interface comparison reveals it — which is precisely why it reached this release. |

**Not affected:** whole-degree set points; the on/off behaviour of pre-conditioning; the VHAL mirror,
which faithfully reflects what the ECU holds.

## 7. Recommendation

### Fix

1. Set `hvac_temp_quantize` to **`round_half`** in `tcu_cal.json`. The gateway already implements
   this mode (`round(temp_c * scale)`), so it is a calibration change with no code change.
2. **Validate the encoder against the contract**, not against a calibration flag. The `.proto`
   defines the encoding normatively; a gateway that can be calibrated into violating its own
   interface contract is a design weakness independent of which value is currently set.
3. Consider rejecting, at the API, set points that are not a multiple of 0.5 °C, so the accepted
   resolution and the transmitted resolution are the same thing.

### Regression tests that will catch it

| Test | Suite | Catches |
|---|---|---|
| `Preconditioning Honours A Half Degree Set Point` | `03_e2e/climate_preconditioning.robot` | the truncation, asserting the **raw** signal against the contract |
| `Cloud And Body Ecu Agree On The Set Point Once Converged` | `03_e2e/climate_preconditioning.robot` | the divergence it creates (also RCA-004) |

The first asserts on `climate_target_raw`, not on the decoded temperature, so it fails even if a
future backend rounds the displayed value to hide the difference.

### Verification steps after the fix

1. `adb shell cat /vendor/etc/calibration/tcu_cal.json` shows `"hvac_temp_quantize": "round_half"`.
2. Request 22.5 °C; confirm `temperature encoded temp_c=22.5 raw=45` in the gateway log.
3. Confirm `GetBodyState` reports `target_temp_raw: 45` and the VHAL mirror shows `22.5`.
4. Re-run both tests above; both shall pass.
