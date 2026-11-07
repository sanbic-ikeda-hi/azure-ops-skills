#requires -Version 7.2
# Offline boundary tests. All auth/ARM/HTTP/token calls are mocked; only isolated TEMP logs are written.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'AppServiceDiagnostics.ps1')
$diagnosisCounter=@{Checks=0}
function Verify-Diagnosis([bool]$Condition,[string]$Message) {
    if (-not $Condition) {throw "FAIL: $Message"}
    $diagnosisCounter.Checks++
}
function Reject-Diagnosis([scriptblock]$Work,[string]$Message) {
    $failed=$false
    try {& $Work | Out-Null} catch {$failed=$true;Verify-Diagnosis ($_.Exception.Message -notmatch 'DO_NOT_OUTPUT_') 'Rejected output is sanitized'}
    Verify-Diagnosis $failed $Message
}
function Connect-AzAccount {throw 'Unexpected live sign-in in offline test.'}
function Invoke-AzRestMethod {throw 'Unexpected live ARM request in offline test.'}
function Invoke-WebRequest {throw 'Unexpected live HTTP request in offline test.'}
function Get-AzAccessToken {throw 'Unexpected live token request in offline test.'}
function Copy-DiagnosisData($Value) {$Value | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable}
$unused=@('facebook','gitHub','google','twitter','legacyMicrosoftAccount','apple')
$before=@{platform=@{enabled=$true};globalValidation=@{requireAuthentication=$true;unauthenticatedClientAction='Return401'};
    identityProviders=@{azureActiveDirectory=@{enabled=$true;registration=@{clientId='DO_NOT_OUTPUT_CLIENT'}};
        customOpenIdConnectProviders=@{partner=@{enabled=$true;registration=@{clientId='DO_NOT_OUTPUT_CUSTOM'}}}}}
foreach ($name in $unused) {$before.identityProviders[$name]=@{enabled=$true}}
$summary=Get-OpsAppServiceProviderSummary $before
foreach ($name in $unused) {
    $row=@($summary.Providers | Where-Object {$_.Name -eq $name})[0]
    Verify-Diagnosis ($row.EnabledState -eq 'Enabled' -and -not $row.HasRegistrationData) "Returned true without registration is observed: $name"
}
Verify-Diagnosis ($summary.CustomProviderCount -eq 1 -and $summary.UnknownProviderCount -eq 0) 'Custom OIDC is a known map, not an enabled flag'
Verify-Diagnosis (($summary | ConvertTo-Json -Depth 12) -notmatch 'DO_NOT_OUTPUT_|partner') 'Provider identifiers and custom alias values are omitted'
$original=Get-OpsFingerprint $before
$after=Copy-DiagnosisData $before
foreach ($name in $unused) {$after.identityProviders[$name].enabled=$false}
Assert-OpsAppServiceUnusedProviderChange $before $after $unused
Verify-Diagnosis ((Get-OpsFingerprint $before) -eq $original) 'Validation does not mutate the original authentication state'
foreach ($field in @('clientId','appId','consumerKey','clientSecretSettingName','appSecretSettingName','consumerSecretSettingName','clientSecretCertificateThumbprint','unknownFutureField')) {
    foreach ($name in $unused) {
        $registered=Copy-DiagnosisData $before
        $registered.identityProviders[$name].registration=@{$field='DO_NOT_OUTPUT_REGISTRATION'}
        Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $registered $after @($name)} "Existing registration is protected: $name/$field"
    }
}
$changed=Copy-DiagnosisData $after
$changed.globalValidation.requireAuthentication=$false
Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $before $changed $unused} 'Unrelated authentication settings cannot be changed'
$changed=Copy-DiagnosisData $after
$changed.identityProviders.Remove('customOpenIdConnectProviders')
Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $before $changed $unused} 'Existing custom providers cannot be dropped'
$unknown=Copy-DiagnosisData $before
$unknown.identityProviders['DO_NOT_OUTPUT_UNKNOWN']=@{enabled=$true}
Verify-Diagnosis ((Get-OpsAppServiceProviderSummary $unknown).UnknownProviderCount -eq 1) 'Unknown provider does not prevent safe diagnosis'
Verify-Diagnosis (((Get-OpsAppServiceProviderSummary $unknown) | ConvertTo-Json -Depth 12) -notmatch 'DO_NOT_OUTPUT_') 'Unknown provider names are not emitted'
Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $unknown $after $unused} 'Unknown provider stops an update decision'
foreach ($case in @(@{Provider=@{};Expected='Missing'},@{Provider=@{enabled=$null};Expected='Null'},@{Provider=@{enabled='false'};Expected='Invalid'},@{Provider=@{enabled=$false};Expected='Disabled'})) {
    $item=Get-OpsAppServiceProviderSummary @{identityProviders=@{google=$case.Provider}}
    Verify-Diagnosis (@($item.Providers | Where-Object {$_.Name -eq 'google'})[0].EnabledState -eq $case.Expected) 'Boolean state is not coerced from null, missing or text'
}
$empty=@{identityProviders=@{google=@{enabled=$true;registration=@{clientId=$null;clientSecretSettingName=''}}}}
$disabled=Copy-DiagnosisData $empty
$disabled.identityProviders.google.enabled=$false
Assert-OpsAppServiceUnusedProviderChange $empty $disabled @('google')
Verify-Diagnosis $true 'Empty known registration fields can be preserved while explicitly disabling'
$invalid=@{identityProviders=@{google=@{enabled=$true;registration='DO_NOT_OUTPUT_INVALID'}}}
Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $invalid $disabled @('google')} 'Malformed registration is protected'
Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $before $after @('azureActiveDirectory')} 'The primary identity provider cannot be declared unused'
Reject-Diagnosis {Assert-OpsAppServiceUnusedProviderChange $before $after @('google','google')} 'Duplicate unused-provider requests are rejected'

