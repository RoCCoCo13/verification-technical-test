*** Settings ***
Documentation     Cloud REST API (CVB_API_1.8.3) - the user/app view of the vehicle.
...
...               Commands are asynchronous: the endpoint returns ``ACCEPTED`` with a
...               ``request_id`` and the outcome is polled at
...               ``GET /vehicle/commands/{request_id}`` (docs/API_REFERENCE.md). The
...               keywords below keep that two-step shape visible instead of hiding it,
...               because REQ-API-003 is precisely about commands that never reach a
...               terminal state.
...
...               No address or key appears here: ``${BACKEND_URL}`` and ``${API_KEY}``
...               come from the variable file.

Library           RequestsLibrary
Library           Collections
Library           String
Library           DateTime


*** Variables ***
${SESSION}                  backend
${SESSION_NO_AUTH}          backend_no_auth
# REQ-API-003: terminal state within 5 s. Polled, not slept.
${COMMAND_TERMINAL_TIMEOUT}     5s
${COMMAND_POLL_INTERVAL}        200ms


*** Keywords ***
Open Backend Session
    [Documentation]    Open the authenticated session used by every REST keyword, plus an
    ...    unauthenticated one so REQ-API-001 can be checked without re-creating sessions.
    ${headers}=    Create Dictionary    X-API-Key=${API_KEY}
    Create Session    ${SESSION}            ${BACKEND_URL}    headers=${headers}    verify=${False}
    Create Session    ${SESSION_NO_AUTH}    ${BACKEND_URL}                          verify=${False}

# --------------------------------------------------------------------- state
Get Vehicle Status
    [Documentation]    Return ``GET /vehicle/status`` as a dictionary: the cloud's view of
    ...    the vehicle, built from the last state report pushed by the gateway.
    ${resp}=    GET On Session    ${SESSION}    /vehicle/status
    RETURN    ${resp.json()}

Get Backend Health
    [Documentation]    Return ``GET /health`` (no API key required).
    ${resp}=    GET On Session    ${SESSION_NO_AUTH}    /health
    RETURN    ${resp.json()}

Get Openapi Document
    [Documentation]    Return the OpenAPI 3 document published at ``/openapi.json`` (REQ-API-006).
    ${resp}=    GET On Session    ${SESSION_NO_AUTH}    /openapi.json
    Should Be Equal As Integers    ${resp.status_code}    200
    RETURN    ${resp.json()}

# ------------------------------------------------------------------ commands
Send Command
    [Documentation]    POST a command endpoint and return the raw response object, so the
    ...    caller can assert on status code, body *and* latency (REQ-API-002).
    ...
    ...    ``expected_status=any`` lets negative tests receive 401/422 without failing here.
    [Arguments]    ${path}    ${body}=${None}    ${expected_status}=any    ${session}=${SESSION}
    ${resp}=    POST On Session    ${session}    ${path}    json=${body}    expected_status=${expected_status}
    RETURN    ${resp}

Send Accepted Command
    [Documentation]    POST a command endpoint, assert it was accepted, and return its ``request_id``.
    ...    Use this whenever the command is a *precondition* rather than the thing under test.
    [Arguments]    ${path}    ${body}=${None}
    ${resp}=    Send Command    ${path}    ${body}    expected_status=200
    ${json}=    Set Variable    ${resp.json()}
    Should Be Equal As Strings    ${json}[status]    ACCEPTED
    ...    msg=${path} did not return ACCEPTED: ${json}
    RETURN    ${json}[request_id]

Lock Vehicle
    [Documentation]    Lock the doors. Returns the ``request_id`` of the remote command.
    ${request_id}=    Send Accepted Command    /vehicle/lock
    RETURN    ${request_id}

Unlock Vehicle
    [Documentation]    Unlock the doors. Returns the ``request_id`` of the remote command.
    ${request_id}=    Send Accepted Command    /vehicle/unlock
    RETURN    ${request_id}

Start Preconditioning At
    [Documentation]    Start HVAC pre-conditioning at ``${target_temp_c}`` degC.
    ...    Returns the ``request_id``.
    [Arguments]    ${target_temp_c}
    ${body}=    Create Dictionary    target_temp_c=${target_temp_c}
    ${request_id}=    Send Accepted Command    /climate/start    ${body}
    RETURN    ${request_id}

