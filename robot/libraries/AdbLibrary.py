"""Robot Framework keywords for inspecting the gateway ECU (TCU-GW-2) over ADB.

The gateway exposes an ADB daemon on TCP 5555. This library is a thin, typed
wrapper around the ``adb`` binary; it deliberately does not hide adb's quirks,
it documents them:

* the gateway's shell has no shell-v2 framing, so **exit codes are not
  propagated** to the adb client (as on old devices). Keywords that need to
  know whether a command worked append ``; echo rc=$?`` and parse the marker.
* ``adb connect`` is idempotent and is performed lazily on first use.

The serial is never hard-coded: it comes from the ``ADB_SERIAL`` variable
supplied by the variable file, so the same suite runs against
``127.0.0.1:5555`` from the host and ``ecu-gateway:5555`` from the toolbox.
"""
from __future__ import annotations

import json
import subprocess

from robot.api import logger
from robot.api.deco import keyword, library

#: Paths on the gateway, per docs/ARCHITECTURE.md section 4.
VHAL_PROPS_PATH = "/data/vendor/vhal/props.json"
COMMAND_JOURNAL_PATH = "/data/misc/telematics/command_journal.jsonl"
CALIBRATION_PATH = "/vendor/etc/calibration/tcu_cal.json"
RELEASE_NOTES_PATH = "/vendor/etc/release_notes.txt"
GATEWAY_DLT_PATH = "/data/log/dlt/tcu.dlt"

_RC_MARKER = "__rc="


class AdbError(RuntimeError):
    """Raised when the adb client itself fails (transport, unknown device)."""


@library(scope="GLOBAL", version="1.0")
class AdbLibrary:
    """Inspect the gateway ECU over the ADB wire protocol."""

    def __init__(self, serial: str = "127.0.0.1:5555", timeout: int = 30):
        self._serial = serial
        self._timeout = timeout
        self._connected = False

    # ------------------------------------------------------------- internals
    def _adb(self, *args: str, timeout: int | None = None) -> subprocess.CompletedProcess:
        cmd = ["adb", "-s", self._serial, *args]
        logger.debug(f"running: {' '.join(cmd)}")
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout or self._timeout)

    def _ensure_connected(self) -> None:
        if self._connected:
            return
        proc = subprocess.run(["adb", "connect", self._serial],
                              capture_output=True, text=True, timeout=self._timeout)
        out = (proc.stdout or "") + (proc.stderr or "")
        if "connected" not in out.lower():
            raise AdbError(f"cannot connect to {self._serial}: {out.strip()}")
        self._connected = True
        logger.info(f"adb connected to {self._serial}")

    # -------------------------------------------------------------- keywords
    @keyword("Adb Shell")
    def adb_shell(self, command: str) -> str:
        """Run ``command`` in the gateway shell and return stdout, stripped.

        Fails only if the adb *client* fails. The remote exit code is not
        checked here because the gateway shell does not forward it; use
        `Adb Shell With Return Code` when the exit status matters.
        """
        self._ensure_connected()
        proc = self._adb("shell", command)
        if proc.returncode != 0:
            raise AdbError(f"adb transport failed for {command!r}: {proc.stderr.strip()}")
        return proc.stdout.strip()

    @keyword("Adb Shell With Return Code")
    def adb_shell_with_return_code(self, command: str) -> tuple[str, int]:
        """Run ``command`` and return ``(stdout, remote_exit_code)``.

        Works around the missing shell-v2 framing documented in
        ``docs/ADB_GUIDE.md`` by echoing a marker the keyword then strips.
        """
        raw = self.adb_shell(f"{command}; echo {_RC_MARKER}$?")
        if _RC_MARKER not in raw:
            raise AdbError(f"return-code marker missing in output of {command!r}")
        body, _, tail = raw.rpartition(_RC_MARKER)
        return body.strip(), int(tail.strip())

    @keyword("Get Gateway Property")
    def get_gateway_property(self, name: str) -> str:
        """Return one Android system property, e.g. ``ro.product.model``."""
        return self.adb_shell(f"getprop {name}")

    @keyword("Get Vhal Properties")
    def get_vhal_properties(self) -> dict:
        """Return the gateway VHAL mirror (``/data/vendor/vhal/props.json``) as a dict.

        This is the ECU's own view of the vehicle, mirrored from the Body ECU
        by the gateway's sync loop. It is the oracle for REQ-ADB-002.
        """
        return self._read_json(VHAL_PROPS_PATH)

    @keyword("Get Gateway Calibration")
    def get_gateway_calibration(self) -> dict:
        """Return the calibration in use on the gateway (``tcu_cal.json``)."""
        return self._read_json(CALIBRATION_PATH)

    @keyword("Get Release Notes")
    def get_release_notes(self) -> str:
        """Return the supplier release notes, including the declared known issues."""
        return self.adb_shell(f"cat {RELEASE_NOTES_PATH}")

    @keyword("Get Command Journal")
    def get_command_journal(self) -> list[dict]:
        """Return every record of the gateway command journal, oldest first.

        The journal (``command_journal.jsonl``) holds one line per state change
        of a remote command on the vehicle side: ``QUEUED`` when received, then
        the outcome (``COMPLETED``/``FAILED``/``DROPPED``). It is the vehicle's
        own account of what the cloud asked it to do.
        """
        raw = self.adb_shell(f"cat {COMMAND_JOURNAL_PATH}")
        records = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                logger.warn(f"skipping malformed journal line: {line[:120]}")
        return records

    @keyword("Get Journal Records For Request Id")
    def get_journal_records_for_request_id(self, request_id: str) -> list[dict]:
        """Return the journal records belonging to one ``request_id``, in order."""
        return [r for r in self.get_command_journal() if r.get("request_id") == request_id]

    @keyword("Get Logcat")
    def get_logcat(self, spec: str = "") -> str:
        """Dump the Android log buffer (``logcat -d``).

        ``spec`` is passed through verbatim, so the usual filters work:
        ``TelematicsSvc:I *:S``, ``*:W``, ``-t 50``.
        """
        return self.adb_shell(f"logcat -d {spec}".strip())

    @keyword("Get Telematics Dumpsys")
    def get_telematics_dumpsys(self) -> str:
        """Return ``dumpsys telematics`` output (gateway service state)."""
        return self.adb_shell("dumpsys telematics")

    @keyword("Get Vehicle Dumpsys")
    def get_vehicle_dumpsys(self) -> str:
        """Return ``dumpsys vehicle`` output (VHAL properties as the HMI sees them)."""
        return self.adb_shell("dumpsys vehicle")

    # --------------------------------------------------------------- helpers
    def _read_json(self, path: str) -> dict:
        raw = self.adb_shell(f"cat {path}")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise AdbError(f"{path} is not valid JSON: {exc}; first 200 chars: {raw[:200]!r}") from exc
