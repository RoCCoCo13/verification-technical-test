*** Settings ***
Resource    ../resources/rest_api.resource
Resource    ../resources/adb.resource
Suite Setup    Open Backend Session

*** Test Cases ***
Backend Is Reachable
    [Tags]    smoke    req:REQ-API-005
    ${status}=    Get Vehicle Status
    Should Be Equal As Strings    ${status}[vin]    WVGZZZ5NZTW000042

Gateway Is Reachable Over Adb
    [Tags]    smoke    req:REQ-ADB-001
    ${model}=    Adb Shell    getprop ro.product.model
    Should Be Equal As Strings    ${model.strip()}    TCU-GW-2