foreach ($case in @(
    @{Status=403;Body='<h1>This web app is stopped.</h1> DO_NOT_OUTPUT_BODY';Category='StoppedSite'},
    @{Status=403;Body='IP Forbidden DO_NOT_OUTPUT_BODY';Category='IpRestriction'},
    @{Status=403;Body='web app is stopped; IP Forbidden';Category='ConflictingEvidence'},
    @{Status=403;Body='{"error":{"code":"AuthorizationFailed","message":"DO_NOT_OUTPUT_MESSAGE"}}';Category='Authorization'},
    @{Status=403;Body='DO_NOT_OUTPUT_UNKNOWN';Category='Unknown'},
    @{Status=401;Body='DO_NOT_OUTPUT_UNKNOWN';Category='Unknown'},
    @{Status=302;Body='DO_NOT_OUTPUT_REDIRECT';Category='Unknown'},
    @{Status=200;Body='DO_NOT_OUTPUT_SUCCESS';Category='Reachable'}
)) {
    $safe=Get-OpsAppServiceHttpSummary @{StatusCode=$case.Status;Content=$case.Body;Headers=@{Authorization='DO_NOT_OUTPUT_HEADER'}} 'SCM'
    Verify-Diagnosis ($safe.CategoryHint -eq $case.Category -and $safe.HttpStatus -eq $case.Status) "Evidence-based HTTP category: $($case.Category)"
    Verify-Diagnosis (($safe | ConvertTo-Json) -notmatch 'DO_NOT_OUTPUT_') 'HTTP response and header values are omitted'
}
$safe=Get-OpsAppServiceHttpSummary @{StatusCode=403;Content='';Headers=@{'X-MS-Forbidden-IP'='DO_NOT_OUTPUT_IP'}} 'Main'
Verify-Diagnosis ($safe.CategoryHint -eq 'IpRestriction' -and $safe.ForbiddenIpHeaderPresent) 'IP-denial header presence is evidence without recording its value'
$safe=Get-OpsAppServiceHttpSummary @{StatusCode=403;Content=('x'*1048577+'web app is stopped')} 'SCM'
Verify-Diagnosis ($safe.CategoryHint -eq 'Unknown') 'Oversized content is not scanned or emitted'
$safe=Get-OpsAppServiceHttpSummary @{StatusCode=[Net.HttpStatusCode]::Forbidden;Content='web app is stopped'} 'SCM'
Verify-Diagnosis ($safe.HttpStatus -eq 403 -and $safe.CategoryHint -eq 'StoppedSite') 'Real HTTP status enum is classified correctly'
$safe=Get-OpsAppServiceHttpSummary @{} 'SCM'
Verify-Diagnosis ($null -eq $safe.HttpStatus -and $safe.CategoryHint -eq 'Unknown') 'Missing status is unknown, not successful'

