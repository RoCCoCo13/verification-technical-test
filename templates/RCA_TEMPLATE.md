# RCA-<n>: <short title>

| Field | Value |
|---|---|
| Requirement(s) violated | REQ-... |
| Severity | S1 safety / S2 function lost / S3 degraded / S4 cosmetic |
| Component suspected | backend / gateway / body ECU / calibration / integration |
| Reproducibility | always / intermittent (x of N) |
| Build | TCU_GW2_SW_4.12.0, CVB_API_1.8.3, BCM4_SW_2.7.1 |

## 1. Observed behaviour
What the user/tester sees. Which test case(s) detect it.

## 2. Reproduction steps
Exact commands (curl / Robot test name / scenario id) and the request ids obtained.

## 3. Evidence
### 3.1 REST API
### 3.2 ADB (VHAL, journal, logcat)
### 3.3 DLT logs (quote lines, all three nodes, time ordered)
### 3.4 Network trace (file, frame numbers / times, what is present, what is missing)

## 4. Analysis
Causal chain from symptom to root cause. State what is proven and what is hypothesis.

## 5. Root cause
One or two sentences. Component + parameter/logic.

## 6. Impact
Functional, safety, user-facing, other features affected.

## 7. Recommendation
Fix proposal, regression test that will catch it (name it), verification steps.
