"""Robot Framework keywords for the scenario runner's timeline (``run_summary.json``).

Each scenario capture ships with a JSON timeline listing every REST call the
runner made, with its ``request_id``, HTTP status and the command/vehicle state
observed (docs/NETWORK_TRACES.md). Pairing that timeline with the PCAP is what
turns "how many gRPC calls are in this file" into "did *this* command reach the
Body ECU", which is the question the requirements actually ask.

That distinction matters on this bench: the captures are taken inside the
gateway's **network namespace**, so a capture records every packet the gateway
exchanges, including traffic from anything else talking to the bench at the
same time. Counting totals is therefore only sound while the capture has the
bench to itself. Correlating by ``request_id`` is sound either way.
"""
from __future__ import annotations

import json
from pathlib import Path

from robot.api import logger
from robot.api.deco import keyword, library


@library(scope="GLOBAL", version="1.0")
class ScenarioLibrary:
    """Read the scenario runner's timeline and pair it with the captures."""

    @keyword("Get Scenario Summary")
    def get_scenario_summary(self, summary_path: str) -> dict:
        """Return the parsed ``run_summary.json`` of a scenario run."""
        path = Path(summary_path)
        if not path.is_file():
            raise AssertionError(
                f"scenario timeline not found at {path}; run "
                f"'docker compose run --rm -e SCENARIO_LABEL=ci scenario-runner' first"
            )
        return json.loads(path.read_text(encoding="utf-8"))

    @keyword("Get Scenario Commands")
    def get_scenario_commands(self, summary_path: str, scenario: str,
                              path_contains: str | None = None) -> list[dict]:
        """Return the accepted remote commands of one scenario.

        Only REST calls that the backend accepted (HTTP 200 with a
        ``request_id``) are returned, because only those are commands the
        vehicle was expected to act on -- a request rejected with 401 or 422
        must *not* produce a call on the backbone, and counting it as one
        would invert the meaning of the test.

        ``path_contains`` narrows to one domain, e.g. ``/charging/``.
        Each entry: ``t``, ``path``, ``request_id``, ``http``, ``status``.
        """
        summary = self.get_scenario_summary(summary_path)
        scenarios = summary.get("scenarios", {})
        if scenario not in scenarios:
            raise AssertionError(
                f"scenario {scenario!r} is not in {summary_path}; present: {sorted(scenarios)}")
        commands = []
        for event in scenarios[scenario].get("events", []):
            if event.get("kind") != "REST" or not event.get("request_id"):
                continue
            if event.get("http") != 200:
                continue
            if path_contains and path_contains not in event.get("path", ""):
                continue
            commands.append(event)
        logger.info(f"{len(commands)} accepted commands in {scenario}"
                    + (f" matching {path_contains}" if path_contains else ""))
        return commands

    @keyword("Get Scenario Label")
    def get_scenario_label(self, summary_path: str) -> str:
        """Return the label the capture run was recorded under."""
        return self.get_scenario_summary(summary_path).get("label", "unknown")
