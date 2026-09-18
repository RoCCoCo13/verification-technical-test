*** Settings ***
Documentation     HVAC pre-conditioning end to end, with emphasis on set-point fidelity.
...
...               The requirements ask for 0.5 degC resolution (REQ-CLI-001) and for the
...               backend and the Body ECU to agree once converged (REQ-CLI-004). Those are
...               two different claims and they fail for different reasons, so they are two
...               tests: one asks "did the car receive what the user asked for?", the other
...               asks "does the cloud tell the truth about what the car received?".
...
...               A suite that only read ``/vehicle/status`` would see neither.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Test Setup        Reset Bench To Known State
Force Tags        e2e    climate


*** Variables ***
# REQ-CLI-001: a half-degree set point is the whole point of 0.5 degC resolution.
${HALF_DEGREE_SET_POINT}        22.5
${WHOLE_DEGREE_SET_POINT}       21.0


*** Test Cases ***
Preconditioning Starts At A Whole Degree Set Point
    [Documentation]    REQ-CLI-001 at a whole-degree value: climate.active=true, the Body ECU
    ...    set point equals the request and the gateway VHAL mirrors it, within 10 s.
    ...
    ...    Run first and separately from the half-degree case so the report distinguishes
    ...    "pre-conditioning is broken" from "the resolution is wrong".
    [Tags]    req:REQ-CLI-001    rest    adb    grpc
    ${request_id}=    Start Preconditioning At    ${WHOLE_DEGREE_SET_POINT}
    ${record}=    Wait Until Command Reaches Terminal State    ${request_id}
    Should Be Equal As Strings    ${record}[status]    COMPLETED
    ...    msg=climate start ended ${record}[status] (reason=${record}[reason])
    Wait Until Body Ecu Reports    climate_active            True
    Wait Until Body Ecu Reports    climate_target_temp_c     ${WHOLE_DEGREE_SET_POINT}
    Wait Until Vhal Property Is    HVAC_POWER_ON             1
    Wait Until Vhal Property Is    HVAC_TEMPERATURE_SET      ${WHOLE_DEGREE_SET_POINT}
    [Teardown]    Stop Preconditioning Quietly

Preconditioning Honours A Half Degree Set Point
    [Documentation]    REQ-CLI-001: the set point shall be applied with 0.5 degC resolution.
    ...
    ...    22.5 degC is raw signal 45 on the contract in env/proto/vehicle_ecu.proto
    ...    ("44 -> 22.0 degC, 45 -> 22.5 degC"). The raw value is asserted as well as the
    ...    decoded one, so the report names the signal the vehicle actually received rather
    ...    than only the temperature it rounds to.
    [Tags]    req:REQ-CLI-001    grpc    adb
    ${expected_raw}=    Temperature In Celsius To Raw    ${HALF_DEGREE_SET_POINT}
    ${request_id}=    Start Preconditioning At    ${HALF_DEGREE_SET_POINT}
    ${record}=    Wait Until Command Reaches Terminal State    ${request_id}
    Should Be Equal As Strings    ${record}[status]    COMPLETED
    ...    msg=climate start ended ${record}[status] (reason=${record}[reason])
    Wait Until Body Ecu Reports    climate_active    True
    ${state}=    Capture Body Ecu State
    ${vhal_set_point}=    Get Vhal Property    HVAC_TEMPERATURE_SET
    Log    Requested ${HALF_DEGREE_SET_POINT} degC (raw ${expected_raw}); Body ECU holds raw ${state}[climate_target_raw] (${state}[climate_target_temp_c] degC); gateway VHAL shows ${vhal_set_point} degC
    [Teardown]    Stop Preconditioning Quietly
    Should Be Equal As Integers    ${state}[climate_target_raw]    ${expected_raw}
    ...    msg=requested ${HALF_DEGREE_SET_POINT} degC (raw ${expected_raw}) but the Body ECU holds raw ${state}[climate_target_raw] = ${state}[climate_target_temp_c] degC; the 0.5 degC step was lost between the cloud and the ECU

