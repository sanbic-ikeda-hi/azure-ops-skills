#requires -Version 7.2
# Offline: all certificate access, sign-ins, ARM calls, report writes and waits are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Verify-FunctionsExecution {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Test-FunctionsExecutionScenario {
    param([string]$Scenario)
    $sub='11111111-1111-1111-1111-111111111111';$operator='22222222-2222-2222-2222-222222222222';$hostId='33333333-3333-3333-3333-333333333333'
    $group="/subscriptions/$sub/resourceGroups/test-rg"
    $appId="$group/providers/Microsoft.Web/sites/test-function";$planId="$group/providers/Microsoft.Web/serverfarms/test-plan"
    $storageId="$group/providers/Microsoft.Storage/storageAccounts/teststorage"
    $assignment="$appId/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-4444-444444444444"
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$operator;servicePrincipalObjectId=$operator;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $report=Join-Path $env:TEMP 'azureops-functions-offline-mocked-report.txt'
    $calls=@{connect=0;disconnect=0;files=0;get=0;sleep=0;writes=[Collections.Generic.List[string]]::new();records=[Collections.Generic.List[string]]::new();patches=[Collections.Generic.List[object]]::new()}
    $simulatedApp=@{running='Running';maximum=$(if($Scenario -eq 'WrongBaseline'){41}else{40});pending=0}
    function Test-Path {param($LiteralPath,$PathType) if($LiteralPath -eq $report){return ($Scenario -eq 'ExistingReport')};return $true}
    function Get-Content {$profile}
    function Get-Item {[pscustomobject]@{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)}}
    function New-Item {param($ItemType,$Path) if($ItemType -ne 'File' -or $Path -ne $report){throw 'Unexpected file write'};$calls.files++}
    function Add-Content {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)][string]$Value,$LiteralPath,$Encoding)
        process {
            if($LiteralPath -ne $report -or $Encoding -ne 'utf8'){throw 'Unexpected report destination/encoding'}
            if($Scenario -eq 'OutputFailure'){throw 'Simulated report failure'}
            $calls.records.Add($Value)
        }
    }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {param([switch]$ServicePrincipal) if(-not $ServicePrincipal){throw 'Only dedicated app authentication allowed'};$calls.connect++}
    function Disconnect-AzAccount {$calls.disconnect++}
    function Get-AzContext {
        @{Tenant=@{Id=$sub};Subscription=@{Id=$sub};Account=@{Type='ServicePrincipal';Id=$(if($Scenario -eq 'WrongIdentity' -or ($Scenario -eq 'ContextChanged' -and $calls.writes.Count -gt 0)){$sub}else{$operator})};Environment=@{Name='AzureCloud'}}
    }
    function Start-Sleep {$calls.sleep++}
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        $id=$Path.Split('?')[0]
        if($Method -ne 'GET') {
            if($id -notin @($appId,"$appId/stop","$appId/start")){throw 'Mutation outside test Function App'}
            $calls.writes.Add("$Method $id")
            if($Scenario -eq 'StopDenied' -and $id -like '*/stop'){return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
            if($Scenario -eq 'StartFailure' -and $id -like '*/start'){return @{StatusCode=409;Content='DO_NOT_OUTPUT_ERROR'}}
            if($Method -eq 'POST' -and $id -like '*/stop') {$simulatedApp.running='Stopped'}
            elseif($Method -eq 'POST' -and $id -like '*/start') {$simulatedApp.running='Running'}
            elseif($Method -eq 'PATCH' -and $id -eq $appId) {
                if($Scenario -eq 'PatchFailure' -or ($Scenario -eq 'RestoreFailure' -and $calls.writes.Count -eq 4)){return @{StatusCode=409;Content='DO_NOT_OUTPUT_ERROR'}}
                $body=$Payload | ConvertFrom-Json -AsHashtable
                if($body.Count -ne 1 -or $body.properties.Count -ne 1 -or -not $body.properties.ContainsKey('functionAppConfig')) {throw 'PATCH must only contain Function App configuration'}
                $f=$body.properties.functionAppConfig
                if($f.runtime.name -ne 'node' -or $f.runtime.version -ne '22' -or
                    $f.deployment.storage.value -ne 'https://teststorage.blob.core.windows.net/deployment' -or
                    $f.deployment.storage.authentication.type -ne 'SystemAssignedIdentity' -or
                    $f.siteUpdateStrategy.type -ne 'Recreate' -or $f.scaleAndConcurrency.instanceMemoryMB -ne 2048 -or
                    $f.scaleAndConcurrency.alwaysReady.Count -ne 0 -or $f.scaleAndConcurrency.triggers.http.perInstanceConcurrency -ne 8) {throw 'PATCH failed to preserve unrelated configuration'}
                $calls.patches.Add($f)
                $simulatedApp.maximum=$f.scaleAndConcurrency.maximumInstanceCount
            } else {throw 'Unexpected mutation'}
            if($Scenario -eq 'Pending') {$simulatedApp.pending=1}
            return @{StatusCode=200}
        }
        $calls.get++
        if($Scenario -eq 'ReadDenied') {return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
        if($id -eq $planId) {
            $item=@{id=$planId;type='Microsoft.Web/serverfarms';location='Japan East';sku=@{name=$(if($Scenario -eq 'WrongPlan'){'P0v4'}else{'FC1'});tier='FlexConsumption'};properties=@{provisioningState='Succeeded';status='Ready';reserved=$true;numberOfSites=$(if($Scenario -eq 'PlanChanged' -and $calls.writes.Count -gt 0){2}else{1});perSiteScaling=$false;zoneRedundant=$false}}
        } elseif($id -eq "$appId/functions") {
            $item=@{value=@()}
            if($Scenario -eq 'FunctionsExist' -or ($Scenario -eq 'FunctionsAppeared' -and $calls.writes.Count -gt 0)) {$item.value=@(@{name='DO_NOT_OUTPUT_CODE';properties=@{config='DO_NOT_OUTPUT_SETTINGS'}})}
            if($Scenario -eq 'FunctionsPaged') {$item.nextLink='https://management.azure.com/DO_NOT_OUTPUT_LINK'}
        } elseif($id -eq $appId) {
            $pending=$simulatedApp.pending -gt 0
            if($pending) {$simulatedApp.pending--}
            $f=@{
                deployment=@{storage=@{type='blobContainer';value=$(if($Scenario -eq 'WrongStorage'){'https://other.blob.core.windows.net/deployment'}else{'https://teststorage.blob.core.windows.net/deployment'});authentication=@{type='SystemAssignedIdentity'}}}
                runtime=@{name='node';version='22'};siteUpdateStrategy=@{type='Recreate'}
                scaleAndConcurrency=@{maximumInstanceCount=$simulatedApp.maximum;instanceMemoryMB=2048;alwaysReady=@();triggers=@{http=@{perInstanceConcurrency=$(if($Scenario -eq 'ConfigChanged' -and $calls.writes.Count -gt 0){9}else{8})}}}
            }
            if($Scenario -eq 'AlwaysReady') {$f.scaleAndConcurrency.alwaysReady=@(@{name='http';instanceCount=1})}
            if($Scenario -eq 'Reordered') {
                $f.runtime=[ordered]@{version='22';name='node'}
                if($calls.writes.Count -gt 0){$f.runtime=[ordered]@{name='node';version='22'}}
            }
            $item=@{
                id=$appId;type='Microsoft.Web/sites';kind=$(if($Scenario -eq 'WrongService'){'functionapp,workflowapp,linux'}else{'functionapp,linux'});location='Japan East'
                identity=@{type='SystemAssigned';principalId=$(if($Scenario -eq 'HostIdentityChanged' -and $calls.writes.Count -gt 0){$operator}else{$hostId});tenantId=$sub}
                properties=@{
                    state=$(if($pending -or ($Scenario -eq 'Timeout' -and $calls.writes.Count -gt 0)){'Starting'}else{$simulatedApp.running})
                    serverFarmId=$planId;reserved=$true;httpsOnly=(-not($Scenario -eq 'ProtectedChanged' -and $calls.writes.Count -gt 0));publicNetworkAccess='Disabled'
                    functionAppConfig=$f;privateTestField='DO_NOT_OUTPUT_SECRET';siteConfig=@{appSettings=@(@{name='DO_NOT_OUTPUT_SETTINGS';value='DO_NOT_OUTPUT_SECRET'})}
                }
            }
        } else {throw 'Unexpected GET; storage and role APIs are forbidden'}
        @{StatusCode=200;Content=($item | ConvertTo-Json -Depth 14)}
    }
    $arguments=@{ResourceId=$appId;PlanResourceId=$planId;StorageResourceId=$storageId;ManagedIdentityObjectId=$hostId;AssignmentId=$assignment;OutputPath=$report;Location='japaneast';Execute=($Scenario -ne 'Plan')}
    if($Scenario -eq 'RepositoryReport') {$arguments.OutputPath=Join-Path $PSScriptRoot 'unsafe-report.txt'}
    if($Scenario -eq 'OtherAssignment') {$arguments.AssignmentId=$assignment.Replace('/test-function/','/other-app/')}
    if($Scenario -eq 'OtherStorageSubscription') {$arguments.StorageResourceId=$storageId.Replace($sub,$operator)}
    if($Scenario -eq 'OperatorAsHost') {$arguments.ManagedIdentityObjectId=$operator}
    $failed=$false;$failure=''
    try {& (Join-Path $PSScriptRoot 'Invoke-SandboxFunctionsTest.ps1') @arguments 6>$null} catch {$failed=$true;$failure=$_.Exception.Message}
    $success=$Scenario -in @('Plan','Success','Pending','Reordered')
    Verify-FunctionsExecution ($failed -ne $success) "Expected result: $Scenario $failure"
    Verify-FunctionsExecution ($calls.connect -eq $calls.disconnect) "Dedicated app disconnected: $Scenario"
    $records=@($calls.records | ForEach-Object {$_ | ConvertFrom-Json -AsHashtable})
    Verify-FunctionsExecution (($calls.records -join '') -notmatch 'DO_NOT_OUTPUT_') "No raw responses, errors, settings, code or secrets in report: $Scenario"
    if($Scenario -in @('Plan','ExistingReport','RepositoryReport','OtherAssignment','OtherStorageSubscription','OperatorAsHost','OutputFailure')) {
        Verify-FunctionsExecution ($calls.connect -eq 0 -and $calls.get -eq 0 -and $calls.writes.Count -eq 0) "Plan and invalid inputs do not reach Azure: $Scenario"
    } elseif($success) {
        Verify-FunctionsExecution (($calls.writes -join '|') -eq "POST $appId/stop|POST $appId/start|PATCH $appId|PATCH $appId") "Only four approved writes in order: $Scenario"
        Verify-FunctionsExecution ($simulatedApp.running -eq 'Running' -and $simulatedApp.maximum -eq 40 -and $records[-1].Event -eq 'Succeeded' -and -not $records[-1].Data.HostHealthVerified) "Original management state restored, no host-health claim: $Scenario"
        Verify-FunctionsExecution (@($records | Where-Object Event -Like '*Verified').Count -eq 4) "All four writes independently read back: $Scenario"
        Verify-FunctionsExecution ($calls.patches.Count -eq 2 -and $calls.patches[0].scaleAndConcurrency.maximumInstanceCount -eq 41 -and $calls.patches[1].scaleAndConcurrency.maximumInstanceCount -eq 40) "Only scale ceiling changes, baseline copy stays intact: $Scenario"
        if($Scenario -eq 'Pending') {Verify-FunctionsExecution ($calls.sleep -eq 4) 'Eventual state uses GET polling, not repeated writes'}
    } else {
        Verify-FunctionsExecution ($records[-1].Event -eq 'Failed' -and -not @($records | Where-Object Event -EQ 'Succeeded').Count) "Failure reported without false success: $Scenario"
        $expectedWrites=switch($Scenario){'StopDenied'{1};'StartFailure'{2};'PatchFailure'{3};'RestoreFailure'{4};'ProtectedChanged'{1};'ConfigChanged'{1};'HostIdentityChanged'{1};'ContextChanged'{1};'Timeout'{1};'PlanChanged'{4};'FunctionsAppeared'{4};default{0}}
        Verify-FunctionsExecution ($calls.writes.Count -eq $expectedWrites) "No retries or automatic rollback: $Scenario"
        if($Scenario -eq 'RestoreFailure') {Verify-FunctionsExecution ($simulatedApp.maximum -eq 41) 'Failed restore is left for user review and is not claimed successful'}
    }
}
foreach($scenario in @('Plan','Success','Pending','Reordered','WrongBaseline','WrongIdentity','WrongService','WrongPlan','WrongStorage','AlwaysReady',
    'FunctionsExist','FunctionsPaged','ReadDenied','StopDenied','StartFailure','PatchFailure','RestoreFailure','ProtectedChanged','ConfigChanged','HostIdentityChanged','ContextChanged',
    'Timeout','PlanChanged','FunctionsAppeared','ExistingReport','RepositoryReport','OtherAssignment','OtherStorageSubscription','OperatorAsHost','OutputFailure')) {
    Test-FunctionsExecutionScenario $scenario
}
Write-Host "PASS: $checks Functions management execution/report checks (offline)."
