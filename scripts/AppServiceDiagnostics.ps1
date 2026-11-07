#requires -Version 7.2
# Pure validation/diagnostic helpers. Importing this file never connects or changes Azure.
. (Join-Path $PSScriptRoot 'ServiceOperations.ps1')

function Get-OpsAppServiceProviderSummary {
    param([Parameter(Mandatory)][Collections.IDictionary]$Properties)
    $providers=$Properties['identityProviders']
    if ($null -eq $providers) {$providers=@{}}
    if ($providers -isnot [Collections.IDictionary]) {throw 'Invalid identity provider collection. Details omitted.'}
    $known=@('azureActiveDirectory','azureStaticWebApps','facebook','gitHub','google','twitter','legacyMicrosoftAccount','apple')
    $registrationFields=@('clientId','appId','consumerKey','openIdIssuer','clientSecretSettingName','appSecretSettingName',
        'consumerSecretSettingName','clientSecretCertificateThumbprint','clientSecretCertificateSubjectAlternativeName')
    $rows=@(foreach ($name in $known) {
        $present=$providers.Contains($name)
        $provider=if ($present) {$providers[$name]} else {$null}
        $shapeValid=($null -eq $provider -or $provider -is [Collections.IDictionary])
        $enabled='Missing';$registrationState='Missing';$hasData=$false
        $flags=@{HasClientId=$false;HasAppId=$false;HasConsumerKey=$false;HasSecretReference=$false}
        if ($present -and $null -eq $provider) {$enabled='Null';$registrationState='Null'}
        elseif (-not $shapeValid) {$enabled='Invalid';$registrationState='Invalid'}
        elseif ($null -ne $provider) {
            if ($provider.Contains('enabled')) {
                $enabled=if ($null -eq $provider['enabled']) {'Null'} elseif ($provider['enabled'] -isnot [bool]) {'Invalid'} elseif ($provider['enabled']) {'Enabled'} else {'Disabled'}
            }
            if ($provider.Contains('registration')) {
                $registration=$provider['registration']
                if ($null -eq $registration) {$registrationState='Null'}
                elseif ($registration -isnot [Collections.IDictionary]) {$registrationState='Invalid';$hasData=$true}
                else {
                    $registrationState='Present'
                    foreach ($key in $registration.Keys) {
                        $value=$registration[$key]
                        # Unknown fields are conservatively protected even when their value is null.
                        if ($key -notin $registrationFields -or
                            ($null -ne $value -and ($value -isnot [string] -or -not [string]::IsNullOrWhiteSpace($value)))) {$hasData=$true}
                    }
                    foreach ($pair in @(@('clientId','HasClientId'),@('appId','HasAppId'),@('consumerKey','HasConsumerKey'))) {
                        $value=$registration[$pair[0]]
                        $flags[$pair[1]]=($null -ne $value -and ($value -isnot [string] -or -not [string]::IsNullOrWhiteSpace($value)))
                    }
                    foreach ($key in @('clientSecretSettingName','appSecretSettingName','consumerSecretSettingName','clientSecretCertificateThumbprint','clientSecretCertificateSubjectAlternativeName')) {
                        if ($null -ne $registration[$key] -and -not [string]::IsNullOrWhiteSpace([string]$registration[$key])) {$flags.HasSecretReference=$true}
                    }
                }
            }
        }
        [ordered]@{Name=$name;Present=$present;EnabledState=$enabled;ShapeValid=$shapeValid;
            RegistrationState=$registrationState;HasRegistrationData=$hasData;
            HasClientId=$flags.HasClientId;HasAppId=$flags.HasAppId;HasConsumerKey=$flags.HasConsumerKey;HasSecretReference=$flags.HasSecretReference}
    })
    $unknown=@($providers.Keys | Where-Object {$_ -notin ($known+@('customOpenIdConnectProviders'))}).Count
    $custom=$providers['customOpenIdConnectProviders']
    [ordered]@{Providers=$rows;UnknownProviderCount=$unknown;
        CustomProviderCount=$(if ($custom -is [Collections.IDictionary]) {$custom.Count} else {$null});
        CustomProviderShapeValid=($null -eq $custom -or $custom -is [Collections.IDictionary]);
        ValuesOmitted=$true}
}

