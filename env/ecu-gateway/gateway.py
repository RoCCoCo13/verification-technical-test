"""
Telematics / Gateway ECU application (TCU-GW-2), the "vehicle side" of the
connected-car service.

Responsibilities
* Telematics command receiver: HTTP/1.1 JSON listener on :8081 used by the
  cloud backend to push remote commands (LOCK, CLIMATE_START, ...).
* Command queue worker: maps each remote command to a gRPC call towards the
  Body ECU (BCM-4) using the calibration table and reports the outcome back to
  the backend.
* Body state sync: polls GetBodyState periodically, mirrors the values into
  the local VHAL property store (/data/vendor/vhal/props.json) and pushes a
  state report to the backend.
* Heartbeat supervision of the Body ECU.
* Logging: DLT-like file /data/log/dlt/tcu.dlt and Android logcat-style file
  /data/log/logcat.log (read by the `logcat` tool via adb).
"""
from __future__ import annotations

import asyncio
import json
import os
import random
import time
import uuid
from datetime import datetime

import grpc
from aiohttp import ClientSession, ClientTimeout, TCPConnector, web

import vehicle_ecu_pb2 as pb
import vehicle_ecu_pb2_grpc as pb_grpc
from dltlog import DltLogger

CAL_PATH = os.environ.get("TCU_CAL_PATH", "/vendor/etc/calibration/tcu_cal.json")
DLT_PATH = os.environ.get("TCU_DLT_PATH", "/data/log/dlt/tcu.dlt")
LOGCAT_PATH = os.environ.get("TCU_LOGCAT_PATH", "/data/log/logcat.log")
VHAL_PATH = "/data/vendor/vhal/props.json"
QUEUE_PATH = "/data/misc/telematics/command_journal.jsonl"
BODY_ECU_ADDR = os.environ.get("BODY_ECU_ADDR", "body-ecu:50051")
BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend:8000")
LISTEN_PORT = int(os.environ.get("TCU_TELEMATICS_PORT", "8081"))
SW_VERSION = "TCU_GW2_SW_4.12.0"

log = DltLogger("TCU1", "TCU ", DLT_PATH)
T0 = time.monotonic()


# ----------------------------------------------------------------- logcat sink
class Logcat:
    """Writes Android logcat 'threadtime' formatted lines."""

    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.pid = os.getpid()

    def write(self, level: str, tag: str, msg: str, tid: int | None = None) -> None:
        ts = datetime.now().strftime("%m-%d %H:%M:%S.%f")[:-3]
        tid = tid or self.pid
        line = f"{ts} {self.pid:5d} {tid:5d} {level} {tag}: {msg}\n"
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(line)


logcat = Logcat(LOGCAT_PATH)


def temp_raw_to_c(raw: int) -> float:
    return raw / 2.0


class Calibration:
    def __init__(self, path: str):
        with open(path, encoding="utf-8") as fh:
            self.data = json.load(fh)
        log.info("CAL", "calibration loaded", cal_id=self.data["calibration_id"], path=path)
        logcat.write("I", "TelematicsSvc", f"calibration {self.data['calibration_id']} loaded from {path}")

    def __getitem__(self, key):
        return self.data[key]

    def get(self, key, default=None):
        return self.data.get(key, default)