$web=@{ipSecurityRestrictions=@(@{action='Allow';ipAddress='203.0.113.7/32';tag='Default';priority=100});
    ipSecurityRestrictionsDefaultAction='Deny';scmIpSecurityRestrictions=@(@{action='Allow';ipAddress='203.0.113.7/32';tag='Default';priority=100});
    scmIpSecurityRestrictionsDefaultAction='Deny';scmIpSecurityRestrictionsUseMain=$false}
Assert-OpsAppServiceIpv4Restriction $web '203.0.113.7/32'
Verify-Diagnosis (((Get-OpsAppServiceNetworkSummary $web) | ConvertTo-Json) -notmatch '203\.0\.113') 'Network summary omits IP addresses and rule bodies'
$inherited=Copy-DiagnosisData $web
$inherited.scmIpSecurityRestrictionsUseMain=$true
$inherited.Remove('scmIpSecurityRestrictions')
Assert-OpsAppServiceIpv4Restriction $inherited '203.0.113.7/32'
Verify-Diagnosis $true 'Effective SCM inheritance is checked against main rules'
foreach ($case in @('WideCidr','WrongScmIp','AllowDefault','UnknownInheritance','ExtraAllow','Header','Priority','ExtraDeny')) {
    $changed=Copy-DiagnosisData $web
    switch ($case) {
        'WideCidr' {$changed.ipSecurityRestrictions[0].ipAddress='203.0.113.0/24'}
        'WrongScmIp' {$changed.scmIpSecurityRestrictions[0].ipAddress='203.0.113.8/32'}
        'AllowDefault' {$changed.scmIpSecurityRestrictionsDefaultAction='Allow'}
        'UnknownInheritance' {$changed.Remove('scmIpSecurityRestrictionsUseMain')}
        'ExtraAllow' {$changed.ipSecurityRestrictions+=@{action='Allow';ipAddress='0.0.0.0/0';tag='Default';priority=101}}
        'Header' {$changed.ipSecurityRestrictions[0].headers=@{'x-forwarded-for'='DO_NOT_OUTPUT_HEADER'}}
        'Priority' {$changed.ipSecurityRestrictions[0].priority=2147483647}
        'ExtraDeny' {$changed.ipSecurityRestrictions+=@{action='Deny';ipAddress='203.0.113.7/32';priority=1}}
    }
    Reject-Diagnosis {Assert-OpsAppServiceIpv4Restriction $changed '203.0.113.7/32'} "Unsafe effective ingress is rejected: $case"
}
foreach ($cidr in @('203.0.113.0/24','::1/128','999.0.0.1/32','203.0.113.007/32')) {
    Reject-Diagnosis {Assert-OpsAppServiceIpv4Restriction $web $cidr} 'Only a canonical /32 can satisfy this explicit contract'
}

$sub='11111111-1111-1111-1111-111111111111'
$siteId="/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/sites/test-app"
$planId="/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/serverfarms/test-plan"
$site=@{id=$siteId;type='Microsoft.Web/sites';kind='app,linux';properties=@{state='Stopped';enabled=$false;scmSiteAlsoStopped=$false;
    defaultHostName='test-app.azurewebsites.net';hostNameSslStates=@(@{hostType='Repository';name='test-app.scm.azurewebsites.net'})}}
