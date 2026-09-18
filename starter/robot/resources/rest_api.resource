*** Settings ***
Library    RequestsLibrary

*** Keywords ***
Open Backend Session
    ${headers}=    Create Dictionary    X-API-Key=${API_KEY}
    Create Session    backend    ${BACKEND_URL}    headers=${headers}

Get Vehicle Status
    ${resp}=    GET On Session    backend    /vehicle/status
    RETURN    ${resp.json()}

# TODO: Send Remote Command, Wait For Command Terminal State, ...
