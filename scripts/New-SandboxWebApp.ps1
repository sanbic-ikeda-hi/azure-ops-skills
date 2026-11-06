#requires -Version 7.2
# USER-RUN ONLY. Add one empty test Web App to an explicitly selected existing plan.
# No plan/RG creation, plan updates, role changes, deployment, or cleanup.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Create')][string]$Action='Plan',
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][string]$PlanResourceId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+$')][string]$ExpectedLocation,
    [Parameter(Mandatory)][ValidateSet('Windows','Linux')][string]$ExpectedOperatingSystem,
    [Parameter(Mandatory)][ValidateSet('B1','P0v4')][string]$ExpectedSku
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection=Read-OpsConnection
$config=Select-OpsSubscription $connection $connection.sandboxSubscriptionId
Assert-OpsResourceScope $ResourceId $config.subscriptionId
Assert-OpsResourceScope $PlanResourceId $config.subscriptionId
if ($ResourceId -notmatch '^(?<group>/subscriptions/[^/]+/resourceGroups/[^/]+)/providers/Microsoft\.Web/sites/(?<name>[a-z0-9][a-z0-9-]{0,58}[a-z0-9])$') {
    throw 'ResourceId must identify one Sandbox Web App with a valid 2-60 character name.'
}
$groupId=$Matches.group
if ($PlanResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/serverfarms/[^/]+$') {
    throw 'PlanResourceId must identify one Sandbox App Service plan.'
}
$location=$ExpectedLocation.ToLowerInvariant()
$linux=$ExpectedOperatingSystem -eq 'Linux'
[pscustomobject][ordered]@{
    Action=$Action;TenantId=$config.tenantId;SubscriptionId=$config.subscriptionId
    ResourceId=$ResourceId;PlanResourceId=$PlanResourceId;Location=$location
    OperatingSystem=$ExpectedOperatingSystem;Sku=$ExpectedSku;PlanInstances=1
    HttpsOnly=$true;PublicNetworkAccess='Disabled';ClientAffinityEnabled=$false
    GrantsPermissions=$false;ChangesPlan=$false;DeploysCode=$false
    Impact='Adds one empty app sharing the existing plan CPU and memory. Plan billing continues.'
} | ConvertTo-Json
if ($Action -eq 'Plan') {return}
Import-Module Az.Accounts -ErrorAction Stop

function Invoke-AppRequest {
    param([string]$Id,[string]$Method='GET',[hashtable]$Body,[string]$Version='2024-11-01')
    Assert-OpsContext (Get-AzContext) $config 'User'
    $parameters=@{Path="${Id}?api-version=$Version";Method=$Method;ErrorAction='Stop'}
    if ($Body) {$parameters.Payload=$Body | ConvertTo-Json -Depth 6}
    Invoke-AzRestMethod @parameters
}
function Read-AppResource {
    param([string]$Id,[switch]$AllowAbsent,[string]$Version='2024-11-01')
    $response=Invoke-AppRequest -Id $Id -Version $Version
    if ($AllowAbsent -and $response.StatusCode -eq 404) {return $null}
    if ($response.StatusCode -ne 200) {throw "Read failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)"}
    $item=$response.Content | ConvertFrom-Json -AsHashtable
    if ($item.id -ine $Id) {throw 'Response resource ID mismatch.'}
    $item
}
function Assert-ExistingPlan {
    param($Item)
    if ($Item.type -ine 'Microsoft.Web/serverfarms' -or ($Item.location -replace '\s','') -ine $location -or
        $Item.properties.reserved -isnot [bool] -or $Item.properties.reserved -ne $linux -or
        $Item.sku.name -ine $ExpectedSku -or $Item.sku.capacity -ne 1 -or
        $Item.properties.provisioningState -ne 'Succeeded' -or $Item.properties.status -ne 'Ready') {
        throw 'Existing plan OS, location, SKU, single instance or readiness differs from the reviewed target.'
    }
}
$connected=$false
$stage='Preflight'
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $config.tenantId -Subscription $config.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected=$true
    Assert-OpsContext (Get-AzContext) $config 'User'
    # A resource group's metadata location can differ from its plan/app locations.
    $null=Read-AppResource -Id $groupId -Version '2021-04-01'
    $before=Read-AppResource $PlanResourceId
    Assert-ExistingPlan $before
    if (Read-AppResource -Id $ResourceId -AllowAbsent) {throw 'The app already exists. No overwrite.'}
    $stage='CreatingApp'
    $response=Invoke-AppRequest -Id $ResourceId -Method PUT -Body @{
        location=$location;kind=$(if($linux){'app,linux'}else{'app'})
        tags=@{purpose='azure-ops-skills-existing-plan-test'}
        properties=@{
            serverFarmId=$PlanResourceId;reserved=$linux;httpsOnly=$true
            publicNetworkAccess='Disabled';clientAffinityEnabled=$false
            siteConfig=@{alwaysOn=$false;ftpsState='Disabled';minTlsVersion='1.2'}
        }
    }
    if ($response.StatusCode -notin @(200,201,202)) {throw "Creation failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)"}
    $stage='VerifyingApp'
    $ready=$false
    for ($attempt=0;$attempt -lt 36;$attempt++) {
        $site=Read-AppResource -Id $ResourceId -AllowAbsent
        if ($site -and $site.properties.state -in @('Running','Stopped')) {$ready=$true;break}
        Write-Host "Waiting for Web App readiness ($($attempt+1)/36)."
        Start-Sleep -Seconds 5
    }
    if (-not $ready) {throw 'Readiness not confirmed. Inspect the exact app before any further action; do not repeat creation.'}
    if ((Get-OpsServiceKind $site.type $site.kind) -ne 'AppService' -or
        ($site.location -replace '\s','') -ine $location -or $site.properties.serverFarmId -ine $PlanResourceId -or
        $site.properties.reserved -isnot [bool] -or $site.properties.reserved -ne $linux -or
        $site.properties.httpsOnly -ne $true -or $site.properties.publicNetworkAccess -ne 'Disabled' -or
        $site.properties.clientAffinityEnabled -ne $false) {throw 'Created app does not match the reviewed plan, OS, location or settings.'}
    $after=Read-AppResource $PlanResourceId
    Assert-ExistingPlan $after
    if ($after.sku.tier -ine $before.sku.tier -or $after.properties.perSiteScaling -ne $before.properties.perSiteScaling -or
        $after.properties.zoneRedundant -ne $before.properties.zoneRedundant) {throw 'Plan configuration changed during creation. Inspect before proceeding.'}
    ConvertTo-OpsInventoryRow $site | ConvertTo-Json -Depth 5
    [pscustomobject]@{PlanResourceId=$PlanResourceId;PlanSku=$after.sku.name;PlanInstances=$after.sku.capacity;PlanConfigurationVerified=$true;PlanWritePerformed=$false} | ConvertTo-Json
    Write-Host 'App created on the existing plan. No role was granted. Continue with the separate access script.'
} catch {
    Write-Warning "Stopped at $stage. No automatic write retry, rollback, plan update or deletion. Inspect partial creation before resuming."
    throw
} finally {
    if ($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
