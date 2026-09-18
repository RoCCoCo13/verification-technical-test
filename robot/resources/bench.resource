*** Settings ***
Documentation     Bench lifecycle: the known state every suite starts from, and the
...               observation window every log assertion is scoped to.
...
...               Two things make suites order-independent and re-runnable:
...
...               1. ``POST /bench/reset`` returns backend records *and* the Body ECU to
...                  factory state, and the suite then waits for a fresh state report so
...                  the cloud view is not stale (docs/TROUBLESHOOTING.md).
...               2. The DLT files append forever, across bench restarts. Every suite
...                  records a log mark at reset time and passes it as ``since`` to log
...                  queries, so no assertion can ever see a line from an earlier run.

Resource          rest_api.resource
Resource          adb.resource
Resource          body_ecu.resource
Resource          logs.resource


*** Variables ***
# The gateway pushes a state report every 5 s (tcu_cal.json state_poll_period_s)
# and after every command, so a fresh report is due well inside 15 s.
${FRESH_REPORT_TIMEOUT}     15s
${FRESH_REPORT_INTERVAL}    500ms
${MAX_REPORT_AGE_S}         10


*** Keywords ***
Reset Bench To Known State
    [Documentation]    Return backend and vehicle to factory state and wait until the cloud
    ...    has a fresh report. Returns the log mark to scope this suite's log assertions to.
    ...
    ...    Use as ``Suite Setup`` (and as ``Test Setup`` where a test needs isolation), so
    ...    suites can run in any order and on a bench left dirty by a previous run.
    ${resp}=    POST On Session    ${SESSION}    /bench/reset    expected_status=200
    ${mark}=    Mark Log Position
    Wait Until Vehicle Report Is Fresh
    RETURN    ${mark}

Open Bench Session And Reset
    [Documentation]    Convenience ``Suite Setup``: open the REST sessions, reset the bench,
    ...    and publish the log mark as the suite variable ``${LOG_MARK}``.
    Open Backend Session
    ${mark}=    Reset Bench To Known State
    Set Suite Variable    ${LOG_MARK}    ${mark}

Wait Until Vehicle Report Is Fresh
    [Documentation]    Wait until ``/vehicle/status`` carries a report younger than
    ...    ${MAX_REPORT_AGE_S} s, i.e. the cloud view reflects the vehicle after the reset.
    Wait Until Keyword Succeeds    ${FRESH_REPORT_TIMEOUT}    ${FRESH_REPORT_INTERVAL}
    ...    Vehicle Report Should Be Fresh

Vehicle Report Should Be Fresh
    [Documentation]    Assert the last state report is younger than ${MAX_REPORT_AGE_S} s
    ...    and that the vehicle is online (REQ-API-005).
    ${status}=    Get Vehicle Status
    Should Be Equal As Strings    ${status}[source]    telematics_report
    ...    msg=backend has no vehicle report yet (source=${status}[source])
    Should Be True    ${status}[connectivity][ecu_online]
    ...    msg=backend reports the ECU offline
    Should Be True    ${status}[connectivity][report_age_s] < ${MAX_REPORT_AGE_S}
    ...    msg=state report is ${status}[connectivity][report_age_s] s old, above the ${MAX_REPORT_AGE_S} s limit

Get Vehicle Truth
    [Documentation]    Return the three views of the vehicle side by side, as one dictionary
    ...    with keys ``cloud`` (REST), ``vhal`` (gateway mirror over ADB) and ``body``
    ...    (Body ECU over gRPC).
    ...
    ...    Cross-interface comparison is the whole point of this bench: several defects are
    ...    invisible at any single interface and only appear when the three are put next to
    ...    each other.
    ${cloud}=    Get Vehicle Status
    ${vhal}=     Get Vhal Properties
    ${body}=     Get Body Ecu State
    ${truth}=    Create Dictionary    cloud=${cloud}    vhal=${vhal}    body=${body}
    Log    Cloud: ${cloud}
    Log    VHAL: ${vhal}
    Log    Body: ${body}
    RETURN    ${truth}
