#requires -Version 7.2
# Offline tests; all user sign-in and REST calls are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Check-Quota([bool]$Condition,[string]$Message) {
    if (-not $Condition) {throw "FAIL: $Message"}
    $script:checks++
}
foreach ($scenario in @('Plan','Success','Empty','Failure','WrongContext','CrossRegion','Cycle','Malformed','UnlistedSubscription','InvalidLocation')) {
    & {
        $sub='11111111-1111-1111-1111-111111111111';$other='22222222-2222-2222-2222-222222222222'
        $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$other;servicePrincipalObjectId=$other;certificateThumbprint=('A'*40)} | ConvertTo-Json
        $calls=@{connect=0;disconnect=0;get=0}
        function Test-Path {$true}
        function Get-Content {$profile}
        function Import-Module {}
        function Disable-AzContextAutosave {}
        function Connect-AzAccount {$calls.connect++}
        function Disconnect-AzAccount {$calls.disconnect++}
        function Get-AzContext {@{Tenant=@{Id=$sub};Subscription=@{Id=$(if ($scenario -eq 'WrongContext') {$other} else {$sub})};Account=@{Type='User'};Environment=@{Name='AzureCloud'}}}
        function Invoke-AzRestMethod {
            param($Path,$Method)
            if ($Method -ne 'GET' -or $Path -notmatch "/subscriptions/$sub/providers/Microsoft.Web/locations/(eastus|westus2)/usages\?") {throw 'Unexpected request'}
            $calls.get++
            if ($scenario -eq 'Failure' -and $calls.get -eq 2) {return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
            if ($scenario -eq 'Malformed') {return @{StatusCode=200;Content='{"value":null}'}}
            $page=@{value=@()}
            if ($scenario -ne 'Empty') {$page.value=@(@{name=@{value='P0v4 VMs'};unit='Count';currentValue=0;limit=2;extra='DO_NOT_OUTPUT_FIELD'})}
            if ($scenario -eq 'CrossRegion') {$page.nextLink="https://management.azure.com/subscriptions/$sub/providers/Microsoft.Web/locations/westeurope/usages?api-version=2025-05-01"}
            elseif ($scenario -eq 'Cycle') {$page.nextLink="https://management.azure.com$Path"}
            elseif ($calls.get -eq 1) {$page.nextLink="https://management.azure.com${Path}&skiptoken=next"}
            @{StatusCode=200;Content=($page | ConvertTo-Json -Depth 5)}
        }
        $output=[Collections.Generic.List[object]]::new();$failed=$false
        $parameters=@{SubscriptionId=$(if ($scenario -eq 'UnlistedSubscription') {$other} else {$sub});Location=$(if ($scenario -eq 'InvalidLocation') {@('../evil')} else {@('eastus','westus2')});Plan=($scenario -eq 'Plan')}
        try {& (Join-Path $PSScriptRoot 'Get-AppServiceQuota.ps1') @parameters | ForEach-Object {$output.Add($_)}} catch {$failed=$true}
        $success=$scenario -in @('Plan','Success','Empty')
        Check-Quota ($failed -ne $success) "Expected outcome: $scenario"
        Check-Quota ($calls.connect -eq $calls.disconnect) "Disconnect: $scenario"
        Check-Quota (($output -join '') -notmatch 'DO_NOT_OUTPUT_') "No arbitrary fields: $scenario"
        if ($scenario -in @('Plan','UnlistedSubscription','InvalidLocation')) {Check-Quota ($calls.connect -eq 0 -and $calls.get -eq 0) "No auth for plan or invalid input: $scenario"}
        elseif ($success) {
            $result=($output -join '') | ConvertFrom-Json
            Check-Quota ($result.Complete -and $result.Regions.Count -eq 2 -and $calls.get -eq 3) 'Every region and page is read'
            if ($scenario -eq 'Success') {Check-Quota ($result.Regions[0].Quotas[0].Remaining -eq 2) 'Headroom is calculated without losing zero usage'}
            else {Check-Quota (-not $result.Regions[0].HasQuotaData -and $result.Regions[0].Quotas.Count -eq 0) 'Empty response explicitly has no quota data'}
        } else {Check-Quota ($output.Count -eq 0) "No partial result on failure: $scenario"}
    }
}
Write-Host "PASS: $checks App Service quota checks (offline)."
