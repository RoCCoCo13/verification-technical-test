*** Settings ***
Documentation     Gateway supervision of the Body ECU, and verification of the supplier's
...               declared known issue KI-217.
...
...               The release notes declare KI-217 ("Body ECU heartbeat occasionally exceeds
...               100 ms, cosmetic, no functional impact") and REQ-ECU-001 sets the acceptance
...               limit at 10 % of heartbeats. A declared known issue is a claim, not a fact,
...               so this suite measures the real rate over a sample large enough to mean
...               something and reports the number either way. Confirming a supplier's claim
...               with evidence is as much a result as refuting it.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Force Tags        diagnostics    supervision


*** Variables ***
# REQ-ECU-001: heartbeat every 2 s, warn above 100 ms, at most 10 % of heartbeats warned.
${HEARTBEAT_PERIOD_S}           2.0
${HEARTBEAT_WARN_LATENCY_MS}    100
${MAX_WARN_RATE_PERCENT}        10.0
# 60 samples at 2 s is ~2 min of observation. Enough for a 1-in-17 effect to show up
# repeatedly rather than by chance, which is what makes the measured rate quotable.
${HEARTBEAT_SAMPLE_SIZE}        60


*** Test Cases ***
Heartbeat Latency Warnings Stay Within The Accepted Rate
    [Documentation]    REQ-ECU-001 / KI-217: latency warnings shall affect at most 10 % of
    ...    heartbeats.
    ...
    ...    Collects ${HEARTBEAT_SAMPLE_SIZE} consecutive heartbeats from the gateway log and
    ...    computes the rate above the 100 ms threshold. The gateway logs every heartbeat
    ...    with its latency, at DEBUG when nominal and WARN when late, so the sample is the
    ...    complete population rather than only the outliers. The measured rate, minimum,
    ...    maximum and mean are logged so the number can be quoted in a defect report or used
    ...    to close KI-217.
    [Tags]    req:REQ-ECU-001    slow
    ${samples}=    Collect Heartbeat Samples    ${HEARTBEAT_SAMPLE_SIZE}
    ${late}=       Evaluate    [s for s in $samples if s > ${HEARTBEAT_WARN_LATENCY_MS}]
    ${rate}=       Evaluate    round(100.0 * len($late) / len($samples), 2)
    ${stats}=      Evaluate
    ...    {'n': len($samples), 'min': min($samples), 'max': max($samples), 'mean': round(sum($samples)/len($samples), 1)}
    Log    Heartbeat latency over ${stats}[n] samples: min ${stats}[min] ms, mean ${stats}[mean] ms, max ${stats}[max] ms
    Log    ${{ len($late) }} of ${stats}[n] heartbeats exceeded ${HEARTBEAT_WARN_LATENCY_MS} ms = ${rate} % (REQ-ECU-001 allows ${MAX_WARN_RATE_PERCENT} %)
    Log    Late samples (ms): ${late}
    Should Be True    ${rate} <= ${MAX_WARN_RATE_PERCENT}
    ...    msg=${rate} % of heartbeats exceeded ${HEARTBEAT_WARN_LATENCY_MS} ms (${{ len($late) }} of ${stats}[n]), above the ${MAX_WARN_RATE_PERCENT} % allowed by REQ-ECU-001

Heartbeats Are Issued On The Specified Period
    [Documentation]    REQ-ECU-001: the gateway supervises the Body ECU with a heartbeat every
    ...    2 s. Measured from the timestamps of consecutive heartbeat log entries.
    ...
    ...    A 25 % tolerance covers scheduler jitter on a containerised bench while still
    ...    catching a period that is wrong by design (1 s or 5 s).
    [Tags]    req:REQ-ECU-001    slow
    ${mark}=    Mark Log Position
    Sleep    30s    reason=collect roughly 15 heartbeat intervals at the specified 2 s period
    ${entries}=    Get Gateway Entries    since=${mark}    ctx=HB
    ${intervals}=    Evaluate
    ...    [round((b['timestamp'] - a['timestamp']).total_seconds(), 3) for a, b in zip($entries, $entries[1:])]
    Should Not Be Empty    ${intervals}    msg=the gateway logged no heartbeats in 30 s
    ${mean}=    Evaluate    round(sum($intervals) / len($intervals), 3)
    Log    ${{ len($intervals) }} heartbeat intervals, mean ${mean} s, range ${{ min($intervals) }}..${{ max($intervals) }} s
    Should Be True    abs(${mean} - ${HEARTBEAT_PERIOD_S}) <= ${HEARTBEAT_PERIOD_S} * 0.25
    ...    msg=mean heartbeat interval is ${mean} s, expected ${HEARTBEAT_PERIOD_S} s +/- 25 %

The Body Ecu Is Supervised As Online
    [Documentation]    REQ-ECU-001: while the Body ECU answers, the gateway shall consider it
    ...    online and the cloud shall reflect that.
    [Tags]    req:REQ-ECU-001    adb    rest
    Vhal Property Should Be    BODY_ECU_ONLINE    True
    ${status}=    Get Vehicle Status
    Should Be True    ${status}[connectivity][ecu_online]
    ...    msg=the backend reports the ECU offline while it is answering gRPC calls

The Declared Known Issue Is Still Declared In The Release Notes
    [Documentation]    Traceability guard for KI-217. If the supplier removes or renumbers the
    ...    known issue in a later release, this test fails and the measurement above has to be
    ...    re-examined against whatever replaced it, instead of silently validating a claim
    ...    nobody makes any more.
    [Tags]    req:REQ-ECU-001    adb
    ${notes}=    Get Release Notes
    Log    ${notes}
    Should Contain    ${notes}    KI-217
    ...    msg=KI-217 is no longer declared in /vendor/etc/release_notes.txt; re-assess the heartbeat measurement against the current known-issue list


*** Keywords ***
Collect Heartbeat Samples
    [Documentation]    Wait until the gateway has logged at least ``${count}`` heartbeats since
    ...    now, then return their latencies in ms.
    ...
    ...    Waiting for the sample to fill is not a retry: the assertion is made once, on the
    ...    complete sample. Nothing here can turn a bad rate green.
    [Arguments]    ${count}
    ${mark}=    Mark Log Position
    ${timeout}=    Evaluate    int(${count} * ${HEARTBEAT_PERIOD_S} * 1.5) + 20
    Wait Until Keyword Succeeds    ${timeout}s    5s    Heartbeat Sample Should Be Complete    ${mark}    ${count}
    ${samples}=    Get Heartbeat Latency Samples    since=${mark}
    RETURN    ${samples}

Heartbeat Sample Should Be Complete
    [Documentation]    Assert at least ``${count}`` heartbeat latencies are available since ``${since}``.
    [Arguments]    ${since}    ${count}
    ${samples}=    Get Heartbeat Latency Samples    since=${since}
    Should Be True    ${{ len($samples) }} >= ${count}
    ...    msg=only ${{ len($samples) }} of ${count} heartbeat samples collected so far
