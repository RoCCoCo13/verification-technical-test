"""Render a Robot Framework run as a GitHub Actions step summary.

    python3 tools/ci_summary.py results/output.xml >> "$GITHUB_STEP_SUMMARY"

The summary names the failing tests and states plainly that a red run is the
expected outcome on this release, so nobody reads the red badge as a broken
pipeline and stops looking. Standard library only: it runs on the runner
itself, so it still works when the bench or the suite did not.
"""
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ci_summary.py <output.xml>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"## Regression suite: no report at {path}")
        return 0

    root = ET.parse(path).getroot()
    stat = root.find("statistics/total/stat")
    passed = int(stat.get("pass", 0)) if stat is not None else 0
    failed = int(stat.get("fail", 0)) if stat is not None else 0
    skipped = int(stat.get("skip", 0)) if stat is not None else 0

    print(f"## Regression suite: {passed} passed, {failed} failed, {skipped} skipped")
    print()

    failures = []
    for test in root.iter("test"):
        status = test.find("status")
        if status is not None and status.get("status") == "FAIL":
            reason = (status.text or "").strip().splitlines()
            failures.append((test.get("name", "<unnamed>"), reason[0] if reason else ""))

    if failures:
        print("### Failing tests")
        print()
        print("| Test | First line of the failure |")
        print("|---|---|")
        for name, reason in failures:
            # Escape the table separator outside the f-string: a backslash inside an
            # f-string expression is a syntax error before Python 3.12.
            cell = reason.replace("|", r"\|")[:160]
            print(f"| {name} | {cell} |")
        print()

    skips = [t.get("name", "<unnamed>") for t in root.iter("test")
             if (s := t.find("status")) is not None and s.get("status") == "SKIP"]
    if skips:
        print("### Not exercised")
        print()
        for name in skips:
            print(f"- {name}")
        print()

    if failed:
        print("> A red run is the **expected** result on release TCU_GW2_SW_4.12.0: the suite")
        print("> detects open defects in the software under test, not problems with itself.")
        print("> See `docs/rca/` for the analyses and the release verdict in")
        print("> `docs/TEST_STRATEGY.md`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
