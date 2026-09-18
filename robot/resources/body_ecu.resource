*** Settings ***
Documentation     Body ECU (BCM-4) over gRPC - the *physical truth* of the vehicle.
...
...               docs/API_REFERENCE.md names ``GetBodyState`` the physical truth, so it is
...               the oracle of last resort: when the cloud and the ECU disagree, this is
...               the side that is right about what the car actually did.

Library           BodyEcuLibrary    address=${BODY_ECU_ADDR}    proto_path=${PROTO_PATH}
Library           Collections


*** Variables ***
# REQ-LCK-001/CLI-001/CHG-001 all grant 10 s for the vehicle to converge after a command.
${BODY_CONVERGENCE_TIMEOUT}     10s
${BODY_POLL_INTERVAL}           500ms


*** Keywords ***
Body Ecu State Should Be
    [Documentation]    Assert one field of the Body ECU snapshot equals ``${expected}``.
    ...    Field names are those of `Get Body Ecu State`, e.g. ``doors_locked``,
    ...    ``climate_active``, ``climate_target_temp_c``, ``charging_state``.
    [Arguments]    ${field}    ${expected}
    ${state}=    Get Body Ecu State
    Dictionary Should Contain Key    ${state}    ${field}
    ...    msg=unknown Body ECU state field '${field}'
    Should Be Equal As Strings    ${state}[${field}]    ${expected}
    ...    msg=Body ECU ${field} is '${state}[${field}]', expected '${expected}'

Wait Until Body Ecu Reports
    [Documentation]    Wait until a Body ECU state field converges on ``${expected}``.
    ...
    ...    Timeout defaults to ${BODY_CONVERGENCE_TIMEOUT}, the window the feature
    ...    requirements grant for the vehicle to reach the commanded state. The Body ECU
    ...    state is authoritative and monotonic for a single command, so waiting here
    ...    measures convergence rather than hiding a flaky outcome.
    [Arguments]    ${field}    ${expected}    ${timeout}=${BODY_CONVERGENCE_TIMEOUT}
    Wait Until Keyword Succeeds    ${timeout}    ${BODY_POLL_INTERVAL}
    ...    Body Ecu State Should Be    ${field}    ${expected}

Get Body Ecu Field
    [Documentation]    Return one field of the Body ECU snapshot.
    [Arguments]    ${field}
    ${state}=    Get Body Ecu State
    RETURN    ${state}[${field}]

Capture Body Ecu State
    [Documentation]    Return the full Body ECU snapshot, for before/after comparisons.
    ${state}=    Get Body Ecu State
    RETURN    ${state}

Body Ecu Fields Should Be Unchanged
    [Documentation]    Assert the listed fields are identical in two snapshots.
    ...    Used by REQ-LCK-004 to prove locking did not disturb climate or charging.
    [Arguments]    ${before}    ${after}    @{fields}
    @{differences}=    Create List
    FOR    ${field}    IN    @{fields}
        IF    '${before}[${field}]' != '${after}[${field}]'
            Append To List    ${differences}
            ...    ${field}: ${before}[${field}] -> ${after}[${field}]
        END
    END
    Should Be Empty    ${differences}
    ...    msg=Body ECU state changed where it should not have: ${differences}
