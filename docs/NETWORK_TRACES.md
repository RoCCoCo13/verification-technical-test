# Network Traces (PCAP)

## Where traces come from

| Location | Produced by | Vantage point | Content |
|---|---|---|---|
| `traces/pcap/live/tcu_*.pcap` | `capture-tcu` (always on, 2-minute files) | gateway network namespace | backend -> gateway HTTP, gateway -> backend HTTP callbacks, gateway <-> body-ecu gRPC. **Not** your own REST calls from the host. |
| `traces/pcap/live/cloud_*.pcap` | `capture-cloud` (always on) | backend namespace | your REST calls, backend -> gateway, gateway callbacks |
| `traces/pcap/scenarios/<label>/*.pcap` | `docker compose run --rm scenario-runner` | gateway namespace, **with the client inside it**: all three legs in one file | one file per scripted scenario + `run_summary.json` (timeline with request ids) |
| `traces/reference/*.pcap` | validation team | same as scenarios, on a bench whose behaviour was accepted as correct | golden traces to compare against |
| `traces/samples/*.pcap` | validation team | same scenarios recorded on **this** build | fallback if you cannot capture yourself |

ADB traffic (port 5555) is filtered out of all captures.

Run selected scenarios: `docker compose run --rm -e SCENARIO_ONLY=S01,S03 -e SCENARIO_LABEL=myrun scenario-runner`.

## Scenarios

| Id | Steps |
|---|---|
| S01_lock_unlock_cycles | 5 x (unlock, lock) with command polling, then status |
| S02_climate_preconditioning | climate start 22.5 degC, status, unlock, status, climate stop |
| S03_charging_session | charging start (target 60), status, charging stop, status x2 |
| S04_api_validation | request without key, unknown command id, climate start at 16.0 / 28.0 / 35.0, status, stop |

## Decoding

Ports: 8000 backend REST, 8081 telematics receiver (HTTP/1.1), 50051 gRPC (HTTP/2 without TLS).
Wireshark decodes 8000/8081 as HTTP automatically. For gRPC add a *Decode As* rule: TCP port 50051
-> HTTP2, and (optional) load `env/proto/vehicle_ecu.proto` under Preferences > Protocols >
Protobuf > search paths, then enable "Dissect Protobuf fields as Wireshark fields".

tshark equivalents:

```bash
# gRPC method calls with time and stream id
tshark -r S01_lock_unlock_cycles.pcap -d tcp.port==50051,http2 -Y "http2.headers.path" \
       -T fields -e frame.time_relative -e ip.src -e http2.streamid -e http2.headers.path

# streams cancelled by the client (RST_STREAM = http2.type 3)
tshark -r S01_lock_unlock_cycles.pcap -d tcp.port==50051,http2 -Y "http2.type==3" \
       -T fields -e frame.time_relative -e ip.src -e http2.streamid

# HTTP/1.1 requests and server response time
tshark -r S03_charging_session.pcap -Y "http.response" -T fields -e tcp.stream -e http.response.code -e http.time
tshark -r S03_charging_session.pcap -Y "http.request"  -T fields -e tcp.stream -e http.request.method -e http.request.uri
```

The gateway sends literal (uncompressed) HTTP/2 headers, so captures that start mid-connection still
decode. Every gRPC request carries the backend `request_id` inside the protobuf payload; with the
`.proto` loaded you can filter on it.

## What to look for

* Request flow: one REST command -> one `POST /telematics/command` -> one gRPC call -> one result
  callback -> one state report. Count them.
* Missing messages: a REST command without a matching gRPC call.
* Timing: time between the gRPC HEADERS frame from the gateway and the first HEADERS frame back from
  the ECU, and `RST_STREAM` frames (who sent them, when, how long after the request).
* Compare with `traces/reference/` for the same scenario.
