#requires -Version 7.2
# Shared, allowlisted management metadata and operations. No sign-in on import.
. (Join-Path $PSScriptRoot 'Common.ps1')

function Assert-OpsServiceId {
    param([string]$Id, [hashtable]$Config)
    Assert-OpsResourceScope $Id $Config.subscriptionId
    if ($Id -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/(Microsoft\.Web/sites|Microsoft\.Logic/workflows)/[^/]+$') {
        throw 'Select one top-level Web App, Function App or Logic App. Slots are separate operations.'
    }
}

function Invoke-OpsServiceRequest {
    param([hashtable]$Config, [string]$Id, [ValidateSet('GET','POST','PATCH')][string]$Method='GET', [hashtable]$Body)
    if ($Method -eq 'POST') {
        if ($Id -notmatch '^(.+/providers/Microsoft\.Web/sites/[^/]+)/(start|stop|restart)$' -and
            $Id -notmatch '^(.+/providers/Microsoft\.Logic/workflows/[^/]+)/(enable|disable)$') {throw 'Unsupported lifecycle request.'}
        Assert-OpsServiceId $Matches[1] $Config
    } else {
        Assert-OpsResourceScope $Id $Config.subscriptionId
        if ($Method -eq 'PATCH' -and $Id -notmatch '/providers/Microsoft\.Web/sites/[^/]+$') {throw 'Only site property PATCH is supported.'}
    }
    $version=if ($Id -match '/providers/Microsoft\.Logic/') {'2019-05-01'} else {'2024-11-01'}
    Assert-OpsContext (Get-AzContext) $Config 'ServicePrincipal'
    $requestParameters=@{Path="${Id}?api-version=$version";Method=$Method;ErrorAction='Stop'}
    if ($Body) {$requestParameters.Payload=$Body | ConvertTo-Json -Depth 60 -Compress}
    try {$response=Invoke-AzRestMethod @requestParameters}
    catch {
        $failure=[InvalidOperationException]::new('Management request failed. No automatic retry; details omitted.')
        $failure.Data['AzureOpsFailure']=Get-OpsFailureSummary $_
        throw $failure
    }
    if (($Method -eq 'GET' -and $response.StatusCode -ne 200) -or
        ($Method -ne 'GET' -and $response.StatusCode -notin @(200,201,202,204))) {
        $summary=Get-OpsArmErrorSummary $response
        $failure=[InvalidOperationException]::new('Management request failed. No automatic retry; details omitted.')
        $failure.Data['AzureOpsFailure']=@{HttpStatus=$summary.HttpStatus;CategoryHint=$summary.CategoryHint}
        throw $failure
    }
    if ($Method -ne 'GET') {return [int]$response.StatusCode}
    try {$item=$response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop}
    catch {throw 'Invalid management JSON. Response body omitted.'}
    if ($item -isnot [Collections.IDictionary] -or $item['id'] -isnot [string] -or $item['id'] -ine $Id -or
        $item['properties'] -isnot [Collections.IDictionary]) {throw 'Management response resource ID or shape mismatch.'}
    return $item
}

function Get-OpsServiceResource {
    param([hashtable]$Config,[string]$Id)
    Assert-OpsServiceId $Id $Config
    $item=Invoke-OpsServiceRequest $Config $Id
    $expectedType=if($Id -match '/Microsoft\.Logic/') {'Microsoft.Logic/workflows'} else {'Microsoft.Web/sites'}
    if ($item['type'] -ine $expectedType -or $item['kind'] -is [Collections.IDictionary] -or $item['kind'] -is [array]) {throw 'Unexpected service type.'}
    $service=Get-OpsServiceKind $item['type'] ([string]$item['kind'])
    if ($service -eq 'Other') {throw 'Unsupported service kind.'}
    return $item
}

function Get-OpsScalar {
    param($Object,[string]$Name)
    if ($Object -isnot [Collections.IDictionary]) {return $null}
    $value=$Object[$Name]
    if ($null -ne $value -and $value -isnot [string] -and $value -isnot [bool] -and
        $value -isnot [ValueType]) {throw 'Unexpected metadata field shape.'}
    return $value
}

