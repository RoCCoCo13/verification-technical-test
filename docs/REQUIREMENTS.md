# Requirements - Remote Vehicle Functions (bench release 4.12.0)

Requirement ids are stable; reference them in test tags (`req:REQ-LCK-001`) and in your RCA.
"Within N s" means measured from the HTTP response of the command endpoint.

## API (backend CVB_API_1.8.3)

| Id | Requirement |
|---|---|
| REQ-API-001 | All `/vehicle/*`, `/climate/*`, `/charging/*` endpoints shall require a valid `X-API-Key`; requests without it shall be rejected with HTTP 401. |
| REQ-API-002 | Command endpoints shall respond within 500 ms with HTTP 200 and a body containing `request_id` (UUID), `status = ACCEPTED`, and `submitted_at` (ISO 8601 UTC, millisecond precision, `Z` suffix). |
| REQ-API-003 | Every accepted command shall reach a terminal state (`COMPLETED` or `FAILED`, with a `reason`) observable at `GET /vehicle/commands/{request_id}` within 5 s. No command shall remain `ACCEPTED`. |
| REQ-API-004 | `GET /vehicle/commands/{request_id}` with an unknown id shall return HTTP 404. |
| REQ-API-005 | `GET /vehicle/status` shall return `vin`, `doors.locked`, `climate.{active,target_temp_c}`, `charging.{state,soc_percent,target_soc_percent}`, `connectivity.{ecu_online,last_report_at,report_age_s}`; when the vehicle is connected, `report_age_s` shall be below 10 s. |
| REQ-API-006 | The API shall publish an OpenAPI 3 document at `/openapi.json` covering all public endpoints. |

## Central locking

| Id | Requirement |
|---|---|
| REQ-LCK-001 | `POST /vehicle/lock` shall lock the doors: `doors.locked = true` in `/vehicle/status`, `DOOR_LOCK = 1` in the gateway VHAL, and the Body ECU shall report `doors_locked = true`, all within 10 s. |
| REQ-LCK-002 | `POST /vehicle/unlock` shall unlock the doors (mirror of REQ-LCK-001, value false/0). |
| REQ-LCK-003 | Lock/unlock commands shall complete with `COMPLETED` whenever the Body ECU actuates successfully. Body ECU door actuation takes up to 1 s. Over 20 consecutive cycles, 0 commands shall be `FAILED`. A command reported `FAILED` shall not have changed the vehicle state. |
| REQ-LCK-004 | Lock/unlock shall not modify the climate or charging state. |

## HVAC pre-conditioning

| Id | Requirement |
|---|---|
| REQ-CLI-001 | `POST /climate/start {target_temp_c}` shall start pre-conditioning at the requested set point with 0.5 degC resolution; within 10 s `climate.active = true` and the Body ECU set point equals the requested value; the gateway VHAL `HVAC_TEMPERATURE_SET` equals the requested value. |
| REQ-CLI-002 | `target_temp_c` shall be validated at the API: values outside [16.0, 28.0] shall be rejected with HTTP 422 and no command shall be forwarded to the vehicle. |
| REQ-CLI-003 | `POST /climate/stop` shall stop pre-conditioning: `climate.active = false` on backend, VHAL `HVAC_POWER_ON = 0`, Body ECU `climate.active = false` within 10 s. |
| REQ-CLI-004 | The set point and active state shown by the backend shall equal the Body ECU values at all times once the state has converged (10 s). |

## Remote charging

| Id | Requirement |
|---|---|
| REQ-CHG-001 | `POST /charging/start {target_soc_percent}` shall start charging: `charging.state = CHARGING`, `target_soc_percent` echoed, SOC increasing by at least 1 % within 10 s. |
| REQ-CHG-002 | `POST /charging/stop` shall complete (`COMPLETED`) and stop charging on the Body ECU: `charging.state = IDLE` on backend, VHAL and Body ECU within 10 s; SOC stops increasing. |
| REQ-CHG-003 | `target_soc_percent` outside [50, 100] shall be rejected with HTTP 422. |
| REQ-CHG-004 | When SOC reaches the target, the Body ECU shall switch to `COMPLETE` and the backend shall reflect it within 10 s. |

## Gateway / Body ECU interaction

| Id | Requirement |
|---|---|
| REQ-ECU-001 | The gateway shall supervise the Body ECU with a heartbeat every 2 s; latency above 100 ms shall be logged as `WARN`; three consecutive misses shall mark the ECU offline. Latency warnings shall affect at most 10 % of heartbeats. |
| REQ-ECU-002 | The gateway shall forward every queued remote command to the Body ECU as exactly one gRPC call within 1 s of queuing, and shall never drop a command silently: a command that cannot be executed shall be reported `FAILED` with a reason. |
| REQ-NET-001 | gRPC deadlines used by the gateway shall accommodate the Body ECU actuation times (REQ-LCK-003); in a nominal capture no `SetDoorLock` stream shall be cancelled (`RST_STREAM`) by the gateway. |

## Logging and diagnostics

| Id | Requirement |
|---|---|
| REQ-LOG-001 | Every remote command shall be traceable across backend, gateway and Body ECU logs through its `request_id` (`req=` field), and in `logcat` (`TelematicsSvc`) on the gateway. |
| REQ-LOG-002 | Nominal lock/unlock, climate and charging flows shall produce no `ERROR`-level entries in the gateway log. |
| REQ-ADB-001 | The gateway shall be reachable over ADB (TCP 5555): `ro.product.model = TCU-GW-2`, `sys.boot_completed = 1`, `init.svc.telematics = running`. |
| REQ-ADB-002 | The gateway VHAL mirror (`/data/vendor/vhal/props.json`, `dumpsys vehicle`) shall match the Body ECU state within 10 s for `DOOR_LOCK`, `HVAC_POWER_ON`, `HVAC_TEMPERATURE_SET`, `EV_CHARGE_STATE`. |

## Known issues declared by the supplier (release notes, `/vendor/etc/release_notes.txt`)

* KI-217: Body ECU heartbeat occasionally exceeds 100 ms on the bench. Declared cosmetic. Verify the claim.
