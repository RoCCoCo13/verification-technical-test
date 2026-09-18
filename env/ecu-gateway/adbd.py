"""
Minimal ADB daemon (device side) implementing the ADB TCP transport protocol
so that a stock `adb` client can `adb connect`, `adb shell`, `adb pull/push`,
`adb logcat` against this container.

Implements: CNXN, OPEN, OKAY, WRTE, CLSE  (no AUTH, no TLS)
Services  : shell:<cmd>, shell: (interactive pty), exec:<cmd>, sync:
            (STAT/LIST/RECV/SEND/QUIT), root:, remount:, reboot:

Reference: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/protocol.txt
"""
from __future__ import annotations

import asyncio
import fcntl
import os
import pty
import struct
import termios
import time

from dltlog import DltLogger

A_SYNC, A_CNXN, A_OPEN, A_OKAY, A_CLSE, A_WRTE, A_AUTH, A_STLS = (
    0x434E5953, 0x4E584E43, 0x4E45504F, 0x59414B4F, 0x45534C43, 0x45545257, 0x48545541, 0x534C5453)
NAMES = {A_SYNC: "SYNC", A_CNXN: "CNXN", A_OPEN: "OPEN", A_OKAY: "OKAY", A_CLSE: "CLSE",
         A_WRTE: "WRTE", A_AUTH: "AUTH", A_STLS: "STLS"}
A_VERSION = 0x01000001
MAX_PAYLOAD = 1024 * 1024
HEADER = struct.Struct("<IIIIII")

ANDROID_ENV = {
    "PATH": "/system/bin:/vendor/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME": "/",
    "ANDROID_ROOT": "/system",
    "ANDROID_DATA": "/data",
    "EXTERNAL_STORAGE": "/sdcard",
    "TERM": "xterm-256color",
    "HOSTNAME": "tcu_gw2",
    "PS1": "tcu_gw2:$PWD # ",
    "LANG": "C.UTF-8",
}

log = DltLogger("TCU1", "ADBD", os.environ.get("TCU_DLT_PATH", "/data/log/dlt/tcu.dlt"))


def checksum(data: bytes) -> int:
    return sum(data) & 0xFFFFFFFF


def pack(cmd: int, arg0: int, arg1: int, data: bytes = b"") -> bytes:
    return HEADER.pack(cmd, arg0, arg1, len(data), checksum(data), cmd ^ 0xFFFFFFFF) + data


class Stream:
    """One ADB logical stream (device side)."""

    def __init__(self, conn: "AdbConnection", local_id: int, remote_id: int, service: str):
        self.conn = conn
        self.local_id = local_id
        self.remote_id = remote_id
        self.service = service
        self.inbox: asyncio.Queue[bytes | None] = asyncio.Queue()
        self.ack = asyncio.Event()
        self.ack.set()
        self.closed = False
        self._buf = b""

    async def write(self, data: bytes) -> None:
        for i in range(0, len(data), self.conn.max_payload):
            chunk = data[i:i + self.conn.max_payload]
            await self.ack.wait()
            if self.closed:
                return
            self.ack.clear()
            await self.conn.send(A_WRTE, self.local_id, self.remote_id, chunk)

    async def read_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = await self.inbox.get()
            if chunk is None:
                raise EOFError
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    async def close(self) -> None:
        if not self.closed:
            self.closed = True
            self.ack.set()
            await self.conn.send(A_CLSE, self.local_id, self.remote_id)
            self.conn.streams.pop(self.local_id, None)