function Assert-OpsAppServiceUnusedProviderChange {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Before,
        [Parameter(Mandatory)][Collections.IDictionary]$After,
        [Parameter(Mandatory)][ValidateCount(1,6)][string[]]$UnusedProvider
    )
    # This guard permits only explicit disabling; it never constructs or sends an ARM update.
    $unused=@('facebook','gitHub','google','twitter','legacyMicrosoftAccount','apple')
    if (@($UnusedProvider | Select-Object -Unique).Count -ne $UnusedProvider.Count -or
        @($UnusedProvider | Where-Object {$_ -notin $unused}).Count) {throw 'Select explicit unused built-in providers only.'}
    $summary=Get-OpsAppServiceProviderSummary $Before
    if ($summary.UnknownProviderCount -gt 0 -or -not $summary.CustomProviderShapeValid) {throw 'Unknown provider configuration requires review.'}
    $expected=$Before | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable
    if ($null -eq $expected['identityProviders']) {$expected['identityProviders']=@{}}
    foreach ($name in $UnusedProvider) {
        $row=@($summary.Providers | Where-Object {$_.Name -ieq $name})[0]
        if (-not $row.ShapeValid -or $row.EnabledState -eq 'Invalid' -or $row.RegistrationState -eq 'Invalid' -or $row.HasRegistrationData) {
            throw 'Existing provider registration or invalid shape is protected.'
        }
        if ($null -eq $expected['identityProviders'][$name]) {$expected['identityProviders'][$name]=@{}}
        $expected['identityProviders'][$name]['enabled']=$false
    }
    if ((Get-OpsFingerprint $expected) -cne (Get-OpsFingerprint $After)) {
        throw 'Authentication change would modify unapproved or preserved settings.'
    }
}

function Get-OpsAppServiceHttpSummary {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][ValidateSet('Main','SCM')][string]$Endpoint
    )
    $status=0
    $rawStatus=if ($Response -is [Collections.IDictionary]) {$Response['StatusCode']} elseif ($Response.PSObject.Properties['StatusCode']) {$Response.StatusCode} else {$null}
    if ($rawStatus -is [Net.HttpStatusCode]) {$status=[int]$rawStatus}
    else {[void][int]::TryParse([string]$rawStatus,[ref]$status)}
    $content=if ($Response -is [Collections.IDictionary]) {$Response['Content']} elseif ($Response.PSObject.Properties['Content']) {$Response.Content} else {$null}
    $text=if ($content -is [string] -and $content.Length -le 1048576) {$content} else {''}
    $headers=if ($Response -is [Collections.IDictionary]) {$Response['Headers']} elseif ($Response.PSObject.Properties['Headers']) {$Response.Headers} else {$null}
    $ipHeader=$false
    if ($headers -is [Collections.IDictionary]) {$ipHeader=@($headers.Keys | Where-Object {$_ -ieq 'x-ms-forbidden-ip'}).Count -gt 0}
    $stopped=($text -match '(?i)web app is stopped|site is stopped|app has been stopped')
    $ip=($text -match '(?i)\bIP Forbidden\b') -or $ipHeader
    $arm=Get-OpsArmErrorSummary @{StatusCode=$status;Content=$text}
    $auth=($arm.CategoryHint -in @('Authentication','Authorization'))
    $category='Unknown'
    if ($status -eq 403 -and (@($stopped,$ip,$auth | Where-Object {$_}).Count -gt 1)) {$category='ConflictingEvidence'}
    elseif ($status -eq 403 -and $stopped) {$category='StoppedSite'}
    elseif ($status -eq 403 -and $ip) {$category='IpRestriction'}
    elseif ($auth) {$category=$arm.CategoryHint}
    elseif ($status -ge 200 -and $status -lt 300) {$category='Reachable'}
    [ordered]@{Endpoint=$Endpoint;HttpStatus=$(if ($status -ge 100 -and $status -le 599) {$status} else {$null});
        CategoryHint=$category;StoppedMarker=$stopped;IpForbiddenMarker=$ip;ForbiddenIpHeaderPresent=$ipHeader;DetailsOmitted=$true}
}