$overview=(ConvertTo-OpsServiceDetail $site @('Overview') @{} $null).Overview
Verify-Diagnosis ($overview.Enabled -eq $false -and $overview.ScmSiteAlsoStopped -eq $false) 'Enabled and SCM stop flags are observed separately from runtime state'
$badBoolean=Copy-DiagnosisData $site
$badBoolean.properties.enabled='DO_NOT_OUTPUT_INVALID_BOOLEAN'
Reject-Diagnosis {ConvertTo-OpsServiceDetail $badBoolean @('Overview') @{} $null} 'Invalid enabled metadata is rejected without echoing its value'
$endpoints=Get-OpsAppServiceEndpoints $site
Verify-Diagnosis ($endpoints.ScmUri -eq 'https://test-app.scm.azurewebsites.net/api/deployments') 'SCM endpoint comes from verified site metadata'
$bad=Copy-DiagnosisData $site
$bad.properties.hostNameSslStates+=@{hostType='Repository';name='other.scm.azurewebsites.net'}
Reject-Diagnosis {Get-OpsAppServiceEndpoints $bad} 'Ambiguous SCM hosts are rejected'
foreach ($location in @('http://test-app.scm.azurewebsites.net/api/deployments/latest','https://other.scm.azurewebsites.net/api/deployments/latest',
    '//example.invalid/api/deployments/latest','https://user:DO_NOT_OUTPUT_VALUE@test-app.scm.azurewebsites.net/api/deployments/latest',
    '/api/deployments/latest#DO_NOT_OUTPUT_FRAGMENT','/api/settings','/api/deployments/../settings','/api/deployments/%2e%2e')) {
    Reject-Diagnosis {Resolve-OpsAppServiceDeploymentLocation $endpoints.ScmHost $location} 'Unsafe polling location is rejected without exposing it'
}
$location=Resolve-OpsAppServiceDeploymentLocation $endpoints.ScmHost '/api/deployments/latest?deployer=OneDeploy'
Verify-Diagnosis ($location.Host -eq $endpoints.ScmHost) 'Relative deployment status location remains on the exact SCM host'
foreach ($status in @(0,1,2,3,4,'4',5,$true)) {
    $safe=Get-OpsAppServiceDeploymentSummary $status
    Verify-Diagnosis ($safe.Succeeded -eq ($status -is [int] -and $status -eq 4)) 'Only numeric deployment status 4 is successful'
}
$plan=Get-OpsAppServiceDiagnosticPermissionPlan -SubscriptionId $sub -ResourceId $siteId -Section PublishingPolicies -IncludeMetrics -PlanResourceId $planId
Verify-Diagnosis ($plan.Assignments.Count -eq 2 -and $plan.Assignments[0].Scope -eq $siteId -and $plan.Assignments[1].Scope -eq $planId) 'App and plan use their exact individual scopes'
Verify-Diagnosis (($plan.Assignments[1].Actions -join '|') -eq 'Microsoft.Insights/metricDefinitions/read|Microsoft.Insights/metrics/read') 'Plan has only the two metric reads'
Verify-Diagnosis ('Microsoft.Web/sites/basicPublishingCredentialsPolicies/read' -in $plan.Assignments[0].Actions -and -not $plan.GrantsPermissions -and -not $plan.FetchesMetrics) 'Policy permission is distinct from secret retrieval and never granted here'
foreach ($badScope in @("/subscriptions/$sub","/subscriptions/$sub/resourceGroups/rg-test",($siteId+'/slots/staging'),($siteId+'/providers/Microsoft.Web/sites/child'),$planId)) {
    Reject-Diagnosis {Get-OpsAppServiceDiagnosticPermissionPlan -SubscriptionId $sub -ResourceId $badScope} 'Invalid app permission scope is rejected'
}
Reject-Diagnosis {Get-OpsAppServiceDiagnosticPermissionPlan -SubscriptionId $sub -ResourceId $siteId -IncludeMetrics -PlanResourceId $planId.Replace($sub,'22222222-2222-2222-2222-222222222222')} 'Cross-subscription plan scope is rejected'

