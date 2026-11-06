#requires -Version 7.2
# Offline integration checks of the real inventory script with in-memory Az mocks.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$checks = 0
function Verify {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Test-InventoryScenario {
    param([string]$Scenario)
    $sub = '11111111-1111-1111-1111-111111111111'
    $app = '22222222-2222-2222-2222-222222222222'
    $profile = @{
        tenantId=$sub; subscriptionIds=@($sub); sandboxSubscriptionId=$sub
        applicationId=$app; servicePrincipalObjectId=$app; certificateThumbprint=('A' * 40)
    } | ConvertTo-Json
    $collection = "/subscriptions/$sub/providers/Microsoft.Web/sites"
    $logicCollection = "/subscriptions/$sub/providers/Microsoft.Logic/workflows"
    $firstPath = "${collection}?api-version=2024-11-01"
    $nextPath = "${collection}?api-version=2024-11-01&skiptoken=next"
    $calls = @{connect=0; disconnect=0; context=0; paths=[Collections.Generic.List[string]]::new()}
    function Test-Path { $true }
    function Get-Content { $profile }
    function Get-Item {
        @{
            HasPrivateKey=($Scenario -ne 'NoPrivateKey')
            NotBefore=(Get-Date).AddDays($(if ($Scenario -eq 'FutureCertificate') {1} else {-1}))
            NotAfter=(Get-Date).AddDays($(if ($Scenario -eq 'ExpiredCertificate') {-1} else {1}))
        }
    }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {
        param([switch]$ServicePrincipal, $Tenant, $Subscription, $ApplicationId, $CertificateThumbprint, $Scope, [switch]$SkipContextPopulation)
        if (-not $ServicePrincipal -or $Tenant -ne $sub -or $Subscription -ne $sub -or
            $ApplicationId -ne $app -or $Scope -ne 'Process' -or -not $SkipContextPopulation) { throw 'Unexpected authentication request' }
        $calls.connect++
    }
    function Disconnect-AzAccount { $calls.disconnect++ }
    function Get-AzContext {
        $calls.context++
        @{
            Tenant=@{Id=$(if ($Scenario -eq 'WrongTenant') {$app} else {$sub})}
            Subscription=@{Id=$(if ($Scenario -eq 'ContextChange' -and $calls.context -ge 3) {$app} else {$sub})}
            Account=@{Type=$(if ($Scenario -eq 'UserAccount') {'User'} else {'ServicePrincipal'}); Id=$(if ($Scenario -eq 'WrongApp') {$sub} else {$app})}
            Environment=@{Name=$(if ($Scenario -eq 'CloudChange') {'AzureUSGovernment'} else {'AzureCloud'})}
        }
    }
    function New-TestResource {
        param([string]$Name, [string]$Kind, [string]$Type='Microsoft.Web/sites')
        @{
            id="/subscriptions/$sub/resourceGroups/rg-test/providers/$Type/$Name"
            name=$Name; type=$Type; kind=$Kind; location='japaneast'
            tags=@{hidden='DO_NOT_OUTPUT_TAG'}
            properties=@{state='Running'; appSettings=@{sample='DO_NOT_OUTPUT_SETTING'}; accessEndpoint='DO_NOT_OUTPUT_ENDPOINT'}
        }
    }
    function Invoke-AzRestMethod {
        param($Path, $Method)
        if ($Method -ne 'GET') { throw 'Inventory must only read' }
        $calls.paths.Add($Path)
        $page = @{value=@()}
        if ($Path -eq $firstPath) {
            if ($Scenario -eq 'Empty') { return @{StatusCode=200; Content='{"value":[]}'} }
            $page.value = @((New-TestResource 'web-first' 'app,linux'), (New-TestResource 'function-first' 'functionapp,linux'),
                (New-TestResource 'standard-first' 'functionapp,workflowapp'), (New-TestResource 'unknown' 'unrecognized'))
            $page.nextLink = "https://management.azure.com$nextPath"
            switch ($Scenario) {
                'NullCollection' { $page.value=$null }
                'ObjectCollection' { $page.value=$page.value[0] }
                'MissingCollection' { $page.Remove('value') }
                'ExternalLink' { $page.nextLink="https://example.invalid$nextPath" }
                'Cycle' { $page.nextLink="https://management.azure.com$firstPath" }
                'CrossSubscription' { $page.value[0].id=$page.value[0].id.Replace($sub,$app) }
                'MalformedEntry' { $page.value += $null }
            }
        } elseif ($Path -eq $nextPath) {
            if ($Scenario -eq 'SecondPage403') { return @{StatusCode=403; Content='DO_NOT_OUTPUT_ERROR_BODY'} }
            $page.value = @((New-TestResource 'web-second' 'app'), (New-TestResource 'function-second' 'functionapp'),
                (New-TestResource 'standard-second' 'workflowapp'))
        } elseif ($Path -eq "${logicCollection}?api-version=2019-05-01") {
            $page.value = @((New-TestResource 'consumption' '' 'Microsoft.Logic/workflows'))
        } else { throw 'Unexpected endpoint' }
        @{StatusCode=200; Content=($page | ConvertTo-Json -Depth 8)}
    }
    $service = if ($Scenario -in @('Functions','LogicApps')) {$Scenario} else {'AppService'}
    $parameters = @{Service=$service; SubscriptionId=$sub}
    if ($Scenario -eq 'FilteredSecondPage') { $parameters.Keyword='SECOND'; $parameters.ResourceGroupName='RG-TEST' }
    if ($Scenario -eq 'NoMatch') { $parameters.Keyword='missing' }
    $output = [Collections.Generic.List[object]]::new()
    $failed = $false
    try { & (Join-Path $PSScriptRoot 'Get-ServiceInventory.ps1') @parameters | ForEach-Object { $output.Add($_) } }
    catch { $failed=$true }
    $success = $Scenario -in @('AppService','Functions','LogicApps','FilteredSecondPage','NoMatch','Empty')
    Verify ($failed -ne $success) "Expected success/failure: $Scenario"
    Verify (($output -join '') -notmatch 'DO_NOT_OUTPUT_') "No raw fields or error body: $Scenario"
    Verify ($calls.disconnect -eq $calls.connect) "Every established session is disconnected: $Scenario"
    if ($success) {
        $result = ($output -join '') | ConvertFrom-Json
        $expectedTotal = if ($Scenario -eq 'Empty') {0} elseif ($service -eq 'LogicApps') {3} else {2}
        $expectedCount = if ($Scenario -in @('Empty','NoMatch')) {0} elseif ($Scenario -eq 'FilteredSecondPage') {1} else {$expectedTotal}
        Verify ($result.Complete -and $result.TotalCount -eq $expectedTotal -and $result.Count -eq $expectedCount) "Complete service-specific counts: $Scenario"
        Verify ($result.Resources -is [array] -and $result.Resources.Count -eq $expectedCount) "Stable array output including zero/one result: $Scenario"
        Verify ($calls.paths.Count -eq $(if ($Scenario -eq 'Empty') {1} elseif ($service -eq 'LogicApps') {3} else {2})) "All required pages and collections read: $Scenario"
        if ($Scenario -eq 'FilteredSecondPage') { Verify ($result.Resources[0].Name -eq 'web-second') 'Filter runs after all pages and preserves identity' }
    } else {
        Verify ($output.Count -eq 0) "Failure never emits partial inventory as complete: $Scenario"
        $expectedCalls = if ($Scenario -eq 'SecondPage403') {2} elseif ($Scenario -in @('WrongApp','WrongTenant','UserAccount','CloudChange','ExpiredCertificate','NoPrivateKey','FutureCertificate')) {0} else {1}
        Verify ($calls.paths.Count -eq $expectedCalls) "Stops at unsafe boundary with no retries: $Scenario"
    }
}
foreach ($scenario in @('AppService','Functions','LogicApps','FilteredSecondPage','NoMatch','Empty','SecondPage403',
    'NullCollection','ObjectCollection','MissingCollection','ExternalLink','Cycle','CrossSubscription','MalformedEntry',
    'ContextChange','WrongApp','WrongTenant','UserAccount','CloudChange','ExpiredCertificate','NoPrivateKey','FutureCertificate')) {
    Test-InventoryScenario $scenario
}
Write-Host "PASS: $checks inventory integration checks (offline)."