Stop Preconditioning
    [Documentation]    Stop HVAC pre-conditioning. Returns the ``request_id``.
    ${request_id}=    Send Accepted Command    /climate/stop
    RETURN    ${request_id}

Start Charging To
    [Documentation]    Start a charging session with target ``${target_soc_percent}`` %.
    ...    Returns the ``request_id``.
    [Arguments]    ${target_soc_percent}
    ${body}=    Create Dictionary    target_soc_percent=${target_soc_percent}
    ${request_id}=    Send Accepted Command    /charging/start    ${body}
    RETURN    ${request_id}

Stop Charging
    [Documentation]    Stop the active charging session. Returns the ``request_id``.
    ${request_id}=    Send Accepted Command    /charging/stop
    RETURN    ${request_id}

# ------------------------------------------------------- command lifecycle
Get Command Record
    [Documentation]    Return the command record for ``${request_id}``.
    ...    ``expected_status=any`` allows the REQ-API-004 unknown-id check to reuse this.
    [Arguments]    ${request_id}    ${expected_status}=200
    ${resp}=    GET On Session    ${SESSION}    /vehicle/commands/${request_id}
    ...    expected_status=${expected_status}
    RETURN    ${resp}

Get Command Status
    [Documentation]    Return just the ``status`` field of a command record.
    [Arguments]    ${request_id}
    ${resp}=    Get Command Record    ${request_id}
    RETURN    ${resp.json()}[status]

Command Should Have Reached A Terminal State
    [Documentation]    Fail unless the command is no longer ``ACCEPTED``.
    ...    Terminal means ``COMPLETED`` or ``FAILED`` (docs/API_REFERENCE.md).
    [Arguments]    ${request_id}
    ${status}=    Get Command Status    ${request_id}
    Should Not Be Equal As Strings    ${status}    ACCEPTED
    ...    msg=command ${request_id} is still ACCEPTED

Wait Until Command Reaches Terminal State
    [Documentation]    Poll the command record until it leaves ``ACCEPTED``, then return it.
    ...
    ...    Timeout is ${COMMAND_TERMINAL_TIMEOUT}, the budget REQ-API-003 grants. This is a
    ...    genuine convergence wait on an asynchronous protocol, not a retry that masks a
    ...    flaky result: the value polled is monotonic (ACCEPTED -> terminal, never back).
    [Arguments]    ${request_id}    ${timeout}=${COMMAND_TERMINAL_TIMEOUT}
    Wait Until Keyword Succeeds    ${timeout}    ${COMMAND_POLL_INTERVAL}
    ...    Command Should Have Reached A Terminal State    ${request_id}
    ${resp}=    Get Command Record    ${request_id}
    RETURN    ${resp.json()}

Get Command Outcome
    [Documentation]    Return the terminal record of ``${request_id}``, or the record as-is if
    ...    it never became terminal within the REQ-API-003 budget.
    ...
    ...    Unlike `Wait Until Command Reaches Terminal State` this keyword never fails, so a
    ...    campaign measuring how *often* commands hang can collect every outcome and assert
    ...    on the resulting distribution instead of aborting on the first bad one.
    [Arguments]    ${request_id}    ${timeout}=${COMMAND_TERMINAL_TIMEOUT}
    ${passed}    ${record}=    Run Keyword And Ignore Error
    ...    Wait Until Command Reaches Terminal State    ${request_id}    ${timeout}
    IF    '${passed}' == 'PASS'
        RETURN    ${record}
    END
    ${resp}=    Get Command Record    ${request_id}
    RETURN    ${resp.json()}

List Recent Commands
    [Documentation]    Return the most recent command records, newest first.
    [Arguments]    ${limit}=50
    ${resp}=    GET On Session    ${SESSION}    /vehicle/commands    params=limit=${limit}
    RETURN    ${resp.json()}

# ---------------------------------------------------------------- assertions
Response Time Should Be Below
    [Documentation]    Assert the round trip of ``${response}`` took less than ``${limit_ms}`` ms.
    [Arguments]    ${response}    ${limit_ms}
    ${elapsed_ms}=    Evaluate    ${response.elapsed.total_seconds()} * 1000
    Should Be True    ${elapsed_ms} < ${limit_ms}
    ...    msg=response took ${elapsed_ms} ms, above the ${limit_ms} ms budget
    RETURN    ${elapsed_ms}
