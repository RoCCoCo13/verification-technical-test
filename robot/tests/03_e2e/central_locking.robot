*** Settings ***
Documentation     Central locking end to end: cloud command -> gateway VHAL -> Body ECU.
...
...               Each functional test asserts on all three interfaces, because agreement
...               between them is the requirement (REQ-LCK-001/002), not a bonus. The
...               reliability campaign at the end runs 20 real cycles and asserts on the
...               measured outcome distribution: an intermittent fault is quantified, never
...               retried away.
...
...               Requirements are kept strictly apart. REQ-LCK-001/002 own the resulting
...               vehicle *state*; REQ-LCK-003 owns the reported command *outcome* and the
...               consistency between the two. On a build where commands intermittently
...               report FAILED while the doors actuate correctly, merging the two would
...               blame the wrong requirement and make the state tests flip between runs.

Resource          ../../resources/bench.resource
Library           Collections
Suite Setup       Open Bench Session And Reset
Test Setup        Reset Bench To Known State
Force Tags        e2e    locking


*** Variables ***
# REQ-LCK-003: over 20 consecutive cycles, 0 commands shall be FAILED.
${LOCK_CYCLES}                  20
${ALLOWED_FAILED_COMMANDS}      0


*** Test Cases ***
Lock Command Locks The Doors On Every Interface
    [Documentation]    REQ-LCK-001: POST /vehicle/lock results in doors.locked=true in the
    ...    cloud status, DOOR_LOCK=1 in the gateway VHAL and doors_locked=true on the Body
    ...    ECU, all within 10 s.
    [Tags]    req:REQ-LCK-001    rest    adb    grpc
    Unlock Vehicle And Wait
    ${request_id}=    Lock Vehicle
    ${record}=    Wait Until Command Reaches Terminal State    ${request_id}
    # REQ-LCK-001 is about the resulting vehicle *state*, not the reported command
    # outcome. The outcome is REQ-LCK-003's subject and is asserted there. Keeping them
    # apart matters on this build: lock commands intermittently report FAILED while the
    # doors actuate correctly, and folding that into this test would attribute the defect
    # to the wrong requirement and make this one flip between runs.
    Log    Command outcome (asserted by REQ-LCK-003, not here): ${record}[status] / ${record}[reason]
    Wait Until Body Ecu Reports        doors_locked    True
    Wait Until Vhal Property Is        DOOR_LOCK       1
    Wait Until Cloud Reports Doors Locked    ${True}

Unlock Command Unlocks The Doors On Every Interface
    [Documentation]    REQ-LCK-002: the mirror of REQ-LCK-001 with value false/0.
    [Tags]    req:REQ-LCK-002    rest    adb    grpc
    Lock Vehicle And Wait
    ${request_id}=    Unlock Vehicle
    ${record}=    Wait Until Command Reaches Terminal State    ${request_id}
    # See the note in the lock case: the command outcome belongs to REQ-LCK-003.
    Log    Command outcome (asserted by REQ-LCK-003, not here): ${record}[status] / ${record}[reason]
    Wait Until Body Ecu Reports        doors_locked    False
    Wait Until Vhal Property Is        DOOR_LOCK       0
    Wait Until Cloud Reports Doors Locked    ${False}

Twenty Lock Unlock Cycles Complete Without A Single Failure
    [Documentation]    REQ-LCK-003: over 20 consecutive cycles, 0 commands shall be FAILED.
    ...    Body ECU door actuation takes up to 1 s, which the gateway is required to
    ...    accommodate.
    ...
    ...    The campaign runs all ${LOCK_CYCLES} cycles and measures the failure rate before
    ...    asserting. Stopping at the first failure would report "it failed once"; running
    ...    the full campaign reports *how often* and with which reason, which is what
    ...    distinguishes a flaky test from an intermittent product fault and what an RCA
    ...    needs in order to be believed.
    [Tags]    req:REQ-LCK-003    req:REQ-ECU-002    slow    reliability
    ${outcomes}=    Run Lock Unlock Campaign    ${LOCK_CYCLES}
    ${failed}=      Evaluate    [o for o in $outcomes if o['status'] != 'COMPLETED']
    ${reasons}=     Evaluate    sorted({o['reason'] for o in $failed})
    ${rate}=        Evaluate    round(100.0 * len($failed) / len($outcomes), 1)
    Log    ${{ len($failed) }} of ${{ len($outcomes) }} commands did not complete (${rate} %), reasons: ${reasons}
    Log    Full campaign outcomes: ${outcomes}
    Should Be True    ${{ len($failed) }} <= ${ALLOWED_FAILED_COMMANDS}
    ...    msg=${{ len($failed) }} of ${{ len($outcomes) }} lock/unlock commands failed (${rate} %), reasons ${reasons}; REQ-LCK-003 allows ${ALLOWED_FAILED_COMMANDS}

A Failed Lock Command Leaves The Vehicle State Untouched
    [Documentation]    REQ-LCK-003, second clause: a command reported FAILED shall not have
    ...    changed the vehicle state.
    ...
    ...    This is the dangerous half of the requirement. The test drives cycles until it
    ...    observes a FAILED command, then compares the Body ECU state before and after it.
    ...    If the vehicle moved anyway, the cloud and the car disagree about whether the
    ...    doors are locked - and the user was told the command failed.
    ...
    ...    Skips itself, rather than passing, when no failure occurs in the sample: a clean
    ...    sample proves nothing about this clause and must not be reported as evidence.
    [Tags]    req:REQ-LCK-003    reliability
    ${evidence}=    Find First Failed Command With State Comparison    ${LOCK_CYCLES}
    IF    ${evidence} == ${None}
        Skip    no FAILED lock/unlock command occurred in ${LOCK_CYCLES} cycles, so this clause could not be exercised
    END
    Log    Failed command evidence: ${evidence}
    Should Be Equal As Strings    ${evidence}[before]    ${evidence}[after]
    ...    msg=command ${evidence}[request_id] was reported ${evidence}[status] (${evidence}[reason]) but the Body ECU door state changed from ${evidence}[before] to ${evidence}[after]

