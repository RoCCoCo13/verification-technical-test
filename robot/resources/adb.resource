*** Settings ***
Documentation     Gateway ECU (TCU-GW-2) inspection over ADB - the *ECU's own* view.
...
...               The gateway mirrors the Body ECU state into VHAL properties; that mirror
...               is what the head unit would display, so it is a third, independent
...               oracle next to the cloud REST view and the Body ECU gRPC truth.
...               REQ-ADB-002 is exactly the requirement that the three agree.

Library           AdbLibrary    serial=${ADB_SERIAL}
Library           Collections
Library           String


*** Variables ***
# REQ-ADB-002 grants 10 s for the VHAL mirror to follow the Body ECU; the gateway
# polls every 5 s (tcu_cal.json state_poll_period_s), so one missed poll still fits.
${VHAL_SYNC_TIMEOUT}        10s
${VHAL_POLL_INTERVAL}       500ms


*** Keywords ***
Gateway Should Be Online
    [Documentation]    Fail unless the gateway answers over ADB and reports itself booted
    ...    with the telematics service running (REQ-ADB-001).
    ${model}=    Get Gateway Property    ro.product.model
    Should Be Equal As Strings    ${model}    TCU-GW-2
    ...    msg=unexpected product model over ADB: '${model}'
    ${booted}=    Get Gateway Property    sys.boot_completed
    Should Be Equal As Strings    ${booted}    1    msg=gateway reports sys.boot_completed='${booted}'
    ${svc}=    Get Gateway Property    init.svc.telematics
    Should Be Equal As Strings    ${svc}    running    msg=telematics service is '${svc}', expected 'running'

Get Vhal Property
    [Documentation]    Return one property of the gateway VHAL mirror, e.g. ``DOOR_LOCK``.
    [Arguments]    ${name}
    ${props}=    Get Vhal Properties
    Dictionary Should Contain Key    ${props}    ${name}
    ...    msg=VHAL mirror has no property '${name}'; present: ${props.keys()}
    RETURN    ${props}[${name}]

Vhal Property Should Be
    [Documentation]    Assert a VHAL property currently equals ``${expected}`` (string compare,
    ...    so 1/0 and enum names are handled the same way).
    [Arguments]    ${name}    ${expected}
    ${actual}=    Get Vhal Property    ${name}
    Should Be Equal As Strings    ${actual}    ${expected}
    ...    msg=VHAL ${name} is '${actual}', expected '${expected}'

Wait Until Vhal Property Is
    [Documentation]    Wait for the VHAL mirror to converge on ``${expected}``.
    ...
    ...    Justified by REQ-ADB-002 (mirror shall match within 10 s) and the 5 s gateway
    ...    poll period. The mirror is only ever written by the sync loop, so polling it
    ...    cannot turn an intermittent fault green - it can only wait out the poll period.
    [Arguments]    ${name}    ${expected}    ${timeout}=${VHAL_SYNC_TIMEOUT}
    Wait Until Keyword Succeeds    ${timeout}    ${VHAL_POLL_INTERVAL}
    ...    Vhal Property Should Be    ${name}    ${expected}

Get Gateway Software Version
    [Documentation]    Return the gateway software version property (expected TCU_GW2_SW_4.12.0).
    ${version}=    Get Gateway Property    ro.oem.tcu.sw_version
    RETURN    ${version}

Get Journal Record For Command
    [Documentation]    Return the *last* journal record the vehicle wrote for ``${request_id}``.
    ...
    ...    The journal appends one record per state change, so the last one carries the
    ...    vehicle's final verdict on that command: ``COMPLETED``, ``FAILED`` or ``DROPPED``.
    ...    Fails if the vehicle has no record of the command at all.
    [Arguments]    ${request_id}
    ${records}=    Get Journal Records For Request Id    ${request_id}
    Should Not Be Empty    ${records}
    ...    msg=the vehicle has no journal record for ${request_id}
    RETURN    ${records}[-1]

Logcat Should Contain
    [Documentation]    Assert the Android log buffer contains ``${text}``, optionally within a
    ...    tag filter such as ``TelematicsSvc:I *:S``.
    [Arguments]    ${text}    ${spec}=${EMPTY}
    ${buffer}=    Get Logcat    ${spec}
    Should Contain    ${buffer}    ${text}
    ...    msg=logcat does not mention '${text}'
