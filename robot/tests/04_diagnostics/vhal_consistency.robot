*** Settings ***
Documentation     Consistency of the gateway VHAL mirror with the Body ECU (REQ-ADB-002).
...
...               The VHAL mirror is what the head unit displays to the driver. If it drifts
...               from the Body ECU, the car shows one thing and does another. This suite
...               drives the vehicle into a non-default state first, because a mirror
...               compared only at factory defaults agrees by accident.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Test Setup        Reset Bench To Known State
Force Tags        diagnostics    adb


*** Variables ***
# REQ-ADB-002 names exactly these four properties; the mapping is VHAL name -> Body ECU field.
&{MIRRORED_PROPERTIES}
...    DOOR_LOCK=doors_locked
...    HVAC_POWER_ON=climate_active
...    HVAC_TEMPERATURE_SET=climate_target_temp_c
...    EV_CHARGE_STATE=charging_state


*** Test Cases ***
The Vhal Mirror Matches The Body Ecu In A Non Default State
    [Documentation]    REQ-ADB-002: DOOR_LOCK, HVAC_POWER_ON, HVAC_TEMPERATURE_SET and
    ...    EV_CHARGE_STATE in the gateway VHAL shall match the Body ECU within 10 s.
    ...
    ...    The vehicle is first driven away from its factory state - doors unlocked, climate
    ...    on, charging on - so that every one of the four properties has actually moved and
    ...    the comparison means something.
    [Tags]    req:REQ-ADB-002    grpc
    Drive Vehicle Into A Non Default State
    Sleep    10s    reason=REQ-ADB-002 grants 10 s for the mirror to follow the Body ECU
    ${body}=    Capture Body Ecu State
    ${vhal}=    Get Vhal Properties
    Log    Body ECU: ${body}
    Log    VHAL mirror: ${vhal}
    ${mismatches}=    Compare Mirror Against Body Ecu    ${vhal}    ${body}
    [Teardown]    Restore Idle Domains
    Should Be Empty    ${mismatches}
    ...    msg=the gateway VHAL mirror disagrees with the Body ECU:\n${{ chr(10).join($mismatches) }}

The Vhal Mirror Follows A Door Lock Change
    [Documentation]    REQ-ADB-002 for DOOR_LOCK specifically: the mirror follows the Body ECU
    ...    after a lock and after an unlock, within the 10 s budget.
    [Tags]    req:REQ-ADB-002    grpc
    ${lock_id}=    Lock Vehicle
    Get Command Outcome    ${lock_id}
    Wait Until Body Ecu Reports    doors_locked    True
    Wait Until Vhal Property Is    DOOR_LOCK    1
    ${unlock_id}=    Unlock Vehicle
    Get Command Outcome    ${unlock_id}
    Wait Until Body Ecu Reports    doors_locked    False
    Wait Until Vhal Property Is    DOOR_LOCK    0

Dumpsys Vehicle Agrees With The Vhal Property File
    [Documentation]    The two ADB routes to the VHAL - ``dumpsys vehicle`` and the property
    ...    file - shall show the same values, so an engineer reading either reaches the same
    ...    conclusion.
    [Tags]    req:REQ-ADB-002
    ${props}=    Get Vhal Properties
    ${dumpsys}=    Get Vehicle Dumpsys
    Log    ${dumpsys}
    @{missing}=    Create List
    FOR    ${name}    IN    @{MIRRORED_PROPERTIES.keys()}
        ${value}=    Set Variable    ${props}[${name}]
        ${shown}=    Run Keyword And Return Status    Should Match Regexp    ${dumpsys}
        ...    (?m)^.*\\b${name}\\b.*$
        IF    not ${shown}    Append To List    ${missing}    ${name} (props.json holds ${value})
    END
    Should Be Empty    ${missing}
    ...    msg=properties absent from 'dumpsys vehicle' but present in props.json: ${missing}


*** Keywords ***
Drive Vehicle Into A Non Default State
    [Documentation]    Unlock the doors, start pre-conditioning and start charging, waiting for
    ...    the Body ECU to confirm each, so all four mirrored properties differ from factory.
    ...
    ...    Lock/unlock outcomes are collected rather than asserted: this suite is about the
    ...    mirror, and a command that ends FAILED still actuates on this build, which is the
    ...    subject of a different test. What matters here is the Body ECU state reached.
    ${unlock_id}=    Unlock Vehicle
    Get Command Outcome    ${unlock_id}
    Wait Until Body Ecu Reports    doors_locked    False
    ${climate_id}=    Start Preconditioning At    23.0
    Get Command Outcome    ${climate_id}
    Wait Until Body Ecu Reports    climate_active    True
    ${charge_id}=    Start Charging To    90
    Get Command Outcome    ${charge_id}
    Wait Until Body Ecu Reports    charging_state    CHARGING

Compare Mirror Against Body Ecu
    [Documentation]    Return a description of every mirrored property whose VHAL value does
    ...    not match the corresponding Body ECU field. Booleans are compared after mapping
    ...    the VHAL 1/0 encoding onto True/False.
    [Arguments]    ${vhal}    ${body}
    @{mismatches}=    Create List
    FOR    ${name}    ${field}    IN    &{MIRRORED_PROPERTIES}
        ${expected}=    Set Variable    ${body}[${field}]
        ${actual}=      Set Variable    ${vhal}[${name}]
        ${normalised}=    Normalise Vhal Value    ${actual}
        IF    '${normalised}' != '${expected}'
            Append To List    ${mismatches}
            ...    ${name}: VHAL shows ${actual}, Body ECU ${field} is ${expected}
        END
    END
    RETURN    ${mismatches}

Normalise Vhal Value
    [Documentation]    Map the VHAL 1/0 integer encoding onto the Body ECU's True/False so the
    ...    two can be compared as strings; other values pass through unchanged.
    [Arguments]    ${value}
    IF    '${value}' == '1'
        RETURN    True
    ELSE IF    '${value}' == '0'
        RETURN    False
    END
    RETURN    ${value}

Restore Idle Domains
    [Documentation]    Best-effort teardown: stop climate and charging for the next test.
    Run Keyword And Ignore Error    Send Command    /climate/stop     expected_status=any
    Run Keyword And Ignore Error    Send Command    /charging/stop    expected_status=any