function Get-OpsBoolean {
    param($Object,[string]$Name)
    $value=Get-OpsScalar $Object $Name
    if ($null -ne $value -and $value -isnot [bool]) {throw 'Expected boolean management metadata. Details omitted.'}
    return $value
}

function ConvertTo-OpsCanonical {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $result=[ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {$result[$key]=ConvertTo-OpsCanonical $Value[$key]}
        return $result
    }
    if ($Value -is [array]) {return ,@(foreach ($entry in $Value) {ConvertTo-OpsCanonical $entry})}
    return $Value
}

function Get-OpsFingerprint {
    param($Value)
    $json=ConvertTo-OpsCanonical $Value | ConvertTo-Json -Depth 70 -Compress
    $hash=[Security.Cryptography.SHA256]::Create()
    try {return [Convert]::ToHexString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))}
    finally {$hash.Dispose()}
}

function Get-OpsServiceSnapshot {
    param($Item)
    $p=$Item['properties']
    $snapshot=[ordered]@{ResourceId=$Item['id'];Service=(Get-OpsServiceKind $Item['type'] ([string]$Item['kind']))}
    foreach ($field in @('type','kind','location')) {$snapshot[$field]=Get-OpsScalar $Item $field}
    foreach ($field in @('state','provisioningState','serverFarmId','reserved','httpsOnly','publicNetworkAccess','clientAffinityEnabled')) {
        $snapshot[$field]=Get-OpsScalar $p $field
    }
    # Hashes are comparison evidence only. Raw identities/configuration never enter reports.
    $snapshot['IdentityFingerprint']=Get-OpsFingerprint $Item['identity']
    $f=$p['functionAppConfig']
    if ($null -ne $f) {
        if ($f -isnot [Collections.IDictionary] -or $f['scaleAndConcurrency'] -isnot [Collections.IDictionary]) {throw 'Invalid Function App configuration.'}
        $snapshot['maximumInstanceCount']=Get-OpsScalar $f['scaleAndConcurrency'] 'maximumInstanceCount'
        $snapshot['FunctionConfigurationFingerprint']=Get-OpsFingerprint $f
    }
    if ($Item['type'] -ieq 'Microsoft.Logic/workflows') {
        $snapshot['WorkflowConfigurationFingerprint']=Get-OpsFingerprint ([ordered]@{definition=$p['definition'];parameters=$p['parameters']})
    }
    return $snapshot
}

