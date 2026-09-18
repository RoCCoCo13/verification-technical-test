# Submission — Automation & Validation Engineer technical assessment

**Ale Mendez** · release under validation: gateway `TCU_GW2_SW_4.12.0`, backend `CVB_API_1.8.3`,
Body ECU `BCM4_SW_2.7.1` · 2026-09-18

This is the entry point for my work. The bench README and the bench documentation under `docs/` are
unchanged; everything below describes what I added.

---

## 1. Verdict in one paragraph

**Do not release to vehicle testing.** The automated suite covers all 25 requirements and finds
**six defects**, two of them S2. Remote charging **cannot be stopped** — the command is discarded
inside the gateway, never reaches a terminal state, and the vehicle keeps charging. Central locking
reports **`FAILED` on 42.5 % of commands while the doors actuate anyway**, so the cloud's belief
about whether the car is secured is wrong on a large fraction of operations. The supplier's declared known issue
KI-217 was measured over two independent samples and **confirmed as not a defect** (4.84 % and
6.56 %, against a 10 % limit). Full reasoning
and exit criteria: `docs/TEST_STRATEGY.md` §7.

---

## 2. How to run it

### Locally — the supported path (nothing to install but Docker)

The suite runs inside the bench's own `toolbox` container, which already ships `adb`, `tshark`,
Robot Framework and `grpcio`, and sits on the vehicle network. **No host tooling is required** — not
even `adb`.

```bash
# 1. start the bench
docker compose up -d --build --wait

# 2. capture the end-to-end scenarios (needed by the 05_network suite)
docker compose run --rm --no-deps -e SCENARIO_LABEL=ci scenario-runner

# 3. run the full suite
docker compose run --rm --no-deps toolbox \
  robot --pythonpath robot/libraries \
        --variablefile robot/variables/bench_toolbox.py \
        --outputdir results \
        robot/tests
```

Reports land in `results/` (`report.html`, `log.html`, `output.xml`).

> **Run step 2 to completion before step 3.** The captures are taken inside the gateway's *network
> namespace*, so a capture records everything the gateway does. Overlapping the two puts the suite's
> own traffic into the scenario captures. I made exactly this mistake during development — see §6.

Useful subsets:

```bash
# smoke only (~20 s)
docker compose run --rm --no-deps toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results robot/tests/01_smoke

# everything except the slow measurement campaigns (~3 min instead of ~12)
docker compose run --rm --no-deps toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results --exclude slow robot/tests

# one requirement
docker compose run --rm --no-deps toolbox robot --pythonpath robot/libraries \
  --variablefile robot/variables/bench_toolbox.py --outputdir results \
  --include req:REQ-CHG-002 robot/tests
```

### Locally — from the host

Only if you want to drive the suite from an IDE. Requires `adb`, `tshark` and
`pip install -r requirements.txt`:

```bash
robot --pythonpath robot/libraries --variablefile robot/variables/bench_local.py \
      --outputdir results robot/tests
```

`bench_local.py` defaults to `http://localhost:8800` — see the port note in §3.

### In CI

`.github/workflows/validation.yml` runs on every push and pull request. It starts the bench, waits
for the first vehicle state report, captures the scenarios, runs the suite in the toolbox container,
and **always** uploads `report.html`, `log.html`, `output.xml`, `xunit.xml`, the three `.dlt` logs
and the scenario PCAPs. No manual step, no self-hosted runner, no secrets.

**The pipeline is red, and that is the correct result.** It is red because the suite detects real
open defects, which `docs/DELIVERABLES.md` states is the expected outcome. The job summary says so
explicitly on every run so the red badge is never mistaken for a broken pipeline.

---

## 3. Changes to the bench, and why

The bench sources (`env/`, `docker-compose.yml`, `docs/*.md` as delivered, `templates/`, `starter/`)
are **unmodified**. The first commit of this repository is the bundle exactly as received, so
everything I did is reviewable as a diff against it.

