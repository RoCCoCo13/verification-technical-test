"""Robot Framework keywords for reading the Body ECU (BCM-4) over gRPC.

``GetBodyState`` is the *physical truth* of the vehicle (docs/API_REFERENCE.md):
the doors, HVAC and charger state as the ECU that owns them sees it. Every
end-to-end test uses it as the oracle, against which the cloud REST view and
the gateway VHAL mirror are compared.

The protobuf stubs are generated from ``env/proto/vehicle_ecu.proto`` on first
use rather than committed, so the suite can never drift from the contract the
bench actually ships. Generated code lands in ``libraries/generated/`` which is
git-ignored.

Raw signal decoding is done here, once, so no test case has to remember it:
temperatures are 0.5 degC per LSB (raw 44 -> 22.0 degC) and charging power is
0.1 kW per LSB.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from robot.api import logger
from robot.api.deco import keyword, library

_GENERATED_DIR = Path(__file__).parent / "generated"


def _generate_stubs(proto_path: str) -> None:
    """Compile the .proto into ``generated/`` unless already up to date."""
    proto = Path(proto_path)
    if not proto.is_file():
        raise FileNotFoundError(
            f"proto contract not found at {proto}. Set PROTO_PATH in the variable file "
            f"to point at env/proto/vehicle_ecu.proto."
        )
    stub = _GENERATED_DIR / "vehicle_ecu_pb2.py"
    if stub.is_file() and stub.stat().st_mtime >= proto.stat().st_mtime:
        return
    _GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    (_GENERATED_DIR / "__init__.py").touch()
    cmd = [sys.executable, "-m", "grpc_tools.protoc",
           f"-I{proto.parent}", f"--python_out={_GENERATED_DIR}",
           f"--grpc_python_out={_GENERATED_DIR}", str(proto)]
    logger.info(f"generating gRPC stubs: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"protoc failed: {proc.stderr}")


@library(scope="GLOBAL", version="1.0")
class BodyEcuLibrary:
    """Read the physical vehicle state directly from the Body ECU."""

    def __init__(self, address: str = "127.0.0.1:50051",
                 proto_path: str = "env/proto/vehicle_ecu.proto",
                 timeout: float = 5.0):
        self._address = address
        self._timeout = timeout
        _generate_stubs(proto_path)
        if str(_GENERATED_DIR) not in sys.path:
            sys.path.insert(0, str(_GENERATED_DIR))
        import grpc                                    # noqa: PLC0415
        import vehicle_ecu_pb2 as pb                   # noqa: PLC0415
        import vehicle_ecu_pb2_grpc as pb_grpc         # noqa: PLC0415
        self._grpc, self._pb, self._pb_grpc = grpc, pb, pb_grpc
        self._channel = None
        self._stub = None

    def _connect(self):
        if self._stub is None:
            self._channel = self._grpc.insecure_channel(self._address)
            self._stub = self._pb_grpc.BodyControlStub(self._channel)
            logger.info(f"gRPC channel opened to {self._address}")
        return self._stub

    # -------------------------------------------------------------- keywords
    @keyword("Get Body Ecu State")
    def get_body_ecu_state(self) -> dict:
        """Return the Body ECU state snapshot as a dict with decoded units.

        This is the vehicle's physical truth and the oracle for REQ-LCK-001/002,
        REQ-CLI-001/004, REQ-CHG-001/002/004 and REQ-ADB-002.

        Keys: ``doors_locked``, ``climate_active``, ``climate_target_temp_c``,
        ``climate_target_raw``, ``cabin_temp_c``, ``charging_state``,
        ``soc_percent``, ``target_soc_percent``, ``power_kw``, ``state_seq``,
        ``ecu_uptime_ms``. Both the decoded temperature and the raw signal are
        returned because the 0.5 degC quantisation is itself under test.
        """
        stub = self._connect()
        state = stub.GetBodyState(self._pb.StateRequest(), timeout=self._timeout)
        decoded = {
            "doors_locked": state.doors_locked,
            "climate_active": state.climate.active,
            "climate_target_raw": state.climate.target_temp_raw,
            "climate_target_temp_c": state.climate.target_temp_raw / 2.0,
            "cabin_temp_raw": state.climate.cabin_temp_raw,
            "cabin_temp_c": state.climate.cabin_temp_raw / 2.0,
            "charging_state": self._pb.ChargingState.Name(state.charging.state),
            "soc_percent": state.charging.soc_percent,
            "target_soc_percent": state.charging.target_soc_percent,
            "power_kw": state.charging.power_kw_x10 / 10.0,
            "state_seq": state.state_seq,
            "ecu_uptime_ms": state.ecu_uptime_ms,
        }
        logger.debug(f"body ecu state: {decoded}")
        return decoded

    @keyword("Body Ecu Should Be Reachable")
    def body_ecu_should_be_reachable(self) -> None:
        """Fail unless the Body ECU answers a ``GetBodyState`` call."""
        try:
            self.get_body_ecu_state()
        except Exception as exc:                        # noqa: BLE001
            raise AssertionError(f"Body ECU at {self._address} is not reachable: {exc}") from exc

    @keyword("Temperature In Celsius To Raw")
    def temperature_in_celsius_to_raw(self, temp_c: float) -> int:
        """Return the raw HVAC signal for ``temp_c`` per the .proto contract.

        0.5 degC per LSB with no offset, so 22.5 degC is raw 45. This encodes
        what the *contract* requires, independently of what the gateway does,
        which is exactly what REQ-CLI-001 needs to be checked against.
        """
        return int(round(float(temp_c) * 2))