Cloud And Body Ecu Agree On The Set Point Once Converged
    [Documentation]    REQ-CLI-004: the set point and active state shown by the backend shall
    ...    equal the Body ECU values at all times once the state has converged (10 s).
    ...
    ...    This test deliberately does not trust the API. It compares the cloud value against
    ...    the vehicle's own value, which is the only way to notice a backend that reports
    ...    what the user *asked for* instead of what the car *did*.
    [Tags]    req:REQ-CLI-004    rest    grpc
    ${request_id}=    Start Preconditioning At    ${HALF_DEGREE_SET_POINT}
    Wait Until Command Reaches Terminal State    ${request_id}
    Wait Until Body Ecu Reports    climate_active    True
    Sleep    10s    reason=REQ-CLI-004 grants 10 s for convergence; compare only after it has elapsed
    ${truth}=    Get Vehicle Truth
    ${cloud_target}=    Set Variable    ${truth}[cloud][climate][target_temp_c]
    ${body_target}=     Set Variable    ${truth}[body][climate_target_temp_c]
    ${cloud_active}=    Set Variable    ${truth}[cloud][climate][active]
    ${body_active}=     Set Variable    ${truth}[body][climate_active]
    @{divergences}=    Create List
    IF    ${cloud_target} != ${body_target}
        Append To List    ${divergences}
        ...    set point: backend says ${cloud_target} degC, Body ECU holds ${body_target} degC (raw ${truth}[body][climate_target_raw])
    END
    IF    ${cloud_active} != ${body_active}
        Append To List    ${divergences}
        ...    active: backend says ${cloud_active}, Body ECU says ${body_active}
    END
    [Teardown]    Stop Preconditioning Quietly
    Should Be Empty    ${divergences}
    ...    msg=backend and Body ECU disagree after convergence:\n${{ chr(10).join($divergences) }}

Preconditioning Stops On Every Interface
    [Documentation]    REQ-CLI-003: POST /climate/stop sets climate.active=false on the
    ...    backend, HVAC_POWER_ON=0 in the gateway VHAL and climate.active=false on the Body
    ...    ECU, within 10 s.
    [Tags]    req:REQ-CLI-003    rest    adb    grpc
    ${start_id}=    Start Preconditioning At    ${WHOLE_DEGREE_SET_POINT}
    Wait Until Command Reaches Terminal State    ${start_id}
    Wait Until Body Ecu Reports    climate_active    True
    ${stop_id}=    Stop Preconditioning
    ${record}=    Wait Until Command Reaches Terminal State    ${stop_id}
    Should Be Equal As Strings    ${record}[status]    COMPLETED
    ...    msg=climate stop ended ${record}[status] (reason=${record}[reason])
    Wait Until Body Ecu Reports    climate_active    False
    Wait Until Vhal Property Is    HVAC_POWER_ON     0
    Wait Until Cloud Reports Climate Active    ${False}


*** Keywords ***
Wait Until Cloud Reports Climate Active
    [Documentation]    Wait until ``/vehicle/status`` shows the expected climate active state.
    ...    10 s is the REQ-CLI-003 budget and covers two 5 s state-poll periods.
    [Arguments]    ${expected}    ${timeout}=10s
    Wait Until Keyword Succeeds    ${timeout}    500ms    Cloud Climate Active Should Be    ${expected}

Cloud Climate Active Should Be
    [Documentation]    Assert the cloud view of the climate active flag.
    [Arguments]    ${expected}
    ${status}=    Get Vehicle Status
    Should Be Equal    ${status}[climate][active]    ${expected}
    ...    msg=cloud reports climate.active=${status}[climate][active], expected ${expected}

Stop Preconditioning Quietly
    [Documentation]    Best-effort teardown; never fails the test it cleans up after.
    Run Keyword And Ignore Error    Send Command    /climate/stop    expected_status=any
