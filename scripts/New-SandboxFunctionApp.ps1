#requires -Version 7.2
# USER-RUN ONLY. Create an empty Linux Flex Consumption fixture and its host storage.
# No code deployment, keys, operator-app grants, deletion, retries or automatic provider registration.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Create')][string]$Action='Plan',
    [ValidatePattern('^[a-z0-9]+$')][string]$Location='japaneast',
    [ValidatePattern('^[A-Za-z0-9_-]{1,90}$')][string]$ResourceGroupName='rg-azureops-functions-test',
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection=Read-OpsConnection
$config=Select-OpsSubscription $connection $connection.sandboxSubscriptionId
$suffix=$config.applicationId.Replace('-','').Substring(0,12).ToLowerInvariant()
$groupId="/subscriptions/$($config.subscriptionId)/resourceGroups/$ResourceGroupName"
$siteId="$groupId/providers/Microsoft.Web/sites/func-azureops-test-$suffix"
$planId="$groupId/providers/Microsoft.Web/serverfarms/asp-azureops-functions-test"
$storageName="stazopsfn$suffix"
$storageId="$groupId/providers/Microsoft.Storage/storageAccounts/$storageName"
$containerId="$storageId/blobServices/default/containers/deployment"
$deploymentUrl="https://$storageName.blob.core.windows.net/deployment"
foreach($id in @($siteId,$planId,$storageId,$containerId)) {Assert-OpsResourceScope $id $config.subscriptionId}
$roles=@(
    @{Name='Storage Blob Data Owner';Id='b7e6dc6d-f1e8-4753-8033-0f276bb0955b'},
    @{Name='Storage Table Data Contributor';Id='0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'}
)
$reportPath=[IO.Path]::GetFullPath($OutputPath)
$repositoryPath=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
if([IO.Path]::GetExtension($reportPath) -ine '.txt' -or $reportPath -match '[*?\[\]]' -or
    $reportPath.StartsWith($repositoryPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Use a new .txt report outside the repository.'}
if((Test-Path -LiteralPath $reportPath) -or -not (Test-Path -LiteralPath (Split-Path $reportPath -Parent) -PathType Container)) {throw 'Report exists or its directory is missing.'}
New-Item -ItemType File -Path $reportPath -ErrorAction Stop | Out-Null
function Write-FunctionRecord {
    param([string]$Event,$Data)
    # Only selected fields supplied by this script, never a raw ARM response or exception.
    [ordered]@{AtUtc=[DateTime]::UtcNow.ToString('o');Event=$Event;Data=$Data} |
        ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $reportPath -Encoding utf8 -ErrorAction Stop
    Write-Host $Event
}
$review=[ordered]@{
    Action=$Action;TenantId=$config.tenantId;SubscriptionId=$config.subscriptionId
    ResourceGroupId=$groupId;ResourceId=$siteId;PlanResourceId=$planId;StorageResourceId=$storageId;ContainerResourceId=$containerId
    Location=$Location;Hosting='Flex Consumption';OperatingSystem='Linux';Sku='FC1';Runtime='node';RuntimeVersion='22'
    InstanceMemoryMB=2048;MaximumInstanceCount=40;AlwaysReadyInstances=0;HttpsOnly=$true;PublicNetworkAccess='Disabled'
    StorageSku='Standard_LRS';StoragePublicNetworkAccess='Enabled';StorageAnonymousAccess=$false;StorageSharedKeyAccess=$false
    StorageRoleRecipient='New Function App system-assigned managed identity; NOT the Azure Ops application'
    StorageRoleScope=$storageId;StorageRoles=$roles;AutomaticallyExpires=$false;GrantsOpsAppPermissions=$false
    DeploysCode=$false;Triggers='None';Monitoring='No Application Insights; host diagnostic tables only'
    Cost='On-demand execution and storage usage. No always-ready instances. MaximumInstanceCount is a ceiling, not allocated instances.'
    Cleanup='User removes the Function App, plan and dedicated storage after testing; no automatic cleanup.'
}
Write-FunctionRecord 'Plan' $review
$review | ConvertTo-Json -Depth 6
Write-Host "Report: $reportPath"
if($Action -eq 'Plan') {return}

function Invoke-FunctionCreationRequest {
    param([string]$Id,[string]$Version='2024-11-01',[string]$Method='GET',[hashtable]$Body)
    Assert-OpsContext (Get-AzContext) $config 'User'
    $parameters=@{Path="${Id}?api-version=$Version";Method=$Method;ErrorAction='Stop'}
    if($Body) {$parameters.Payload=$Body | ConvertTo-Json -Depth 12 -Compress}
    $response=Invoke-AzRestMethod @parameters
    $accepted=if($Method -eq 'GET') {@(200,404)} else {@(200,201,202)}
    if($response.StatusCode -notin $accepted) {
        Write-FunctionRecord 'ArmFailure' (Get-OpsArmErrorSummary $response)
        throw 'ARM request failed. See the sanitized report.'
    }
    $response
}
function Read-FunctionCreationResource {
    param([string]$Id,[string]$Version='2024-11-01',[switch]$AllowAbsent)
    $response=Invoke-FunctionCreationRequest -Id $Id -Version $Version
    if($response.StatusCode -eq 404) {
        if($AllowAbsent) {return $null}
        throw 'Expected resource is absent.'
    }
    $item=$response.Content | ConvertFrom-Json -AsHashtable
    if($item['id'] -ine $Id) {throw 'Response resource ID mismatch.'}
    $item
}
function Wait-FunctionCreationResource {
    param([string]$Id,[string]$Version,[scriptblock]$Ready)
    for($attempt=0;$attempt -lt 36;$attempt++) {
        $item=Read-FunctionCreationResource -Id $Id -Version $Version -AllowAbsent
        if($item) {
            if($item['properties'] -and $item['properties']['provisioningState'] -in @('Failed','Canceled')) {throw 'Provisioning failed. No automatic retry.'}
            if(& $Ready $item) {return $item}
        }
        if($attempt -lt 35) {Start-Sleep -Seconds 5}
    }
    throw 'Read-only readiness polling timed out. Do not repeat creation automatically.'
}
function Assert-FunctionFixture {
    param($Item)
    $p=$Item['properties'];$f=$p['functionAppConfig']
    if((Get-OpsServiceKind $Item['type'] $Item['kind']) -ne 'Functions' -or
        ($Item['location'] -replace '\s','') -ine $Location -or $p['serverFarmId'] -ine $planId -or
        $p['reserved'] -ne $true -or $p['httpsOnly'] -ne $true -or $p['publicNetworkAccess'] -ne 'Disabled' -or
        $Item['identity']['type'] -ne 'SystemAssigned' -or
        $f['runtime']['name'] -ne 'node' -or $f['runtime']['version'] -ne '22' -or
        $f['scaleAndConcurrency']['instanceMemoryMB'] -ne 2048 -or $f['scaleAndConcurrency']['maximumInstanceCount'] -ne 40 -or
        @($f['scaleAndConcurrency']['alwaysReady'] | Where-Object {$_ -and $_['instanceCount'] -gt 0}).Count -gt 0 -or
        $f['deployment']['storage']['type'] -ne 'blobContainer' -or $f['deployment']['storage']['value'] -ine $deploymentUrl -or
        $f['deployment']['storage']['authentication']['type'] -ne 'SystemAssignedIdentity') {throw 'Created Function App differs from the reviewed fixture.'}
    Assert-OpsGuid $Item['identity']['principalId'] 'Function identity principalId'
    if($Item['identity']['principalId'] -ieq $config.servicePrincipalObjectId -or $Item['identity']['tenantId'] -ine $config.tenantId) {throw 'Function identity does not match the expected tenant or is the operator identity.'}
}
$connected=$false
$stage='Connecting'
try {
    Import-Module Az.Accounts -ErrorAction Stop
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $config.tenantId -Subscription $config.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected=$true
    Assert-OpsContext (Get-AzContext) $config 'User'
    $stage='Preflight'
    foreach($namespace in @('Microsoft.Web','Microsoft.Storage')) {
        $response=Invoke-FunctionCreationRequest -Id "/subscriptions/$($config.subscriptionId)/providers/$namespace" -Version '2021-04-01'
        if($response.StatusCode -ne 200) {throw 'Provider registration could not be verified.'}
        $provider=$response.Content | ConvertFrom-Json -AsHashtable
        Write-FunctionRecord 'Provider' @{Namespace=$namespace;RegistrationState=$provider['registrationState']}
        if($provider['namespace'] -ine $namespace -or $provider['registrationState'] -ne 'Registered') {throw "$namespace is not Registered. User registration is required."}
    }
    $group=Read-FunctionCreationResource -Id $groupId -Version '2021-04-01' -AllowAbsent
    foreach($target in @(@{Id=$siteId;Version='2024-11-01'},@{Id=$planId;Version='2024-11-01'},@{Id=$storageId;Version='2023-05-01'})) {
        if(Read-FunctionCreationResource -Id $target.Id -Version $target.Version -AllowAbsent) {throw 'A target already exists. No overwrite or automatic resume.'}
    }
    Write-FunctionRecord 'PreflightPassed' @{ExistingGroup=[bool]$group;TargetResourcesAbsent=$true;Capacity='Not guaranteed by provider registration; creation can still fail for quota or regional availability.'}
    if(-not $group) {
        $stage='CreatingGroup'
        $null=Invoke-FunctionCreationRequest -Id $groupId -Version '2021-04-01' -Method PUT -Body @{location=$Location;tags=@{purpose='azure-ops-skills-functions-test'}}
        $null=Read-FunctionCreationResource -Id $groupId -Version '2021-04-01'
        Write-FunctionRecord 'GroupCreated' @{ResourceId=$groupId}
    }
    # Try the plan before allocating storage; quota failures stop here without an SKU/region retry.
    $stage='CreatingPlan'
    $null=Invoke-FunctionCreationRequest -Id $planId -Method PUT -Body @{
        location=$Location;kind='functionapp';sku=@{name='FC1';tier='FlexConsumption'}
        tags=@{purpose='azure-ops-skills-functions-test'};properties=@{reserved=$true}
    }
    $plan=Wait-FunctionCreationResource -Id $planId -Version '2024-11-01' -Ready {param($r) $r['properties']['provisioningState'] -eq 'Succeeded'}
    if($plan['type'] -ine 'Microsoft.Web/serverfarms' -or $plan['sku']['name'] -ne 'FC1' -or $plan['properties']['reserved'] -ne $true -or ($plan['location'] -replace '\s','') -ine $Location) {throw 'Plan differs from the reviewed fixture.'}
    Write-FunctionRecord 'PlanCreated' @{ResourceId=$planId;Sku='FC1';OperatingSystem='Linux'}
    $stage='CreatingStorage'
    $null=Invoke-FunctionCreationRequest -Id $storageId -Version '2023-05-01' -Method PUT -Body @{
        location=$Location;kind='StorageV2';sku=@{name='Standard_LRS'};tags=@{purpose='azure-ops-skills-functions-test'}
        properties=@{supportsHttpsTrafficOnly=$true;minimumTlsVersion='TLS1_2';allowBlobPublicAccess=$false;allowSharedKeyAccess=$false;defaultToOAuthAuthentication=$true;publicNetworkAccess='Enabled';dnsEndpointType='Standard'}
    }
    $storage=Wait-FunctionCreationResource -Id $storageId -Version '2023-05-01' -Ready {param($r) $r['properties']['provisioningState'] -eq 'Succeeded'}
    if($storage['type'] -ine 'Microsoft.Storage/storageAccounts' -or $storage['kind'] -ne 'StorageV2' -or $storage['sku']['name'] -ne 'Standard_LRS' -or
        ($storage['location'] -replace '\s','') -ine $Location -or $storage['properties']['allowBlobPublicAccess'] -ne $false -or
        $storage['properties']['allowSharedKeyAccess'] -ne $false -or $storage['properties']['supportsHttpsTrafficOnly'] -ne $true -or
        $storage['properties']['minimumTlsVersion'] -ne 'TLS1_2') {throw 'Storage differs from the reviewed fixture.'}
    Write-FunctionRecord 'StorageCreated' @{ResourceId=$storageId;SharedKeyAccess=$false;AnonymousAccess=$false}
    $stage='CreatingDeploymentContainer'
    $null=Invoke-FunctionCreationRequest -Id $containerId -Version '2023-05-01' -Method PUT -Body @{properties=@{publicAccess='None'}}
    $container=Read-FunctionCreationResource -Id $containerId -Version '2023-05-01'
    if($container['properties']['publicAccess'] -ne 'None') {throw 'Container is not private.'}
    Write-FunctionRecord 'ContainerCreated' @{ResourceId=$containerId;PublicAccess='None'}
    $stage='CreatingFunctionApp'
    $null=Invoke-FunctionCreationRequest -Id $siteId -Method PUT -Body @{
        location=$Location;kind='functionapp,linux';identity=@{type='SystemAssigned'};tags=@{purpose='azure-ops-skills-functions-test'}
        properties=@{
            serverFarmId=$planId;reserved=$true;httpsOnly=$true;publicNetworkAccess='Disabled'
            functionAppConfig=@{
                runtime=@{name='node';version='22'}
                scaleAndConcurrency=@{maximumInstanceCount=40;instanceMemoryMB=2048;alwaysReady=@()}
                deployment=@{storage=@{type='blobContainer';value=$deploymentUrl;authentication=@{type='SystemAssignedIdentity'}}}
            }
            siteConfig=@{minTlsVersion='1.2';appSettings=@(
                @{name='AzureWebJobsStorage__accountName';value=$storageName},
                @{name='AzureWebJobsStorage__credential';value='managedidentity'}
            )}
        }
    }
    $site=Wait-FunctionCreationResource -Id $siteId -Version '2024-11-01' -Ready {param($r) $r['identity'] -and $r['identity']['principalId'] -and $r['properties']['state'] -eq 'Running'}
    Assert-FunctionFixture $site
    $principalId=$site['identity']['principalId']
    Write-FunctionRecord 'FunctionAppCreated' @{ResourceId=$siteId;State=$site['properties']['state'];ManagedIdentityObjectId=$principalId;CodeDeployed=$false;HostHealthVerified=$false}
    $stage='GrantingHostStorageAccess'
    foreach($role in $roles) {
        $assignmentId="$storageId/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
        $definitionId="/subscriptions/$($config.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($role.Id)"
        Write-FunctionRecord 'HostRolePlanned' @{AssignmentId=$assignmentId;RoleName=$role.Name;RoleDefinitionId=$definitionId;PrincipalId=$principalId;Scope=$storageId}
        $null=Invoke-FunctionCreationRequest -Id $assignmentId -Version '2022-04-01' -Method PUT -Body @{properties=@{roleDefinitionId=$definitionId;principalId=$principalId;principalType='ServicePrincipal'}}
        $assignment=Read-FunctionCreationResource -Id $assignmentId -Version '2022-04-01'
        if($assignment['properties']['principalId'] -ine $principalId -or $assignment['properties']['roleDefinitionId'] -ine $definitionId -or $assignment['properties']['scope'] -ine $storageId) {throw 'Host storage role assignment mismatch.'}
        Write-FunctionRecord 'HostRoleAssigned' @{AssignmentId=$assignmentId;RoleName=$role.Name;PrincipalId=$principalId;Scope=$storageId}
    }
    $stage='FinalVerification'
    $site=Read-FunctionCreationResource $siteId
    Assert-FunctionFixture $site
    if($site['identity']['principalId'] -ine $principalId -or $site['properties']['state'] -ne 'Running') {throw 'Final Function App state or identity changed.'}
    Write-FunctionRecord 'Succeeded' @{ResourceId=$siteId;PlanResourceId=$planId;StorageResourceId=$storageId;State='Running';ManagedIdentityObjectId=$principalId;GrantsOpsAppPermissions=$false;CodeDeployed=$false;HostHealthVerified=$false;UserCleanupRequired=$true}
} catch {
    Write-FunctionRecord 'Failed' @{Stage=$stage;ErrorType=$_.Exception.GetType().FullName;MayHaveCreatedResources=($stage -notin @('Connecting','Preflight'));AutomaticRetry=$false}
    throw "Stopped at $stage. See the report. No automatic retry, rollback, provider registration, or cleanup."
} finally {
    if($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
