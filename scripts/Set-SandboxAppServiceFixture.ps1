#requires -Version 7.2
# USER-RUN ONLY. Separate plan creation, app addition to that existing plan, and cleanup.
# This test fixture is not packaged with skills. Never use it against a production plan.
[CmdletBinding()]
param(
    [ValidateSet('Plan','CreatePlan','ResumePlan','AddApp','Remove')][string]$Action='Plan',
    [ValidateSet('B1','P0v4')][string]$Sku,
    [ValidatePattern('^[a-z0-9]+$')][string]$Location,
    [string]$ResourceGroupName,
    [string]$PlanName,
    [string]$AppName
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection = Read-OpsConnection
$config = Select-OpsSubscription $connection $connection.sandboxSubscriptionId
$settings=Resolve-OpsSandboxSettings -Name AppServiceFixture -Connection $connection -ExplicitOnly:($Action -eq 'Remove') -Values @{sku=$Sku;location=$Location;resourceGroupName=$ResourceGroupName;planName=$PlanName;appName=$AppName}
$Location=$settings.location
$Sku=$settings.sku
$groupName=$settings.resourceGroupName
$planName=$settings.planName
$appName=$settings.appName
$groupId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$groupName"
$planId = "$groupId/providers/Microsoft.Web/serverfarms/$planName"
$appId = "$groupId/providers/Microsoft.Web/sites/$appName"
$purpose = 'azure-ops-skills-appservice-test'
Assert-OpsResourceScope $planId $config.subscriptionId
Assert-OpsResourceScope $appId $config.subscriptionId
[pscustomobject][ordered]@{
    Action=$Action; TenantId=$config.tenantId; SubscriptionId=$config.subscriptionId
    ResourceGroupId=$groupId; PlanResourceId=$planId; AppResourceId=$appId
    Location=$location; OperatingSystem='Linux'; Sku=$Sku; Instances=1
    PublicNetworkAccess='Disabled'; HttpsOnly=$true; GrantsPermissions=$false
    Cleanup='Remove deletes only this test app and test plan; the empty resource group remains.'
} | ConvertTo-Json
if ($Action -eq 'Plan') { return }
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -MinimumVersion 10.0.0 -ErrorAction Stop

function Invoke-FixtureRequest {
    param([string]$Id, [string]$Method='GET', [hashtable]$Body, [string]$Query='')
    Assert-OpsContext (Get-AzContext) $config 'User'
    $parameters = @{Path="${Id}?api-version=2024-11-01$Query"; Method=$Method; ErrorAction='Stop'}
    if ($Body) { $parameters.Payload=$Body | ConvertTo-Json -Depth 10 }
    Invoke-AzRestMethod @parameters
}
function Read-FixtureResource {
    param([string]$Id)
    $response = Invoke-FixtureRequest $Id
    if ($response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -ne 200) { throw "Resource read failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)" }
    $item = $response.Content | ConvertFrom-Json -AsHashtable
    if ($item.id -ine $Id -or $item.tags.purpose -cne $purpose -or
        ($item.location -replace '\s','') -ine $Location) {
        throw 'Resource ID, location or test ownership tag mismatch. No overwrite or deletion is permitted.'
    }
    return $item
}
function Assert-FixturePlan {
    param($Plan)
    if (-not $Plan -or $Plan.type -ine 'Microsoft.Web/serverfarms' -or
        $Plan.sku.name -ine $Sku -or $Plan.sku.capacity -ne 1 -or
        $Plan.properties.reserved -ne $true -or ($Plan.location -replace '\s','') -ine $location) {
        throw "The expected $Location Linux $Sku single-instance test plan was not verified."
    }
}
function Wait-FixtureResource {
    param([string]$Id)
    # Poll GET only. PUT/DELETE are never retried, including on permission/network errors.
    for ($attempt=0; $attempt -lt 36; $attempt++) {
        $item = Read-FixtureResource $Id
        if ($item) {
            if ($Id -eq $planId) {
                if ($item.properties.provisioningState -in @('Failed','Canceled')) { throw 'Plan provisioning failed.' }
                if ($item.properties.provisioningState -eq 'Succeeded' -and $item.properties.status -eq 'Ready') { return $item }
            } elseif ($item.properties.state -in @('Running','Stopped')) { return $item }
        }
        Write-Host "Waiting for resource readiness ($($attempt + 1)/36)."
        Start-Sleep -Seconds 5
    }
    throw 'Readiness was not confirmed within 3 minutes. Do not repeat creation; inspect and clean up the test plan.'
}
function Remove-FixtureResource {
    param([string]$Id, [string]$Query='')
    $response = Invoke-FixtureRequest -Id $Id -Method DELETE -Query $Query
    if ($response.StatusCode -notin @(200,204)) { throw "Delete failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress). No retry." }
    for ($attempt=0; $attempt -lt 12; $attempt++) {
        if (-not (Read-FixtureResource $Id)) { return }
        Start-Sleep -Seconds 5
    }
    throw 'Deletion was not confirmed. The test plan may still incur charges; inspect it without repeating DELETE.'
}
$connected=$false
$stage='Preflight'
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $config.tenantId -Subscription $config.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected=$true
    Assert-OpsContext (Get-AzContext) $config 'User'
    $groups = @(Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $groupName)
    if ($Action -in @('CreatePlan','ResumePlan')) {
        if ($Action -eq 'CreatePlan') {
            if ($groups.Count) { throw 'The test RG already exists. Inspect the failure before explicitly selecting ResumePlan.' }
        } elseif ($groups.Count -ne 1 -or $groups[0].Tags.purpose -cne $purpose -or
            ($groups[0].Location -replace '\s','') -ine $location) {
            throw 'Resume requires the existing test RG with the expected ownership tag and location.'
        }
        $providers = @(Get-AzResourceProvider -ListAvailable -ErrorAction Stop |
            Where-Object ProviderNamespace -EQ 'Microsoft.Web')
        if (-not @($providers | Where-Object RegistrationState -EQ 'Registered').Count) {
            $registrationState = if ($providers.Count) { ($providers.RegistrationState | Sort-Object -Unique) -join ', ' } else { 'Unknown' }
            throw "Microsoft.Web registration is not complete (state: $registrationState). No automatic registration. Follow the Microsoft.Web registration steps in docs/sandbox-test.md."
        }
        if ($Action -eq 'CreatePlan') {
            Assert-OpsContext (Get-AzContext) $config 'User'
            $stage='CreatingResourceGroup'
            New-AzResourceGroup -Name $groupName -Location $location -Tag @{purpose=$purpose} -ErrorAction Stop | Out-Null
        }
        if (Read-FixtureResource $planId) { throw 'The plan already exists. No overwrite.' }
        if ($Action -eq 'ResumePlan') {
            Assert-OpsContext (Get-AzContext) $config 'User'
            if (@(Get-AzResource -ResourceGroupName $groupName -ErrorAction Stop).Count) {
                throw 'Resume requires an empty test RG. No existing resource will be changed.'
            }
        }
        $stage='CreatingPlan'
        $response = Invoke-FixtureRequest -Id $planId -Method PUT -Body @{
            location=$location; kind='linux'; tags=@{purpose=$purpose}
            sku=@{name=$Sku; tier=$(if ($Sku -eq 'B1') {'Basic'} else {'PremiumV4'}); capacity=1}
            properties=@{reserved=$true; perSiteScaling=$false; zoneRedundant=$false}
        }
        if ($response.StatusCode -notin @(200,201,202)) { throw "Plan creation failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)" }
        $plan = Wait-FixtureResource $planId
        Assert-FixturePlan $plan
        [pscustomobject]@{PlanResourceId=$planId; Sku=$plan.sku.name; Instances=$plan.sku.capacity; Ready=$true} | ConvertTo-Json
        Write-Host 'Plan created. Run AddApp to test adding a Web App to this existing plan. Billing continues until the plan is deleted.'
    } else {
        if ($groups.Count -ne 1 -or $groups[0].Tags.purpose -cne $purpose -or
            ($groups[0].Location -replace '\s','') -ine $Location) { throw 'The isolated test RG and its location were not verified.' }
        $plan = Read-FixtureResource $planId
        $app = Read-FixtureResource $appId
        if ($plan) { Assert-FixturePlan $plan }
        if ($Action -eq 'AddApp') {
            Assert-FixturePlan $plan
            if ($plan.properties.provisioningState -ne 'Succeeded' -or $plan.properties.status -ne 'Ready') { throw 'The existing plan is not ready.' }
            if ($app) { throw 'The app already exists. No overwrite.' }
            $stage='AddingAppToExistingPlan'
            $response = Invoke-FixtureRequest -Id $appId -Method PUT -Body @{
                location=$location; kind='app,linux'; tags=@{purpose=$purpose}
                properties=@{
                    serverFarmId=$planId; reserved=$true; httpsOnly=$true
                    publicNetworkAccess='Disabled'; clientAffinityEnabled=$false
                    siteConfig=@{alwaysOn=$false; ftpsState='Disabled'; minTlsVersion='1.2'}
                }
            }
            if ($response.StatusCode -notin @(200,201,202)) { throw "App creation failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)" }
            $app = Wait-FixtureResource $appId
            if ((Get-OpsServiceKind $app.type $app.kind) -ne 'AppService' -or
                $app.properties.serverFarmId -ine $planId -or $app.properties.httpsOnly -ne $true -or
                $app.properties.publicNetworkAccess -ne 'Disabled' -or $app.properties.clientAffinityEnabled -ne $false) {
                throw 'App type, existing plan, or expected settings were not verified.'
            }
            Assert-FixturePlan (Read-FixtureResource $planId)
            ConvertTo-OpsInventoryRow $app | ConvertTo-Json -Depth 5
            Write-Host 'App added to the existing plan. No plan PUT/PATCH and no RBAC changes were performed.'
        } else {
            # This user-requested fixture cleanup is never part of the installed skill or test command.
            $resources = @(Get-AzResource -ResourceGroupName $groupName -ErrorAction Stop)
            if (@($resources | Where-Object { $_.ResourceId -inotmatch ('^(' + [regex]::Escape($appId) + '|' + [regex]::Escape($planId) + ')$') }).Count) {
                throw 'Other resources exist in the test RG. Cleanup stopped before deletion.'
            }
            if ($app -and ($app.properties.serverFarmId -ine $planId -or (Get-OpsServiceKind $app.type $app.kind) -ne 'AppService')) {
                throw 'The app is not the expected test app on the test plan.'
            }
            if ($plan -and $plan.properties.numberOfSites -gt $(if ($app) {1} else {0})) {
                throw 'Other apps use this plan. Cleanup stopped before deletion.'
            }
            if ($app) {
                $stage='DeletingApp'
                Remove-FixtureResource -Id $appId -Query '&deleteEmptyServerFarm=false'
            }
            if ($plan) {
                $plan = Read-FixtureResource $planId
                Assert-FixturePlan $plan
                if ($plan.properties.numberOfSites -ne 0) { throw 'The plan is not confirmed empty. Do not delete it.' }
                $stage='DeletingPlan'
                Remove-FixtureResource $planId
            }
            [pscustomobject]@{AppAbsent=$true; PlanAbsent=$true; EmptyResourceGroupRetained=$true} | ConvertTo-Json
        }
    }
} catch {
    if ($stage -eq 'Preflight') {
        Write-Warning 'Stopped during preflight. This invocation did not start resource creation, changes, or deletion.'
    } else {
        Write-Warning "Stopped at $stage. No automatic mutation retry, rollback, SKU change, or cleanup. A created plan incurs charges until deleted."
    }
    throw
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
