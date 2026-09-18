# Sample traces of this build

Same four scenarios as `traces/reference/`, recorded on **this** software release, in case you cannot
run the scenario runner on your machine. Prefer your own captures when you can: `docker compose run --rm scenario-runner`.

`run_summary.json` lists every REST call with its request id, HTTP status and the command/vehicle
status observed, so you can correlate PCAP frames with `traces/logs/*.dlt` lines.
