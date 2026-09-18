# KI-217 — verification of a supplier-declared known issue

| Field | Value |
|---|---|
| Known issue | **KI-217**, declared in `/vendor/etc/release_notes.txt` |
| Supplier's text | *"Body ECU heartbeat occasionally exceeds 100 ms on the bench (scheduler contention on the BCM-4 simulator). Cosmetic, no functional impact."* |
| Requirement | REQ-ECU-001 — *"latency above 100 ms shall be logged as WARN … latency warnings shall affect at most 10 % of heartbeats"* |
| Build | TCU_GW2_SW_4.12.0 / CVB_API_1.8.3 / BCM4_SW_2.7.1 |
| **Outcome** | **Claim substantiated across two independent samples. Not a defect.** Retained as a watch item. |

This is deliberately **not** an RCA. `docs/REQUIREMENTS.md` instructs "Verify the claim", and the
measurement supports it. Writing a root cause analysis for a non-defect would misrepresent the
result; reporting the measured number either way is the result.

---

## 1. Why this needed measuring at all

A declared known issue is a claim by the supplier, not an accepted deviation. Two things had to be
established independently before it could be closed:

1. **"Occasionally" is not a quantity.** REQ-ECU-001 sets a numeric limit — at most 10 % of
   heartbeats — and only a measured rate can be compared against it.
2. **"No functional impact" is a separate claim from "rare".** Even a rate inside the limit would
   matter if it tripped the three-consecutive-miss supervision that marks the ECU offline.

Accepting the note without measuring would have left an untested requirement in the matrix.

## 2. Method

REQ-ECU-001 is a *rate*, so it needs a population, not an anecdote. The gateway logs **every**
heartbeat with its measured latency — at `DEBUG` when within threshold and at `WARN` when above it:

```
2026-09-18T07:37:51.530321Z 001009.536 TCU1 TCU  HB   DEBUG 0x0418 heartbeat ok seq=496 latency_ms=17
2026-09-18T07:21:34.682124Z 000032.613 TCU1 TCU  HB   WARN  0x001E heartbeat latency above threshold seq=17 latency_ms=164 threshold_ms=100 ecu_sw=BCM4_SW_2.7.1
```

so the sample collected is the **complete population** over the window, not just the outliers.
Counting only `WARN` lines would have given a rate with no denominator.

The test opens a log window, waits until at least 60 heartbeats have been logged (~2 minutes at the
2 s period), then computes the rate and asserts **once**. The waiting is for the sample to fill, not
a retry: no repetition can change the outcome.

Test: `Heartbeat Latency Warnings Stay Within The Accepted Rate`
(`robot/tests/04_diagnostics/ecu_supervision.robot`, tagged `req:REQ-ECU-001`).

## 3. Result

Delivered run (`results/output.xml`), with an independent earlier run alongside it:

| Metric | Delivered run | Earlier run | Limit | Verdict |
|---|---|---|---|---|
| Sample size | 62 heartbeats | 61 heartbeats | — | — |
| Heartbeats above 100 ms | 3 | 4 | — | — |
| **Warning rate** | **4.84 %** | **6.56 %** | ≤ 10 % (REQ-ECU-001) | **within limit** |
| Minimum latency | 5 ms | 2 ms | — | — |
| Mean latency | 26.9 ms | 27.5 ms | — | — |
| Maximum latency | 228 ms | 192 ms | — | — |
| Heartbeat period | 2.027 s over 14 intervals | 2.042 s over 14 | 2 s | within tolerance |
| Consecutive misses | 0 | 0 | 3 marks the ECU offline | never approached |

Two samples taken hours apart agree on the conclusion and bracket the rate at roughly 5–7 %, which
is what makes the verdict quotable rather than a single lucky measurement.

The gateway reported the Body ECU as online throughout (`BODY_ECU_ONLINE=True` in the VHAL mirror,
`ecu_online: true` at `/vehicle/status`), and the backbone capture shows the heartbeat calls
arriving as expected. **No functional impact was observed.**

## 4. Assessment

**The supplier's claim is supported by evidence.** The rate is inside the requirement, the
supervision mechanism was never close to tripping, and no dependent function degraded.

Two qualifications, stated because they bound the conclusion:

- **The margin is roughly 3–5 percentage points**, not an order of magnitude. The elevated latencies are
  also strikingly regular — the sample shows them at `seq` 17, 34, 51, i.e. every 17th heartbeat,
  which is a periodic pattern rather than random scheduler contention as the note describes. The
  *effect* is within limits; the *characterisation* in the release note looks inaccurate. A
  mechanism that is periodic scales predictably, so any change that raises the base latency, or a
  target with less headroom than this bench, could cross 10 % without warning.
- **This was measured on a containerised bench**, not on target hardware. The absolute latencies
  are not transferable; the *ratio* and the periodicity are.

## 5. Recommendation

1. **Close KI-217 as verified-not-a-defect for this release.** REQ-ECU-001 is met, at 4.84 % and 6.56 % across two samples.
2. **Keep the test in the regression suite.** It asserts against the 10 % limit on every CI run, so
   a regression that pushes the rate over the line fails the pipeline instead of being absorbed into
   an existing known issue — which is the failure mode a declared known issue creates.
3. **Ask the supplier to correct the characterisation.** "Occasionally … scheduler contention" does
   not describe a deterministic every-17th-heartbeat pattern. The distinction matters for predicting
   behaviour on target hardware, and an inaccurate mechanism in a release note is how a real defect
   gets filed under an accepted one later.
4. **Re-measure on target hardware** before production sign-off.