| Change | Why |
|---|---|
| `.env`: `BACKEND_PORT=8800` | Port 8000 was already taken on my workstation by an unrelated service. This is the mechanism `.env.example` and `docs/TROUBLESHOOTING.md` prescribe; no bench source was touched. **It does not affect the suite or CI**: tests address nodes by Compose service name from inside the vehicle network, so they use `backend:8000` regardless. Only `bench_local.py` (host execution) reflects it. `.env` itself is not committed. |
| Added `.gitignore` | Keeps `.env` (which holds a token on my machine) and generated artefacts out of the repository. |
| Added `.gitattributes` | Forces LF in the working tree. The bench's shell entrypoints and Android `/system/bin` stubs run inside Linux containers, and a CRLF checkout on Windows would break the image build. |

Nothing else was added to, removed from or edited in the bench.

---

## 4. What I added

```
SUBMISSION.md                    this file
requirements.txt                 pinned, matching the toolbox image
.github/workflows/validation.yml CI pipeline
docs/TEST_STRATEGY.md            strategy, risks, traceability, release verdict
docs/KI-217-VERIFICATION.md      measurement of the supplier's declared known issue
docs/rca/RCA-001..006-*.md       one RCA per root cause
docs/rca/evidence/               log extracts the RCAs quote
robot/libraries/                 AdbLibrary, BodyEcuLibrary, DltLogLibrary,
                                 PcapLibrary, ScenarioLibrary
robot/resources/                 bench, rest_api, adb, body_ecu, logs, pcap
robot/variables/                 bench_toolbox.py (default, CI), bench_local.py (host)
robot/tests/                     01_smoke 02_api 03_e2e 04_diagnostics 05_network
tools/traceability.py            regenerates the requirement matrix from output.xml
tools/ci_summary.py              renders the run as a CI job summary
results/                         report.html, log.html, output.xml, xunit.xml
```

**Where to look first:** `docs/TEST_STRATEGY.md` for the approach and the verdict, then
`docs/rca/RCA-001-charging-stop-silently-dropped.md` for the most serious defect analysed at four
interfaces.

### Three design decisions worth a sentence each

- **The Body ECU is the primary oracle, not the REST API.** The cloud reports the user's *request*
  as vehicle state (RCA-004), so a suite that trusted `/vehicle/status` would have passed the climate
  domain. Cross-interface comparison is what made two defects visible at all.
- **Intermittent behaviour is measured, never retried.** Campaigns collect N samples and assert on
  the resulting rate, so the report says *"17 of 40 commands failed (42.5 %), reason `ECU_TIMEOUT`"*
  rather than going green on a lucky run. `Wait Until Keyword Succeeds` is used only where the value
  polled is monotonic for a single command.
- **Log assertions are scoped to a `since` mark** taken at each suite's reset. The `.dlt` files
  append across bench restarts; without the scope, REQ-LOG-002 could never pass on a bench that had
  been running.

---

## 5. Assumptions

1. **`traces/reference/` is a trustworthy baseline.** Every network finding is measured identically
   on the golden capture, and each control is a **test in its own right**, so if the reference ever
   stopped being clean the suite would say so rather than silently comparing against a bad baseline.
2. **The four bench scenarios represent nominal use.** REQ-LOG-002's "nominal flow" is exercised as
   five passes of each documented happy path — five rather than one so the verdict does not depend
   on whether an intermittent fault happened to fire during a single pass.
3. **`GNSS` and `NET` gateway contexts are background noise**, per `docs/ARCHITECTURE.md`, and are
   excluded from the REQ-LOG-002 ERROR check. No other context is excluded.
4. **Absolute timings are bench-specific.** The bench is containerised, so latency *ratios* and
   *patterns* transfer to target hardware but absolute milliseconds do not. This is stated in the
   KI-217 note rather than glossed over.
5. **The supplier's requirement wording is authoritative** where it conflicts with observed intent.
   RCA-004 and RCA-005 are reported as defects against the requirements as written, while flagging
   that the correct resolution for RCA-005 may be a requirement change rather than a code change.

---

## 6. Honest notes

