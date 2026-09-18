*** Settings ***
Documentation     In-vehicle backbone analysis from scenario PCAPs.
...
...               The network is the one interface that cannot be talked out of. A REST
...               command with no matching gRPC call on the backbone proves the vehicle was
...               never asked; an RST_STREAM proves who gave up on whom and after how long.
...               Both are facts a supplier cannot attribute to the test harness.
...
...               Captures come from the scenario runner (``SCENARIO_LABEL=ci``), which runs
...               inside the gateway network namespace so all three legs land in one file.
...               If no fresh capture exists the suite falls back to ``traces/samples/``,
...               recorded by the validation team on this same build, and says so in the
...               report rather than skipping silently.

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
No Door Lock Stream Is Cancelled By The Gateway
    [Documentation]    REQ-NET-001: gRPC deadlines used by the gateway shall accommodate the
    ...    Body ECU actuation times; in a nominal capture no SetDoorLock stream shall be
    ...    cancelled (RST_STREAM) by the gateway.
    ...
    ...    Each RST_STREAM is correlated back to the call that opened the stream, so the
    ...    failure message names the method and how long the gateway waited before giving up.
    ...    That elapsed time, next to the calibrated deadline, is the whole argument.
    [Tags]    req:REQ-NET-001    req:REQ-LCK-003
    ${pcap}=    Scenario Capture    ${S01}
    ${cancelled}=    Get Cancelled Grpc Calls    ${pcap}    SetDoorLock    cancelled_by=${GATEWAY_IP}
    ${all_calls}=    Get Grpc Calls    ${pcap}
    ${lock_calls}=   Evaluate    [c for c in $all_calls if c['method'] == 'SetDoorLock']
    ${rendered}=    Format Cancelled Grpc Calls    ${cancelled}
    Log    ${{ len($lock_calls) }} SetDoorLock calls in ${SCENARIO_LABEL}/${S01}, ${{ len($cancelled) }} cancelled
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
    Should Be Empty    ${cancelled}
    ...    msg=the golden reference capture itself contains cancelled SetDoorLock streams (${cancelled}); the comparison baseline is not clean and the REQ-NET-001 finding must be re-assessed

Every Charging Command Reaches The Body Ecu On The Backbone
    [Documentation]    REQ-ECU-002 on the wire: in the charging scenario the backend issues a
    ...    start and a stop, so the backbone must carry two SetCharging calls.
    ...
    ...    Counting REST requests against gRPC calls in the same capture is the cleanest
    ...    possible proof that a command was dropped inside the gateway: both legs are in one
    ...    file, taken at one vantage point, at the same instant.
    [Tags]    req:REQ-ECU-002    req:REQ-CHG-002
    ${pcap}=    Scenario Capture    ${S03}
    ${rest_starts}=    Count Http Requests    ${pcap}    /charging/start
    ${rest_stops}=     Count Http Requests    ${pcap}    /charging/stop
    ${grpc_calls}=     Count Grpc Calls      ${pcap}    SetCharging
    ${expected}=    Evaluate    ${rest_starts} + ${rest_stops}
    Log    ${SCENARIO_LABEL}/${S03}: ${rest_starts} REST start + ${rest_stops} REST stop = ${expected} expected SetCharging calls; ${grpc_calls} observed on the backbone
    Should Be Equal As Integers    ${grpc_calls}    ${expected}
    ...    msg=${expected} charging commands were sent from the cloud but only ${grpc_calls} SetCharging calls reached the Body ECU; ${{ ${expected} - ${grpc_calls} }} never left the gateway

The Reference Bench Forwards Both Charging Commands
    [Documentation]    Control for the test above: on the golden capture the start and the stop
    ...    both appear on the backbone, which establishes that two SetCharging calls is the
    ...    correct expectation for this scenario rather than an assumption of mine.
    [Tags]    req:REQ-ECU-002    reference
    ${pcap}=    Join Path    ${REFERENCE_DIR}    ${S03}
    ${starts}=    Count Http Requests    ${pcap}    /charging/start
    ${stops}=     Count Http Requests    ${pcap}    /charging/stop
    ${rest_commands}=    Evaluate    ${starts} + ${stops}
    ${grpc_calls}=    Count Grpc Calls    ${pcap}    SetCharging
    Log    Reference ${S03}: ${rest_commands} REST charging commands, ${grpc_calls} SetCharging calls on the backbone
    Should Be Equal As Integers    ${grpc_calls}    ${rest_commands}
    ...    msg=the golden reference itself does not forward every charging command (${grpc_calls} of ${rest_commands}); the baseline is not clean

Each Remote Command Produces One Backbone Call In The Climate Scenario
    [Documentation]    REQ-ECU-002: the climate scenario issues one start and one stop, so the
    ...    backbone shall carry exactly two SetClimate calls - no drop and no retry.
    [Tags]    req:REQ-ECU-002    req:REQ-CLI-001
    ${pcap}=    Scenario Capture    ${S02}
    ${starts}=    Count Http Requests    ${pcap}    /climate/start
    ${stops}=     Count Http Requests    ${pcap}    /climate/stop
    ${rest_commands}=    Evaluate    ${starts} + ${stops}
    ${grpc_calls}=    Count Grpc Calls    ${pcap}    SetClimate
    Log    ${SCENARIO_LABEL}/${S02}: ${rest_commands} REST climate commands, ${grpc_calls} SetClimate calls on the backbone
    Should Be Equal As Integers    ${grpc_calls}    ${rest_commands}
    ...    msg=${rest_commands} climate commands from the cloud produced ${grpc_calls} SetClimate calls on the backbone

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
