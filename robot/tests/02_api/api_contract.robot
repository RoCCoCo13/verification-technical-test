*** Settings ***
Documentation     REST API contract of CVB_API_1.8.3: authentication, command response
...               shape and latency, command lifecycle, error handling and OpenAPI.
...
...               This suite validates the cloud interface *on its own terms*. It does not
...               look at the vehicle - that is the job of the end-to-end suite. Keeping the
...               two apart means a failure here points at the backend and nowhere else.

Resource          ../../resources/bench.resource
Library           String
Library           Collections
Suite Setup       Open Bench Session And Reset
Force Tags        rest


*** Variables ***
# REQ-API-002: command endpoints shall respond within 500 ms.
${COMMAND_LATENCY_BUDGET_MS}    500
${UUID_PATTERN}     ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$
# REQ-API-002: ISO 8601 UTC, millisecond precision, Z suffix.
${ISO_MS_Z_PATTERN}    ^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$
@{PROTECTED_ENDPOINTS}
...    POST:/vehicle/lock
...    POST:/vehicle/unlock
...    POST:/climate/start
...    POST:/climate/stop
...    POST:/charging/start
...    POST:/charging/stop
...    GET:/vehicle/status
...    GET:/vehicle/commands


*** Test Cases ***
Every Protected Endpoint Rejects A Request Without An Api Key
    [Documentation]    REQ-API-001: all /vehicle/*, /climate/* and /charging/* endpoints
    ...    require a valid X-API-Key and answer 401 without one.
    ...
    ...    Checks the whole endpoint list in one test and reports every offender, rather
    ...    than stopping at the first, so one run tells you the full exposure.
    [Tags]    req:REQ-API-001    security
    @{unprotected}=    Create List
    FOR    ${endpoint}    IN    @{PROTECTED_ENDPOINTS}
        ${method}    ${path}=    Split String    ${endpoint}    separator=:    max_split=1
        ${resp}=    Run Keyword    ${method} On Session    ${SESSION_NO_AUTH}    ${path}
        ...    expected_status=any
        IF    ${resp.status_code} != 401
            Append To List    ${unprotected}    ${method} ${path} -> HTTP ${resp.status_code}
        END
    END
    Should Be Empty    ${unprotected}
    ...    msg=endpoints reachable without an API key: ${unprotected}

An Invalid Api Key Is Rejected
    [Documentation]    REQ-API-001: a wrong key is rejected exactly like a missing one.
    [Tags]    req:REQ-API-001    security
    ${headers}=    Create Dictionary    X-API-Key=not-the-key
    ${resp}=    GET On Session    ${SESSION_NO_AUTH}    /vehicle/status    headers=${headers}
    ...    expected_status=any
    Should Be Equal As Integers    ${resp.status_code}    401
    ...    msg=an invalid API key returned HTTP ${resp.status_code}, expected 401

Command Endpoints Answer Within The Latency Budget With A Well Formed Body
    [Documentation]    REQ-API-002: every command endpoint answers within 500 ms with HTTP 200
    ...    and a body carrying request_id (UUID), status=ACCEPTED and an ISO 8601 UTC
    ...    submitted_at with millisecond precision and a Z suffix.
    ...
    ...    All six commands are exercised, and each is driven to its terminal state
    ...    afterwards so this test leaves no command in flight for the next one.
    [Tags]    req:REQ-API-002
    @{violations}=    Create List
    FOR    ${path}    IN    /vehicle/lock    /vehicle/unlock    /climate/start    /climate/stop
    ...                    /charging/start    /charging/stop
        ${resp}=    Send Command    ${path}    expected_status=any
        ${issues}=    Check Command Response Contract    ${path}    ${resp}
        Append To List    ${violations}    @{issues}
        IF    ${resp.status_code} == 200
            Get Command Outcome    ${resp.json()}[request_id]
        END
    END
    Should Be Empty    ${violations}
    ...    msg=command response contract violations:\n${{ chr(10).join($violations) }}

Every Accepted Command Reaches A Terminal State
    [Documentation]    REQ-API-003: an accepted command shall reach COMPLETED or FAILED within
    ...    5 s; none shall stay ACCEPTED.
    ...
    ...    Every one of the six commands is submitted and polled. The outcomes are collected
    ...    and asserted together, so the report names *all* the commands that hang, which is
    ...    what an RCA needs, not just the first.
    [Tags]    req:REQ-API-003    req:REQ-ECU-002
    @{stuck}=    Create List
    FOR    ${path}    IN    /vehicle/lock    /vehicle/unlock    /climate/start    /climate/stop
    ...                    /charging/start    /charging/stop
        ${request_id}=    Send Accepted Command    ${path}
        ${record}=    Get Command Outcome    ${request_id}
        Log    ${path} -> ${record}[status] (reason=${record}[reason], request_id=${request_id})
        IF    '${record}[status]' == 'ACCEPTED'
            Append To List    ${stuck}    ${path} request_id=${request_id} still ACCEPTED after ${COMMAND_TERMINAL_TIMEOUT}
        END
    END
    [Teardown]    Stop Charging Session Quietly
    Should Be Empty    ${stuck}
    ...    msg=commands that never reached a terminal state:\n${{ chr(10).join($stuck) }}

An Unknown Request Id Returns Not Found
    [Documentation]    REQ-API-004: GET /vehicle/commands/{request_id} with an id the backend
    ...    never issued returns HTTP 404.
    [Tags]    req:REQ-API-004
    ${resp}=    Get Command Record    00000000-0000-4000-8000-000000000000    expected_status=any
    Should Be Equal As Integers    ${resp.status_code}    404
    ...    msg=unknown request_id returned HTTP ${resp.status_code}, expected 404

Vehicle Status Carries The Full Documented Structure
    [Documentation]    REQ-API-005: /vehicle/status exposes vin, doors.locked,
    ...    climate.{active,target_temp_c}, charging.{state,soc_percent,target_soc_percent}
    ...    and connectivity.{ecu_online,last_report_at,report_age_s}, and the report is
    ...    younger than 10 s while the vehicle is connected.
    [Tags]    req:REQ-API-005
    ${status}=    Get Vehicle Status
    Dictionary Should Contain Key    ${status}    vin
    Should Not Be Empty    ${status}[vin]
    Dictionary Should Contain Key    ${status}[doors]      locked
    FOR    ${key}    IN    active    target_temp_c
        Dictionary Should Contain Key    ${status}[climate]    ${key}
    END
    FOR    ${key}    IN    state    soc_percent    target_soc_percent
        Dictionary Should Contain Key    ${status}[charging]    ${key}
    END
    FOR    ${key}    IN    ecu_online    last_report_at    report_age_s
        Dictionary Should Contain Key    ${status}[connectivity]    ${key}
    END
    Should Contain    ${{ ['IDLE','CHARGING','COMPLETE','FAULT','UNKNOWN'] }}    ${status}[charging][state]
    ...    msg=charging.state '${status}[charging][state]' is outside the documented enum
    Should Be True    ${status}[connectivity][ecu_online]
    ...    msg=the vehicle is expected to be connected on this bench
    Should Be True    ${status}[connectivity][report_age_s] < ${MAX_REPORT_AGE_S}
    ...    msg=report_age_s is ${status}[connectivity][report_age_s] s, above the 10 s limit

Openapi Document Covers Every Public Endpoint
    [Documentation]    REQ-API-006: an OpenAPI 3 document is published at /openapi.json and
    ...    describes all public endpoints.
    [Tags]    req:REQ-API-006
    ${doc}=    Get Openapi Document
    Should Match Regexp    ${doc}[openapi]    ^3\\.
    ...    msg=/openapi.json declares version '${doc}[openapi]', expected OpenAPI 3.x
    @{missing}=    Create List
    FOR    ${endpoint}    IN    @{PROTECTED_ENDPOINTS}
        ${method}    ${path}=    Split String    ${endpoint}    separator=:    max_split=1
        ${documented}=    Evaluate
        ...    $path in $doc['paths'] and $method.lower() in $doc['paths'][$path]
        IF    not ${documented}    Append To List    ${missing}    ${method} ${path}
    END
    Should Be Empty    ${missing}    msg=public endpoints absent from the OpenAPI document: ${missing}


*** Keywords ***
Check Command Response Contract
    [Documentation]    Return a list of REQ-API-002 violations for one command response.
    ...    Returns findings instead of failing, so the caller can report every endpoint at once.
    [Arguments]    ${path}    ${response}
    @{issues}=    Create List
    IF    ${response.status_code} != 200
        Append To List    ${issues}    ${path}: HTTP ${response.status_code}, expected 200
        RETURN    ${issues}
    END
    ${elapsed_ms}=    Evaluate    ${response.elapsed.total_seconds()} * 1000
    IF    ${elapsed_ms} >= ${COMMAND_LATENCY_BUDGET_MS}
        Append To List    ${issues}
        ...    ${path}: answered in ${elapsed_ms} ms, above the ${COMMAND_LATENCY_BUDGET_MS} ms budget
    END
    ${body}=    Set Variable    ${response.json()}
    ${is_uuid}=    Run Keyword And Return Status
    ...    Should Match Regexp    ${body}[request_id]    ${UUID_PATTERN}
    IF    not ${is_uuid}
        Append To List    ${issues}    ${path}: request_id '${body}[request_id]' is not a UUID
    END
    IF    '${body}[status]' != 'ACCEPTED'
        Append To List    ${issues}    ${path}: status is '${body}[status]', expected ACCEPTED
    END
    ${is_iso}=    Run Keyword And Return Status
    ...    Should Match Regexp    ${body}[submitted_at]    ${ISO_MS_Z_PATTERN}
    IF    not ${is_iso}
        Append To List    ${issues}
        ...    ${path}: submitted_at '${body}[submitted_at]' is not ISO 8601 UTC with ms precision and Z
    END
    RETURN    ${issues}

Stop Charging Session Quietly
    [Documentation]    Best-effort teardown: leave the charger idle for the next test even if
    ...    the stop command itself is defective. Never fails the test it cleans up after.
    Run Keyword And Ignore Error    Send Command    /charging/stop    expected_status=any
