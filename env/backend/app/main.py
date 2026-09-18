"""
Connected Vehicle Backend (cloud side) - REST API consumed by the mobile app /
HMI and by test automation. Forwards remote commands to the vehicle's
Telematics ECU (TCU-GW-2) and keeps the last reported vehicle state.

OpenAPI: http://localhost:8000/docs  |  http://localhost:8000/openapi.json
"""
from __future__ import annotations

import os
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Literal, Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Path, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from dltlog import DltLogger  # noqa: E402

API_KEY = os.environ.get("VEHICLE_API_KEY", "dev-key-001")
TCU_URL = os.environ.get("TCU_URL", "http://ecu-gateway:8081")
LEGACY_CLIMATE_SCHEMA = os.environ.get("API_COMPAT_LEGACY_CLIMATE_SCHEMA", "true").lower() == "true"
DLT_PATH = os.environ.get("BACKEND_DLT_PATH", "/var/log/dlt/backend.dlt")
SW_VERSION = "CVB_API_1.8.3"

log = DltLogger("CLD1", "API ", DLT_PATH)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


# ------------------------------------------------------------------ schemas
CommandType = Literal["LOCK", "UNLOCK", "CLIMATE_START", "CLIMATE_STOP", "CHARGING_START", "CHARGING_STOP"]
CommandStatus = Literal["ACCEPTED", "COMPLETED", "FAILED"]


class ClimateStartRequest(BaseModel):
    """Current schema (v2): validated set point."""
    target_temp_c: float = Field(22.0, ge=16.0, le=28.0, description="Cabin set point in degC, 0.5 degC steps",
                                 json_schema_extra={"example": 21.5})


class ClimateCommand(BaseModel):
    """Legacy schema kept for app versions < 3.2 (compat mode)."""
    target_temp_c: float = Field(22.0, description="Cabin set point in degC")


class ChargingStartRequest(BaseModel):
    target_soc_percent: int = Field(80, ge=50, le=100, description="Charge until this state of charge")


class CommandResponse(BaseModel):
    request_id: str
    command: CommandType
    status: CommandStatus
    submitted_at: str
    message: str


class CommandRecord(BaseModel):
    request_id: str
    command: CommandType
    params: dict
    status: CommandStatus
    reason: Optional[str] = None
    submitted_at: str
    completed_at: Optional[str] = None
    elapsed_ms: Optional[int] = None
    tcu_ack: Optional[dict] = None


class Doors(BaseModel):
    locked: Optional[bool]


class Climate(BaseModel):
    active: Optional[bool]
    target_temp_c: Optional[float]
    cabin_temp_c: Optional[float] = None


class Charging(BaseModel):
    state: Optional[Literal["IDLE", "CHARGING", "COMPLETE", "FAULT", "UNKNOWN"]]
    soc_percent: Optional[int]
    target_soc_percent: Optional[int]
    power_kw: Optional[float] = None


class Connectivity(BaseModel):
    ecu_online: bool
    last_report_at: Optional[str]
    report_age_s: Optional[float]
    state_seq: Optional[int]


class VehicleStatus(BaseModel):
    vin: str
    doors: Doors
    climate: Climate
    charging: Charging
    connectivity: Connectivity
    source: Literal["telematics_report", "none"]
    server_time: str
    api_version: str = SW_VERSION


class StateReport(BaseModel):
    vin: str
    reported_at: str
    state_seq: int
    doors_locked: bool
    climate: dict
    charging: dict
    ecu_online: bool
    tcu_sw: str


class CommandResult(BaseModel):
    status: Literal["COMPLETED", "FAILED"]
    reason: str
    elapsed_ms: int
    tcu_sw: str


# -------------------------------------------------------------------- state
class Store:
    def __init__(self):
        self.reset()

    def reset(self):
        self.vin = "WVGZZZ5NZTW000042"
        self.report: Optional[dict] = None
        self.commands: dict[str, CommandRecord] = {}
        self.desired_climate_target: Optional[float] = None


store = Store()
app = FastAPI(
    title="Connected Vehicle Backend",
    version=SW_VERSION,
    description=(
        "Cloud-side REST API for remote vehicle functions. Commands are **asynchronous**: the API "
        "returns `ACCEPTED` once the Telematics ECU has queued the command; poll "
        "`GET /vehicle/commands/{request_id}` for the terminal state and `GET /vehicle/status` for the "
        "vehicle state as last reported by the vehicle.\n\n"
        "Authentication: header `X-API-Key` (bench default `dev-key-001`)."
    ),
    openapi_tags=[
        {"name": "Vehicle", "description": "Remote functions exposed to the app/HMI"},
        {"name": "Climate", "description": "HVAC pre-conditioning"},
        {"name": "Charging", "description": "Remote charging control"},
        {"name": "Internal", "description": "Vehicle -> cloud callbacks (used by the TCU, not by clients)"},
        {"name": "Bench", "description": "Test-bench utilities. Never deployed to production."},
    ],
)


