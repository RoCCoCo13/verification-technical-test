# Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker compose up` fails with `error mounting ... to rootfs at "/data/log/dlt" ... no such file or directory` (or the same for `/var/log/dlt`, `/traces`) | Docker Desktop (WSL2/macOS) kept a stale bind-mount entry: the bench folder was deleted, moved or re-unzipped **while containers from it were still running**. Run `docker compose down --remove-orphans`, then `docker compose up -d --wait`. If it persists, restart Docker Desktop. Always `docker compose down` before deleting or replacing the folder. |
| `port is already allocated` on 8000/5555/50051/8081 | Another service (an Android emulator uses 5555!). Copy `.env.example` to `.env` and change the port, then `docker compose up -d`. Remember to use the new port in `adb connect`. |
| `adb connect localhost:5555` says `Connection refused` **inside the toolbox container** | Inside a container `localhost` is the container itself. Use the service names: `adb connect ecu-gateway:5555`, `http://backend:8000`, `body-ecu:50051` (the toolbox shell prints them and pre-connects adb). |
| `adb connect localhost:5555` fails **on your host** | Bench not up (`docker compose ps`), or port changed in `.env`. Check `docker compose ps` shows `0.0.0.0:5555->5555/tcp` on `ecu-gateway`. |
| `adb: command not found` on your host | Install Android platform-tools, or use `docker compose run --rm toolbox`. |
| `adb devices` shows `offline` | Run `adb kill-server && adb connect localhost:5555`. |
| `adb shell` prints nothing for a command | The command failed silently (no exit code forwarding). Run `adb shell "cmd; echo rc=$?"`. |
| REST returns 401 | Missing `X-API-Key: dev-key-001` header. |
| REST returns 503 `vehicle unreachable` | Gateway container down or restarting: `docker compose logs ecu-gateway`. |
| `/vehicle/status` has `source: none` | No state report received yet; wait 5 s after start. |
| Vehicle state looks stale between tests | Use `POST /bench/reset` in your suite setup. |
| PCAP files owned by root on Linux | tcpdump runs as root in the container. Use `docker compose run --rm toolbox rm -rf /traces/pcap/live/*` or `sudo`. |
| Wireshark shows gRPC as plain TCP | Add *Decode As*: TCP 50051 -> HTTP2. |
| No `traces/pcap/live` files | Docker Desktop on Windows/macOS: bind-mount permissions. Check `docker compose logs capture-tcu`. |
| Windows: `make` not available | Use the `docker compose` commands directly; the Makefile only wraps them. |
| Slow first start | Image build (~2-4 min). Subsequent starts take seconds. |
| Logs keep growing across restarts | `.dlt` files append. Note the timestamp of your reset, or delete `traces/logs/*` while the bench is down. |
| Robot cannot import `grpc` | `pip install grpcio grpcio-tools` (see `starter/requirements.txt`) or run inside the toolbox. |

Collect diagnostics for a support request: `docker compose ps; docker compose logs --tail=100 > bench.log`.
