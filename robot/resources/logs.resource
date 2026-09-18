*** Settings ***
Documentation     DLT log correlation across backend, gateway and Body ECU.
...
...               Every keyword here takes the suite's ``since`` mark, so assertions see
...               only lines written by the current run. Without that, REQ-LOG-002 would
...               fail permanently on any bench whose log file survived an earlier restart.

Library           DltLogLibrary    logs_dir=${LOGS_DIR}
Library           Collections


*** Keywords ***
Command Should Be Traceable Across All Nodes
    [Documentation]    Assert the ``request_id`` appears in the backend, gateway **and**
    ...    Body ECU logs (REQ-LOG-001), and return the merged time-ordered entries.
    [Arguments]    ${request_id}    ${since}=${None}
    ${nodes}=      Get Nodes Tracing Request Id    ${request_id}    since=${since}
    ${entries}=    Get Log Entries For Request Id    ${request_id}    since=${since}
    ${rendered}=   Format Log Entries    ${entries}
    Log    Correlated trace for ${request_id}:\n${rendered}
    Lists Should Be Equal    ${nodes}    ${{ ['backend', 'body_ecu', 'gateway'] }}
    ...    msg=request ${request_id} is not traceable across all three nodes; found in ${nodes}
    RETURN    ${entries}

Gateway Log Should Have No Errors
    [Documentation]    Assert the gateway logged no ``ERROR`` since ``${since}`` (REQ-LOG-002).
    ...
    ...    The ``GNSS`` and ``NET`` contexts are excluded: docs/ARCHITECTURE.md describes
    ...    them as background telematics chatter present on every bench, unrelated to the
    ...    remote-command flows this requirement is about.
    [Arguments]    ${since}=${None}
    ${errors}=    Get Gateway Error Entries    since=${since}
    ${rendered}=  Format Log Entries    ${errors}
    Should Be Empty    ${errors}
    ...    msg=gateway logged ${{ len($errors) }} ERROR entries during a nominal flow:\n${rendered}

Get Gateway Entries
    [Documentation]    Return gateway log entries matching the given filters.
    [Arguments]    ${since}=${None}    ${level}=${None}    ${ctx}=${None}    ${contains}=${None}
    ${entries}=    Get Log Entries    node=gateway    since=${since}    level=${level}
    ...    ctx=${ctx}    contains=${contains}
    RETURN    ${entries}

Get Dropped Command Entries
    [Documentation]    Return the gateway lines reporting a command it could not map and
    ...    therefore discarded. REQ-ECU-002 forbids dropping a command silently, so any
    ...    entry here is a finding.
    [Arguments]    ${since}=${None}
    ${entries}=    Get Gateway Entries    since=${since}    ctx=CMD    contains=no handler for command
    RETURN    ${entries}

Get Grpc Calls From Log
    [Documentation]    Return the gateway ``GRPC`` lines for outgoing calls (``->``) since
    ...    ``${since}``, optionally filtered to one method such as ``SetDoorLock``.
    [Arguments]    ${since}=${None}    ${method}=${None}
    ${filter}=    Set Variable If    $method is None    ->    ${method} ->
    ${entries}=    Get Gateway Entries    since=${since}    ctx=GRPC    contains=${filter}
    RETURN    ${entries}

Log Excerpt Should Be Attached
    [Documentation]    Attach a rendered log excerpt to the Robot report, so a failure carries
    ...    its own evidence and an RCA can quote it straight from log.html.
    [Arguments]    ${title}    ${entries}
    ${rendered}=    Format Log Entries    ${entries}
    Log    ${title}:\n${rendered}