async def require_api_key(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    if x_api_key != API_KEY:
        log.warn("AUTH", "rejected request", reason="invalid_api_key", presented=(x_api_key or "")[:8])
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid or missing X-API-Key")


@app.middleware("http")
async def access_log(request: Request, call_next):
    t0 = time.monotonic()
    response = await call_next(request)
    if not request.url.path.startswith("/internal"):
        log.info("HTTP", "request", method=request.method, path=request.url.path, status=response.status_code,
                 elapsed_ms=int((time.monotonic() - t0) * 1000), client=request.client.host if request.client else None)
    return response


async def dispatch(command: CommandType, params: dict) -> CommandResponse:
    request_id = str(uuid.uuid4())
    submitted = now_iso()
    rec = CommandRecord(request_id=request_id, command=command, params=params, status="ACCEPTED", submitted_at=submitted)
    store.commands[request_id] = rec
    log.info("CMD", "dispatching to vehicle", req=request_id, command=command, tcu=TCU_URL)
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.post(f"{TCU_URL}/telematics/command",
                                     json={"request_id": request_id, "command": command, "params": params})
    except httpx.HTTPError as exc:
        rec.status, rec.reason, rec.completed_at = "FAILED", "VEHICLE_UNREACHABLE", now_iso()
        log.error("CMD", "vehicle unreachable", req=request_id, error=repr(exc)[:80])
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                            detail={"request_id": request_id, "error": "vehicle unreachable"})
    if resp.status_code != 200:
        rec.status, rec.reason, rec.completed_at = "FAILED", f"TCU_HTTP_{resp.status_code}", now_iso()
        log.error("CMD", "tcu rejected command", req=request_id, http=resp.status_code)
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail={"request_id": request_id, "error": "tcu rejected"})
    rec.tcu_ack = resp.json()
    log.info("CMD", "accepted by tcu", req=request_id, tcu_result=rec.tcu_ack.get("result"), queue_depth=rec.tcu_ack.get("queue_depth"))
    return CommandResponse(request_id=request_id, command=command, status="ACCEPTED", submitted_at=submitted,
                           message="command queued on vehicle; poll /vehicle/commands/{request_id}")


# ---------------------------------------------------------------- endpoints
@app.get("/health", tags=["Bench"])
async def health():
    return {"status": "ok", "version": SW_VERSION, "tcu_url": TCU_URL, "server_time": now_iso()}


@app.post("/vehicle/lock", response_model=CommandResponse, tags=["Vehicle"], dependencies=[Depends(require_api_key)],
          responses={401: {"description": "missing/invalid API key"}, 503: {"description": "vehicle unreachable"}})
async def vehicle_lock():
    """Lock all doors (central locking)."""
    return await dispatch("LOCK", {})


@app.post("/vehicle/unlock", response_model=CommandResponse, tags=["Vehicle"], dependencies=[Depends(require_api_key)])
async def vehicle_unlock():
    """Unlock all doors."""
    return await dispatch("UNLOCK", {})


if LEGACY_CLIMATE_SCHEMA:
    @app.post("/climate/start", response_model=CommandResponse, tags=["Climate"], dependencies=[Depends(require_api_key)])
    async def climate_start(body: ClimateCommand = ClimateCommand()):
        """Start HVAC pre-conditioning at `target_temp_c` (16.0 - 28.0 degC, 0.5 degC steps)."""
        store.desired_climate_target = body.target_temp_c
        return await dispatch("CLIMATE_START", {"target_temp_c": body.target_temp_c})
else:
    @app.post("/climate/start", response_model=CommandResponse, tags=["Climate"], dependencies=[Depends(require_api_key)],
              responses={422: {"description": "target_temp_c out of range"}})
    async def climate_start(body: ClimateStartRequest = ClimateStartRequest()):
        """Start HVAC pre-conditioning at `target_temp_c` (16.0 - 28.0 degC, 0.5 degC steps)."""
        store.desired_climate_target = body.target_temp_c
        return await dispatch("CLIMATE_START", {"target_temp_c": body.target_temp_c})


@app.post("/climate/stop", response_model=CommandResponse, tags=["Climate"], dependencies=[Depends(require_api_key)])
async def climate_stop():
    """Stop HVAC pre-conditioning."""
    store.desired_climate_target = None
    return await dispatch("CLIMATE_STOP", {})


@app.post("/charging/start", response_model=CommandResponse, tags=["Charging"], dependencies=[Depends(require_api_key)])
async def charging_start(body: ChargingStartRequest = ChargingStartRequest()):
    """Start a charging session until `target_soc_percent`."""
    return await dispatch("CHARGING_START", {"target_soc_percent": body.target_soc_percent})


