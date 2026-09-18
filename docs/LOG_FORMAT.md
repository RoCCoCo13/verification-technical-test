# Log Format (DLT-like) and Correlation

All three nodes write the same text format, inspired by AUTOSAR DLT (Diagnostic Log and Trace)
but kept as plain text so you can use `grep`, `awk`, pandas or a Robot keyword. Files:

| File (host) | Also on the ECU | Writer |
|---|---|---|
| `traces/logs/tcu.dlt` | `/data/log/dlt/tcu.dlt` (adb pull) | gateway application + adbd |
| `traces/logs/body_ecu.dlt` | - | Body ECU |
| `traces/logs/backend.dlt` | - | backend |

The files persist across restarts (append). Note the timestamp of your `POST /bench/reset` to
delimit a test run, or truncate the files while the bench is stopped.

## Line format

```
<timestamp_utc> <uptime_s> <ECU> <APP> <CTX> <LEVEL> <counter> <payload>
2026-09-15T17:20:08.412101Z 000079.592 TCU1 TCU  GRPC ERROR 0x0097 SetDoorLock failed req=42f8e7ab-... grpc_code=DEADLINE_EXCEEDED elapsed_ms=502 detail=Deadline Exceeded
```

| Field | Width | Meaning |
|---|---|---|
| `timestamp_utc` | 27 | ISO 8601 UTC with microseconds, host wall clock (all containers share the Docker host clock, so timestamps are comparable across files) |
| `uptime_s` | 10 | seconds since the writing process started (`000079.592`) |
| `ECU` | 4 | `TCU1` gateway, `BCM4` body ECU, `CLD1` backend |
| `APP` | 4 | application: `TCU ` gateway app, `ADBD` adb daemon, `BODY`, `API ` |
| `CTX` | 4 | context (subsystem), see table below |
| `LEVEL` | 5 (padded) | `FATAL ERROR WARN INFO DEBUG VERBOSE` |
| `counter` | 6 | per-process 16-bit message counter `0x0000..0xFFFF`; a gap means lost or filtered lines |
| `payload` | free | message, then `key=value` tokens separated by spaces. Values never contain spaces except `detail=` which is last. |

Correlation id: the `req=<uuid>` token carries the backend `request_id` through the whole chain:
backend (`CMD`) -> gateway (`CMD`, `GRPC`) -> body ECU (`LOCK`/`HVAC`/`CHG`) -> gateway result -> backend (`TLM`).

## Contexts

| ECU | CTX | Meaning |
|---|---|---|
| TCU1 | `MAIN` `CAL` | start-up, calibration loading |
| TCU1 | `CMD` | remote command reception, queueing, dispatch, completion |
| TCU1 | `GRPC` | outgoing gRPC calls to the Body ECU (`->` request, `<-` response, `failed`) |
| TCU1 | `SYNC` | body state polling and VHAL mirror updates |
| TCU1 | `CLD` | callbacks to the cloud backend (result, state report) |
| TCU1 | `HB` | heartbeat supervision |
| TCU1 | `HVAC` | HVAC signal encoding |
| TCU1 | `GNSS` `NET` | background telematics noise |
| TCU1/ADBD | `CONN` `SVC` `SHEL` `SYNC` | adb sessions, streams, shell commands, file transfers |
| BCM4 | `LOCK` `HVAC` `CHG` | actuations |
| BCM4 | `STAT` `HB` `CAL` `MAIN` | state snapshots, heartbeat, calibration, start-up |
| CLD1 | `HTTP` | access log (public endpoints) |
| CLD1 | `CMD` | command dispatch to the vehicle |
| CLD1 | `TLM` | telemetry received from the vehicle (state reports, command results) |
| CLD1 | `AUTH` `BNCH` | rejected requests, bench utilities |

## Recipes

```bash
# everything about one command, across the three nodes, in time order
grep -h "req=6f1c" traces/logs/*.dlt | sort

# errors and warnings on the gateway, without GNSS noise
grep -E " (ERROR|WARN) " traces/logs/tcu.dlt | grep -v GNSS

# how long each gRPC call took
grep "GRPC INFO" traces/logs/tcu.dlt | grep -o "elapsed_ms=[0-9]*"

# commands the gateway received vs. commands it forwarded
grep -c "remote command received" traces/logs/tcu.dlt ; grep -c "GRPC.*->" traces/logs/tcu.dlt
```

## Android logcat (gateway only)

`adb shell logcat -d` prints the Android log buffer in `threadtime` format:

```
09-15 17:19:04.594  1834  1834 I TelematicsSvc: onRemoteCommand id=6f1c... type=LOCK
```

Useful tags: `TelematicsSvc`, `VehicleHal`, `CarPowerManager`, `GnssLocationProvider`. Filters work
as on a real device: `logcat -d TelematicsSvc:I '*:S'`, `logcat -d '*:W'`, `logcat -t 50`.