**A mistake I made and corrected, because it changed a result.** An intermediate run reported *"2
climate commands from the cloud produced 14 SetClimate calls on the backbone"*, which looks like a
serious product defect. It was not. I had started the regression suite while the scenario runner was
still capturing, and because the captures are taken in the gateway's network namespace, the suite's
own traffic landed in the scenario file. File timestamps confirmed it. I fixed it twice over: the
process is now serialised, and more importantly the test no longer depends on an exclusive namespace
— each command is correlated by its `request_id`, which the gateway embeds in the gRPC payload, so
the result holds whatever else is talking to the bench. Commit `e5bf566`.

I mention it because distinguishing a test artefact from a product defect is the core skill this
exercise is testing, and I got it wrong once before getting it right.

**Known limitations of what I delivered.**

- The `03_e2e` and `04_diagnostics` suites take ~12 minutes because the measurement campaigns are
  deliberately not shortcut. `--exclude slow` trades coverage for speed.
- `A Failed Lock Command Leaves The Vehicle State Untouched` **skips** rather than passes if no
  failure occurs in its sample. A clean sample proves nothing about that clause and must not be
  reported as evidence that it holds.
- The ADB library shells out to the `adb` binary rather than speaking the wire protocol. It is
  sufficient here and keeps the library readable.
- I did not test TLS, OTA, HMI behaviour, or load beyond the stated latency budgets — out of scope
  per `docs/TEST_STRATEGY.md` §1.

**The delivered run:** `results/` holds a real run against this bench — **50 tests, 36 passed,
14 failed**, every failure traceable to one of the six RCAs. Requirement coverage is 25 of 25
(`python tools/traceability.py results/output.xml`).

**Two late corrections worth recording**, both found by reading the delivered reports rather than by
being told:

- `Nominal Flows Produce No Errors In The Gateway Log` (REQ-LOG-002) passed on one run and failed on
  another. That was my test being sample-dependent, not the product changing: it only sees an ERROR
  when a lock command happens to exceed the deadline, so a single nominal pass cleared roughly half
  the time. It now drives five passes and asserts once on everything collected. A gate that flips
  between runs is worse than no gate.
- `Lock Command Locks The Doors On Every Interface` (REQ-LCK-001) was asserting the command
  *outcome*, which belongs to REQ-LCK-003. That mis-attributed RCA-002 to the wrong requirement and
  made REQ-LCK-001 flip with the same intermittency. REQ-LCK-001/002 now own the resulting vehicle
  state and REQ-LCK-003 owns the reported outcome and the consistency between them, which is what
  the requirements actually say.

**Time spent:** approximately 4 hours, within the suggested 3–5 hour window.

---

## 7. Use of AI

I used Claude (Opus 5) throughout, as the assessment invites, and I own the result.

**What it did:** drafted the Robot resource and library scaffolding and the keyword documentation;
worked out the `tshark` field syntax for HTTP/2 frame filtering and `RST_STREAM` correlation; wrote
the first drafts of the strategy and RCA prose.

**What it did not do:** find the defects. Every finding came from running the suite against the bench
and reading the output. I consulted `env/` only *after* observing a symptom, to name the parameter
behind it — the assessment rules make that distinction explicit, and the commit history shows the
order: the defect appears in a test result first, the calibration parameter is named afterwards.

**Where I had to correct it**, since that is the more useful half of this note:

- It produced Robot `Log` statements whose message text was aligned with two spaces, which Robot
  parses as an argument separator — the dict landed in the `level` parameter and the test errored
  with `'dict' object has no attribute 'upper'`. Found by running the suite.
- Its first `RST_STREAM` analysis counted **6** cancelled streams where the correct answer for
  REQ-NET-001 is **5**: when the gateway abandons a call, the Body ECU resets the same stream in
  response, and attributing the ECU's answer to the gateway overstates the finding. Corrected after
  reading the frames, by filtering on the source address.
- A failure message used an inline Python expression containing quotes, which broke Robot's variable
  parser. Moved into the library.
- It initially proposed counting gRPC calls per method for the message-accounting tests, which is the
  fragile design described in §6.

Every number in the strategy and the RCAs was re-verified against the delivered artefacts in
`results/` and `traces/` before I wrote it down; the `tshark` commands quoted in the RCAs were
re-executed to confirm they reproduce.
