"""Robot Framework keywords for analysing the bench network captures with tshark.

Vantage points and decoding rules come from docs/NETWORK_TRACES.md:

* TCP 8000 backend REST and 8081 telematics are HTTP/1.1 and decode natively;
* TCP 50051 is gRPC over **plaintext HTTP/2**, so every call passes
  ``-d tcp.port==50051,http2``;
* the gateway sends literal (uncompressed) HPACK headers, so ``:path`` is
  readable even in a capture that started mid-connection.

The keywords answer the three questions docs/NETWORK_TRACES.md tells us to ask
of a trace: *which calls happened*, *which streams were cancelled*, and
*does the REST -> gRPC message count add up*. The last one is how a silently
dropped command becomes visible on the wire: a REST command with no matching
gRPC call on the backbone.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from robot.api import logger
from robot.api.deco import keyword, library

#: HTTP/2 frame type 3 = RST_STREAM (stream cancellation)
HTTP2_RST_STREAM = "3"
GRPC_DECODE = ["-d", "tcp.port==50051,http2"]


@library(scope="GLOBAL", version="1.0")
class PcapLibrary:
    """Analyse scenario captures with tshark."""

    def __init__(self, tshark: str = "tshark"):
        self._tshark = tshark

    # ------------------------------------------------------------- internals
    def _run(self, pcap: str, args: list[str]) -> list[list[str]]:
        path = Path(pcap)
        if not path.is_file():
            raise AssertionError(f"capture not found: {path}")
        if shutil.which(self._tshark) is None:
            raise AssertionError(
                f"{self._tshark!r} is not on PATH. Run the suite inside the toolbox container "
                f"(docker compose run --rm toolbox), which ships tshark."
            )
        cmd = [self._tshark, "-r", str(path), *args]
        logger.debug(f"running: {' '.join(cmd)}")
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if proc.returncode != 0:
            raise AssertionError(f"tshark failed on {path}: {proc.stderr.strip()[:400]}")
        return [line.split("\t") for line in proc.stdout.splitlines() if line.strip()]

    # -------------------------------------------------------------- keywords
    @keyword("Get Grpc Calls")
    def get_grpc_calls(self, pcap: str) -> list[dict]:
        """Return every gRPC call in ``pcap`` as dicts.

        Keys: ``time`` (seconds from start of capture, float), ``src`` (IP),
        ``stream_id``, ``path`` (e.g. ``/vehicle.body.v1.BodyControl/SetDoorLock``)
        and ``method`` (the bare method name, e.g. ``SetDoorLock``).
        """
        rows = self._run(pcap, [*GRPC_DECODE, "-Y", "http2.headers.path", "-T", "fields",
                                "-e", "frame.number", "-e", "frame.time_relative",
                                "-e", "ip.src", "-e", "http2.streamid", "-e", "http2.headers.path"])
        calls = []
        for row in rows:
            row += [""] * (5 - len(row))
            frame, rel, src, stream, path = row[:5]
            # one frame can carry several HEADERS; tshark comma-joins the values
            for one_stream, one_path in zip(stream.split(","), path.split(",")):
                if not one_path:
                    continue
                calls.append({"frame": int(frame) if frame else 0,
                              "time": float(rel) if rel else 0.0,
                              "src": src.split(",")[0],
                              "stream_id": one_stream,
                              "path": one_path,
                              "method": one_path.rsplit("/", 1)[-1]})
        logger.info(f"{len(calls)} gRPC calls in {Path(pcap).name}")
        return calls

    @keyword("Count Grpc Calls")
    def count_grpc_calls(self, pcap: str, method: str) -> int:
        """Return how many times ``method`` (e.g. ``SetCharging``) was called in ``pcap``."""
        return len([c for c in self.get_grpc_calls(pcap) if c["method"] == method])

    @keyword("Get Rst Stream Frames")
    def get_rst_stream_frames(self, pcap: str) -> list[dict]:
        """Return every HTTP/2 ``RST_STREAM`` frame on the gRPC backbone.

        An ``RST_STREAM`` sent by the gateway means it gave up on a call the
        Body ECU was still serving -- the wire-level signature of a deadline
        that is too short (REQ-NET-001).
        """
        rows = self._run(pcap, [*GRPC_DECODE, "-Y", f"http2.type=={HTTP2_RST_STREAM}", "-T", "fields",
                                "-e", "frame.number", "-e", "frame.time_relative",
                                "-e", "ip.src", "-e", "http2.streamid"])
        frames = []
        for row in rows:
            row += [""] * (4 - len(row))
            frame, rel, src, stream = row[:4]
            frames.append({"frame": int(frame) if frame else 0,
                           "time": float(rel) if rel else 0.0,
                           "src": src.split(",")[0],
                           "stream_id": stream.split(",")[0]})
        logger.info(f"{len(frames)} RST_STREAM frames in {Path(pcap).name}")
        return frames

    @keyword("Get Cancelled Grpc Calls")
    def get_cancelled_grpc_calls(self, pcap: str, method: str | None = None) -> list[dict]:
        """Return the gRPC calls whose HTTP/2 stream was later reset.

        Correlates each ``RST_STREAM`` back to the call that opened the same
        stream id, so the result names the *method* that was cancelled rather
        than an anonymous stream number. Optionally filtered to one ``method``.
        """
        calls = {c["stream_id"]: c for c in self.get_grpc_calls(pcap)}
        cancelled = []
        for rst in self.get_rst_stream_frames(pcap):
            call = calls.get(rst["stream_id"])
            if call is None:
                continue
            if method and call["method"] != method:
                continue
            cancelled.append({**call, "rst_frame": rst["frame"], "rst_time": rst["time"],
                              "rst_src": rst["src"],
                              "elapsed_ms": round((rst["time"] - call["time"]) * 1000, 1)})
        return cancelled

    @keyword("Get Http Requests")
    def get_http_requests(self, pcap: str) -> list[dict]:
        """Return the HTTP/1.1 requests in ``pcap`` (REST on 8000, telematics on 8081).

        Keys: ``frame``, ``time``, ``src``, ``dst_port``, ``method``, ``uri``.
        """
        rows = self._run(pcap, ["-Y", "http.request", "-T", "fields",
                                "-e", "frame.number", "-e", "frame.time_relative",
                                "-e", "ip.src", "-e", "tcp.dstport",
                                "-e", "http.request.method", "-e", "http.request.uri"])
        requests = []
        for row in rows:
            row += [""] * (6 - len(row))
            frame, rel, src, dport, method, uri = row[:6]
            requests.append({"frame": int(frame) if frame else 0,
                             "time": float(rel) if rel else 0.0,
                             "src": src.split(",")[0], "dst_port": dport.split(",")[0],
                             "method": method.split(",")[0], "uri": uri.split(",")[0]})
        return requests

    @keyword("Count Http Requests")
    def count_http_requests(self, pcap: str, uri_contains: str) -> int:
        """Return how many HTTP/1.1 requests in ``pcap`` have ``uri_contains`` in their URI."""
        return len([r for r in self.get_http_requests(pcap) if uri_contains in r["uri"]])

    @keyword("Format Grpc Calls")
    def format_grpc_calls(self, calls: list) -> str:
        """Render gRPC calls as a text table, for failure messages and RCA evidence."""
        return "\n".join(
            f"frame {c['frame']:>5}  t={c['time']:7.3f}s  src={c['src']:<12} "
            f"stream={c['stream_id']:<4} {c['method']}" for c in calls)
