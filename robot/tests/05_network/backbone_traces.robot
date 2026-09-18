*** Settings ***
Documentation     In-vehicle backbone analysis from scenario PCAPs.
...
...               The network is the one interface that cannot be talked out of. A REST
...               command with no matching gRPC call on the backbone proves the vehicle was
...               never asked; an RST_STREAM proves who gave up on whom and after how long.
...
...               Captures come from the scenario runner (``SCENARIO_LABEL=ci``), which runs
...               inside the gateway network namespace so all three legs land in one file.
...               That vantage point has a consequence this suite is built around: the
...               capture sees **everything** the gateway does, not only the scenario being
...               recorded. Counting calls per method would therefore be sound only while the
...               capture has the bench to itself. Instead, each command is correlated by its
...               ``request_id``, which the gateway embeds in the gRPC payload -- a result
...               that holds whatever else is talking to the bench at the time.
...
...               Every finding is paired with the same measurement on the golden capture in
...               ``traces/reference/``: a clean reference and a dirty build is a difference
...               in the software, not in the method.

Resource          ../../resources/bench.resource
Resource          ../../resources/pcap.resource
Library           Collections
Library           OperatingSystem
Suite Setup       Select Scenario Capture Directory
Force Tags        network    pcap


*** Variables ***
${S01}      S01_lock_unlock_cycles.pcap
${S02}      S02_climate_preconditioning.pcap
${S03}      S03_charging_session.pcap
${S04}      S04_api_validation.pcap
# vehicle-net addresses are fixed in docker-compose.yml so traces compare across runs.
${GATEWAY_IP}       172.28.0.10
${BODY_ECU_IP}      172.28.0.30


*** Test Cases ***
Every Charging Command Reaches The Body Ecu On The Backbone
    [Documentation]    REQ-ECU-002 / REQ-CHG-002 on the wire: every charging command the cloud
    ...    accepted shall appear on the backbone as a gRPC call carrying its request_id.
    ...
    ...    This is the cleanest possible proof that a command was dropped inside the gateway:
    ...    the cloud leg and the backbone leg are in one file, at one vantage point, at the
    ...    same instant, and each command is identified individually rather than counted.
    [Tags]    req:REQ-ECU-002    req:REQ-CHG-002
    ${missing}=    Commands Missing From The Backbone    ${S03}    /charging/
    Should Be Empty    ${missing}
    ...    msg=charging commands accepted by the cloud that never reached the Body ECU:\n${{ chr(10).join($missing) }}

Every Climate Command Reaches The Body Ecu On The Backbone
    [Documentation]    REQ-ECU-002 for the climate domain, by the same per-command correlation.
    [Tags]    req:REQ-ECU-002    req:REQ-CLI-001
    ${missing}=    Commands Missing From The Backbone    ${S02}    /climate/
    Should Be Empty    ${missing}
    ...    msg=climate commands accepted by the cloud that never reached the Body ECU:\n${{ chr(10).join($missing) }}

Every Locking Command Reaches The Body Ecu On The Backbone
    [Documentation]    REQ-ECU-002 for central locking, by the same per-command correlation.
    [Tags]    req:REQ-ECU-002    req:REQ-LCK-001
    ${missing}=    Commands Missing From The Backbone    ${S01}    /vehicle/
    Should Be Empty    ${missing}
    ...    msg=locking commands accepted by the cloud that never reached the Body ECU:\n${{ chr(10).join($missing) }}

No Door Lock Stream Is Cancelled By The Gateway
    [Documentation]    REQ-NET-001: gRPC deadlines used by the gateway shall accommodate the
    ...    Body ECU actuation times; in a nominal capture no SetDoorLock stream shall be
    ...    cancelled (RST_STREAM) by the gateway.
    ...
    ...    Each RST_STREAM is correlated back to the call that opened the stream, so the
    ...    failure names the method and how long the gateway waited before giving up. That
    ...    elapsed time, next to the calibrated deadline, is the whole argument.
    ...
    ...    Only resets sent by the gateway are counted: when a client abandons a call the
    ...    peer resets the same stream in response, and attributing the ECU's answer to the
    ...    gateway would overstate the finding.
    [Tags]    req:REQ-NET-001    req:REQ-LCK-003
    ${pcap}=    Scenario Capture    ${S01}
    ${cancelled}=    Get Cancelled Grpc Calls    ${pcap}    SetDoorLock    cancelled_by=${GATEWAY_IP}
    ${all_calls}=    Get Grpc Calls    ${pcap}
    ${lock_calls}=   Evaluate    [c for c in $all_calls if c['method'] == 'SetDoorLock']
    ${rendered}=     Format Cancelled Grpc Calls    ${cancelled}
    Log    ${{ len($lock_calls) }} SetDoorLock calls in ${SCENARIO_LABEL}/${S01}, ${{ len($cancelled) }} cancelled by the gateway
    Log    Cancelled streams:\n${rendered}
    Should Be Empty    ${cancelled}
    ...    msg=the gateway cancelled ${{ len($cancelled) }} of ${{ len($lock_calls) }} SetDoorLock streams with RST_STREAM:\n${rendered}