Locking Does Not Disturb Climate Or Charging
    [Documentation]    REQ-LCK-004: lock/unlock shall not modify the climate or charging state.
    ...
    ...    Pre-conditioning and charging are started first, so the test has something to
    ...    disturb; a test run with both domains idle would pass regardless.
    [Tags]    req:REQ-LCK-004    grpc
    ${climate_id}=    Start Preconditioning At    22.0
    Wait Until Command Reaches Terminal State    ${climate_id}
    ${charging_id}=    Start Charging To    90
    Wait Until Command Reaches Terminal State    ${charging_id}
    Wait Until Body Ecu Reports    climate_active    True
    Wait Until Body Ecu Reports    charging_state    CHARGING
    ${before}=    Capture Body Ecu State
    ${unlock_id}=    Unlock Vehicle
    Wait Until Command Reaches Terminal State    ${unlock_id}
    ${lock_id}=    Lock Vehicle
    Wait Until Command Reaches Terminal State    ${lock_id}
    ${after}=    Capture Body Ecu State
    Log    Before lock/unlock: ${before}
    Log    After lock/unlock: ${after}
    [Teardown]    Restore Idle Domains
    Body Ecu Fields Should Be Unchanged    ${before}    ${after}
    ...    climate_active    climate_target_raw    charging_state    target_soc_percent


*** Keywords ***
Wait Until Cloud Reports Doors Locked
    [Documentation]    Wait until ``/vehicle/status`` shows the expected lock state.
    ...    The cloud only learns the state from the gateway's report, so it converges last;
    ...    10 s is the REQ-LCK-001 budget and covers two 5 s state-poll periods.
    [Arguments]    ${expected}    ${timeout}=10s
    Wait Until Keyword Succeeds    ${timeout}    500ms    Cloud Doors Locked Should Be    ${expected}

Cloud Doors Locked Should Be
    [Documentation]    Assert the cloud view of the door lock state.
    [Arguments]    ${expected}
    ${status}=    Get Vehicle Status
    Should Be Equal    ${status}[doors][locked]    ${expected}
    ...    msg=cloud reports doors.locked=${status}[doors][locked], expected ${expected}

Lock Vehicle And Wait
    [Documentation]    Precondition helper: leave the doors locked, whatever they were.
    ${request_id}=    Lock Vehicle
    Get Command Outcome    ${request_id}
    Wait Until Body Ecu Reports    doors_locked    True

Unlock Vehicle And Wait
    [Documentation]    Precondition helper: leave the doors unlocked, whatever they were.
    ${request_id}=    Unlock Vehicle
    Get Command Outcome    ${request_id}
    Wait Until Body Ecu Reports    doors_locked    False

Run Lock Unlock Campaign
    [Documentation]    Run ``${cycles}`` unlock/lock cycles and return one outcome dict per
    ...    command: ``cycle``, ``command``, ``request_id``, ``status``, ``reason``,
    ...    ``elapsed_ms``. Never fails - measuring is the point.
    [Arguments]    ${cycles}
    @{outcomes}=    Create List
    FOR    ${index}    IN RANGE    1    ${cycles} + 1
        FOR    ${command}    IN    unlock    lock
            ${request_id}=    Send Accepted Command    /vehicle/${command}
            ${record}=    Get Command Outcome    ${request_id}
            ${outcome}=    Create Dictionary
            ...    cycle=${index}    command=${command}    request_id=${request_id}
            ...    status=${record}[status]    reason=${record}[reason]
            ...    elapsed_ms=${record}[elapsed_ms]
            Append To List    ${outcomes}    ${outcome}
        END
    END
    RETURN    ${outcomes}

Find First Failed Command With State Comparison
    [Documentation]    Drive lock/unlock commands until one is reported FAILED, capturing the
    ...    Body ECU door state immediately before and after that command. Returns ``None``
    ...    if every command in the sample completed.
    [Arguments]    ${max_cycles}
    FOR    ${index}    IN RANGE    1    ${max_cycles} + 1
        FOR    ${command}    IN    unlock    lock
            ${before}=    Get Body Ecu Field    doors_locked
            ${request_id}=    Send Accepted Command    /vehicle/${command}
            ${record}=    Get Command Outcome    ${request_id}
            IF    '${record}[status]' == 'FAILED'
                # The actuator may still be travelling when the gateway gives up, so allow
                # the Body ECU to settle before reading the state the command left behind.
                Sleep    1500ms    reason=Body ECU door actuation takes up to 1 s (REQ-LCK-003)
                ${after}=    Get Body Ecu Field    doors_locked
                ${evidence}=    Create Dictionary
                ...    request_id=${request_id}    command=${command}
                ...    status=${record}[status]    reason=${record}[reason]
                ...    elapsed_ms=${record}[elapsed_ms]
                ...    before=${before}    after=${after}
                RETURN    ${evidence}
            END
        END
    END
    RETURN    ${None}

Restore Idle Domains
    [Documentation]    Best-effort teardown: stop climate and charging for the next test.
    Run Keyword And Ignore Error    Send Command    /climate/stop     expected_status=any
    Run Keyword And Ignore Error    Send Command    /charging/stop    expected_status=any
