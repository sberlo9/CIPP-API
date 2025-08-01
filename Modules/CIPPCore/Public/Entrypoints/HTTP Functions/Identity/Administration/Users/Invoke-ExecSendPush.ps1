using namespace System.Net

function Invoke-ExecSendPush {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Identity.User.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed this API' -Sev 'Debug'

    $TenantFilter = $Request.body.TenantFilter
    $UserEmail = $Request.body.UserEmail
    $MFAAppID = '981f26a1-7f43-403b-a875-f8b09b8cd720'

    # Function to keep trying to get the access token while we wait for MS to actually set the temp password
    function Get-ClientAccess {
        param(
            $uri,
            $body,
            $count = 1
        )
        try {
            $ClientToken = Invoke-RestMethod -Method post -Uri $uri -Body $body -ea stop
        } catch {
            if ($count -lt 20) {

                $count++
                Start-Sleep 1
                $ClientToken = Get-ClientAccess -uri $uri -body $body -count $count
            } else {
                throw "Could not get Client Token: $_"
            }
        }
        return $ClientToken
    }


    # Get all service principals
    $SPResult = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/servicePrincipals?`$top=999&`$select=id,appId" -tenantid $TenantFilter -AsApp $true

    # Check if we have one for the MFA App
    $SPID = ($SPResult | Where-Object { $_.appId -eq $MFAAppID }).id

    # Create a service principal if needed
    if (!$SPID) {

        $SPBody = [pscustomobject]@{
            appId = $MFAAppID
        } | ConvertTo-Json -Depth 5
        $SPID = (New-GraphPostRequest -uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -tenantid $TenantFilter -type POST -body $SPBody -AsApp $true).id
    }


    $PassReqBody = @{
        'passwordCredential' = @{
            'displayName'   = 'MFA Temporary Password'
            'endDateTime'   = $((Get-Date).AddMinutes(5))
            'startDateTime' = $((Get-Date).AddMinutes(-5))
        }
    } | ConvertTo-Json -Depth 5

    $TempPass = (New-GraphPostRequest -uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SPID/addPassword" -tenantid $TenantFilter -type POST -body $PassReqBody -AsApp $true).secretText

    # Give it a chance to apply
    #Start-Sleep 5

    # Generate the XML for the push request
    $XML = @"
<BeginTwoWayAuthenticationRequest>
<Version>1.0</Version>
<UserPrincipalName>$UserEmail</UserPrincipalName>
<Lcid>en-us</Lcid><AuthenticationMethodProperties xmlns:a="http://schemas.microsoft.com/2003/10/Serialization/Arrays"><a:KeyValueOfstringstring><a:Key>OverrideVoiceOtp</a:Key><a:Value>false</a:Value></a:KeyValueOfstringstring></AuthenticationMethodProperties><ContextId>69ff05bf-eb61-47f7-a70e-e7d77b6d47d0</ContextId>
<SyncCall>true</SyncCall><RequireUserMatch>true</RequireUserMatch><CallerName>radius</CallerName><CallerIP>UNKNOWN:</CallerIP></BeginTwoWayAuthenticationRequest>
"@

    # Request to get client token
    $body = @{
        'resource'      = 'https://adnotifications.windowsazure.com/StrongAuthenticationService.svc/Connector'
        'client_id'     = $MFAAppID
        'client_secret' = $TempPass
        'grant_type'    = 'client_credentials'
        'scope'         = 'openid'
    }

    # Attempt to get a token using the temp password
    $ClientUri = "https://login.microsoftonline.com/$TenantFilter/oauth2/token"
    try {
        $ClientToken = Get-ClientAccess -Uri $ClientUri -Body $body
    } catch {
        $Body = 'Failed to create temporary token for MFA Application. Error: ' + $_.Exception.Message
    }

    # If we got a token send a push
    if ($ClientToken) {

        $ClientHeaders = @{ 'Authorization' = "Bearer $($ClientToken.access_token)" }

        $obj = Invoke-RestMethod -Uri 'https://adnotifications.windowsazure.com/StrongAuthenticationService.svc/Connector//BeginTwoWayAuthentication' -Method POST -Headers $ClientHeaders -Body $XML -ContentType 'application/xml'

        if ($obj.BeginTwoWayAuthenticationResponse.result) {
            $Body = "Received an MFA confirmation: $($obj.BeginTwoWayAuthenticationResponse.result.value | Out-String)"
            $State = 'success'
        }
        if ($obj.BeginTwoWayAuthenticationResponse.AuthenticationResult -ne $true) {
            $Body = "Authentication Failed! Does the user have Push/Phone call MFA configured? ErrorCode: $($obj.BeginTwoWayAuthenticationResponse.result.value | Out-String)"
            $State = 'error'
        }

    }

    $Results = [pscustomobject]@{'Results' = @{ resultText = $Body; state = $State } }
    Write-LogMessage -headers $Request.Headers -API $APINAME -message "Sent push request to $UserEmail - Result: $($obj.BeginTwoWayAuthenticationResponse.result.value | Out-String)" -Sev 'Info'

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Results
        })


}