function ConvertTo-OpsServiceDetail {
    param($Item,[string[]]$Section,$WebConfiguration,$Plan,[int]$Limit=20)
    $p=$Item['properties'];$f=$p['functionAppConfig']
    $service=Get-OpsServiceKind $Item['type'] ([string]$Item['kind'])
    $result=[ordered]@{ResourceId=$Item['id'];Service=$service;Kind=(Get-OpsScalar $Item 'kind');Location=(Get-OpsScalar $Item 'location');State=(Get-OpsScalar $p 'state')}
    $consumption=$Item['type'] -ieq 'Microsoft.Logic/workflows'
    if ('Overview' -in $Section) {
        $result['Overview']=[ordered]@{Enabled=(Get-OpsBoolean $p 'enabled');ScmSiteAlsoStopped=(Get-OpsBoolean $p 'scmSiteAlsoStopped');ProvisioningState=(Get-OpsScalar $p 'provisioningState');PlanResourceId=(Get-OpsScalar $p 'serverFarmId');Linux=(Get-OpsScalar $p 'reserved');HttpsOnly=(Get-OpsScalar $p 'httpsOnly');PublicNetworkAccess=(Get-OpsScalar $p 'publicNetworkAccess')}
    }
    if ('Runtime' -in $Section) {
        if ($consumption -or $service -eq 'LogicApps') {$result['Runtime']=@{Status='NotApplicableToWorkflowMetadata'}}
        elseif ($f -is [Collections.IDictionary]) {
            $scale=$f['scaleAndConcurrency'];$ready=@($scale['alwaysReady'] | Where-Object {$null -ne $_})
            $result['Runtime']=[ordered]@{Source='functionAppConfig';Name=(Get-OpsScalar $f['runtime'] 'name');Version=(Get-OpsScalar $f['runtime'] 'version');MaximumInstanceCount=(Get-OpsScalar $scale 'maximumInstanceCount');InstanceMemoryMB=(Get-OpsScalar $scale 'instanceMemoryMB');AlwaysReadyGroupCount=$ready.Count;AlwaysReady=@($ready | Select-Object -First $Limit | ForEach-Object { @{Name=(Get-OpsScalar $_ 'name');InstanceCount=(Get-OpsScalar $_ 'instanceCount')} });DisplayTruncated=($ready.Count -gt $Limit)}
        } else {
            $runtime=[ordered]@{Source='config/web';FunctionsWorkerRuntime='NotReadFromAppSettings'}
            foreach ($key in @('linuxFxVersion','windowsFxVersion')) {
                $value=Get-OpsScalar $WebConfiguration $key
                # Container image references may contain credentials. Only code-stack identifiers are shown.
                $runtime[$key]=if ($value -and $value -notmatch '^(NODE|PYTHON|DOTNETCORE|DOTNET|PHP|JAVA|TOMCAT|JBOSSEAP)\|[A-Za-z0-9_.-]{1,50}$') {'OmittedNonCodeStack'} else {$value}
            }
            foreach ($key in @('netFrameworkVersion','phpVersion','pythonVersion','nodeVersion','javaVersion','javaContainer','javaContainerVersion','powerShellVersion','alwaysOn','use32BitWorkerProcess')) {$runtime[$key]=Get-OpsScalar $WebConfiguration $key}
            $result['Runtime']=$runtime
        }
    }
    if ('Network' -in $Section) {
        if ($consumption) {$result['Network']=@{Status='NotSupportedForConsumptionInThisHelper'}}
        else {
            $network=[ordered]@{}
            foreach ($key in @('httpsOnly','publicNetworkAccess','virtualNetworkSubnetId','clientAffinityEnabled')) {$network[$key]=Get-OpsScalar $p $key}
            foreach ($key in @('minTlsVersion','scmMinTlsVersion','ftpsState','http20Enabled','vnetRouteAllEnabled','ipSecurityRestrictionsDefaultAction','scmIpSecurityRestrictionsDefaultAction')) {$network[$key]=Get-OpsScalar $WebConfiguration $key}
            foreach ($key in @('ipSecurityRestrictions','scmIpSecurityRestrictions')) {$network[$key+'Count']=@($WebConfiguration[$key] | Where-Object {$null -ne $_}).Count}
            $result['Network']=$network
        }
    }
    if ('Identity' -in $Section) {
        $identity=$Item['identity'];$ids=@()
        if ($identity -is [Collections.IDictionary] -and $identity['userAssignedIdentities'] -is [Collections.IDictionary]) {$ids=@($identity['userAssignedIdentities'].Keys | Sort-Object)}
        $result['Identity']=[ordered]@{Type=(Get-OpsScalar $identity 'type');PrincipalId=(Get-OpsScalar $identity 'principalId');TenantId=(Get-OpsScalar $identity 'tenantId');UserAssignedCount=$ids.Count;UserAssignedIds=@($ids | Select-Object -First $Limit);DisplayTruncated=($ids.Count -gt $Limit)}
    }
    if ('Plan' -in $Section) {
        if ($consumption -or $null -eq $Plan) {$result['Plan']=@{Status='NoPlanAssociation'}}
        else {
            $result['Plan']=[ordered]@{ResourceId=$Plan['id'];Location=(Get-OpsScalar $Plan 'location');Sku=(Get-OpsScalar $Plan['sku'] 'name');Tier=(Get-OpsScalar $Plan['sku'] 'tier');Instances=(Get-OpsScalar $Plan['sku'] 'capacity');Linux=(Get-OpsScalar $Plan['properties'] 'reserved');NumberOfSites=(Get-OpsScalar $Plan['properties'] 'numberOfSites');Status=(Get-OpsScalar $Plan['properties'] 'status')}
        }
    }
    if ('Structure' -in $Section) {
        if (-not $consumption) {$result['Structure']=@{Status='ConsumptionOnly;StandardRequiresSeparateVerification'}}
        else {
            $structure=[ordered]@{Scope='TopLevelOnly;NoInputsExpressionsOrConnectionValues'}
            foreach ($group in @('triggers','actions')) {
                $map=$p['definition'][$group];$names=@()
                if ($map -is [Collections.IDictionary]) {$names=@($map.Keys | Sort-Object)}
                $structure[$group]=@{Count=$names.Count;DisplayTruncated=($names.Count -gt $Limit);Items=@($names | Select-Object -First $Limit | ForEach-Object { @{Name=$_;Type=(Get-OpsScalar $map[$_] 'type')} })}
            }
            $result['Structure']=$structure
        }
    }
    return $result
}

