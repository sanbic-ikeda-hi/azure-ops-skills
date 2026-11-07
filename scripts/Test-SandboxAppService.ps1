#requires -Version 7.2
# Offline fixture tests: all Azure, authentication and waiting are mocked in memory.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Verify-Fixture {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Test-FixtureScenario {
    param([string]$Scenario, [string]$TestLocation='japaneast', [switch]$ExplicitLocation)
    $sub='11111111-1111-1111-1111-111111111111'
    $app='22222222-2222-2222-2222-222222222222'
    $expectedLocation=$TestLocation.ToLowerInvariant()
    $regionSuffix=if ($expectedLocation -eq 'japaneast') {''} else {"-$expectedLocation"}
    $groupName='rg-azureops-appservice-test' + $regionSuffix
    $groupId="/subscriptions/$sub/resourceGroups/$groupName"
    $planId="$groupId/providers/Microsoft.Web/serverfarms/asp-azureops-sandbox-test$regionSuffix"
    $appId="$groupId/providers/Microsoft.Web/sites/app-azureops-test-222222222222$regionSuffix"
    $purpose='azure-ops-skills-appservice-test'
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$app;servicePrincipalObjectId=$app;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $action=if ($Scenario -eq 'Plan') {'Plan'} elseif ($Scenario.StartsWith('Create')) {'CreatePlan'} elseif ($Scenario.StartsWith('Resume')) {'ResumePlan'} elseif ($Scenario.StartsWith('Remove')) {'Remove'} else {'AddApp'}
    $testSku=if ($Scenario -eq 'CreateQuotaFailure') {'B1'} else {'P0v4'}
    $calls=@{connect=0;disconnect=0;group=0;put=[Collections.Generic.List[string]]::new();delete=[Collections.Generic.List[string]]::new();payload=$null;sleeps=0;pending=0}
    $state=@{plan=($action -notin @('CreatePlan','ResumePlan') -or $Scenario -eq 'ResumeExistingPlan');app=($action -eq 'Remove' -or $Scenario -eq 'ExistingApp')}
    if ($Scenario -eq 'MissingPlan') {$state.plan=$false}
    if ($Scenario -eq 'RemovePlanOnly') {$state.app=$false}
    function Test-Path {$true}
    function Get-Content {$profile}
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {$calls.connect++}
    function Disconnect-AzAccount {$calls.disconnect++}
    function Start-Sleep {$calls.sleeps++}
    function Get-AzContext {
        @{Tenant=@{Id=$sub};Subscription=@{Id=$(if ($Scenario -eq 'WrongContext') {$app} else {$sub})};Account=@{Type='User'};Environment=@{Name='AzureCloud'}}
    }
    function Get-AzResourceGroup {
        if ($Scenario -eq 'ResumeMissingGroup') { return }
        if ($action -ne 'CreatePlan' -or $Scenario -eq 'CreateExistingGroup') {
            @{ResourceGroupName=$groupName;Location=$(if ($Scenario -in @('ResumeWrongLocation','WrongGroupLocation','RemoveWrongGroupLocation')) {'westus'} else {$expectedLocation});Tags=@{purpose=$(if ($Scenario -in @('ForeignGroup','ResumeForeignGroup')) {'unrelated'} else {$purpose})}}
        }
    }
    function New-AzResourceGroup {
        param($Name,$Location,$Tag)
        if ($Name -ne $groupName -or $Location -cne $expectedLocation -or $Tag.purpose -ne $purpose) {throw 'Unexpected RG target or location'}
        $calls.group++
    }
    function Get-AzResourceProvider {
        param([switch]$ListAvailable)
        if (-not $ListAvailable) {throw 'Expected ListAvailable'}
        @{ProviderNamespace='Microsoft.Storage';RegistrationState='Registered'}
        if ($Scenario -ne 'CreateProviderMissing') {
            @{ProviderNamespace='Microsoft.Web';RegistrationState=$(if ($Scenario -eq 'CreateUnregistered') {'NotRegistered'} elseif ($Scenario -eq 'CreateRegistering') {'Registering'} else {'Registered'})}
        }
    }
    function Get-AzResource {
        if ($state.app) {@{ResourceId=$appId}}
        if ($state.plan) {@{ResourceId=$planId}}
        if ($Scenario -in @('RemoveOtherResource','ResumeOtherResource')) {@{ResourceId="$groupId/providers/Microsoft.Storage/storageAccounts/other"}}
    }
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        $id=$Path.Split('?')[0]
        if ($id -notin @($appId,$planId)) {throw 'Unexpected fixture target'}
        if ($Method -eq 'PUT') {
            $calls.put.Add($id)
            $calls.payload=$Payload | ConvertFrom-Json -AsHashtable
            if ($Scenario -in @('CreatePutFailure','AddPutFailure')) {return @{StatusCode=403}}
            if ($Scenario -in @('CreateQuotaFailure','ResumeQuotaFailure')) {
                return @{StatusCode=401;Content=(@{Code='Unauthorized';Message="Operation cannot be completed without additional quota. Current Limit ($testSku VMs): 0 Current Usage: 0 Amount required for this deployment ($testSku VMs): 1 (Minimum) New Limit that you should request to enable this deployment: 1. DO_NOT_OUTPUT_MESSAGE";Details=@(@{ErrorEntity=@{ExtendedCode='70007';Parameters=@('DO_NOT_OUTPUT_PARAMETERS')}})} | ConvertTo-Json -Depth 6)}
            }
            if ($id -eq $planId) {$state.plan=$true; $calls.pending=1} else {$state.app=$true}
            return @{StatusCode=202}
        }
        if ($Method -eq 'DELETE') {
            $calls.delete.Add($id)
            if ($Scenario -eq 'RemoveFailure') {return @{StatusCode=409}}
            if ($id -eq $appId) {
                if ($Path -notlike '*&deleteEmptyServerFarm=false') {throw 'App deletion must not implicitly delete a plan'}
                if ($Scenario -ne 'RemoveStale') {$state.app=$false}
            } else {$state.plan=$false}
            return @{StatusCode=204}
        }
        if ($Method -ne 'GET') {throw 'Unexpected fixture operation'}
        if ($Scenario -eq 'Read403') {return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR_BODY'}}
        if (($id -eq $planId -and -not $state.plan) -or ($id -eq $appId -and -not $state.app)) {return @{StatusCode=404}}
        if ($id -eq $planId) {
            $body=@{
                id=$planId;type='Microsoft.Web/serverfarms';location=$(if ($Scenario -in @('WrongResourceLocation','RemoveWrongResourceLocation')) {'westus'} else {$expectedLocation});kind='linux'
                tags=@{purpose=$(if ($Scenario -eq 'ForeignPlan') {'unrelated'} else {$purpose})}
                sku=@{name=$(if ($Scenario -eq 'WrongSku') {'P1v3'} else {$testSku});capacity=1}
                properties=@{reserved=$true;provisioningState='Succeeded';status='Ready';numberOfSites=$(if ($Scenario -eq 'RemoveSharedPlan') {2} elseif ($state.app) {1} else {0})}
            }
            if ($calls.pending -gt 0) {$body.properties.provisioningState='InProgress'; $calls.pending--}
        } else {
            $body=@{
                id=$appId;name="app-azureops-test-222222222222$regionSuffix";type='Microsoft.Web/sites';location=$expectedLocation;kind='app,linux'
                tags=@{purpose=$purpose}
                properties=@{state='Running';serverFarmId=$(if ($Scenario -eq 'WrongAppPlan') {'other-plan'} else {$planId});httpsOnly=$true;publicNetworkAccess='Disabled';clientAffinityEnabled=$false;accessEndpoint='DO_NOT_OUTPUT_ENDPOINT'}
            }
        }
        @{StatusCode=200;Content=($body | ConvertTo-Json -Depth 8)}
    }
    $failed=$false
    $output=@()
    $locationArgument=@{Location=$TestLocation;ResourceGroupName=$groupName;PlanName=('asp-azureops-sandbox-test'+$regionSuffix);AppName=('app-azureops-test-222222222222'+$regionSuffix)}
    try {$output=& (Join-Path $PSScriptRoot 'Set-SandboxAppServiceFixture.ps1') -Action $action -Sku $testSku @locationArgument -WarningAction SilentlyContinue -WarningVariable fixtureWarnings 6>$null}
    catch {$failed=$true; $failure=$_.Exception.Message}
    $success=$Scenario -in @('Plan','CreateSuccess','ResumeSuccess','AddSuccess','RemoveSuccess','RemovePlanOnly')
    Verify-Fixture ($failed -ne $success) "Expected fixture outcome: $Scenario $(if ($failed -and $success) {$failure})"
    Verify-Fixture ($calls.disconnect -eq $calls.connect) "Fixture session disconnected: $Scenario"
    Verify-Fixture (($output -join '') -notmatch 'DO_NOT_OUTPUT_') "No raw response fields: $Scenario"
    if ($success) {
        $displayedPlan=@($output)[0] | ConvertFrom-Json -AsHashtable
        Verify-Fixture ($displayedPlan.Location -ceq $expectedLocation -and $displayedPlan.ResourceGroupId -eq $groupId -and
            $displayedPlan.PlanResourceId -eq $planId -and $displayedPlan.AppResourceId -eq $appId) "Displayed targets match selected region: $Scenario / $TestLocation"
    }
    if ($calls.put.Count) {
        Verify-Fixture ($calls.payload.location -ceq $expectedLocation) "Writes use only the selected location: $Scenario / $TestLocation"
    }
    if ($Scenario -eq 'Plan') {
        Verify-Fixture ($calls.connect -eq 0 -and $calls.group -eq 0 -and $calls.put.Count -eq 0 -and $calls.delete.Count -eq 0) 'Plan is local only'
    } elseif ($Scenario -eq 'CreateSuccess') {
        Verify-Fixture ($calls.group -eq 1 -and $calls.put.Count -eq 1 -and $calls.put[0] -eq $planId -and $calls.sleeps -eq 1) 'Create plan once; asynchronous readiness uses GET only'
        Verify-Fixture ($calls.payload.sku.name -eq 'P0v4' -and $calls.payload.sku.tier -eq 'PremiumV4' -and $calls.payload.sku.capacity -eq 1 -and $calls.payload.properties.reserved) 'Linux P0v4 single instance matching the production tier'
    } elseif ($Scenario -eq 'ResumeSuccess') {
        Verify-Fixture ($calls.group -eq 0 -and $calls.put.Count -eq 1 -and $calls.put[0] -eq $planId -and $calls.delete.Count -eq 0) 'Explicit resume creates only the absent plan in the verified existing RG'
    } elseif ($Scenario -in @('CreateQuotaFailure','ResumeQuotaFailure')) {
        Verify-Fixture ($calls.put.Count -eq 1 -and $calls.delete.Count -eq 0 -and $calls.payload.sku.name -eq $testSku) 'Quota failure never retries, changes SKU, or rolls back'
        Verify-Fixture ($failure -match '"CategoryHint":"Quota"' -and $failure -match '"CurrentLimit":0' -and $failure -match '"Required":1' -and $failure -match '70007' -and $failure -notmatch 'DO_NOT_OUTPUT_') 'HTTP 401 reports safe quota details without printing the message or parameters'
    } elseif ($Scenario -eq 'AddSuccess') {
        Verify-Fixture ($calls.group -eq 0 -and $calls.put.Count -eq 1 -and $calls.put[0] -eq $appId -and $calls.delete.Count -eq 0) 'AddApp never creates, updates or deletes the existing plan/RG'
        Verify-Fixture ($calls.payload.properties.serverFarmId -eq $planId -and $calls.payload.properties.publicNetworkAccess -eq 'Disabled' -and
            $calls.payload.properties.httpsOnly -and -not $calls.payload.ContainsKey('identity') -and -not $calls.payload.properties.ContainsKey('appSettings')) 'App references exact existing plan with no identity, connections or public access'
    } elseif ($Scenario -in @('RemoveSuccess','RemovePlanOnly')) {
        $expected=if ($Scenario -eq 'RemoveSuccess') {"$appId|$planId"} else {$planId}
        Verify-Fixture (($calls.delete -join '|') -eq $expected -and $calls.put.Count -eq 0 -and -not $state.plan -and -not $state.app) "Only the exact test resources are removed in order: $Scenario"
    } elseif ($Scenario -in @('CreatePutFailure','AddPutFailure','WrongAppPlan')) {
        Verify-Fixture ($calls.put.Count -eq 1 -and $calls.delete.Count -eq 0) "No write retry or automatic rollback: $Scenario"
    } elseif ($Scenario -in @('RemoveStale','RemoveFailure')) {
        Verify-Fixture ($calls.delete.Count -eq 1 -and $calls.delete[0] -eq $appId -and $state.plan) "Unconfirmed app deletion never deletes plan or retries: $Scenario"
    } else {
        Verify-Fixture ($calls.group -eq 0 -and $calls.put.Count -eq 0 -and $calls.delete.Count -eq 0) "Preflight failure makes no change: $Scenario"
        Verify-Fixture (($fixtureWarnings -join '') -like '*This invocation did not start*' -and
            ($fixtureWarnings -join '') -notlike '*incurs charges*') "Preflight warning does not imply this invocation created billable resources: $Scenario"
        if ($Scenario -in @('CreateUnregistered','CreateRegistering','CreateProviderMissing')) {
            $expectedState = switch ($Scenario) {
                'CreateUnregistered' {'NotRegistered'}
                'CreateRegistering' {'Registering'}
                'CreateProviderMissing' {'Unknown'}
            }
            Verify-Fixture ($failure -like "*state: $expectedState*" -and $failure -like '*docs/sandbox-test.md*') "Provider state and registration instructions are reported: $Scenario"
        }
    }
}
foreach ($scenario in @('Plan','CreateSuccess','CreateExistingGroup','CreateUnregistered','CreateRegistering','CreateProviderMissing','CreatePutFailure',
    'CreateQuotaFailure','ResumeSuccess','ResumeForeignGroup','ResumeWrongLocation','ResumeMissingGroup','ResumeExistingPlan','ResumeOtherResource','ResumeQuotaFailure',
    'AddSuccess','ExistingApp','MissingPlan','WrongContext','ForeignGroup','ForeignPlan','WrongSku','Read403','AddPutFailure','WrongAppPlan',
    'RemoveSuccess','RemovePlanOnly','RemoveOtherResource','RemoveSharedPlan','RemoveStale','RemoveFailure')) {
    Test-FixtureScenario $scenario
}
foreach ($scenario in @('Plan','CreateSuccess','ResumeSuccess','ResumeWrongLocation','AddSuccess','WrongGroupLocation','WrongResourceLocation',
    'RemoveSuccess','RemovePlanOnly','RemoveWrongGroupLocation','RemoveWrongResourceLocation','RemoveSharedPlan')) {
    Test-FixtureScenario $scenario -TestLocation 'SouthEastAsia' -ExplicitLocation
}
foreach ($region in @('japaneast','westus2','centralus')) {
    Test-FixtureScenario 'Plan' -TestLocation $region -ExplicitLocation
}
Write-Host "PASS: $checks App Service fixture checks (offline)."
