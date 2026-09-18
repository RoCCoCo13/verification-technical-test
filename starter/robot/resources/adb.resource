*** Settings ***
Library    Process

*** Keywords ***
Adb Shell
    [Arguments]    ${command}
    ${result}=    Run Process    adb    -s    ${ADB_SERIAL}    shell    ${command}
    Should Be Equal As Integers    ${result.rc}    0    adb failed: ${result.stderr}
    RETURN    ${result.stdout}

# TODO: Read Vhal Properties, Logcat Dump, ...