function Get-OpsOperationSpec {
    param($Item,[string]$Operation,[string]$Value)
    $service=Get-OpsServiceKind $Item['type'] ([string]$Item['kind'])
    $consumption=$Item['type'] -ieq 'Microsoft.Logic/workflows'
    $p=$Item['properties'];$body=$null;$method='PATCH';$suffix='';$field=$null;$desired=$null
    if ($Operation -in @('Start','Stop','Restart','Enable','Disable') -and $Value) {throw 'Lifecycle operations do not accept a value.'}
    if ($Operation -in @('Enable','Disable')) {
        if (-not $consumption) {throw 'Enable/Disable requires Logic Apps Consumption.'}
        $method='POST';$suffix='/'+$Operation.ToLowerInvariant();$field='state'
        $desired=if ($Operation -eq 'Enable') {'Enabled'} else {'Disabled'}
        $permission="Microsoft.Logic/workflows/$($Operation.ToLowerInvariant())/action"
    } else {
        if ($service -notin @('AppService','Functions')) {throw 'Standard Logic Apps whole-app changes require separate verification.'}
        $permission='Microsoft.Web/sites/write'
        switch ($Operation) {
            {$_ -in @('Start','Stop','Restart')} {
                $method='POST';$suffix='/'+$Operation.ToLowerInvariant();$field='state'
                $desired=if ($Operation -eq 'Stop') {'Stopped'} else {'Running'}
                if ($Operation -eq 'Restart' -and $p['state'] -ne 'Running') {throw 'Restart requires a running app.'}
                $permission="Microsoft.Web/sites/$($Operation.ToLowerInvariant())/action"
            }
            {$_ -in @('SetHttpsOnly','SetClientAffinity')} {
                if ($Value -cnotin @('true','false')) {throw 'Expected literal true or false.'}
                if ($Operation -eq 'SetClientAffinity' -and $service -ne 'AppService') {throw 'Session affinity is supported only for Web Apps.'}
                $field=if ($Operation -eq 'SetHttpsOnly') {'httpsOnly'} else {'clientAffinityEnabled'}
                $desired=$Value -ceq 'true';$body=@{properties=@{$field=$desired}}
            }
            'SetPublicNetworkAccess' {
                if ($Value -cnotin @('Enabled','Disabled')) {throw 'Expected Enabled or Disabled.'}
                $field='publicNetworkAccess';$desired=$Value;$body=@{properties=@{$field=$desired}}
            }
            'SetFlexMaximumInstanceCount' {
                if ($service -ne 'Functions' -or $p['functionAppConfig'] -isnot [Collections.IDictionary] -or $Value -notmatch '^[1-9]\d{0,3}$' -or [int]$Value -gt 1000) {throw 'Flex maximum instance count must be 1-1000.'}
                $f=$p['functionAppConfig'];$scale=$f['scaleAndConcurrency']
                if ($scale -isnot [Collections.IDictionary] -or $f['runtime'] -isnot [Collections.IDictionary] -or $f['deployment'] -isnot [Collections.IDictionary]) {throw 'Incomplete Flex configuration; refuse replacement.'}
                $field='maximumInstanceCount';$desired=[int]$Value
                $copy=$f | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable
                $copy['scaleAndConcurrency'][$field]=$desired
                $body=@{properties=@{functionAppConfig=$copy}}
            }
            default {throw 'Unsupported operation.'}
        }
    }
    $states=if ($consumption) {@('Enabled','Disabled')} else {@('Running','Stopped')}
    if ($p['state'] -notin $states) {throw 'A stable management state is required before planning.'}
    $before=Get-OpsServiceSnapshot $Item
    return @{Method=$method;Suffix=$suffix;Body=$body;Field=$field;Desired=$desired;Permission=$permission;Before=$before}
}