@app.post("/charging/stop", response_model=CommandResponse, tags=["Charging"], dependencies=[Depends(require_api_key)])
async def charging_stop():
    """Stop the active charging session."""
    return await dispatch("CHARGING_STOP", {})


@app.get("/vehicle/status", response_model=VehicleStatus, tags=["Vehicle"], dependencies=[Depends(require_api_key)])
async def vehicle_status():
    """Last vehicle state reported by the Telematics ECU (pushed every few seconds)."""
    r = store.report
    if r is None:
        return VehicleStatus(vin=store.vin, doors=Doors(locked=None), climate=Climate(active=None, target_temp_c=None),
                             charging=Charging(state="UNKNOWN", soc_percent=None, target_soc_percent=None),
                             connectivity=Connectivity(ecu_online=False, last_report_at=None, report_age_s=None, state_seq=None),
                             source="none", server_time=now_iso())
    age = round(time.time() - r["_received_epoch"], 3)
    climate = r["climate"]
    # The set point shown to the user is the one the user asked for (source of truth = user intent),
    # the vehicle only confirms whether HVAC is running.
    target = store.desired_climate_target if (climate.get("active") and store.desired_climate_target is not None) else climate.get("target_temp_c")
    return VehicleStatus(
        vin=r["vin"],
        doors=Doors(locked=r["doors_locked"]),
        climate=Climate(active=climate.get("active"), target_temp_c=target, cabin_temp_c=climate.get("cabin_temp_c")),
        charging=Charging(**{k: r["charging"].get(k) for k in ("state", "soc_percent", "target_soc_percent", "power_kw")}),
        connectivity=Connectivity(ecu_online=r["ecu_online"] and age < 20, last_report_at=r["reported_at"], report_age_s=age,
                                  state_seq=r["state_seq"]),
        source="telematics_report", server_time=now_iso())


@app.get("/vehicle/commands", response_model=list[CommandRecord], tags=["Vehicle"], dependencies=[Depends(require_api_key)])
async def list_commands(limit: int = 50):
    """Most recent commands, newest first."""
    return sorted(store.commands.values(), key=lambda c: c.submitted_at, reverse=True)[:limit]


@app.get("/vehicle/commands/{request_id}", response_model=CommandRecord, tags=["Vehicle"], dependencies=[Depends(require_api_key)],
         responses={404: {"description": "unknown request_id"}})
async def get_command(request_id: str = Path(..., description="request_id returned by a command endpoint")):
    """Lifecycle of one remote command: ACCEPTED -> COMPLETED | FAILED."""
    rec = store.commands.get(request_id)
    if rec is None:
        raise HTTPException(status_code=404, detail="unknown request_id")
    return rec


# ------------------------------------------------------------------ internal
@app.post("/internal/vehicle/state-report", tags=["Internal"], status_code=204)
async def state_report(report: StateReport):
    data = report.model_dump()
    data["_received_epoch"] = time.time()
    prev_seq = store.report["state_seq"] if store.report else None
    store.report = data
    if prev_seq != report.state_seq:
        log.info("TLM", "state report applied", seq=report.state_seq, doors_locked=report.doors_locked,
                 hvac=report.climate.get("active"), chg=report.charging.get("state"), soc=report.charging.get("soc_percent"))
    else:
        log.debug("TLM", "state report unchanged", seq=report.state_seq)
    return JSONResponse(status_code=204, content=None)


@app.post("/internal/commands/{request_id}/result", tags=["Internal"], status_code=204)
async def command_result(request_id: str, result: CommandResult):
    rec = store.commands.get(request_id)
    if rec is None:
        log.warn("TLM", "result for unknown command", req=request_id, status=result.status)
        raise HTTPException(status_code=404, detail="unknown request_id")
    rec.status, rec.reason, rec.elapsed_ms, rec.completed_at = result.status, result.reason, result.elapsed_ms, now_iso()
    (log.info if result.status == "COMPLETED" else log.error)("TLM", "command result", req=request_id, status=result.status,
                                                               reason=result.reason, elapsed_ms=result.elapsed_ms)
    return JSONResponse(status_code=204, content=None)


# --------------------------------------------------------------------- bench
@app.post("/bench/reset", tags=["Bench"], dependencies=[Depends(require_api_key)])
async def bench_reset():
    """Reset backend command history and ask the vehicle to return to factory state. Bench only."""
    log.warn("BNCH", "bench reset")
    store.reset()
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(f"{TCU_URL}/telematics/bench/reset")
            tcu = resp.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"vehicle unreachable: {exc!r}")
    return {"result": "OK", "tcu": tcu, "server_time": now_iso()}


@app.on_event("startup")
async def on_start():
    log.info("MAIN", "backend up", sw=SW_VERSION, tcu=TCU_URL, legacy_climate_schema=LEGACY_CLIMATE_SCHEMA)
