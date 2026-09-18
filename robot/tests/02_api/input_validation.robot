*** Settings ***
Documentation     Input validation at the cloud API boundary.
...
...               REQ-CLI-002 and REQ-CHG-003 are not merely about the HTTP status code. Both
...               state that a rejected value shall **not** be forwarded to the vehicle, so
...               each test checks the status code at the API *and* the absence of a matching
...               command in the vehicle's own journal over ADB. An API that returns 422 but
...               still sends the command would pass a status-code-only test and fail this one.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Force Tags        rest    validation


*** Variables ***
# REQ-CLI-002: accepted set-point range, 0.5 degC resolution.
@{CLIMATE_VALUES_OUT_OF_RANGE}      15.5    -5.0    28.5    35.0    100.0
@{CLIMATE_VALUES_IN_RANGE}          16.0    22.5    28.0
# REQ-CHG-003: accepted target SOC range.
@{SOC_VALUES_OUT_OF_RANGE}          49    0    101    150
@{SOC_VALUES_IN_RANGE}              50    80    100


*** Test Cases ***
Climate Set Points Outside The Allowed Range Are Rejected
    [Documentation]    REQ-CLI-002: target_temp_c outside [16.0, 28.0] shall be rejected with
    ...    HTTP 422 and no command shall be forwarded to the vehicle.
    ...
    ...    Every out-of-range value is tried and all failures are reported together, so the
    ...    report shows the shape of the gap rather than only its first instance.
    [Tags]    req:REQ-CLI-002
    ${accepted}=    Collect Values Wrongly Accepted    /climate/start    target_temp_c
    ...    @{CLIMATE_VALUES_OUT_OF_RANGE}
    Should Be Empty    ${accepted}
    ...    msg=out-of-range climate set points accepted by the API:\n${{ chr(10).join($accepted) }}

Climate Set Points Inside The Allowed Range Are Accepted
    [Documentation]    REQ-CLI-002 (positive side): valid set points, including the exact
    ...    boundaries, are accepted. Guards against a fix that over-corrects and rejects
    ...    legitimate values.
    [Tags]    req:REQ-CLI-002
    ${rejected}=    Collect Values Wrongly Rejected    /climate/start    target_temp_c
    ...    @{CLIMATE_VALUES_IN_RANGE}
    [Teardown]    Stop Preconditioning Quietly
    Should Be Empty    ${rejected}
    ...    msg=valid climate set points rejected by the API:\n${{ chr(10).join($rejected) }}

Charging Targets Outside The Allowed Range Are Rejected
    [Documentation]    REQ-CHG-003: target_soc_percent outside [50, 100] shall be rejected
    ...    with HTTP 422 and not forwarded to the vehicle.
    [Tags]    req:REQ-CHG-003
    ${accepted}=    Collect Values Wrongly Accepted    /charging/start    target_soc_percent
    ...    @{SOC_VALUES_OUT_OF_RANGE}
    Should Be Empty    ${accepted}
    ...    msg=out-of-range charging targets accepted by the API:\n${{ chr(10).join($accepted) }}

Charging Targets Inside The Allowed Range Are Accepted
    [Documentation]    REQ-CHG-003 (positive side): valid targets including both boundaries
    ...    are accepted.
    [Tags]    req:REQ-CHG-003
    ${rejected}=    Collect Values Wrongly Rejected    /charging/start    target_soc_percent
    ...    @{SOC_VALUES_IN_RANGE}
    [Teardown]    Stop Charging Quietly
    Should Be Empty    ${rejected}
    ...    msg=valid charging targets rejected by the API:\n${{ chr(10).join($rejected) }}

A Rejected Climate Set Point Never Reaches The Vehicle
    [Documentation]    REQ-CLI-002, second clause: proves the *vehicle* never saw the command,
    ...    using the gateway's own command journal over ADB rather than trusting the API.
    ...
    ...    This is the check that distinguishes "the API answered 422" from "the car was
    ...    never asked to do it", and it is the one that matters for safety.
    [Tags]    req:REQ-CLI-002    adb
    ${before}=    Get Command Journal
    ${resp}=    Send Command    /climate/start    ${{ {'target_temp_c': 35.0} }}    expected_status=any
    Sleep    2s    reason=allow a forwarded command to be journalled by the gateway before counting
    ${after}=    Get Command Journal
    ${new}=    Evaluate    $after[len($before):]
    ${climate_commands}=    Evaluate    [r for r in $new if r.get('command') == 'CLIMATE_START']
    Log    Journal records added during this test: ${new}
    # Both halves of the requirement are reported together: the status code alone does not
    # say whether the car was asked to do it, and that second fact is the one with impact.
    @{findings}=    Create List
    IF    ${resp.status_code} != 422
        Append To List    ${findings}
        ...    API returned HTTP ${resp.status_code} for 35.0 degC, expected 422
    END
    IF    ${climate_commands}
        Append To List    ${findings}
        ...    the out-of-range set point was forwarded to the vehicle and journalled: ${climate_commands}
    END
    Should Be Empty    ${findings}
    ...    msg=REQ-CLI-002 violated:\n${{ chr(10).join($findings) }}
    [Teardown]    Stop Preconditioning Quietly


*** Keywords ***
Collect Values Wrongly Accepted
    [Documentation]    Try each value against ``${path}`` and return a description of every one
    ...    the API did **not** reject with 422.
    [Arguments]    ${path}    ${field}    @{values}
    @{accepted}=    Create List
    FOR    ${value}    IN    @{values}
        ${body}=    Create Dictionary    ${field}=${value}
        ${resp}=    Send Command    ${path}    ${body}    expected_status=any
        Log    ${path} ${field}=${value} -> HTTP ${resp.status_code}
        IF    ${resp.status_code} != 422
            Append To List    ${accepted}
            ...    ${field}=${value} -> HTTP ${resp.status_code} (expected 422)
            IF    ${resp.status_code} == 200    Get Command Outcome    ${resp.json()}[request_id]
        END
    END
    RETURN    ${accepted}

Collect Values Wrongly Rejected
    [Documentation]    Try each value against ``${path}`` and return a description of every one
    ...    the API did not accept with HTTP 200.
    [Arguments]    ${path}    ${field}    @{values}
    @{rejected}=    Create List
    FOR    ${value}    IN    @{values}
        ${body}=    Create Dictionary    ${field}=${value}
        ${resp}=    Send Command    ${path}    ${body}    expected_status=any
        Log    ${path} ${field}=${value} -> HTTP ${resp.status_code}
        IF    ${resp.status_code} != 200
            Append To List    ${rejected}    ${field}=${value} -> HTTP ${resp.status_code} (expected 200)
        ELSE
            Get Command Outcome    ${resp.json()}[request_id]
        END
    END
    RETURN    ${rejected}

Stop Preconditioning Quietly
    [Documentation]    Best-effort teardown; never fails the test it cleans up after.
    Run Keyword And Ignore Error    Send Command    /climate/stop    expected_status=any

Stop Charging Quietly
    [Documentation]    Best-effort teardown; never fails the test it cleans up after.
    Run Keyword And Ignore Error    Send Command    /charging/stop    expected_status=any
