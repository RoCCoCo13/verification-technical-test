# Deliverables and Suggested Repository Layout

## Checklist (submit all)

- [ ] `SUBMISSION.md` (or a clearly marked section in a README): how to run your suite (host and CI), assumptions, time spent, AI usage note
- [ ] `docs/TEST_STRATEGY.md` (1-3 pages)
- [ ] Robot Framework project with `tests/`, `resources/`, `variables/` (and `libraries/` if you wrote Python keywords)
- [ ] Tests tagged with requirement ids
- [ ] `.github/workflows/<name>.yml` (or equivalent) that starts the bench, runs the suite and uploads `report.html`, `log.html`, `output.xml`
- [ ] `results/` with `report.html`, `log.html`, `output.xml` from a run against this bench
- [ ] `docs/rca/RCA-001.md` (at least one), with the evidence files it references (log excerpts, pcap)
- [ ] Bench sources (`env/`, `docker-compose.yml`) unmodified, or modifications documented

## Suggested layout

Work **inside the unzipped bundle** and turn that folder into your Git repository, so the bench and your
work travel together and your pipeline can start the bench with `docker compose up` from the repository root:

```
vehicle-bench-candidate-<date>/          <- git init here
├── README.md                             bench README (unchanged)
├── SUBMISSION.md                         YOUR entry point: how to run, assumptions, time spent, AI usage
├── docker-compose.yml, env/, traces/     bench (unchanged; traces/logs and traces/pcap are runtime output)
├── docs/
│   ├── *.md                              bench docs (unchanged)
│   ├── TEST_STRATEGY.md                  yours
│   └── rca/
│       ├── RCA-001-<short-title>.md      yours
│       └── evidence/                     log excerpts, pcap, screenshots
├── requirements.txt                      your Python dependencies, pinned
├── .github/workflows/validation.yml      your pipeline
├── robot/
│   ├── tests/                            01_smoke/ 02_api/ 03_e2e/ 04_diagnostics/ ...
│   ├── resources/                        one resource file per interface: rest_api, adb, body_ecu, logs, pcap
│   ├── variables/                        bench_local.py, bench_ci.py
│   └── libraries/                        Python keyword libraries (optional)
└── results/
    ├── report.html
    ├── log.html
    └── output.xml
```

If you prefer to keep the bench in a sub-folder (e.g. `bench/`), that is fine too: just make sure your
README and pipeline state where `docker compose` must be run from.

## Robot Framework expectations

* No hard-coded URLs, serials or credentials in test cases; use variable files and `--variablefile`.
* Keywords named as actions in the domain language (`Lock Vehicle`, `Wait Until Body Ecu Reports`), documented with `[Documentation]`.
* Suite/test setup restores a known state; suites are order independent.
* Intermittent behaviour is measured (collect N samples, then assert), not hidden by retrying until green.
* Tags: at least `req:<id>` per test; optional `smoke`, `slow`, interface tags.
* Use `Wait Until Keyword Succeeds` with justified timeouts (the state sync period is 5 s).

## CI expectations

* Runs on push/PR without manual steps.
* Starts the bench with `docker compose up -d --wait`, runs Robot, always uploads the three report files.
* Red when a test fails. (A red pipeline because your tests found real defects is the correct result here.)

## RCA expectations

Use `templates/RCA_TEMPLATE.md`. A convincing RCA states: the requirement violated, how to reproduce,
what was observed at each interface (API, ADB, logs, trace), the causal chain to the root cause
(component, parameter or logic), the impact, and a recommendation. Quote log lines and cite PCAP
frame numbers or times. Distinguish facts from hypotheses.
