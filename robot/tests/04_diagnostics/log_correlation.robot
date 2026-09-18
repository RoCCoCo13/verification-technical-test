*** Settings ***
Documentation     Diagnosability: can a field engineer follow one command across the system?
...
...               REQ-LOG-001 and REQ-LOG-002 are not cosmetic. A command that cannot be
...               traced cannot be diagnosed in the field, and ERROR lines during a nominal
...               flow are how a supplier's own logs contradict a "works as designed" reply.
...
...               Every query is scoped to the suite's log mark, so these tests assert on
...               lines this run produced and never on a file left behind by an earlier one.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Force Tags        diagnostics    log


*** Test Cases ***
A Remote Command Is Traceable Across All Three Nodes
    [Documentation]    REQ-LOG-001: every remote command is traceable through its request_id
    ...    in the backend, gateway and Body ECU logs.
    [Tags]    req:REQ-LOG-001
    ${mark}=    Mark Log Position
    ${request_id}=    Lock Vehicle
    Get Command Outcome    ${request_id}
    Wait Until Keyword Succeeds    10s    500ms
    ...    Command Should Be Traceable Across All Nodes    ${request_id}    since=${mark}

A Remote Command Is Visible In Logcat On The Gateway
    [Documentation]    REQ-LOG-001, second clause: the command is also visible in the Android
    ...    log under the TelematicsSvc tag, which is what a technician reads on the device.
    [Tags]    req:REQ-LOG-001    adb
    ${request_id}=    Unlock Vehicle
    Get Command Outcome    ${request_id}
    Wait Until Keyword Succeeds    10s    500ms
    ...    Logcat Should Contain    ${request_id}    TelematicsSvc:I *:S

Nominal Flows Produce No Errors In The Gateway Log
    [Documentation]    REQ-LOG-002: nominal lock/unlock, climate and charging flows shall
    ...    produce no ERROR-level entries in the gateway log.
    ...
    ...    "Nominal" is exercised literally: one pass of each documented happy path, inside a
    ...    log window opened immediately before. Background GNSS/NET chatter is excluded as
    ...    unrelated noise (docs/ARCHITECTURE.md), so anything reported here belongs to the
    ...    remote-command flows themselves.
    [Tags]    req:REQ-LOG-002
    ${mark}=    Mark Log Position
    Run Nominal Flows
    Sleep    2s    reason=let the gateway finish its post-command sync before reading the log
    [Teardown]    Restore Idle Domains
    Gateway Log Should Have No Errors    since=${mark}

The Gateway Never Discards A Command Without Reporting It
    [Documentation]    REQ-ECU-002: the gateway shall forward every queued command to the Body
    ...    ECU and shall never drop one silently; a command that cannot be executed shall be
    ...    reported FAILED with a reason.
    ...
    ...    Checked from the vehicle's own records rather than from the cloud: the gateway log
    ...    says whether it found a handler, and the command journal says what it did about it.
    ...    A command journalled DROPPED with no result callback is the exact shape of a
    ...    silent drop.
    [Tags]    req:REQ-ECU-002    adb
    ${mark}=    Mark Log Position
    ${request_ids}=    Submit One Of Every Command
    Sleep    3s    reason=allow the gateway worker to drain the queue and journal every outcome
    ${dropped}=    Get Dropped Command Entries    since=${mark}
    Log Excerpt Should Be Attached    Gateway entries reporting a discarded command    ${dropped}
    ${silent}=    Collect Silently Dropped Commands    ${request_ids}
    [Teardown]    Restore Idle Domains
    Should Be Empty    ${silent}
    ...    msg=commands the vehicle discarded without reporting a result to the cloud:\n${{ chr(10).join($silent) }}

Every Forwarded Command Produces Exactly One Grpc Call
    [Documentation]    REQ-ECU-002: each queued remote command becomes exactly one gRPC call
    ...    to the Body ECU, within 1 s of queuing.
    ...
    ...    Counted from the gateway's own GRPC log context. Zero calls means the command was
    ...    dropped; more than one would mean an unwanted retry that could actuate twice.
    [Tags]    req:REQ-ECU-002
    ${mark}=    Mark Log Position
    ${request_id}=    Lock Vehicle
    Get Command Outcome    ${request_id}
    Sleep    1s    reason=REQ-ECU-002 grants 1 s between queuing and the outgoing gRPC call
    ${calls}=    Get Grpc Calls From Log    since=${mark}
    ${for_command}=    Evaluate    [c for c in $calls if c['fields'].get('req') == '${request_id}']
    Log Excerpt Should Be Attached    Outgoing gRPC calls for ${request_id}    ${for_command}
    Should Be Equal As Integers    ${{ len($for_command) }}    1
    ...    msg=command ${request_id} produced ${{ len($for_command) }} outgoing gRPC calls, expected exactly 1


*** Keywords ***
Run Nominal Flows
    [Documentation]    Execute one pass of each documented happy path: lock/unlock, climate
    ...    start/stop at a valid set point, charging start/stop at a valid target.
    ${lock}=      Lock Vehicle
    Get Command Outcome    ${lock}
    ${unlock}=    Unlock Vehicle
    Get Command Outcome    ${unlock}
    ${climate_on}=     Start Preconditioning At    22.0
    Get Command Outcome    ${climate_on}
    ${climate_off}=    Stop Preconditioning
    Get Command Outcome    ${climate_off}
    ${charge_on}=      Start Charging To    80
    Get Command Outcome    ${charge_on}
    ${charge_off}=     Stop Charging
    Get Command Outcome    ${charge_off}

Submit One Of Every Command
    [Documentation]    Submit one of each of the six remote commands and return their
    ...    request_ids keyed by endpoint.
    ${ids}=    Create Dictionary
    FOR    ${path}    IN    /vehicle/lock    /vehicle/unlock    /climate/start    /climate/stop
    ...                    /charging/start    /charging/stop
        ${request_id}=    Send Accepted Command    ${path}
        Set To Dictionary    ${ids}    ${path}=${request_id}
    END
    RETURN    ${ids}

Collect Silently Dropped Commands
    [Documentation]    Return a description of every command the vehicle journalled as
    ...    discarded while the cloud was left without a terminal result.
    ...
    ...    Both halves have to hold for it to count as a *silent* drop: the vehicle threw the
    ...    command away, and nobody told the cloud. That distinction is what REQ-ECU-002 is
    ...    about, and it is what makes the finding actionable rather than cosmetic.
    [Arguments]    ${request_ids}
    @{silent}=    Create List
    FOR    ${path}    ${request_id}    IN    &{request_ids}
        ${journal}=    Get Journal Record For Command    ${request_id}
        ${cloud_status}=    Get Command Status    ${request_id}
        Log    ${path}: vehicle journal state=${journal}[state], cloud status=${cloud_status}
        IF    '${journal}[state]' == 'DROPPED' and '${cloud_status}' == 'ACCEPTED'
            Append To List    ${silent}
            ...    ${path} (${request_id}): vehicle journalled DROPPED, cloud still ACCEPTED - no FAILED result was ever reported
        END
    END
    RETURN    ${silent}

Restore Idle Domains
    [Documentation]    Best-effort teardown: stop climate and charging for the next test.
    Run Keyword And Ignore Error    Send Command    /climate/stop     expected_status=any
    Run Keyword And Ignore Error    Send Command    /charging/stop    expected_status=any
