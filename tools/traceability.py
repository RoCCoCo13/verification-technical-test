"""Regenerate the requirement traceability matrix from a Robot Framework run.

The matrix in docs/TEST_STRATEGY.md is derived, not maintained by hand: every
test carries ``req:<REQ-id>`` tags, so the mapping from requirement to test
case and to verdict lives in the suite itself and cannot drift from it.

    python tools/traceability.py results/output.xml
    python tools/traceability.py results/output.xml --requirements docs/REQUIREMENTS.md

With ``--requirements`` the script also reports requirements that have **no**
test, which is the number that matters when judging coverage: a matrix built
only from the tests that exist can never reveal a gap.

Exit code 1 if any requirement in docs/REQUIREMENTS.md has no test, so CI can
gate on coverage rather than only on results.
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

REQ_TAG = re.compile(r"^req:(?P<id>REQ-[A-Z]+-\d+)$", re.IGNORECASE)
REQ_IN_DOC = re.compile(r"\b(REQ-[A-Z]+-\d+)\b")


def collect_tests(output_xml: Path) -> dict[str, list[tuple[str, str]]]:
    """Map each requirement id to the (test name, status) pairs covering it."""
    root = ET.parse(output_xml).getroot()
    coverage: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for test in root.iter("test"):
        name = test.get("name", "<unnamed>")
        status_el = test.find("status")
        status = status_el.get("status", "UNKNOWN") if status_el is not None else "UNKNOWN"
        for tag in test.iter("tag"):
            match = REQ_TAG.match((tag.text or "").strip())
            if match:
                coverage[match.group("id").upper()].append((name, status))
    return coverage


def declared_requirements(requirements_md: Path) -> list[str]:
    """Return the requirement ids declared in the requirements document, in order."""
    seen: list[str] = []
    for match in REQ_IN_DOC.finditer(requirements_md.read_text(encoding="utf-8")):
        if match.group(1) not in seen:
            seen.append(match.group(1))
    return seen


def verdict(results: list[tuple[str, str]]) -> str:
    """A requirement passes only if every test covering it passed."""
    statuses = {status for _, status in results}
    if "FAIL" in statuses:
        return "FAIL"
    if statuses == {"SKIP"}:
        return "NOT EXERCISED"
    return "PASS"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output_xml", type=Path, help="Robot Framework output.xml")
    parser.add_argument("--requirements", type=Path, default=Path("docs/REQUIREMENTS.md"),
                        help="requirements document, to detect uncovered requirements")
    args = parser.parse_args()

    if not args.output_xml.is_file():
        print(f"error: {args.output_xml} not found", file=sys.stderr)
        return 2

    coverage = collect_tests(args.output_xml)
    declared = declared_requirements(args.requirements) if args.requirements.is_file() else []
    order = declared or sorted(coverage)

    print("| Requirement | Test case(s) | Verdict |")
    print("|---|---|---|")
    uncovered = []
    for req in order:
        results = coverage.get(req, [])
        if not results:
            uncovered.append(req)
            print(f"| {req} | *(none)* | **NO TEST** |")
            continue
        names = "; ".join(name for name, _ in results)
        print(f"| {req} | {names} | {verdict(results)} |")

    extra = sorted(set(coverage) - set(order))
    for req in extra:
        results = coverage[req]
        names = "; ".join(name for name, _ in results)
        print(f"| {req} (not in requirements document) | {names} | {verdict(results)} |")

    covered = len(order) - len(uncovered)
    print()
    print(f"Coverage: {covered} of {len(order)} declared requirements have at least one test.")
    if uncovered:
        print(f"Requirements with no test: {', '.join(uncovered)}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
