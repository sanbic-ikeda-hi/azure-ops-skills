#requires -Version 7.2
# Offline behavior tests. No login, Azure request, report write or real wait occurs.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Check-FunctionCreation {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition) {throw "FAIL: $Message"}
    $script:checks++
}
function Test-FunctionCreationScenario {
    param([string]$Scenario)
    $sub='11111111-1111-1111-1111-111111111111'
    $ops='22222222-2222-2222-2222-222222222222'
    $hostIdentity='33333333-3333-3333-3333-333333333333'
    $groupId="/subscriptions/$sub/resourceGroups/rg-azureops-functions-test"
    $siteId="$groupId/providers/Microsoft.Web/sites/func-azureops-test-222222222222"
    $planId="$groupId/providers/Microsoft.Web/serverfarms/asp-azureops-functions-test"
    $storageId="$groupId/providers/Microsoft.Storage/storageAccounts/stazopsfn222222222222"
    $containerId="$storageId/blobServices/default/containers/deployment"
    $profile=@{tenantId=$sub;subscriptionIds=@($sub,$ops);sandboxSubscriptionId=$sub;applicationId=$ops;servicePrincipalObjectId=$ops;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $reportPath=Join-Path ([IO.Path]::GetTempPath()) 'offline-functions-report.txt'
    $calls=@{connect=0;disconnect=0;context=0;sleep=0;files=0;get=0;puts=[Collections.Generic.List[object]]::new();records=[Collections.Generic.List[object]]::new()}
    $simulated=@{resources=@{};pending=($Scenario -eq 'Pending')}
    if($Scenario -eq 'ExistingGroup') {$simulated.resources[$groupId]=@{id=$groupId;location='westus3'}}
    foreach($pair in @(@('ExistingApp',$siteId),@('ExistingPlan',$planId),@('ExistingStorage',$storageId))) {
        if($Scenario -eq $pair[0]) {$simulated.resources[$pair[1]]=@{id=$pair[1]}}
    }
    function Test-Path {
        param($LiteralPath,$PathType)
        if($LiteralPath -eq $reportPath) {return $Scenario -eq 'ExistingReport'}
        if($LiteralPath -eq (Split-Path $reportPath -Parent)) {return $Scenario -ne 'MissingReportDirectory'}
        return $true
    }
    function Get-Content {$profile}
    function New-Item {param($ItemType,$Path) $calls.files++}
    function Add-Content {
        param($LiteralPath,$Encoding,[Parameter(ValueFromPipeline)]$Value)
        process {
            if($Scenario -eq 'ReportWriteFailure') {throw 'Simulated report write failure'}
            $calls.records.Add(($Value | ConvertFrom-Json -AsHashtable))
        }
    }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {$calls.connect++}
    function Disconnect-AzAccount {$calls.disconnect++}
    function Start-Sleep {$calls.sleep++}
    function Get-AzContext {
        $calls.context++
        $wrong=$Scenario -eq 'WrongContext' -or ($Scenario -eq 'ContextChanged' -and $calls.puts.Count -ge 1)
        @{Tenant=@{Id=$sub};Subscription=@{Id=$(if($wrong){$ops}else{$sub})};Account=@{Type='User'};Environment=@{Name='AzureCloud'}}
    }
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        $id=$Path.Split('?')[0]
        if(-not $id.StartsWith("/subscriptions/$sub/")) {throw 'Unexpected subscription'}
        if($Method -eq 'GET') {
            $calls.get++
            if($Scenario -eq 'ReadDenied') {return @{StatusCode=403;Content='DO_NOT_EMIT_SECRET'}}
            if($id -match '/providers/(Microsoft.Web|Microsoft.Storage)$') {
                $namespace=$Matches[1]
                $state=if(($Scenario -eq 'MissingWeb' -and $namespace -eq 'Microsoft.Web') -or ($Scenario -eq 'MissingStorage' -and $namespace -eq 'Microsoft.Storage')) {'Registering'}else{'Registered'}
                return @{StatusCode=200;Content=(@{namespace=$namespace;registrationState=$state}|ConvertTo-Json)}
            }
            if($id -notin @($groupId,$siteId,$planId,$storageId,$containerId) -and -not $id.StartsWith("$storageId/providers/Microsoft.Authorization/roleAssignments/")) {throw 'Unexpected GET'}
            if(-not $simulated.resources.ContainsKey($id)) {return @{StatusCode=404;Content='DO_NOT_EMIT_SECRET'}}
            if($id -eq $planId -and $simulated.pending) {$simulated.pending=$false;return @{StatusCode=404}}
            if($id -eq $siteId -and $Scenario -eq 'NeverReady') {return @{StatusCode=404}}
            $resource=$simulated.resources[$id].Clone()
            if($Scenario -eq 'WrongResponseId') {$resource.id='other-id'}
            return @{StatusCode=200;Content=($resource | ConvertTo-Json -Depth 15)}
        }
        if($Method -ne 'PUT') {throw 'Unexpected mutation'}
        $body=$Payload | ConvertFrom-Json -AsHashtable
        $calls.puts.Add(@{Id=$id;Body=$body})
        if($id -notin @($groupId,$siteId,$planId,$storageId,$containerId) -and -not $id.StartsWith("$storageId/providers/Microsoft.Authorization/roleAssignments/")) {throw 'Unexpected PUT'}
        if($id -eq $planId -and $Scenario -eq 'PlanQuotaFailure') {
            return @{StatusCode=401;Content='{"Code":"Unauthorized","Message":"Operation cannot be completed without additional quota. Current Limit (Flex): 0","Details":[{"ErrorEntity":{"ExtendedCode":"70007"}}]}'}
        }
        if($id -eq $storageId -and $Scenario -eq 'StorageFailure') {return @{StatusCode=403;Content='DO_NOT_EMIT_SECRET'}}
        if($id.Contains('/roleAssignments/') -and $Scenario -eq 'RoleFailure') {return @{StatusCode=403;Content='DO_NOT_EMIT_SECRET'}}
        # Clone so simulated server-side changes do not change our captured request.
        $resource=$Payload | ConvertFrom-Json -AsHashtable
        $resource.id=$id
        if($id -eq $planId) {
            $resource.type='Microsoft.Web/serverfarms';$resource.properties.provisioningState='Succeeded'
            if($Scenario -eq 'WrongPlanSku') {$resource.sku.name='P0v4'}
        } elseif($id -eq $storageId) {
            $resource.type='Microsoft.Storage/storageAccounts';$resource.properties.provisioningState='Succeeded'
            if($Scenario -eq 'UnsafeStorage') {$resource.properties.allowSharedKeyAccess=$true}
        } elseif($id -eq $containerId) {
            if($Scenario -eq 'PublicContainer') {$resource.properties.publicAccess='Blob'}
        } elseif($id -eq $siteId) {
            $resource.type='Microsoft.Web/sites';$resource.properties.state='Running'
            $resource.identity.principalId=$(if($Scenario -eq 'OperatorAsHost'){$ops}else{$hostIdentity})
            $resource.identity.tenantId=$(if($Scenario -eq 'WrongHostTenant'){$ops}else{$sub})
            if($Scenario -eq 'WrongService') {$resource.kind='functionapp,workflowapp,linux'}
            if($Scenario -eq 'WrongAppPlan') {$resource.properties.serverFarmId='other-plan'}
            if($Scenario -eq 'WrongRuntime') {$resource.properties.functionAppConfig.runtime.version='20'}
            if($Scenario -eq 'AlwaysReady') {$resource.properties.functionAppConfig.scaleAndConcurrency.alwaysReady=@(@{name='http';instanceCount=1})}
            $resource.properties.privateTestField='DO_NOT_EMIT_SECRET'
        } elseif($id.Contains('/roleAssignments/')) {
            $resource.type='Microsoft.Authorization/roleAssignments';$resource.properties.scope=$storageId
            if($Scenario -eq 'WrongRoleRecipient') {$resource.properties.principalId=$ops}
        }
        $simulated.resources[$id]=$resource
        @{StatusCode=201;Content='DO_NOT_EMIT_RAW_RESPONSE'}
    }
    $parameters=@{Action=$(if($Scenario -eq 'Plan'){'Plan'}else{'Create'});OutputPath=$reportPath;Location='japaneast';ResourceGroupName='rg-azureops-functions-test';FunctionAppName='func-azureops-test-222222222222';PlanName='asp-azureops-functions-test';StorageAccountName='stazopsfn222222222222'}
    if($Scenario -eq 'InvalidGroup') {$parameters.ResourceGroupName='../other'}
    if($Scenario -eq 'InvalidLocation') {$parameters.Location='bad?region'}
    if($Scenario -eq 'ReportInRepository') {$parameters.OutputPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'should-not-exist.txt'}
    $failed=$false;$output=@()
    try {$output=@(& (Join-Path $PSScriptRoot 'New-SandboxFunctionApp.ps1') @parameters *>&1)} catch {$failed=$true}
    $success=$Scenario -in @('Plan','Success','Pending','ExistingGroup')
    Check-FunctionCreation ($failed -ne $success) "Expected outcome: $Scenario"
    $rendered=($output -join '')+($calls.records | ConvertTo-Json -Depth 16 -Compress)
    Check-FunctionCreation ($rendered -notmatch 'DO_NOT_EMIT') "No raw response, secret or unselected field recorded: $Scenario"
    Check-FunctionCreation ($calls.disconnect -eq $calls.connect) "User connection disposed: $Scenario"
    Check-FunctionCreation (@($calls.puts | Where-Object {$_.Id -notlike "$groupId*"}).Count -eq 0) "No writes outside selected fixture: $Scenario"
    if($Scenario -in @('Plan','ExistingReport','MissingReportDirectory','ReportWriteFailure','ReportInRepository','InvalidGroup','InvalidLocation')) {
        Check-FunctionCreation ($calls.connect -eq 0 -and $calls.puts.Count -eq 0) "Plan/input/report checks precede authentication: $Scenario"
    } elseif($success) {
        $expected=if($Scenario -eq 'ExistingGroup'){6}else{7}
        Check-FunctionCreation ($calls.puts.Count -eq $expected) "Exactly the reviewed creates, no retries: $Scenario"
        $appPut=@($calls.puts | Where-Object Id -EQ $siteId)[0].Body
        $settings=@($appPut.properties.siteConfig.appSettings | ForEach-Object { $_.name })
        Check-FunctionCreation (($settings | Sort-Object) -join '|' -eq 'AzureWebJobsStorage__accountName|AzureWebJobsStorage__credential') "Only non-secret identity settings: $Scenario"
        Check-FunctionCreation (-not $appPut.properties.siteConfig.ContainsKey('alwaysOn') -and -not $appPut.properties.siteConfig.ContainsKey('ftpsState') -and -not $appPut.properties.siteConfig.ContainsKey('linuxFxVersion')) "No settings deprecated for Flex: $Scenario"
        Check-FunctionCreation ($appPut.properties.functionAppConfig.scaleAndConcurrency.maximumInstanceCount -eq 40 -and $appPut.properties.functionAppConfig.scaleAndConcurrency.alwaysReady.Count -eq 0) "No always-ready capacity and explicit scaling ceiling: $Scenario"
        $assignments=@($calls.puts | Where-Object {$_.Id.Contains('/roleAssignments/')})
        Check-FunctionCreation ($assignments.Count -eq 2 -and @($assignments | Where-Object {$_.Body.properties.principalId -ne $hostIdentity -or -not $_.Id.StartsWith("$storageId/providers/")}).Count -eq 0) "Host identity only, individual storage scope: $Scenario"
        Check-FunctionCreation (@($assignments | Where-Object {$_.Body.properties.roleDefinitionId -notmatch '/(b7e6dc6d-f1e8-4753-8033-0f276bb0955b|0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3)$'}).Count -eq 0) "Only approved built-in host roles: $Scenario"
        $last=$calls.records[-1]
        Check-FunctionCreation ($last.Event -eq 'Succeeded' -and $last.Data.HostHealthVerified -eq $false -and $last.Data.GrantsOpsAppPermissions -eq $false) "Creation does not claim code execution or operator grant: $Scenario"
        if($Scenario -eq 'Pending') {Check-FunctionCreation ($calls.sleep -eq 1) 'Provisioning waits with GET, never a repeated PUT'}
    } else {
        Check-FunctionCreation (@($calls.puts | Group-Object Id | Where-Object Count -GT 1).Count -eq 0) "Failed writes are not retried: $Scenario"
        if($Scenario -in @('MissingWeb','MissingStorage','ReadDenied','ExistingApp','ExistingPlan','ExistingStorage','WrongContext')) {
            Check-FunctionCreation ($calls.puts.Count -eq 0) "Failed preflight makes no Azure changes: $Scenario"
        }
        if($Scenario -eq 'PlanQuotaFailure') {
            Check-FunctionCreation ($calls.puts.Count -eq 2 -and @($calls.puts | Where-Object Id -EQ $storageId).Count -eq 0) 'Quota failure stops before storage creation'
            Check-FunctionCreation (@($calls.records | Where-Object {$_.Event -eq 'ArmFailure' -and $_.Data.CategoryHint -eq 'Quota'}).Count -eq 1) 'Quota failure has a sanitized diagnosis'
        }
        if($Scenario -in @('WrongService','WrongAppPlan','WrongRuntime','AlwaysReady','OperatorAsHost','WrongHostTenant','NeverReady')) {
            Check-FunctionCreation (@($calls.puts | Where-Object {$_.Id.Contains('/roleAssignments/')}).Count -eq 0) "Unverified Function App identity/configuration gets no grant: $Scenario"
        }
    }
}
foreach($scenario in @('Plan','Success','ExistingGroup','Pending','ExistingApp','ExistingPlan','ExistingStorage','MissingWeb','MissingStorage',
    'ReadDenied','WrongContext','ContextChanged','WrongResponseId','PlanQuotaFailure','WrongPlanSku','StorageFailure','UnsafeStorage','PublicContainer',
    'WrongService','WrongAppPlan','WrongRuntime','AlwaysReady','OperatorAsHost','WrongHostTenant','RoleFailure','WrongRoleRecipient','NeverReady',
    'ExistingReport','MissingReportDirectory','ReportWriteFailure','ReportInRepository','InvalidGroup','InvalidLocation')) {
    Test-FunctionCreationScenario $scenario
}
Write-Host "PASS: $checks Flex Consumption creation checks (offline)."
