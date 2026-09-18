*** Settings ***
Documentation     Remote charging end to end: start, stop, and the target-reached transition.
...
...               The stop case is the one that matters. A charging session the user cannot
...               stop keeps drawing power from the wall and keeps filling the battery past
...               the point the user chose, so this suite checks the *physical* effect on the
...               Body ECU (state IDLE and the SOC no longer rising) and not merely the
...               command record.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Test Setup        Reset Bench To Known State
Force Tags        e2e    charging


*** Variables ***
${CHARGING_TARGET_SOC}      80
# body_cal.json steps the SOC every 3 s, so 10 s is enough for the +1 % REQ-CHG-001 asks for.
${SOC_RISE_TIMEOUT}         10s


*** Test Cases ***
Charging Starts And The State Of Charge Rises
    [Documentation]    REQ-CHG-001: POST /charging/start sets charging.state=CHARGING, echoes
    ...    target_soc_percent, and the SOC increases by at least 1 % within 10 s.
    [Tags]    req:REQ-CHG-001    rest    grpc
    ${soc_before}=    Get Body Ecu Field    soc_percent
    ${request_id}=    Start Charging To    ${CHARGING_TARGET_SOC}
    ${record}=    Wait Until Command Reaches Terminal State    ${request_id}
    Should Be Equal As Strings    ${record}[status]    COMPLETED
    ...    msg=charging start ended ${record}[status] (reason=${record}[reason])
    Wait Until Body Ecu Reports    charging_state    CHARGING
    Wait Until Keyword Succeeds    ${SOC_RISE_TIMEOUT}    1s
    ...    State Of Charge Should Have Risen By    ${soc_before}    1
    ${status}=    Get Vehicle Status
    Should Be Equal As Integers    ${status}[charging][target_soc_percent]    ${CHARGING_TARGET_SOC}
    ...    msg=backend echoes target_soc_percent=${status}[charging][target_soc_percent], expected ${CHARGING_TARGET_SOC}
    Should Be Equal As Strings    ${status}[charging][state]    CHARGING
    ...    msg=backend reports charging.state=${status}[charging][state], expected CHARGING
    [Teardown]    Stop Charging Quietly

Charging Stops On Command
    [Documentation]    REQ-CHG-002: POST /charging/stop completes, and charging.state becomes
    ...    IDLE on the backend, in the gateway VHAL and on the Body ECU within 10 s.
    [Tags]    req:REQ-CHG-002    rest    adb    grpc
    Start A Charging Session
    ${request_id}=    Stop Charging
    ${record}=    Get Command Outcome    ${request_id}
    Log    Stop command record: ${record}
    Wait Until Body Ecu Reports    charging_state    IDLE
    Wait Until Vhal Property Is    EV_CHARGE_STATE    IDLE
    Wait Until Cloud Reports Charging State    IDLE
    [Teardown]    Stop Charging Quietly
    Should Be Equal As Strings    ${record}[status]    COMPLETED
    ...    msg=charging stop ended ${record}[status] (reason=${record}[reason]) for request ${request_id}

The State Of Charge Stops Rising After A Stop Command
    [Documentation]    REQ-CHG-002, physical clause: once stopped, the SOC stops increasing.
    ...
    ...    Separate from the state check above because it is the consequence the user cares
    ...    about: a stop command the vehicle ignores keeps charging the battery regardless of
    ...    what any status field says. The SOC is sampled over two full charge steps
    ...    (body_cal.json steps every 3 s) so the observation cannot be a timing artefact.
    [Tags]    req:REQ-CHG-002    grpc
    Start A Charging Session
    ${request_id}=    Stop Charging
    Get Command Outcome    ${request_id}
    ${soc_at_stop}=    Get Body Ecu Field    soc_percent
    Sleep    8s    reason=two full 3 s charge steps, so a still-charging pack must have moved
    ${soc_after}=      Get Body Ecu Field    soc_percent
    ${state_after}=    Get Body Ecu Field    charging_state
    Log    SOC at stop: ${soc_at_stop} %, 8 s later: ${soc_after} % (Body ECU state ${state_after})
    [Teardown]    Stop Charging Quietly
    Should Be Equal As Integers    ${soc_after}    ${soc_at_stop}
    ...    msg=the battery kept charging after the stop command: SOC went from ${soc_at_stop} % to ${soc_after} % and the Body ECU is ${state_after}

Charging Completes When The Target Is Reached
    [Documentation]    REQ-CHG-004: when the SOC reaches the target the Body ECU switches to
    ...    COMPLETE and the backend reflects it within 10 s.
    ...
    ...    The target is set just above the current SOC so the transition happens in seconds
    ...    rather than minutes; the mechanism exercised is identical.
    [Tags]    req:REQ-CHG-004    rest    grpc    slow
    ${soc_now}=    Get Body Ecu Field    soc_percent
    ${target}=     Evaluate    max(50, min(100, ${soc_now} + 2))
    ${request_id}=    Start Charging To    ${target}
    Wait Until Command Reaches Terminal State    ${request_id}
    # (target - soc) steps at 3 s each, plus the 5 s cloud report period and margin.
    Wait Until Body Ecu Reports    charging_state    COMPLETE    timeout=30s
    Wait Until Cloud Reports Charging State    COMPLETE    timeout=15s
    ${status}=    Get Vehicle Status
    Should Be True    ${status}[charging][soc_percent] >= ${target}
    ...    msg=charging reported COMPLETE at ${status}[charging][soc_percent] %, below the ${target} % target
    [Teardown]    Stop Charging Quietly


*** Keywords ***
Start A Charging Session
    [Documentation]    Precondition helper: leave the vehicle charging, and fail loudly if it
    ...    could not be started, so a stop test never reports a false pass on an idle charger.
    ${request_id}=    Start Charging To    ${CHARGING_TARGET_SOC}
    ${record}=    Wait Until Command Reaches Terminal State    ${request_id}
    Should Be Equal As Strings    ${record}[status]    COMPLETED
    ...    msg=precondition failed: could not start charging (${record}[status]/${record}[reason])
    Wait Until Body Ecu Reports    charging_state    CHARGING

State Of Charge Should Have Risen By
    [Documentation]    Assert the Body ECU SOC has grown by at least ``${minimum}`` points.
    [Arguments]    ${baseline}    ${minimum}
    ${soc}=    Get Body Ecu Field    soc_percent
    Should Be True    ${soc} >= ${baseline} + ${minimum}
    ...    msg=SOC is ${soc} %, expected at least ${baseline} + ${minimum} %

Wait Until Cloud Reports Charging State
    [Documentation]    Wait until ``/vehicle/status`` shows the expected charging state.
    ...    10 s is the REQ-CHG-002/004 budget and covers two 5 s state-poll periods.
    [Arguments]    ${expected}    ${timeout}=10s
    Wait Until Keyword Succeeds    ${timeout}    500ms    Cloud Charging State Should Be    ${expected}

Cloud Charging State Should Be
    [Documentation]    Assert the cloud view of the charging state.
    [Arguments]    ${expected}
    ${status}=    Get Vehicle Status
    Should Be Equal As Strings    ${status}[charging][state]    ${expected}
    ...    msg=cloud reports charging.state=${status}[charging][state], expected ${expected}

Stop Charging Quietly
    [Documentation]    Best-effort teardown. Note this cannot actually stop the charger on a
    ...    build where the stop command is defective, so the suite also relies on
    ...    ``Reset Bench To Known State`` in Test Setup to return the pack to its initial SOC.
    Run Keyword And Ignore Error    Send Command    /charging/stop    expected_status=any
