#requires -Version 7.2
# Offline tests: all authentication, ARM calls and waits are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Check-AppCreation {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) {throw "FAIL: $Message"}
    $script:checks++
}
function Test-AppCreationScenario {
    param([string]$Scenario)
    $sub='11111111-1111-1111-1111-111111111111'
    $principal='22222222-2222-2222-2222-222222222222'
    $group="/subscriptions/$sub/resourceGroups/rg-test"
    $siteId="$group/providers/Microsoft.Web/sites/test-added-app"
    $planId="$group/providers/Microsoft.Web/serverfarms/manual-plan"
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$principal;servicePrincipalObjectId=$principal;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $linux=$Scenario -eq 'Linux'
    $calls=@{connect=0;disconnect=0;put=0;get=0;sleep=0;context=0;payload=$null}
    $state=@{exists=($Scenario -eq 'ExistingApp');pending=0}
    function Test-Path {$true}
    function Get-Content {$profile}
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {$calls.connect++}
    function Disconnect-AzAccount {$calls.disconnect++}
    function Start-Sleep {$calls.sleep++}
    function Get-AzContext {
        $calls.context++
        @{Tenant=@{Id=$sub};Subscription=@{Id=$(if ($Scenario -eq 'WrongContext' -or ($Scenario -eq 'ContextChanged' -and $calls.context -ge 5)) {$principal} else {$sub})};Account=@{Type='User'};Environment=@{Name='AzureCloud'}}
    }
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        $id=$Path.Split('?')[0]
        if ($id -notin @($group,$siteId,$planId)) {throw 'Unexpected target'}
        if ($Method -eq 'PUT') {
            if ($id -ne $siteId) {throw 'Only the new Web App may be written'}
            $calls.put++;$calls.payload=$Payload | ConvertFrom-Json -AsHashtable
            if ($Scenario -eq 'WriteFailure') {return @{StatusCode=403;Content='DO_NOT_OUTPUT_RAW_ERROR'}}
            $state.exists=$true
            if ($Scenario -eq 'Pending') {$state.pending=1}
            return @{StatusCode=202}
        }
        if ($Method -ne 'GET') {throw 'Unexpected mutation'}
        $calls.get++
        if ($Scenario -eq 'ReadDenied') {return @{StatusCode=403;Content='DO_NOT_OUTPUT_RAW_ERROR'}}
        if ($id -eq $group) {
            if ($Scenario -eq 'MissingGroup') {return @{StatusCode=404}}
            # Metadata location deliberately differs from the West US 3 plan.
            $item=@{id=$group;location='southeastasia'}
        } elseif ($id -eq $planId) {
            $item=@{
                id=$(if($Scenario -eq 'WrongResponseId') {'other-id'}else{$planId})
                type='Microsoft.Web/serverfarms';location=$(if($Scenario -eq 'WrongLocation') {'japaneast'}else{'West US 3'})
                sku=@{name=$(if($Scenario -eq 'WrongSku'){'B1'}else{'P0v4'});tier='PremiumV4';capacity=$(if($Scenario -eq 'ScaledPlan') {2}else{1})}
                properties=@{reserved=$(if($Scenario -eq 'WrongOS') {-not $linux}else{$linux});provisioningState='Succeeded';status='Ready';perSiteScaling=$false;zoneRedundant=($Scenario -eq 'PlanChanged' -and $calls.put -gt 0)}
            }
        } else {
            if (-not $state.exists -or $Scenario -eq 'NeverReady') {return @{StatusCode=404}}
            if ($state.pending -gt 0) {$state.pending--;return @{StatusCode=404}}
            $item=@{
                id=$siteId;name='test-added-app';type='Microsoft.Web/sites';kind=$(if($linux){'app,linux'}else{'app'});location='West US 3'
                properties=@{state='Running';serverFarmId=$(if($Scenario -eq 'WrongAppPlan') {'other-id'}else{$planId});reserved=$linux;httpsOnly=$true;publicNetworkAccess=$(if($Scenario -eq 'WrongAppSecurity') {'Enabled'}else{'Disabled'});clientAffinityEnabled=$false;hostNames=@('DO_NOT_OUTPUT_HOST')}
            }
        }
        @{StatusCode=200;Content=($item | ConvertTo-Json -Depth 6)}
    }
    $args=@{Action=$(if($Scenario -eq 'Plan'){'Plan'}else{'Create'});ResourceId=$siteId;PlanResourceId=$planId;ExpectedLocation='westus3';ExpectedOperatingSystem=$(if($linux){'Linux'}else{'Windows'});ExpectedSku='P0v4';WarningAction='SilentlyContinue'}
    if($Scenario -eq 'OtherSubscription') {$args.ResourceId=$siteId.Replace($sub,$principal)}
    if($Scenario -eq 'Slot') {$args.ResourceId="$siteId/slots/staging"}
    if($Scenario -eq 'PlanAsSite') {$args.ResourceId=$planId}
    if($Scenario -eq 'OtherPlanSubscription') {$args.PlanResourceId=$planId.Replace($sub,$principal)}
    $failed=$false;$output=@();$failure=''
    try {$output=& (Join-Path $PSScriptRoot 'New-SandboxWebApp.ps1') @args 6>$null} catch {$failed=$true;$failure=$_.Exception.Message}
    $success=$Scenario -in @('Plan','Windows','Linux','Pending')
    Check-AppCreation ($failed -ne $success) "Expected outcome: $Scenario $failure"
    Check-AppCreation ($calls.disconnect -eq $calls.connect) "Disconnect after sign-in: $Scenario"
    Check-AppCreation (($output -join '' -notmatch 'DO_NOT_OUTPUT_') -and $failure -notmatch 'DO_NOT_OUTPUT_') "No raw response data: $Scenario"
    if($Scenario -in @('Plan','OtherSubscription','Slot','PlanAsSite','OtherPlanSubscription')) {
        Check-AppCreation ($calls.connect -eq 0 -and $calls.get -eq 0 -and $calls.put -eq 0) "No sign-in or ARM calls for local preview/invalid scope: $Scenario"
    } elseif($success) {
        Check-AppCreation ($calls.put -eq 1 -and $calls.payload.location -eq 'westus3' -and $calls.payload.properties.serverFarmId -eq $planId -and $calls.payload.properties.reserved -eq $linux) "Add once to the exact existing plan in its location: $Scenario"
        Check-AppCreation ($calls.payload.properties.httpsOnly -and $calls.payload.properties.publicNetworkAccess -eq 'Disabled' -and -not $calls.payload.properties.clientAffinityEnabled -and
            -not $calls.payload.ContainsKey('identity') -and -not $calls.payload.properties.ContainsKey('appSettings')) "No public access, identity or app settings: $Scenario"
        Check-AppCreation (($output -join '') -match '"PlanConfigurationVerified": true') "Plan configuration read back: $Scenario"
        if($Scenario -eq 'Pending') {Check-AppCreation ($calls.sleep -eq 1) 'Async readiness uses GET, not repeated PUT'}
    } elseif($Scenario -in @('WriteFailure','WrongAppPlan','WrongAppSecurity','PlanChanged','NeverReady')) {
        Check-AppCreation ($calls.put -eq 1) "No retry or rollback after partial creation: $Scenario"
    } else {Check-AppCreation ($calls.put -eq 0) "Preflight mismatch makes no change: $Scenario"}
}
foreach($scenario in @('Plan','Windows','Linux','Pending','ExistingApp','WrongLocation','WrongSku','ScaledPlan','WrongOS','WrongContext','ContextChanged',
    'ReadDenied','MissingGroup','WrongResponseId','WriteFailure','WrongAppPlan','WrongAppSecurity','PlanChanged','NeverReady','OtherSubscription','Slot','PlanAsSite','OtherPlanSubscription')) {
    Test-AppCreationScenario $scenario
}
Write-Host "PASS: $checks existing-plan Web App creation checks (offline)."