$directory=Join-Path ([IO.Path]::GetTempPath()) ('azureops-appservice-diagnosis-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
function Test-DiagnosisScenario {
    param([string]$Scenario)
    $operator='22222222-2222-2222-2222-222222222222'
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$operator;servicePrincipalObjectId=$operator;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $mockSite=Copy-DiagnosisData $site
    if ($Scenario -eq 'WrongService') {$mockSite.kind='functionapp,linux'}
    if ($Scenario -eq 'BadHost') {$mockSite.properties.defaultHostName='DO_NOT_OUTPUT_HOST'}
    $calls=@{connect=0;disconnect=0;arm=0;write=0;http=0;token=0;paths=[Collections.Generic.List[string]]::new();uris=[Collections.Generic.List[string]]::new()}
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding)
        if ($LiteralPath -eq 'mock-profile') {return $profile}
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
    }
    function Test-Path {param($LiteralPath,$PathType)
        if ($LiteralPath -eq 'mock-profile' -or $LiteralPath -like 'Cert:*') {return $true}
        Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
    }
    function Get-Item {param($LiteralPath,[switch]$Force)
        if ($LiteralPath -like 'Cert:*') {return @{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)}}
        Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
    }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {param([switch]$ServicePrincipal,$Scope)
        if (-not $ServicePrincipal -or $Scope -ne 'Process') {throw 'Unexpected authentication'}
        $calls.connect++
    }
    function Disconnect-AzAccount {$calls.disconnect++}
    function Get-AzContext {
        $account=if ($Scenario -eq 'ContextDrift' -and $calls.arm -ge 2) {$sub} else {$operator}
        @{Tenant=@{Id=$sub};Subscription=@{Id=$sub};Account=@{Type='ServicePrincipal';Id=$account};Environment=@{Name='AzureCloud'}}
    }
    function New-MockHttpError {
        $exception=[Exception]::new('DO_NOT_OUTPUT_EXCEPTION')
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=[Net.HttpStatusCode]::Forbidden;Headers=@{Authorization='DO_NOT_OUTPUT_TOKEN'}})
        $errorRecord=[Management.Automation.ErrorRecord]::new($exception,'MockHttp',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
        $errorRecord.ErrorDetails=[Management.Automation.ErrorDetails]::new('{"error":{"code":"AuthorizationFailed","message":"DO_NOT_OUTPUT_MESSAGE"}}')
        return $errorRecord
    }
    function Invoke-AzRestMethod {
        [CmdletBinding()]param($Path,$Method,$Payload)
        $calls.arm++;$calls.paths.Add($Path)
        if ($Method -ne 'GET') {$calls.write++;throw 'Offline diagnosis attempted a mutation'}
        $id=$Path.Split('?')[0]
        if ($id -eq $siteId) {
            if ($Scenario -eq 'RootDenied') {return @{StatusCode=403;Content='DO_NOT_OUTPUT_ROOT'}}
            $copy=Copy-DiagnosisData $mockSite
            if ($Scenario -eq 'WrongResponse') {$copy.id=$siteId+'-wrong'}
            return @{StatusCode=200;Content=($copy | ConvertTo-Json -Depth 12)}
        }
        if ($id -eq "$siteId/config/web") {
            return @{StatusCode=200;Content=(@{id=$id;properties=$web}|ConvertTo-Json -Depth 12)}
        }
        if ($id -eq "$siteId/config/authsettingsV2") {
            if ($Scenario -eq 'Thrown403') {$PSCmdlet.ThrowTerminatingError((New-MockHttpError))}
            return @{StatusCode=200;Content=(@{id=$id;properties=$before}|ConvertTo-Json -Depth 16)}
        }
        if ($id -in @("$siteId/basicPublishingCredentialsPolicies/ftp","$siteId/basicPublishingCredentialsPolicies/scm")) {
            if ($Scenario -eq 'OptionalDenied' -and $id.EndsWith('/ftp')) {return @{StatusCode=403;Content='{"error":{"code":"AuthorizationFailed","message":"DO_NOT_OUTPUT_POLICY"}}'}}
            return @{StatusCode=200;Content=(@{id=$id;properties=@{allow=$false;unused='DO_NOT_OUTPUT_POLICY'}}|ConvertTo-Json -Depth 6)}
        }
        throw 'Unexpected ARM path'
    }
    function Get-AzAccessToken {param($ResourceUrl)
        $calls.token++
        Verify-Diagnosis ($ResourceUrl -eq 'https://management.azure.com/') 'SCM token audience remains ARM'
        if ($Scenario -eq 'UnsafeToken') {return @{Token='DO_NOT_OUTPUT_TOKEN'}}
        if ($Scenario -eq 'TokenFailure') {throw (New-MockHttpError)}
        @{Token=(ConvertTo-SecureString 'DO_NOT_OUTPUT_TOKEN' -AsPlainText -Force)}
    }
    function Invoke-WebRequest {
        [CmdletBinding()]param($Uri,$Method,[switch]$SkipHttpErrorCheck,$MaximumRedirection,$TimeoutSec,$Authentication,$Token)
        $calls.http++;$calls.uris.Add([string]$Uri)
        Verify-Diagnosis ($Method -eq 'GET' -and $SkipHttpErrorCheck -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 30) 'HTTP diagnosis is bounded GET without redirects'
        if ($Uri -eq 'https://test-app.azurewebsites.net/') {
            Verify-Diagnosis ($null -eq $Token -and -not $Authentication) 'Management token is never sent to the main site'
            if ($Scenario -eq 'HttpFailure') {$PSCmdlet.ThrowTerminatingError((New-MockHttpError))}
        } else {
            Verify-Diagnosis ($Uri -eq 'https://test-app.scm.azurewebsites.net/api/deployments' -and $Authentication -eq 'Bearer' -and $Token -is [Security.SecureString]) 'Secure token goes only to exact SCM GET endpoint'
        }
        @{StatusCode=403;Content='web app is stopped DO_NOT_OUTPUT_HTML';Headers=@{Authorization='DO_NOT_OUTPUT_HEADER'}}
    }
    $output=Join-Path $directory ($Scenario+'.txt')
    if ($Scenario -eq 'ExistingLog') {Set-Content -LiteralPath $output -Value 'KEEP_EXISTING_LOG' -Encoding utf8}
    $captured=[Collections.Generic.List[string]]::new();$failed=$false
    try {& (Join-Path $PSScriptRoot 'Get-AppServiceDiagnostics.ps1') -SubscriptionId $sub -ResourceId $siteId -ConnectionPath 'mock-profile' -Section Authentication,PublishingPolicies,Scm -OutputPath $output | ForEach-Object {$captured.Add([string]$_)}}
    catch {$failed=$true;$captured.Add($_.Exception.Message)}
    Verify-Diagnosis (($captured -join '') -notmatch 'DO_NOT_OUTPUT_') "Console output is sanitized: $Scenario"
    Verify-Diagnosis ($calls.write -eq 0) "Diagnosis never writes Azure: $Scenario"
    if ($Scenario -eq 'ExistingLog') {
        Verify-Diagnosis ($failed -and $calls.connect -eq 0 -and (Microsoft.PowerShell.Management\Get-Content -LiteralPath $output -Raw).Trim() -eq 'KEEP_EXISTING_LOG') 'Existing log stops before sign-in and is preserved'
        return
    }
    Verify-Diagnosis ($calls.connect -eq 1 -and $calls.disconnect -eq 1) "Dedicated session is disconnected: $Scenario"
    $text=Microsoft.PowerShell.Management\Get-Content -LiteralPath $output -Raw -Encoding utf8
    Verify-Diagnosis ($text -notmatch 'DO_NOT_OUTPUT_') "Log omits response/registration/exception/token values: $Scenario"
    $records=@(Microsoft.PowerShell.Management\Get-Content -LiteralPath $output -Encoding utf8 | ForEach-Object {$_ | ConvertFrom-Json -AsHashtable})
    if ($Scenario -eq 'Success') {
        Verify-Diagnosis (-not $failed -and $records[-1].Data.Complete -and $calls.arm -eq 5 -and $calls.http -eq 2) "A stopped-site response is diagnosed without changes (failed=$failed; last=$($records[-1].Stage); arm=$($calls.arm); http=$($calls.http); lastMessage=$($captured[-1]))"
        $result=$captured[0] | ConvertFrom-Json -AsHashtable
        Verify-Diagnosis (@($result.Sections | Where-Object {$_.Section -eq 'ScmHttp'})[0].Summary.CategoryHint -eq 'StoppedSite') 'SCM 403 is classified with enabled=false and SCM stop flag false'
    } elseif ($Scenario -in @('OptionalDenied','Thrown403','HttpFailure','UnsafeToken','TokenFailure')) {
        Verify-Diagnosis ($failed -and $records[-1].Stage -eq 'Completed' -and -not $records[-1].Data.Complete) 'Partial diagnosis has nonzero failure and explicit incomplete completion'
        Verify-Diagnosis ($calls.arm -eq 5 -and $calls.http -eq $(if ($Scenario -in @('UnsafeToken','TokenFailure')) {1} else {2})) 'Independent reads continue after one optional failure'
        if ($Scenario -ne 'UnsafeToken') {
            $failure=@($records | Where-Object {$_.Data.ContainsKey('Retrieved') -and -not $_.Data.Retrieved})[0]
            Verify-Diagnosis ($failure.Data.Failure.HttpStatus -eq 403 -and $failure.Data.Failure.CategoryHint -eq 'Authorization') 'Returned and thrown 403 retain safe status and evidence'
        }
    } else {
        Verify-Diagnosis ($failed -and $records[-1].Stage -eq 'Failed' -and $calls.http -eq 0 -and $calls.token -eq 0) 'Target, context and hostname failures stop dependent requests'
    }
    Verify-Diagnosis (@($calls.paths | Select-Object -Unique).Count -eq $calls.paths.Count) 'Failed ARM requests are never retried'
}
try {
    foreach ($scenario in @('Success','OptionalDenied','Thrown403','HttpFailure','UnsafeToken','TokenFailure','ContextDrift','RootDenied','WrongResponse','WrongService','BadHost','ExistingLog')) {Test-DiagnosisScenario $scenario}
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $resolved=[IO.Path]::GetFullPath($directory)
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'azureops-appservice-diagnosis-*') {throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "PASS: $($diagnosisCounter.Checks) App Service diagnosis boundary checks (offline)."
