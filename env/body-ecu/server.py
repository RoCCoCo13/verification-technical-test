"""
Body Control Module simulator (BCM-4).

Owns the physical state of the vehicle body domain: central locking, HVAC
pre-conditioning and the on-board charger. Talks gRPC (plaintext HTTP/2) to
the gateway. Emits DLT-like logs to stdout and /var/log/dlt/body_ecu.dlt.
"""
from __future__ import annotations

import asyncio
import json
import os
import random
import time

import grpc

import vehicle_ecu_pb2 as pb
import vehicle_ecu_pb2_grpc as pb_grpc
from dltlog import DltLogger

CAL_PATH = os.environ.get("BODY_CAL_PATH", "/etc/body_ecu/body_cal.json")
LOG_PATH = os.environ.get("BODY_DLT_PATH", "/var/log/dlt/body_ecu.dlt")
SW_VERSION = "BCM4_SW_2.7.1"

log = DltLogger("BCM4", "BODY", LOG_PATH)
T0 = time.monotonic()


def uptime_ms() -> int:
    return int((time.monotonic() - T0) * 1000)


def load_cal() -> dict:
    with open(CAL_PATH, encoding="utf-8") as fh:
        cal = json.load(fh)
    log.info("CAL", "calibration loaded", cal_id=cal["calibration_id"], variant=cal["variant"], path=CAL_PATH)
    return cal


class BodyModel:
    def __init__(self, cal: dict):
        self.cal = cal
        self.lock = asyncio.Lock()
        self.reset("power_on")

    def reset(self, reason: str) -> None:
        self.doors_locked = True
        self.climate_active = False
        self.climate_target_raw = 44          # 22.0 degC
        self.cabin_temp_raw = 38              # 19.0 degC
        self.charging_state = pb.IDLE
        self.soc = int(self.cal["initial_soc_percent"])
        self.target_soc = 80
        self.state_seq = 0
        self._soc_acc = 0.0
        log.info("STAT", "body state reset", reason=reason, soc=self.soc, doors_locked=self.doors_locked)

    def bump(self) -> None:
        self.state_seq = (self.state_seq + 1) & 0xFFFFFFFF

    def snapshot(self) -> pb.BodyState:
        power = int(self.cal["charging_power_kw_x10"]) if self.charging_state == pb.CHARGING else 0
        return pb.BodyState(
            doors_locked=self.doors_locked,
            climate=pb.ClimateState(active=self.climate_active,
                                    target_temp_raw=self.climate_target_raw,
                                    cabin_temp_raw=self.cabin_temp_raw),
            charging=pb.ChargingStatus(state=self.charging_state, soc_percent=self.soc,
                                       target_soc_percent=self.target_soc, power_kw_x10=power),
            ecu_uptime_ms=uptime_ms(),
            state_seq=self.state_seq,
        )

    async def physics_loop(self) -> None:
        """Simulate charging progress and cabin temperature drift."""
        period = float(self.cal["charging_soc_step_period_s"])
        while True:
            await asyncio.sleep(1.0)
            async with self.lock:
                if self.charging_state == pb.CHARGING:
                    self._soc_acc += 1.0 / period
                    if self._soc_acc >= 1.0:
                        self._soc_acc -= 1.0
                        self.soc = min(100, self.soc + 1)
                        self.bump()
                        log.debug("CHG", "soc step", soc=self.soc, target=self.target_soc)
                        if self.soc >= self.target_soc:
                            self.charging_state = pb.COMPLETE
                            self.bump()
                            log.info("CHG", "charging complete", soc=self.soc)
                if self.climate_active and self.cabin_temp_raw != self.climate_target_raw:
                    self.cabin_temp_raw += 1 if self.cabin_temp_raw < self.climate_target_raw else -1
                    self.bump()


