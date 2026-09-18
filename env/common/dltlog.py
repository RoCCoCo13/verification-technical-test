"""
Minimal DLT-like structured logger used by every ECU/service on the bench.

Line format (single line, space separated, fixed order):

  <iso_utc_timestamp> <uptime_s> <ECU> <APP> <CTX> <LEVEL> <counter> <payload>

  2026-09-15T18:30:01.123456Z 000123.456 TCU1 TCU  CMD  WARN  0x0042 no handler for command=CHARGING_STOP

* ECU/APP/CTX are 4-char identifiers padded with spaces (as in AUTOSAR DLT).
* LEVEL is one of FATAL ERROR WARN INFO DEBUG VERBOSE.
* counter is a per-process 16-bit message counter (wraps at 0xFFFF).
* payload is free text; structured fields are written as key=value tokens.
  Correlation ids are written as req=<uuid>.

The format is text on purpose so it can be analysed with grep/awk/pandas
without proprietary tooling. See candidate/docs/LOG_FORMAT.md.
"""
from __future__ import annotations

import os
import sys
import threading
import time
from datetime import datetime, timezone

LEVELS = {"FATAL": 0, "ERROR": 1, "WARN": 2, "INFO": 3, "DEBUG": 4, "VERBOSE": 5}


class DltLogger:
    _lock = threading.Lock()
    _counter = 0
    _t0 = time.monotonic()

    def __init__(self, ecu: str, app: str, path: str | None = None,
                 min_level: str = "DEBUG", also_stdout: bool = True):
        self.ecu = ecu[:4].ljust(4)
        self.app = app[:4].ljust(4)
        self.path = path
        self.min_level = LEVELS[min_level]
        self.also_stdout = also_stdout
        if path:
            os.makedirs(os.path.dirname(path), exist_ok=True)

    def _emit(self, ctx: str, level: str, msg: str, **fields) -> None:
        if LEVELS[level] > self.min_level:
            return
        with DltLogger._lock:
            DltLogger._counter = (DltLogger._counter + 1) & 0xFFFF
            counter = DltLogger._counter
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        uptime = time.monotonic() - DltLogger._t0
        extra = " ".join(f"{k}={v}" for k, v in fields.items() if v is not None)
        payload = f"{msg} {extra}".strip()
        line = (f"{now} {uptime:010.3f} {self.ecu} {self.app} {ctx[:4].ljust(4)} "
                f"{level.ljust(5)} 0x{counter:04X} {payload}\n")
        if self.path:
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line)
        if self.also_stdout:
            sys.stdout.write(line)
            sys.stdout.flush()

    def fatal(self, ctx, msg, **f): self._emit(ctx, "FATAL", msg, **f)
    def error(self, ctx, msg, **f): self._emit(ctx, "ERROR", msg, **f)
    def warn(self, ctx, msg, **f): self._emit(ctx, "WARN", msg, **f)
    def info(self, ctx, msg, **f): self._emit(ctx, "INFO", msg, **f)
    def debug(self, ctx, msg, **f): self._emit(ctx, "DEBUG", msg, **f)
    def verbose(self, ctx, msg, **f): self._emit(ctx, "VERBOSE", msg, **f)
