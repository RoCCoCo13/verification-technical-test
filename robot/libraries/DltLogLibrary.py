"""Robot Framework keywords for the DLT-like logs of the three nodes.

Format (docs/LOG_FORMAT.md)::

    <ts_utc> <uptime_s> <ECU> <APP> <CTX> <LEVEL> <counter> <payload>
    2026-09-18T07:22:31.801042Z 000089.736 TCU1 TCU  CMD  WARN  0x0063 no handler ... req=860b8df0-...

Two properties of these files drive the design of this library:

1. **They append across bench restarts.** A suite that greps the whole file
   will assert on lines produced hours earlier, by a different build or by a
   failed start-up. Every keyword therefore takes a ``since`` timestamp and
   the suites take that mark at their own reset. This is what makes
   REQ-LOG-002 ("no ERROR during nominal flows") a meaningful check instead
   of a permanently-red one.
2. **All three nodes share the Docker host wall clock**, so lines from
   ``backend.dlt``, ``tcu.dlt`` and ``body_ecu.dlt`` are directly comparable
   and can be merged into one time-ordered view of a single ``request_id`` --
   which is precisely what REQ-LOG-001 demands.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path

from robot.api import logger
from robot.api.deco import keyword, library

#: node id -> log file name, per docs/LOG_FORMAT.md
NODE_FILES = {"gateway": "tcu.dlt", "backend": "backend.dlt", "body_ecu": "body_ecu.dlt"}

_LINE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s+"
    r"(?P<uptime>[\d.]+)\s+(?P<ecu>\S+)\s+(?P<app>\S+)\s+(?P<ctx>\S+)\s+"
    r"(?P<level>FATAL|ERROR|WARN|INFO|DEBUG|VERBOSE)\s+(?P<counter>0x[0-9A-Fa-f]{4})\s*"
    r"(?P<payload>.*)$"
)
_KV = re.compile(r"(\w+)=(\S+)")


def _parse_ts(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)


@library(scope="GLOBAL", version="1.0")
class DltLogLibrary:
    """Read, filter and correlate the DLT-like logs of backend, gateway and Body ECU."""

    def __init__(self, logs_dir: str = "traces/logs"):
        self._logs_dir = Path(logs_dir)

    # ------------------------------------------------------------- internals
    def _path(self, node: str) -> Path:
        try:
            return self._logs_dir / NODE_FILES[node]
        except KeyError:
            raise ValueError(f"unknown node {node!r}; expected one of {sorted(NODE_FILES)}") from None

    def _read(self, node: str) -> list[dict]:
        path = self._path(node)
        if not path.is_file():
            raise AssertionError(f"log file for node {node!r} not found at {path}")
        entries = []
        with path.open(encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                m = _LINE.match(raw.rstrip("\n"))
                if not m:
                    continue
                entry = m.groupdict()
                entry["node"] = node
                entry["timestamp"] = _parse_ts(entry["ts"])
                entry["fields"] = dict(_KV.findall(entry["payload"]))
                entry["line"] = raw.rstrip("\n")
                entries.append(entry)
        return entries

    # -------------------------------------------------------------- keywords
    @keyword("Mark Log Position")
    def mark_log_position(self) -> datetime:
        """Return 'now' (UTC) as the start of a log observation window.

        Call this in suite/test setup, right after the bench reset, and pass
        the result as ``since`` to every later log query so assertions only
        ever see lines produced by the current test.
        """
        mark = datetime.now(timezone.utc)
        logger.info(f"log observation window starts at {mark.isoformat()}")
        return mark

    @keyword("Get Log Entries")
    def get_log_entries(self, node: str, since: datetime | None = None, level: str | None = None,
                        ctx: str | None = None, contains: str | None = None) -> list[dict]:
        """Return parsed log entries of ``node``, filtered and time-ordered.

        ``node`` is ``gateway``, ``backend`` or ``body_ecu``. ``level`` matches
        exactly (e.g. ``ERROR``); ``ctx`` matches the 4-char context
        (``CMD``, ``GRPC``, ``HB``, ...); ``contains`` is a substring of the
        payload. Each entry is a dict with ``timestamp``, ``level``, ``ctx``,
        ``payload``, ``fields`` (the parsed ``key=value`` tokens) and ``line``.
        """
        entries = self._read(node)
        if since is not None:
            entries = [e for e in entries if e["timestamp"] >= since]
        if level is not None:
            entries = [e for e in entries if e["level"] == level.upper()]
        if ctx is not None:
            entries = [e for e in entries if e["ctx"].strip() == ctx.strip()]
        if contains is not None:
            entries = [e for e in entries if contains in e["payload"]]
        return sorted(entries, key=lambda e: e["timestamp"])

    @keyword("Get Log Entries For Request Id")
    def get_log_entries_for_request_id(self, request_id: str,
                                       since: datetime | None = None) -> list[dict]:
        """Return every line carrying ``req=<request_id>`` across **all three** nodes,
        merged into a single time-ordered sequence.

        This is the end-to-end traceability view required by REQ-LOG-001.
        """
        merged: list[dict] = []
        for node in NODE_FILES:
            merged.extend(e for e in self._read(node)
                          if e["fields"].get("req") == request_id
                          and (since is None or e["timestamp"] >= since))
        merged.sort(key=lambda e: e["timestamp"])
        return merged

    @keyword("Get Nodes Tracing Request Id")
    def get_nodes_tracing_request_id(self, request_id: str,
                                     since: datetime | None = None) -> list[str]:
        """Return the sorted set of node names whose log mentions ``request_id``."""
        return sorted({e["node"] for e in self.get_log_entries_for_request_id(request_id, since)})

    @keyword("Get Heartbeat Latency Samples")
    def get_heartbeat_latency_samples(self, since: datetime | None = None) -> list[int]:
        """Return every heartbeat latency (ms) the gateway logged in the window.

        The gateway logs one ``HB`` line per heartbeat carrying ``latency_ms``,
        at DEBUG when within threshold and at WARN when above it, so this
        returns the *complete* population, not just the outliers. That is what
        lets REQ-ECU-001's "at most 10 % of heartbeats" be measured rather
        than guessed.
        """
        samples = [int(e["fields"]["latency_ms"])
                   for e in self.get_log_entries(node="gateway", since=since, ctx="HB")
                   if "latency_ms" in e["fields"]]
        logger.info(f"collected {len(samples)} heartbeat latency samples")
        return samples

    @keyword("Get Gateway Error Entries")
    def get_gateway_error_entries(self, since: datetime | None = None,
                                  ignore_contexts: list | None = None) -> list[dict]:
        """Return gateway ``ERROR`` lines in the window, excluding noise contexts.

        ``ignore_contexts`` defaults to the background telematics chatter
        (``GNSS``, ``NET``) that docs/ARCHITECTURE.md lists as always present
        and unrelated to the remote-command flows REQ-LOG-002 is about.
        """
        ignored = {str(c).strip().upper() for c in (ignore_contexts or ["GNSS", "NET"])}
        return [e for e in self.get_log_entries(node="gateway", since=since, level="ERROR")
                if e["ctx"].strip().upper() not in ignored]

    @keyword("Format Log Entries")
    def format_log_entries(self, entries: list) -> str:
        """Render entries as text, for embedding in a failure message or RCA."""
        return "\n".join(e["line"] for e in entries)