class BodyControlServicer(pb_grpc.BodyControlServicer):
    def __init__(self, model: BodyModel):
        self.m = model
        self.hb_count = 0

    async def SetDoorLock(self, request: pb.DoorLockRequest, context):
        # The actuation is shielded: once the relay is driven the lock completes even if the
        # requester cancels the stream (as a physical actuator would).
        task = asyncio.ensure_future(self._actuate_door_lock(request, context))
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            log.warn("LOCK", "requester cancelled the stream, actuation continues", req=request.request_id,
                     action=pb.LockAction.Name(request.action))
            raise

    async def _actuate_door_lock(self, request: pb.DoorLockRequest, context):
        t_start = time.monotonic()
        lo, hi = self.m.cal["door_actuator_time_ms"]
        actuation_ms = random.randint(int(lo), int(hi))
        log.info("LOCK", "SetDoorLock received", req=request.request_id,
                 action=pb.LockAction.Name(request.action), actuation_ms=actuation_ms)
        await asyncio.sleep(actuation_ms / 1000.0)      # actuator travel time
        async with self.m.lock:
            if request.action == pb.LOCK:
                self.m.doors_locked = True
            elif request.action == pb.UNLOCK:
                self.m.doors_locked = False
                if self.m.cal.get("hvac_reset_on_door_unlock") and self.m.climate_active:
                    self.m.climate_active = False
                    log.info("HVAC", "pre-conditioning ended", req=request.request_id,
                             reason="door_unlock", cal="hvac_reset_on_door_unlock")
            else:
                log.warn("LOCK", "unsupported lock action", req=request.request_id, action=request.action)
                return pb.CommandAck(request_id=request.request_id, result=pb.REJECTED,
                                     detail="unsupported action", ecu_timestamp_ms=uptime_ms())
            self.m.bump()
        elapsed = int((time.monotonic() - t_start) * 1000)
        log.info("LOCK", "SetDoorLock done", req=request.request_id, doors_locked=self.m.doors_locked, elapsed_ms=elapsed)
        return pb.CommandAck(request_id=request.request_id, result=pb.OK, detail="actuated",
                             ecu_timestamp_ms=uptime_ms())

    async def SetClimate(self, request: pb.ClimateRequest, context):
        log.info("HVAC", "SetClimate received", req=request.request_id,
                 action=pb.ClimateAction.Name(request.action), target_raw=request.target_temp_raw)
        async with self.m.lock:
            if request.action == pb.CLIMATE_START:
                lo, hi = self.m.cal["hvac_temp_raw_min"], self.m.cal["hvac_temp_raw_max"]
                raw = request.target_temp_raw
                if raw < lo or raw > hi:
                    clamped = max(lo, min(hi, raw))
                    log.warn("HVAC", "target out of range, clamped", req=request.request_id,
                             requested_raw=raw, clamped_raw=clamped)
                    raw = clamped
                self.m.climate_target_raw = raw
                self.m.climate_active = True
                detail = f"hvac on target_raw={raw}"
            elif request.action == pb.CLIMATE_STOP:
                self.m.climate_active = False
                detail = "hvac off"
            else:
                return pb.CommandAck(request_id=request.request_id, result=pb.REJECTED,
                                     detail="unsupported action", ecu_timestamp_ms=uptime_ms())
            self.m.bump()
        await asyncio.sleep(random.uniform(0.02, 0.06))
        log.info("HVAC", "SetClimate done", req=request.request_id, active=self.m.climate_active,
                 target_raw=self.m.climate_target_raw)
        return pb.CommandAck(request_id=request.request_id, result=pb.OK, detail=detail,
                             ecu_timestamp_ms=uptime_ms())

    async def SetCharging(self, request: pb.ChargingRequest, context):
        log.info("CHG", "SetCharging received", req=request.request_id,
                 action=pb.ChargingAction.Name(request.action), target_soc=request.target_soc_percent)
        async with self.m.lock:
            if request.action == pb.CHARGING_START:
                if self.m.charging_state == pb.CHARGING:
                    detail = "already charging"
                else:
                    self.m.target_soc = request.target_soc_percent or 80
                    if self.m.soc >= self.m.target_soc:
                        self.m.charging_state = pb.COMPLETE
                        detail = "soc already at target"
                    else:
                        self.m.charging_state = pb.CHARGING
                        detail = "charging started"
            elif request.action == pb.CHARGING_STOP:
                self.m.charging_state = pb.IDLE
                detail = "charging stopped"
            else:
                return pb.CommandAck(request_id=request.request_id, result=pb.REJECTED,
                                     detail="unsupported action", ecu_timestamp_ms=uptime_ms())
            self.m.bump()
        await asyncio.sleep(random.uniform(0.03, 0.08))
        log.info("CHG", "SetCharging done", req=request.request_id,
                 state=pb.ChargingState.Name(self.m.charging_state), soc=self.m.soc)
        return pb.CommandAck(request_id=request.request_id, result=pb.OK, detail=detail,
                             ecu_timestamp_ms=uptime_ms())

    async def GetBodyState(self, request, context):
        async with self.m.lock:
            snap = self.m.snapshot()
        log.debug("STAT", "GetBodyState served", seq=snap.state_seq, doors_locked=snap.doors_locked,
                  hvac=snap.climate.active, chg=pb.ChargingState.Name(snap.charging.state), soc=snap.charging.soc_percent)
        return snap

    async def Heartbeat(self, request: pb.HeartbeatRequest, context):
        self.hb_count += 1
        lo, hi = self.m.cal["heartbeat_jitter_ms"]
        delay = random.randint(int(lo), int(hi))
        if self.hb_count % int(self.m.cal["heartbeat_slow_every_n"]) == 0:
            delay += int(self.m.cal["heartbeat_slow_extra_ms"])
            log.debug("HB", "heartbeat served late (scheduler contention)", seq=request.seq, delay_ms=delay)
        await asyncio.sleep(delay / 1000.0)
        log.verbose("HB", "heartbeat", seq=request.seq)
        return pb.HeartbeatResponse(seq=request.seq, ecu_timestamp_ms=uptime_ms(), ecu_sw_version=SW_VERSION)

    async def ResetState(self, request: pb.ResetRequest, context):
        async with self.m.lock:
            self.m.reset(request.reason or "bench_reset")
        return pb.CommandAck(request_id="", result=pb.OK, detail="reset", ecu_timestamp_ms=uptime_ms())


async def main() -> None:
    cal = load_cal()
    model = BodyModel(cal)
    server = grpc.aio.server(options=[("grpc.http2.hpack_table_size.encoder", 0)])
    pb_grpc.add_BodyControlServicer_to_server(BodyControlServicer(model), server)
    port = int(os.environ.get("BODY_GRPC_PORT", "50051"))
    server.add_insecure_port(f"0.0.0.0:{port}")
    await server.start()
    log.info("MAIN", "Body ECU up", sw=SW_VERSION, port=port)
    asyncio.create_task(model.physics_loop())
    await server.wait_for_termination()


if __name__ == "__main__":
    asyncio.run(main())
