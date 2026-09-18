# REST API Reference (summary)

Base URL `http://localhost:8000`. Live OpenAPI: `/docs` (Swagger UI), `/redoc`, `/openapi.json`.
Authentication: header `X-API-Key: dev-key-001` on every public endpoint.

## Command model

Commands are **asynchronous**. A command endpoint returns immediately with `status = ACCEPTED`
once the vehicle has queued it. The terminal outcome (`COMPLETED`/`FAILED` + `reason`) is read at
`GET /vehicle/commands/{request_id}`. The vehicle state is read at `GET /vehicle/status`, which
returns the last state report pushed by the vehicle (every 5 s and after each command).

## Endpoints

| Method | Path | Body | Purpose |
|---|---|---|---|
| POST | `/vehicle/lock` | - | lock doors |
| POST | `/vehicle/unlock` | - | unlock doors |
| POST | `/climate/start` | `{"target_temp_c": 22.5}` (default 22.0) | start pre-conditioning |
| POST | `/climate/stop` | - | stop pre-conditioning |
| POST | `/charging/start` | `{"target_soc_percent": 80}` (default 80) | start charging |
| POST | `/charging/stop` | - | stop charging |
| GET | `/vehicle/status` | - | vehicle state (last report) |
| GET | `/vehicle/commands` | `?limit=50` | recent command records |
| GET | `/vehicle/commands/{request_id}` | - | one command record |
| GET | `/health` | - | liveness (no key) |
| POST | `/bench/reset` | - | **bench only**: reset backend records and vehicle state |
| POST | `/internal/vehicle/state-report` | (vehicle -> cloud) | used by the gateway |
| POST | `/internal/commands/{request_id}/result` | (vehicle -> cloud) | used by the gateway |

### Command response (200)

```json
{"request_id": "6f1c1d1e-...", "command": "LOCK", "status": "ACCEPTED",
 "submitted_at": "2026-09-15T17:20:08.412Z", "message": "command queued on vehicle; poll /vehicle/commands/{request_id}"}
```

### Command record

```json
{"request_id": "...", "command": "LOCK", "params": {}, "status": "COMPLETED", "reason": "OK",
 "submitted_at": "...", "completed_at": "...", "elapsed_ms": 287,
 "tcu_ack": {"request_id": "...", "result": "QUEUED", "queue_depth": 0, "tcu_sw": "TCU_GW2_SW_4.12.0"}}
```

`status`: `ACCEPTED` -> `COMPLETED` | `FAILED`. `reason` examples: `OK`, `ECU_TIMEOUT`,
`ECU_REJECTED`, `VEHICLE_UNREACHABLE`.

### Vehicle status

```json
{"vin": "WVGZZZ5NZTW000042",
 "doors": {"locked": true},
 "climate": {"active": false, "target_temp_c": 22.0, "cabin_temp_c": 19.0},
 "charging": {"state": "IDLE", "soc_percent": 42, "target_soc_percent": 80, "power_kw": 0.0},
 "connectivity": {"ecu_online": true, "last_report_at": "2026-09-15T17:19:03.868Z", "report_age_s": 1.2, "state_seq": 7},
 "source": "telematics_report", "server_time": "...", "api_version": "CVB_API_1.8.3"}
```

`charging.state`: `IDLE | CHARGING | COMPLETE | FAULT | UNKNOWN`.

### Errors

| Code | When |
|---|---|
| 401 | missing/invalid `X-API-Key` |
| 404 | unknown `request_id` |
| 422 | request body validation error (FastAPI format) |
| 502 / 503 | vehicle rejected / unreachable |

## Body ECU gRPC (inspection only)

`localhost:50051`, plaintext, contract in `env/proto/vehicle_ecu.proto`. `GetBodyState` is the
physical truth of the vehicle. Example with Python:

```python
import grpc, vehicle_ecu_pb2 as pb, vehicle_ecu_pb2_grpc as pbg   # generate with grpcio-tools
stub = pbg.BodyControlStub(grpc.insecure_channel("localhost:50051"))
print(stub.GetBodyState(pb.StateRequest()))
```

Or with grpcurl: `grpcurl -plaintext -proto env/proto/vehicle_ecu.proto localhost:50051 vehicle.body.v1.BodyControl/GetBodyState`.
Temperatures are raw signals: 0.5 degC per LSB (`44` = 22.0 degC).