class Gateway:
    def __init__(self, cal: Calibration):
        self.cal = cal
        self.queue: asyncio.Queue[dict] = asyncio.Queue()
        # HPACK dynamic table disabled on purpose: every request carries literal headers so that
        # network taps started mid-connection still decode :path (diagnosability on the backbone).
        self.channel = grpc.aio.insecure_channel(BODY_ECU_ADDR, options=[("grpc.http2.hpack_table_size.encoder", 0),
                                                                        ("grpc.keepalive_time_ms", 30000)])
        self.stub = pb_grpc.BodyControlStub(self.channel)
        # one TCP connection per request: simpler traces, no keep-alive races with the cloud
        self.http = ClientSession(timeout=ClientTimeout(total=5), connector=TCPConnector(force_close=True))
        self.vhal: dict = {"DOOR_LOCK": None, "HVAC_POWER_ON": None, "HVAC_TEMPERATURE_SET": None,
                           "EV_CHARGE_STATE": None, "EV_BATTERY_LEVEL": None, "EV_CHARGE_TARGET": None,
                           "BODY_ECU_ONLINE": False, "LAST_SYNC_UTC": None, "STATE_SEQ": None}
        self.hb_seq = 0
        self.hb_missed = 0
        self.ecu_online = False
        self.commands_seen = 0
        self.last_result: dict | None = None
        os.makedirs(os.path.dirname(VHAL_PATH), exist_ok=True)
        os.makedirs(os.path.dirname(QUEUE_PATH), exist_ok=True)
        self.persist_vhal()

    # -------------------------------------------------------------- helpers
    def persist_vhal(self) -> None:
        with open(VHAL_PATH, "w", encoding="utf-8") as fh:
            json.dump(self.vhal, fh, indent=2, sort_keys=True)

    def journal(self, record: dict) -> None:
        with open(QUEUE_PATH, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")

    def encode_hvac_temp(self, temp_c: float) -> int:
        scale = int(self.cal.get("hvac_temp_scale", 2))
        mode = self.cal.get("hvac_temp_quantize", "floor_integer")
        if mode == "round_half":
            raw = int(round(temp_c * scale))
        else:  # legacy CAN matrix behaviour: integer degrees only
            raw = int(temp_c) * scale
        log.debug("HVAC", "temperature encoded", temp_c=temp_c, raw=raw, quantize=mode)
        return raw

    # ------------------------------------------------------ telematics HTTP
    async def handle_command(self, request: web.Request) -> web.Response:
        body = await request.json()
        request_id = body.get("request_id") or str(uuid.uuid4())
        command = body.get("command", "")
        params = body.get("params", {}) or {}
        self.commands_seen += 1
        log.info("CMD", "remote command received", req=request_id, command=command, params=json.dumps(params, separators=(",", ":")))
        logcat.write("I", "TelematicsSvc", f"onRemoteCommand id={request_id} type={command}")
        record = {"request_id": request_id, "command": command, "params": params,
                  "received_at": time.time(), "state": "QUEUED"}
        self.journal(record)
        await self.queue.put(record)
        return web.json_response({"request_id": request_id, "result": "QUEUED",
                                  "queue_depth": self.queue.qsize(), "tcu_sw": SW_VERSION})

    async def handle_state(self, request: web.Request) -> web.Response:
        return web.json_response({"vhal": self.vhal, "ecu_online": self.ecu_online,
                                  "queue_depth": self.queue.qsize(), "commands_seen": self.commands_seen,
                                  "sw_version": SW_VERSION, "uptime_s": round(time.monotonic() - T0, 1)})

    async def handle_reset(self, request: web.Request) -> web.Response:
        log.warn("CMD", "bench reset requested")
        logcat.write("W", "TelematicsSvc", "bench reset requested")
        try:
            await self.stub.ResetState(pb.ResetRequest(reason="bench_reset"), timeout=2.0)
        except grpc.aio.AioRpcError as exc:
            return web.json_response({"result": "ERROR", "detail": exc.details()}, status=502)
        while not self.queue.empty():
            self.queue.get_nowait()
        await self.sync_once()
        return web.json_response({"result": "OK"})

    async def handle_health(self, request: web.Request) -> web.Response:
        return web.json_response({"status": "ok", "ecu_online": self.ecu_online, "sw_version": SW_VERSION})

    # -------------------------------------------------------- command worker
    async def worker(self) -> None:
        command_map: dict = self.cal["command_map"]
        while True:
            rec = await self.queue.get()
            req = rec["request_id"]
            handler_name = command_map.get(rec["command"])
            if handler_name is None:
                log.warn("CMD", "no handler for command, dropping", req=req, command=rec["command"],
                         known=",".join(sorted(command_map)))
                logcat.write("W", "TelematicsSvc", f"dropped command id={req} type={rec['command']} (no mapping)")
                rec["state"] = "DROPPED"
                self.journal(rec)
                continue
            handler = getattr(self, f"cmd_{handler_name}")
            t0 = time.monotonic()
            result, reason = await handler(req, rec["params"])
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            rec.update({"state": result, "reason": reason, "elapsed_ms": elapsed_ms})
            self.journal(rec)
            self.last_result = rec
            level = log.info if result == "COMPLETED" else log.error
            level("CMD", "command finished", req=req, command=rec["command"], result=result, reason=reason, elapsed_ms=elapsed_ms)
            logcat.write("I" if result == "COMPLETED" else "E", "TelematicsSvc",
                         f"command id={req} type={rec['command']} result={result} reason={reason} elapsed={elapsed_ms}ms")
            await self.report_result(req, result, reason, elapsed_ms)
            if self.cal.get("sync_after_command", True):
                await self.sync_once()

    async def _grpc(self, req: str, name: str, coro_factory, timeout_ms: int):
        t0 = time.monotonic()
        log.info("GRPC", f"{name} ->", req=req, deadline_ms=timeout_ms, peer=BODY_ECU_ADDR)
        try:
            ack = await coro_factory(timeout_ms / 1000.0)
        except grpc.aio.AioRpcError as exc:
            elapsed = int((time.monotonic() - t0) * 1000)
            code = exc.code().name
            log.error("GRPC", f"{name} failed", req=req, grpc_code=code, elapsed_ms=elapsed, detail=(exc.details() or "")[:80])
            return None, ("ECU_TIMEOUT" if code == "DEADLINE_EXCEEDED" else f"GRPC_{code}")
        elapsed = int((time.monotonic() - t0) * 1000)
        log.info("GRPC", f"{name} <-", req=req, result=pb.AckResult.Name(ack.result), detail=ack.detail, elapsed_ms=elapsed)
        return ack, None

    async def cmd_door_lock(self, req, params):
        return await self._door(req, pb.LOCK)

    async def cmd_door_unlock(self, req, params):
        return await self._door(req, pb.UNLOCK)

    async def _door(self, req, action):
        ack, err = await self._grpc(req, "SetDoorLock", lambda t: self.stub.SetDoorLock(
            pb.DoorLockRequest(request_id=req, action=action), timeout=t), int(self.cal["door_lock_ack_timeout_ms"]))
        if err:
            return "FAILED", err
        if ack.result != pb.OK:
            return "FAILED", f"ECU_{pb.AckResult.Name(ack.result)}"
        logcat.write("I", "VehicleHal", f"DOOR_LOCK set to {1 if action == pb.LOCK else 0} (req={req})")
        return "COMPLETED", "OK"

    async def cmd_hvac_start(self, req, params):
        temp_c = float(params.get("target_temp_c", 22.0))
        raw = self.encode_hvac_temp(temp_c)
        ack, err = await self._grpc(req, "SetClimate", lambda t: self.stub.SetClimate(
            pb.ClimateRequest(request_id=req, action=pb.CLIMATE_START, target_temp_raw=raw), timeout=t),
            int(self.cal["hvac_ack_timeout_ms"]))
        if err:
            return "FAILED", err
        logcat.write("I", "VehicleHal", f"HVAC_TEMPERATURE_SET raw={raw} ({temp_raw_to_c(raw)}C) HVAC_POWER_ON=1 (req={req})")
        return ("COMPLETED", "OK") if ack.result == pb.OK else ("FAILED", f"ECU_{pb.AckResult.Name(ack.result)}")

    async def cmd_hvac_stop(self, req, params):
        ack, err = await self._grpc(req, "SetClimate", lambda t: self.stub.SetClimate(
            pb.ClimateRequest(request_id=req, action=pb.CLIMATE_STOP), timeout=t), int(self.cal["hvac_ack_timeout_ms"]))
        if err:
            return "FAILED", err
        logcat.write("I", "VehicleHal", f"HVAC_POWER_ON=0 (req={req})")
        return ("COMPLETED", "OK") if ack.result == pb.OK else ("FAILED", f"ECU_{pb.AckResult.Name(ack.result)}")

    async def cmd_charge_start(self, req, params):
        target = int(params.get("target_soc_percent", 80))
        ack, err = await self._grpc(req, "SetCharging", lambda t: self.stub.SetCharging(
            pb.ChargingRequest(request_id=req, action=pb.CHARGING_START, target_soc_percent=target), timeout=t),
            int(self.cal["charging_ack_timeout_ms"]))
        if err:
            return "FAILED", err
        logcat.write("I", "VehicleHal", f"EV_CHARGE_STATE=CHARGING target={target} (req={req})")
        return ("COMPLETED", "OK") if ack.result == pb.OK else ("FAILED", f"ECU_{pb.AckResult.Name(ack.result)}")

    async def cmd_charge_stop(self, req, params):
        ack, err = await self._grpc(req, "SetCharging", lambda t: self.stub.SetCharging(
            pb.ChargingRequest(request_id=req, action=pb.CHARGING_STOP), timeout=t), int(self.cal["charging_ack_timeout_ms"]))
        if err:
            return "FAILED", err
        logcat.write("I", "VehicleHal", f"EV_CHARGE_STATE=IDLE (req={req})")
        return ("COMPLETED", "OK") if ack.result == pb.OK else ("FAILED", f"ECU_{pb.AckResult.Name(ack.result)}")

    # ----------------------------------------------------- backend reporting
    async def report_result(self, req: str, result: str, reason: str, elapsed_ms: int) -> None:
        url = f"{BACKEND_URL}/internal/commands/{req}/result"
        payload = {"status": result, "reason": reason, "elapsed_ms": elapsed_ms, "tcu_sw": SW_VERSION}
        try:
            async with self.http.post(url, json=payload) as resp:
                log.debug("CLD", "result reported to backend", req=req, http=resp.status)
        except Exception as exc:  # noqa: BLE001
            log.error("CLD", "result report failed", req=req, error=repr(exc)[:80])

    async def sync_once(self) -> None:
        try:
            state = await self.stub.GetBodyState(pb.StateRequest(), timeout=self.cal["state_poll_timeout_ms"] / 1000.0)
        except grpc.aio.AioRpcError as exc:
            self.ecu_online = False
            self.vhal["BODY_ECU_ONLINE"] = False
            self.persist_vhal()
            log.error("SYNC", "GetBodyState failed", grpc_code=exc.code().name)
            return
        changed = self.vhal.get("STATE_SEQ") != state.state_seq
        self.vhal.update({
            "DOOR_LOCK": 1 if state.doors_locked else 0,
            "HVAC_POWER_ON": 1 if state.climate.active else 0,
            "HVAC_TEMPERATURE_SET": temp_raw_to_c(state.climate.target_temp_raw),
            "HVAC_TEMPERATURE_CURRENT": temp_raw_to_c(state.climate.cabin_temp_raw),
            "EV_CHARGE_STATE": pb.ChargingState.Name(state.charging.state),
            "EV_BATTERY_LEVEL": state.charging.soc_percent,
            "EV_CHARGE_TARGET": state.charging.target_soc_percent,
            "EV_CHARGE_POWER_KW": state.charging.power_kw_x10 / 10.0,
            "BODY_ECU_ONLINE": True,
            "BODY_ECU_UPTIME_MS": state.ecu_uptime_ms,
            "STATE_SEQ": state.state_seq,
            "LAST_SYNC_UTC": datetime.utcnow().isoformat(timespec="milliseconds") + "Z",
        })
        self.ecu_online = True
        self.persist_vhal()
        if changed:
            log.info("SYNC", "body state changed", seq=state.state_seq, door_lock=self.vhal["DOOR_LOCK"],
                     hvac_on=self.vhal["HVAC_POWER_ON"], hvac_set=self.vhal["HVAC_TEMPERATURE_SET"],
                     chg=self.vhal["EV_CHARGE_STATE"], soc=self.vhal["EV_BATTERY_LEVEL"])
            logcat.write("D", "VehicleHal", f"property snapshot seq={state.state_seq} DOOR_LOCK={self.vhal['DOOR_LOCK']} "
                         f"HVAC_POWER_ON={self.vhal['HVAC_POWER_ON']} EV_CHARGE_STATE={self.vhal['EV_CHARGE_STATE']} SOC={self.vhal['EV_BATTERY_LEVEL']}")
        else:
            log.debug("SYNC", "body state unchanged", seq=state.state_seq)
        report = {"vin": self.cal["vin"], "reported_at": self.vhal["LAST_SYNC_UTC"], "state_seq": state.state_seq,
                  "doors_locked": state.doors_locked,
                  "climate": {"active": state.climate.active, "target_temp_c": self.vhal["HVAC_TEMPERATURE_SET"],
                              "cabin_temp_c": self.vhal["HVAC_TEMPERATURE_CURRENT"]},
                  "charging": {"state": self.vhal["EV_CHARGE_STATE"], "soc_percent": state.charging.soc_percent,
                               "target_soc_percent": state.charging.target_soc_percent,
                               "power_kw": self.vhal["EV_CHARGE_POWER_KW"]},
                  "ecu_online": True, "tcu_sw": SW_VERSION}
        try:
            async with self.http.post(f"{BACKEND_URL}/internal/vehicle/state-report", json=report) as resp:
                log.debug("CLD", "state report sent", seq=state.state_seq, http=resp.status)
        except Exception as exc:  # noqa: BLE001
            log.error("CLD", "state report failed", error=repr(exc)[:80])

    async def sync_loop(self) -> None:
        period = float(self.cal["state_poll_period_s"])
        while True:
            await self.sync_once()
            await asyncio.sleep(period)

    async def heartbeat_loop(self) -> None:
        period = float(self.cal["heartbeat_period_s"])
        warn_ms = int(self.cal["heartbeat_warn_latency_ms"])
        while True:
            self.hb_seq += 1
            t0 = time.monotonic()
            try:
                resp = await self.stub.Heartbeat(pb.HeartbeatRequest(seq=self.hb_seq, gateway_timestamp_ms=int(time.time() * 1000)),
                                                 timeout=self.cal["heartbeat_timeout_ms"] / 1000.0)
                latency = int((time.monotonic() - t0) * 1000)
                if latency > warn_ms:
                    log.warn("HB", "heartbeat latency above threshold", seq=self.hb_seq, latency_ms=latency, threshold_ms=warn_ms, ecu_sw=resp.ecu_sw_version)
                else:
                    log.debug("HB", "heartbeat ok", seq=self.hb_seq, latency_ms=latency)
                self.hb_missed = 0
            except grpc.aio.AioRpcError as exc:
                self.hb_missed += 1
                log.error("HB", "heartbeat failed", seq=self.hb_seq, grpc_code=exc.code().name, missed=self.hb_missed)
                if self.hb_missed >= 3:
                    self.ecu_online = False
                    logcat.write("E", "TelematicsSvc", "Body ECU supervision lost (3 missed heartbeats)")
            await asyncio.sleep(period)

    async def noise_loop(self) -> None:
        """Background chatter typical of an AAOS device (makes filtering necessary)."""
        rng = random.Random(7)
        while True:
            await asyncio.sleep(rng.uniform(1.5, 4.0))
            choice = rng.random()
            if choice < 0.35:
                logcat.write("D", "CarPowerManager", f"state=ON reason=periodic uptime={int(time.monotonic() - T0)}s")
            elif choice < 0.55:
                logcat.write("W", "GnssLocationProvider", "fix lost, satellites=3 (indoor bench)")
                log.warn("GNSS", "fix lost", satellites=3)
            elif choice < 0.75:
                logcat.write("I", "ConnectivityService", "NetworkAgentInfo [MOBILE (LTE)] validated")
                log.debug("NET", "lte link ok", rsrp_dbm=-(rng.randint(80, 105)))
            elif choice < 0.9:
                logcat.write("D", "AudioService", "volume group 2 (media) ducked=false")
            else:
                logcat.write("V", "CarService", f"binder txn count={rng.randint(1000, 9000)}")


async def main() -> None:
    cal = Calibration(CAL_PATH)
    gw = Gateway(cal)
    app = web.Application()
    app.add_routes([web.post("/telematics/command", gw.handle_command),
                    web.get("/telematics/state", gw.handle_state),
                    web.post("/telematics/bench/reset", gw.handle_reset),
                    web.get("/health", gw.handle_health)])
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", LISTEN_PORT).start()
    log.info("MAIN", "telematics service up", port=LISTEN_PORT, sw=SW_VERSION, body_ecu=BODY_ECU_ADDR, backend=BACKEND_URL)
    logcat.write("I", "TelematicsSvc", f"service started sw={SW_VERSION} listening on :{LISTEN_PORT}")
    logcat.write("I", "ActivityManager", "Start proc 1834:com.oem.telematics/1000 for service {com.oem.telematics/.TelematicsService}")
    await asyncio.gather(gw.worker(), gw.sync_loop(), gw.heartbeat_loop(), gw.noise_loop())


if __name__ == "__main__":
    asyncio.run(main())