The Reference Bench Shows No Cancelled Door Lock Streams
    [Documentation]    Control for the test above, against the golden capture in
    ...    ``traces/reference/`` recorded on a bench the validation team accepted.
    ...
    ...    Without this, an RST_STREAM finding could be dismissed as normal gRPC behaviour or
    ...    as an artefact of how the capture is taken. The reference is recorded at the same
    ...    vantage point with the same scenario, so a difference between the two is a
    ...    difference in the software, not in the method.
    [Tags]    req:REQ-NET-001    reference
    ${pcap}=    Join Path    ${REFERENCE_DIR}    ${S01}
    ${cancelled}=    Get Cancelled Grpc Calls    ${pcap}    SetDoorLock    cancelled_by=${GATEWAY_IP}
    ${rendered}=    Format Cancelled Grpc Calls    ${cancelled}
    Should Be Empty    ${cancelled}
    ...    msg=the golden reference capture itself contains cancelled SetDoorLock streams; the comparison baseline is not clean and the REQ-NET-001 finding must be re-assessed:\n${rendered}

The Reference Bench Forwards Every Charging Command
    [Documentation]    Control for the charging test: on the golden capture both charging
    ...    commands appear on the backbone. This establishes that "every command reaches the
    ...    ECU" is the correct expectation for this scenario rather than an assumption of mine.
    [Tags]    req:REQ-ECU-002    reference
    ${summary}=    Join Path    ${REFERENCE_DIR}    run_summary.json
    ${pcap}=       Join Path    ${REFERENCE_DIR}    ${S03}
    ${commands}=   Get Scenario Commands    ${summary}    S03_charging_session    path_contains=/charging/
    Should Not Be Empty    ${commands}    msg=the reference timeline lists no charging commands
    ${missing}=    Get Commands Missing From The Backbone    ${pcap}    ${commands}
    Should Be Empty    ${missing}
    ...    msg=the golden reference itself does not forward every charging command; the baseline is not clean:\n${{ chr(10).join($missing) }}

The Gateway Supervises The Body Ecu On The Backbone
    [Documentation]    REQ-ECU-001 observed on the wire rather than in the log: the heartbeat
    ...    is visible as periodic Heartbeat calls from the gateway to the Body ECU.
    [Tags]    req:REQ-ECU-001
    ${pcap}=    Scenario Capture    ${S01}
    ${calls}=    Get Grpc Calls    ${pcap}
    ${heartbeats}=    Evaluate    [c for c in $calls if c['method'] == 'Heartbeat']
    Log    ${{ len($heartbeats) }} Heartbeat calls in ${SCENARIO_LABEL}/${S01}
    Should Not Be Empty    ${heartbeats}
    ...    msg=no Heartbeat calls on the backbone; the gateway is not supervising the Body ECU
    ${from_gateway}=    Evaluate    [c for c in $heartbeats if c['src'] == '${GATEWAY_IP}']
    Should Be Equal As Integers    ${{ len($from_gateway) }}    ${{ len($heartbeats) }}
    ...    msg=some Heartbeat calls did not originate from the gateway (${GATEWAY_IP}); check the capture vantage point


*** Keywords ***
Commands Missing From The Backbone
    [Documentation]    Return the accepted commands of a scenario that produced no gRPC call
    ...    carrying their request_id.
    ...
    ...    Fails loudly if the scenario contains no matching command at all, so a capture that
    ...    recorded nothing cannot be mistaken for a clean result.
    [Arguments]    ${capture}    ${path_contains}
    ${pcap}=       Scenario Capture    ${capture}
    ${summary}=    Scenario Capture    run_summary.json
    ${scenario}=   Set Variable    ${capture.replace('.pcap', '')}
    ${commands}=   Get Scenario Commands    ${summary}    ${scenario}    path_contains=${path_contains}
    Should Not Be Empty    ${commands}
    ...    msg=the timeline of ${scenario} lists no accepted command matching '${path_contains}'; the capture cannot validate anything
    Log    Correlating ${{ len($commands) }} accepted '${path_contains}' commands of ${scenario} against ${SCENARIO_LABEL}/${capture}
    ${missing}=    Get Commands Missing From The Backbone    ${pcap}    ${commands}
    RETURN    ${missing}