class AdbConnection:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, banner: str):
        self.reader, self.writer, self.banner = reader, writer, banner
        self.streams: dict[int, Stream] = {}
        self.next_id = 1
        self.max_payload = MAX_PAYLOAD
        self.wlock = asyncio.Lock()
        self.peer = writer.get_extra_info("peername")

    async def send(self, cmd: int, arg0: int, arg1: int, data: bytes = b"") -> None:
        async with self.wlock:
            self.writer.write(pack(cmd, arg0, arg1, data))
            await self.writer.drain()

    async def run(self) -> None:
        log.info("CONN", "adb client connected", peer=f"{self.peer[0]}:{self.peer[1]}")
        try:
            while True:
                hdr = await self.reader.readexactly(HEADER.size)
                cmd, arg0, arg1, length, _crc, magic = HEADER.unpack(hdr)
                if magic != (cmd ^ 0xFFFFFFFF):
                    log.error("CONN", "bad magic, dropping connection", cmd=hex(cmd))
                    return
                data = await self.reader.readexactly(length) if length else b""
                await self.dispatch(cmd, arg0, arg1, data)
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass
        finally:
            for s in list(self.streams.values()):
                s.closed = True
                s.ack.set()
                await s.inbox.put(None)
            self.streams.clear()
            self.writer.close()
            log.info("CONN", "adb client disconnected", peer=f"{self.peer[0]}:{self.peer[1]}")

    async def dispatch(self, cmd: int, arg0: int, arg1: int, data: bytes) -> None:
        if cmd == A_CNXN:
            self.max_payload = min(MAX_PAYLOAD, arg1) if arg1 else MAX_PAYLOAD
            log.debug("CONN", "CNXN from host", version=hex(arg0), maxdata=arg1, banner=data.rstrip(b"\0").decode(errors="replace")[:80])
            await self.send(A_CNXN, A_VERSION, MAX_PAYLOAD, self.banner.encode() + b"\0")
        elif cmd == A_OPEN:
            service = data.rstrip(b"\0").decode(errors="replace")
            local_id, self.next_id = self.next_id, self.next_id + 1
            stream = Stream(self, local_id, arg0, service)
            self.streams[local_id] = stream
            await self.send(A_OKAY, local_id, arg0)
            log.debug("SVC", "stream opened", local_id=local_id, remote_id=arg0, service=service[:120])
            asyncio.create_task(self.serve(stream))
        elif cmd == A_WRTE:
            stream = self.streams.get(arg1)
            if stream:
                await stream.inbox.put(data)
                await self.send(A_OKAY, stream.local_id, stream.remote_id)
        elif cmd == A_OKAY:
            stream = self.streams.get(arg1)
            if stream:
                stream.ack.set()
        elif cmd == A_CLSE:
            stream = self.streams.get(arg1)
            if stream:
                stream.closed = True
                stream.ack.set()
                await stream.inbox.put(None)
                self.streams.pop(arg1, None)
                await self.send(A_CLSE, stream.local_id, stream.remote_id)
        elif cmd == A_AUTH:
            log.warn("CONN", "AUTH packet received but device runs without auth")
        else:
            log.warn("CONN", "unhandled adb command", cmd=NAMES.get(cmd, hex(cmd)))

    # ---------------------------------------------------------------- services
    async def serve(self, s: Stream) -> None:
        try:
            svc = s.service
            if svc.startswith("shell,"):          # shell v2 header, e.g. "shell,v2,pty,TERM=x:cmd"
                _, _, rest = svc.partition(":")
                await self.serve_shell(s, rest, pty_mode="pty" in svc.split(":")[0])
            elif svc.startswith("shell:"):
                await self.serve_shell(s, svc[len("shell:"):], pty_mode=(svc == "shell:"))
            elif svc.startswith("exec:"):
                await self.serve_shell(s, svc[len("exec:"):], pty_mode=False)
            elif svc == "sync:":
                await self.serve_sync(s)
            elif svc.startswith("root:"):
                await s.write(b"adbd is already running as root\n")
            elif svc.startswith("remount:"):
                await s.write(b"remount succeeded\n")
            elif svc.startswith("reboot:"):
                log.warn("SVC", "reboot requested via adb (ignored on bench)", arg=svc)
            elif svc.startswith("tcpip:") or svc.startswith("usb:"):
                await s.write(b"restarting in TCP mode port: 5555\n")
            else:
                log.warn("SVC", "unsupported service", service=svc[:80])
        except EOFError:
            pass
        except Exception as exc:  # noqa: BLE001
            log.error("SVC", "service crashed", service=s.service[:60], error=repr(exc))
        finally:
            await s.close()

    async def serve_shell(self, s: Stream, command: str, pty_mode: bool) -> None:
        env = dict(os.environ)
        env.update(ANDROID_ENV)
        argv = ["/bin/sh", "-c", command] if command else ["/bin/sh", "-i"]
        log.info("SHEL", "shell command", cmd=(command or "<interactive>")[:200])
        if pty_mode:
            master, slave = pty.openpty()
            def claim_tty():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)   # make the pty the controlling terminal (job control)

            proc = await asyncio.create_subprocess_exec(*argv, stdin=slave, stdout=slave, stderr=slave,
                                                        env=env, cwd="/", preexec_fn=claim_tty)
            os.close(slave)
            loop = asyncio.get_running_loop()
            master_r = os.fdopen(master, "rb", buffering=0)

            async def pump_out():
                try:
                    while True:
                        data = await loop.run_in_executor(None, master_r.read, 4096)
                        if not data:
                            break
                        await s.write(data)
                except OSError:
                    pass

            async def pump_in():
                while True:
                    data = await s.inbox.get()
                    if data is None:
                        break
                    try:
                        os.write(master, data)
                    except OSError:
                        break
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass

            out_task = asyncio.create_task(pump_out())
            in_task = asyncio.create_task(pump_in())
            await proc.wait()
            await asyncio.sleep(0.05)
            out_task.cancel()
            in_task.cancel()
            master_r.close()
        else:
            proc = await asyncio.create_subprocess_exec(*argv, stdin=asyncio.subprocess.PIPE,
                                                        stdout=asyncio.subprocess.PIPE,
                                                        stderr=asyncio.subprocess.STDOUT, env=env, cwd="/")

            async def pump_in():
                while True:
                    data = await s.inbox.get()
                    if data is None:
                        break
                    try:
                        proc.stdin.write(data)
                        await proc.stdin.drain()
                    except (BrokenPipeError, ConnectionResetError):
                        break

            in_task = asyncio.create_task(pump_in())
            while True:
                data = await proc.stdout.read(16384)
                if not data:
                    break
                await s.write(data)
            await proc.wait()
            in_task.cancel()

    async def serve_sync(self, s: Stream) -> None:
        while True:
            req_id = await s.read_exact(4)
            (length,) = struct.unpack("<I", await s.read_exact(4))
            path = (await s.read_exact(length)).decode(errors="replace") if length else ""
            if req_id == b"QUIT":
                return
            if req_id == b"STAT":
                try:
                    st = os.stat(path)
                    await s.write(b"STAT" + struct.pack("<III", st.st_mode, st.st_size & 0xFFFFFFFF, int(st.st_mtime)))
                except OSError:
                    await s.write(b"STAT" + struct.pack("<III", 0, 0, 0))
            elif req_id == b"LIST":
                try:
                    for name in sorted(os.listdir(path)):
                        st = os.lstat(os.path.join(path, name))
                        nb = name.encode()
                        await s.write(b"DENT" + struct.pack("<IIII", st.st_mode, st.st_size & 0xFFFFFFFF, int(st.st_mtime), len(nb)) + nb)
                except OSError:
                    pass
                await s.write(b"DONE" + struct.pack("<IIII", 0, 0, 0, 0))
            elif req_id == b"RECV":
                log.info("SYNC", "adb pull", path=path)
                try:
                    with open(path, "rb") as fh:
                        while True:
                            chunk = fh.read(64 * 1024)
                            if not chunk:
                                break
                            await s.write(b"DATA" + struct.pack("<I", len(chunk)) + chunk)
                    await s.write(b"DONE" + struct.pack("<I", 0))
                except OSError as exc:
                    msg = str(exc).encode()
                    await s.write(b"FAIL" + struct.pack("<I", len(msg)) + msg)
                    return
            elif req_id == b"SEND":
                target, _, mode = path.rpartition(",")
                log.info("SYNC", "adb push", path=target, mode=mode)
                os.makedirs(os.path.dirname(target) or "/", exist_ok=True)
                try:
                    fh = open(target, "wb")
                except OSError as exc:
                    msg = str(exc).encode()
                    # drain until DONE
                    while True:
                        cid = await s.read_exact(4)
                        (n,) = struct.unpack("<I", await s.read_exact(4))
                        if cid == b"DONE":
                            break
                        await s.read_exact(n)
                    await s.write(b"FAIL" + struct.pack("<I", len(msg)) + msg)
                    return
                with fh:
                    while True:
                        cid = await s.read_exact(4)
                        (n,) = struct.unpack("<I", await s.read_exact(4))
                        if cid == b"DONE":
                            break
                        if cid == b"DATA":
                            fh.write(await s.read_exact(n))
                        else:
                            break
                try:
                    os.chmod(target, int(mode) & 0o777 or 0o644)
                except (ValueError, OSError):
                    pass
                await s.write(b"OKAY" + struct.pack("<I", 0))
            else:
                msg = b"unknown sync command"
                await s.write(b"FAIL" + struct.pack("<I", len(msg)) + msg)
                return


async def serve_adb(host: str = "0.0.0.0", port: int = 5555) -> None:
    props = {}
    try:
        with open("/system/build.prop", encoding="utf-8") as fh:
            for line in fh:
                if "=" in line and not line.startswith("#"):
                    k, v = line.strip().split("=", 1)
                    props[k] = v
    except OSError:
        pass
    banner = ("device::ro.product.name={};ro.product.model={};ro.product.device={};".format(
        props.get("ro.product.name", "aaos_tcu"), props.get("ro.product.model", "TCU-GW-2"),
        props.get("ro.product.device", "tcu_gw2")))

    async def on_client(reader, writer):
        await AdbConnection(reader, writer, banner).run()

    server = await asyncio.start_server(on_client, host, port)
    log.info("MAIN", "adbd listening", port=port, banner=banner)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(serve_adb())