function Get-OpsAppServiceNetworkSummary {
    param([Parameter(Mandatory)][Collections.IDictionary]$WebConfiguration)
    $summary=[ordered]@{}
    foreach ($prefix in @('ip','scmIp')) {
        $rules=$WebConfiguration[$prefix+'SecurityRestrictions']
        $action=$WebConfiguration[$prefix+'SecurityRestrictionsDefaultAction']
        $summary[$prefix+'RuleCount']=if ($rules -is [array]) {$rules.Count} else {$null}
        $summary[$prefix+'DefaultAction']=if ($action -in @('Allow','Deny')) {$action} else {'Unknown'}
    }
    $useMain=$WebConfiguration['scmIpSecurityRestrictionsUseMain']
    $summary['ScmUseMainRules']=if ($useMain -is [bool]) {$useMain} else {$null}
    return $summary
}

function Assert-OpsAppServiceIpv4Restriction {
    param([Parameter(Mandatory)][Collections.IDictionary]$WebConfiguration,[Parameter(Mandatory)][string]$AllowedCidr)
    $address=$null
    if ($AllowedCidr -notmatch '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})/32$' -or
        -not [Net.IPAddress]::TryParse($Matches[1],[ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $AllowedCidr -cne ($address.ToString()+'/32')) {
        throw 'An explicit canonical IPv4 /32 is required.'
    }
    $useMain=$WebConfiguration['scmIpSecurityRestrictionsUseMain']
    if ($useMain -isnot [bool]) {throw 'SCM rule inheritance must be explicit.'}
    $prefixes=if ($useMain) {@('ip')} else {@('ip','scmIp')}
    foreach ($prefix in $prefixes) {
        $rules=$WebConfiguration[$prefix+'SecurityRestrictions']
        if ($WebConfiguration[$prefix+'SecurityRestrictionsDefaultAction'] -cne 'Deny' -or $rules -isnot [array]) {
            throw 'Effective main and SCM rules must have explicit default Deny.'
        }
        $allows=@($rules | Where-Object {$_ -is [Collections.IDictionary] -and $_['action'] -ceq 'Allow'})
        if ($allows.Count -ne 1) {throw 'Expected exactly one IPv4 allow rule.'}
        $allow=$allows[0]
        if ($allow['ipAddress'] -cne $AllowedCidr -or $allow['tag'] -cne 'Default' -or
            $allow['headers'] -or $allow['vnetSubnetResourceId'] -or
            ($allow['priority'] -isnot [int] -and $allow['priority'] -isnot [long]) -or
            $allow['priority'] -lt 1 -or $allow['priority'] -ge 2147483647) {throw 'Unexpected IPv4 allow rule.'}
        foreach ($rule in $rules) {
            if ($rule -isnot [Collections.IDictionary]) {throw 'Invalid network rule shape.'}
            if ($rule['action'] -ceq 'Allow') {continue}
            if ($rule['action'] -cne 'Deny' -or $rule['ipAddress'] -cne 'Any' -or
                $rule['priority'] -ne 2147483647 -or $rule['headers'] -or $rule['vnetSubnetResourceId']) {
                throw 'Additional network rules require separate review.'
            }
        }
    }
}

function Get-OpsAppServiceEndpoints {
    param([Parameter(Mandatory)][Collections.IDictionary]$Site)
    $p=$Site['properties']
    if ($p -isnot [Collections.IDictionary]) {throw 'Invalid site metadata.'}
    $main=$p['defaultHostName']
    $scm=@($p['hostNameSslStates'] | Where-Object {$_ -is [Collections.IDictionary] -and $_['hostType'] -eq 'Repository'} | ForEach-Object {$_['name']})
    if ($main -isnot [string] -or $main -notmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.azurewebsites\.net$' -or
        $scm.Count -ne 1 -or $scm[0] -isnot [string] -or $scm[0] -notmatch '^[a-z0-9-]+\.scm(?:\.[a-z0-9-]+)*\.azurewebsites\.net$') {
        throw 'Expected main and SCM hostnames from the verified site metadata.'
    }
    [ordered]@{MainHost=$main;ScmHost=$scm[0];MainUri="https://$main/";ScmUri="https://$($scm[0])/api/deployments"}
}

function Resolve-OpsAppServiceDeploymentLocation {
    param([Parameter(Mandatory)][string]$ScmHost,[Parameter(Mandatory)][string]$Location)
    if ($ScmHost -notmatch '^[a-z0-9-]+\.scm(?:\.[a-z0-9-]+)*\.azurewebsites\.net$') {throw 'Invalid verified SCM host.'}
    $uri=$null
    try {$uri=[uri]::new([uri]("https://$ScmHost"),$Location)} catch {throw 'Invalid deployment location. Details omitted.'}
    if ($uri.Scheme -ne 'https' -or $uri.Authority -ine $ScmHost -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
        $uri.AbsolutePath -notmatch '^/api/deployments/[A-Za-z0-9_-]+$') {throw 'Deployment location leaves the verified SCM endpoint.'}
    return $uri
}

function Get-OpsAppServiceDeploymentSummary {
    param([Parameter(Mandatory)]$Status)
    $valid=($Status -is [int] -or $Status -is [long]) -and $Status -ge 0 -and $Status -le 4
    $stage=if ($valid) {@('Pending','Building','Deploying','Failed','Succeeded')[[int]$Status]} else {'Unknown'}
    [ordered]@{Stage=$stage;Terminal=($valid -and $Status -in @(3,4));Succeeded=($valid -and $Status -eq 4)}
}

function Get-OpsAppServiceDiagnosticPermissionPlan {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceId,
        [ValidateSet('Authentication','PublishingPolicies','Scm')][string[]]$Section=@('Authentication'),
        [switch]$IncludeMetrics,
        [string]$PlanResourceId
    )
    Assert-OpsResourceScope $ResourceId $SubscriptionId
    if ($ResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$') {throw 'Select one top-level Web App.'}
    $actions=@('Microsoft.Web/sites/read')
    if ('Authentication' -in $Section -or 'Scm' -in $Section) {$actions+='Microsoft.Web/sites/config/read'}
    if ('PublishingPolicies' -in $Section) {$actions+='Microsoft.Web/sites/basicPublishingCredentialsPolicies/read'}
    # HTTP GET does not imply that the endpoint accepts the initial reader role.
    if ('Scm' -in $Section) {$actions+='Microsoft.Web/sites/publish/action'}
    if ($IncludeMetrics) {$actions+=@('Microsoft.Insights/metricDefinitions/read','Microsoft.Insights/metrics/read')}
    $rows=@([ordered]@{Scope=$ResourceId;Actions=@($actions | Select-Object -Unique)})
    if ($PlanResourceId) {
        if (-not $IncludeMetrics) {throw 'A plan scope is used only for an explicit metrics permission plan.'}
        Assert-OpsResourceScope $PlanResourceId $SubscriptionId
        if ($PlanResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/serverfarms/[^/]+$') {throw 'Select one App Service plan.'}
        $rows+=([ordered]@{Scope=$PlanResourceId;Actions=@('Microsoft.Insights/metricDefinitions/read','Microsoft.Insights/metrics/read')})
    }
    [ordered]@{Assignments=$rows;GrantsPermissions=$false;FetchesMetrics=$false}
}

function Invoke-OpsAppServiceHttpProbe {
    param([Parameter(Mandatory)][hashtable]$Config,[Parameter(Mandatory)][Collections.IDictionary]$Site,
        [Parameter(Mandatory)][ValidateSet('Main','SCM')][string]$Endpoint)
    $endpoints=Get-OpsAppServiceEndpoints $Site
    Assert-OpsContext (Get-AzContext) $Config 'ServicePrincipal'
    $parameters=@{Uri=$(if ($Endpoint -eq 'SCM') {$endpoints.ScmUri} else {$endpoints.MainUri});
        Method='GET';SkipHttpErrorCheck=$true;MaximumRedirection=0;TimeoutSec=30;ErrorAction='Stop'}
    try {
        if ($Endpoint -eq 'SCM') {
            $token=Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
            if ($token.Token -isnot [Security.SecureString]) {throw 'A memory-only secure token is required.'}
            $parameters.Authentication='Bearer';$parameters.Token=$token.Token
        }
        $response=Invoke-WebRequest @parameters
    }
    catch {
        $failure=[InvalidOperationException]::new('HTTP diagnosis failed. Details omitted; no retry.')
        $failure.Data['AzureOpsFailure']=Get-OpsFailureSummary $_
        throw $failure
    }
    Get-OpsAppServiceHttpSummary $response $Endpoint
}
