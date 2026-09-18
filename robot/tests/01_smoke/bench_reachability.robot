*** Settings ***
Documentation     Smoke: every interface of the bench answers before any feature test runs.
...
...               This suite is the entry criterion of the whole campaign. If it is red, the
...               feature results below it carry no information - a failed lock test means
...               nothing if the Body ECU was simply unreachable. Keep it fast and keep it
...               first.

Resource          ../../resources/bench.resource
Suite Setup       Open Backend Session
Force Tags        smoke


*** Test Cases ***
Backend Rest Api Answers
    [Documentation]    The cloud API is up and reports the expected release.
    [Tags]    rest    req:REQ-API-005
    ${health}=    Get Backend Health
    Should Be Equal As Strings    ${health}[status]    ok
    Should Be Equal As Strings    ${health}[version]    CVB_API_1.8.3
    ...    msg=backend release under test is '${health}[version]', expected CVB_API_1.8.3

Backend Reports A Vehicle
    [Documentation]    The backend has received a state report and knows the vehicle.
    [Tags]    rest    req:REQ-API-005
    ${status}=    Get Vehicle Status
    Should Be Equal As Strings    ${status}[vin]    WVGZZZ5NZTW000042
    Should Be Equal As Strings    ${status}[source]    telematics_report
    ...    msg=backend has no vehicle report (source=${status}[source]); the gateway may be down

Gateway Answers Over Adb
    [Documentation]    The gateway ECU is reachable over ADB and reports itself booted with
    ...    the telematics service running.
    [Tags]    adb    req:REQ-ADB-001
    Gateway Should Be Online

Gateway Runs The Release Under Test
    [Documentation]    The gateway carries the software release this campaign validates.
    [Tags]    adb    req:REQ-ADB-001
    ${version}=    Get Gateway Software Version
    Should Be Equal As Strings    ${version}    TCU_GW2_SW_4.12.0
    ...    msg=gateway runs '${version}', expected TCU_GW2_SW_4.12.0

Body Ecu Answers Over Grpc
    [Documentation]    The Body ECU serves ``GetBodyState``, the oracle every end-to-end test
    ...    depends on.
    [Tags]    grpc    req:REQ-ADB-001
    Body Ecu Should Be Reachable

Dlt Logs Are Being Written
    [Documentation]    All three nodes are writing their DLT log, so log-based evidence is
    ...    available to the diagnostics suites.
    [Tags]    log    req:REQ-LOG-001
    ${mark}=    Mark Log Position
    Wait Until Keyword Succeeds    15s    1s    All Nodes Should Have Logged Since    ${mark}


*** Keywords ***
All Nodes Should Have Logged Since
    [Documentation]    Assert each node produced at least one log line after ``${since}``.
    ...    Waits because the quietest node only logs on its 5 s state-poll period.
    [Arguments]    ${since}
    FOR    ${node}    IN    backend    gateway    body_ecu
        ${entries}=    Get Log Entries    node=${node}    since=${since}
        Should Not Be Empty    ${entries}    msg=node '${node}' has written no log line since ${since}
    END
