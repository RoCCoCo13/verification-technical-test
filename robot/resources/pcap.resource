*** Settings ***
Documentation     Locating and analysing scenario captures.
...
...               The network suite prefers a capture taken during this run
...               (``traces/pcap/scenarios/<label>/``, produced by the scenario runner) and
...               falls back to ``traces/samples/``, recorded by the validation team on this
...               same software build. The fallback is announced in the report, never silent:
...               a reader must be able to tell whether a network finding came from their own
...               run or from a supplied capture.

Library           PcapLibrary
Library           ScenarioLibrary
Library           OperatingSystem
Library           Collections


*** Keywords ***
Select Scenario Capture Directory
    [Documentation]    Choose the capture directory for this run and publish it as the suite
    ...    variables ``${CAPTURE_DIR}`` and ``${SCENARIO_LABEL}``.
    ...
    ...    Fails outright if neither a fresh capture nor the supplied samples are present,
    ...    because a network suite with no captures would otherwise pass vacuously.
    ${fresh}=    Run Keyword And Return Status    Directory Should Not Be Empty    ${SCENARIO_DIR}
    IF    ${fresh}
        Set Suite Variable    ${CAPTURE_DIR}       ${SCENARIO_DIR}
        Set Suite Variable    ${SCENARIO_LABEL}    ${SCENARIO_DIR.rstrip('/').split('/')[-1]}
        Log    Analysing captures taken during this run: ${SCENARIO_DIR}    level=INFO
    ELSE
        Directory Should Exist    ${FALLBACK_SCENARIO_DIR}
        ...    msg=no scenario capture at ${SCENARIO_DIR} and no fallback at ${FALLBACK_SCENARIO_DIR}; run 'docker compose run --rm -e SCENARIO_LABEL=ci scenario-runner' first
        Set Suite Variable    ${CAPTURE_DIR}       ${FALLBACK_SCENARIO_DIR}
        Set Suite Variable    ${SCENARIO_LABEL}    samples
        Log    No fresh capture at ${SCENARIO_DIR}; falling back to the supplied captures of this build at ${FALLBACK_SCENARIO_DIR}    level=WARN
    END

Scenario Capture
    [Documentation]    Return the full path of one scenario capture in the selected directory.
    [Arguments]    ${filename}
    ${path}=    Join Path    ${CAPTURE_DIR}    ${filename}
    File Should Exist    ${path}
    ...    msg=scenario capture ${filename} is missing from ${CAPTURE_DIR}
    RETURN    ${path}

Attach Grpc Call Table
    [Documentation]    Log the gRPC calls of a capture as a table, so a failing network test
    ...    carries the message flow it is complaining about.
    [Arguments]    ${title}    ${calls}
    ${rendered}=    Format Grpc Calls    ${calls}
    Log    ${title}:\n${rendered}
