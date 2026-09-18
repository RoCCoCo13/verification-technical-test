# Reference (golden) traces

Recorded with the scenario runner on a bench whose behaviour the validation team accepted as correct
(same scenarios, same topology, same vantage point as `traces/pcap/scenarios/`). Use them as the
"expected" side when comparing message flows and timing with your own captures of this build.

| File | Scenario |
|---|---|
| `S01_lock_unlock_cycles.pcap` | 5 x unlock/lock with command polling |
| `S02_climate_preconditioning.pcap` | climate start 22.5 degC, unlock, climate stop |
| `S03_charging_session.pcap` | charging start (target 60), stop |
| `S04_api_validation.pcap` | auth/404/boundary requests |
| `run_summary.json` | timeline of the REST calls with request ids and the status observed |

Decode TCP 50051 as HTTP2 (see `docs/NETWORK_TRACES.md`).