function New-OpsOperationPlan {
    param([hashtable]$Config,$Item,[string]$Operation,[string]$Value)
    $spec=Get-OpsOperationSpec $Item $Operation $Value
    return [ordered]@{Schema='AzureOpsOperationPlan/1';RetrievedAtUtc=[DateTime]::UtcNow.ToString('o');Source='Live';TenantId=$Config.tenantId;SubscriptionId=$Config.subscriptionId;ApplicationId=$Config.applicationId;ResourceId=$Item['id'];Operation=$Operation;Value=$Value;RequiredAction=$spec.Permission;PermissionScope=$Item['id'];Before=$spec.Before;Change=@{Field=$spec.Field;Before=$spec.Before[$spec.Field];After=$spec.Desired};Verification='ARM management state only; not application or trigger health'}
}

function Assert-OpsReviewedPlan {
    param($Reviewed,$Current)
    if ($Reviewed -isnot [Collections.IDictionary] -or $Reviewed['Schema'] -ne 'AzureOpsOperationPlan/1') {throw 'Invalid reviewed plan.'}
    $stamp=[DateTimeOffset]::MinValue
    # ConvertFrom-Json in newer PS versions turns ISO timestamps into UTC DateTime objects.
    # Casting that value to string first would discard its timezone.
    $validStamp=$true
    if ($Reviewed['RetrievedAtUtc'] -is [DateTime] -or $Reviewed['RetrievedAtUtc'] -is [DateTimeOffset]) {$stamp=[DateTimeOffset]$Reviewed['RetrievedAtUtc']}
    else {$validStamp=[DateTimeOffset]::TryParse([string]$Reviewed['RetrievedAtUtc'],[ref]$stamp)}
    if (-not $validStamp -or $stamp -gt [DateTimeOffset]::UtcNow.AddMinutes(1) -or $stamp -lt [DateTimeOffset]::UtcNow.AddHours(-1)) {throw 'Plan is expired or has an invalid timestamp. Replan and review.'}
    foreach ($key in @('Schema','Source','TenantId','SubscriptionId','ApplicationId','ResourceId','Operation','Value','RequiredAction','PermissionScope','Before','Change')) {
        if ((Get-OpsFingerprint $Reviewed[$key]) -cne (Get-OpsFingerprint $Current[$key])) {throw 'Reviewed plan differs from the requested operation or current state. Replan and review.'}
    }
}

function Assert-OpsOperationResult {
    param($Before,$After,$Spec)
    $expected=$Before | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $expected[$Spec.Field]=$Spec.Desired
    if ($Spec.Field -eq 'maximumInstanceCount') {$expected['FunctionConfigurationFingerprint']=Get-OpsFingerprint $Spec.Body.properties.functionAppConfig}
    # ProvisioningState may be transient; all other protected metadata must stay unchanged.
    $expected.Remove('provisioningState')
    $actual=$After | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $actual.Remove('provisioningState')
    if ((Get-OpsFingerprint $expected) -cne (Get-OpsFingerprint $actual)) {throw 'Post-change state differs from the reviewed result. No automatic rollback.'}
}
