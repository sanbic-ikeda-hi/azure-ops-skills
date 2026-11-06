#requires -Version 7.2
# Dedicated-app management test only. Default: local plan/report. -Execute requires approved access.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][string]$PlanResourceId,
    [Parameter(Mandatory)][string]$StorageResourceId,
    [Parameter(Mandatory)][string]$ManagedIdentityObjectId,
    [Parameter(Mandatory)][string]$AssignmentId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidatePattern('^[a-z0-9]+$')][string]$Location='japaneast',
    [switch]$Execute
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection=Read-OpsConnection
$config=Select-OpsSubscription $connection $connection.sandboxSubscriptionId
foreach($id in @($ResourceId,$PlanResourceId,$StorageResourceId)) {Assert-OpsResourceScope $id $config.subscriptionId}
if($ResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$' -or
    $PlanResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/serverfarms/[^/]+$' -or
    $StorageResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/([a-z0-9]{3,24})$') {throw 'Exact Sandbox Function App, plan and storage IDs are required.'}
$storageName=$Matches[1]
$deploymentUrl="https://$storageName.blob.core.windows.net/deployment"
Assert-OpsGuid $ManagedIdentityObjectId 'ManagedIdentityObjectId'
if($ManagedIdentityObjectId -ieq $config.servicePrincipalObjectId) {throw 'Host identity must be distinct from the operator app.'}
$assignmentPrefix="$ResourceId/providers/Microsoft.Authorization/roleAssignments/"
if(-not $AssignmentId.StartsWith($assignmentPrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'AssignmentId must belong to the selected Function App.'}
Assert-OpsGuid $AssignmentId.Substring($assignmentPrefix.Length) 'AssignmentId'
$reportPath=[IO.Path]::GetFullPath($OutputPath)
$repositoryPath=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
if([IO.Path]::GetExtension($reportPath) -ine '.txt' -or $reportPath -match '[*?\[\]]' -or
    $reportPath.StartsWith($repositoryPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Use a new .txt report outside the repository.'}
if((Test-Path -LiteralPath $reportPath) -or -not (Test-Path -LiteralPath (Split-Path $reportPath -Parent) -PathType Container)) {throw 'Report exists or its directory is missing.'}
New-Item -ItemType File -Path $reportPath -ErrorAction Stop | Out-Null
function Write-FunctionsRecord {
    param([string]$Event,$Data)
    [ordered]@{AtUtc=[DateTime]::UtcNow.ToString('o');Event=$Event;Data=$Data} |
        ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $reportPath -Encoding utf8 -ErrorAction Stop
    Write-Host $Event
}
Write-FunctionsRecord 'Plan' ([ordered]@{
    TenantId=$config.tenantId;SubscriptionId=$config.subscriptionId;ApplicationId=$config.applicationId
    ResourceId=$ResourceId;PlanResourceId=$PlanResourceId;StorageResourceId=$StorageResourceId;ManagedIdentityObjectId=$ManagedIdentityObjectId
    UserReportedAssignmentId=$AssignmentId;Execute=[bool]$Execute;Location=$Location
    Operations=@('Verify empty Functions fixture','Stop and verify Stopped','Start and verify Running','Set maximumInstanceCount=41 and verify','Restore maximumInstanceCount=40 and verify','Verify protected properties and plan unchanged')
    Scope='ARM management only. No code/host health test, Storage requests, role changes, creation, deletion or automatic rollback.'
})
Write-Host "Report: $reportPath"
if(-not $Execute) {return}

function Invoke-FunctionsTestRequest {
    param([string]$Id,[string]$Method='GET',[hashtable]$Body)
    $allowed=if($Method -eq 'GET') {@($ResourceId,$PlanResourceId,"$ResourceId/functions")} elseif($Method -eq 'POST') {@("$ResourceId/stop","$ResourceId/start")} elseif($Method -eq 'PATCH') {@($ResourceId)} else {@()}
    if($Id -notin $allowed) {throw 'Unexpected management request.'}
    Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
    $parameters=@{Path="${Id}?api-version=2024-11-01";Method=$Method;ErrorAction='Stop'}
    if($Body) {$parameters.Payload=$Body | ConvertTo-Json -Depth 15 -Compress}
    $response=Invoke-AzRestMethod @parameters
    if(($Method -eq 'GET' -and $response.StatusCode -ne 200) -or $response.StatusCode -notin @(200,202)) {
        Write-FunctionsRecord 'ArmFailure' (Get-OpsArmErrorSummary $response)
        throw 'ARM request failed. No automatic retry.'
    }
    $response
}
function ConvertTo-FunctionsCanonicalValue {
    param($Value)
    if($Value -is [Collections.IDictionary]) {
        $ordered=[ordered]@{}
        foreach($key in @($Value.Keys | Sort-Object)) {$ordered[$key]=ConvertTo-FunctionsCanonicalValue $Value[$key]}
        return $ordered
    }
    if($Value -is [array]) {
        $items=@(foreach($element in $Value) {ConvertTo-FunctionsCanonicalValue $element})
        return ,$items
    }
    return $Value
}
function Get-FunctionsConfigurationSignature {
    param([hashtable]$Configuration)
    $copy=$Configuration | ConvertTo-Json -Depth 15 -Compress | ConvertFrom-Json -AsHashtable
    $copy['scaleAndConcurrency']['maximumInstanceCount']=0
    # Used only in memory for comparisons, never emitted to the report.
    ConvertTo-FunctionsCanonicalValue $copy | ConvertTo-Json -Depth 15 -Compress
}
function Read-FunctionsTestSite {
    $r=Invoke-FunctionsTestRequest $ResourceId
    $item=$r.Content | ConvertFrom-Json -AsHashtable
    $p=$item['properties'];$f=$p['functionAppConfig'];$identity=$item['identity']
    if($item['id'] -ine $ResourceId -or (Get-OpsServiceKind $item['type'] $item['kind']) -ne 'Functions' -or
        $p['serverFarmId'] -ine $PlanResourceId -or $identity['type'] -ne 'SystemAssigned' -or
        $identity['principalId'] -ine $ManagedIdentityObjectId -or $identity['tenantId'] -ine $config.tenantId -or
        $p['reserved'] -ne $true -or $p['httpsOnly'] -ne $true -or $p['publicNetworkAccess'] -ne 'Disabled' -or
        ($item['location'] -replace '\s','') -ine $Location -or $f -isnot [Collections.IDictionary] -or
        $f['runtime']['name'] -ne 'node' -or $f['runtime']['version'] -ne '22' -or
        $f['scaleAndConcurrency']['instanceMemoryMB'] -ne 2048 -or
        @($f['scaleAndConcurrency']['alwaysReady'] | Where-Object {$_ -and $_['instanceCount'] -gt 0}).Count -gt 0 -or
        $f['deployment']['storage']['type'] -ne 'blobContainer' -or $f['deployment']['storage']['value'] -ine $deploymentUrl -or
        $f['deployment']['storage']['authentication']['type'] -ne 'SystemAssignedIdentity') {throw 'Function App differs from the reviewed empty Flex fixture.'}
    if(@($f.Keys | Where-Object {$_ -notin @('runtime','deployment','scaleAndConcurrency','siteUpdateStrategy')}).Count) {throw 'Unreviewed Function App configuration fields.'}
    @{
        Configuration=$f
        Snapshot=[ordered]@{
            ResourceId=$ResourceId;Kind=$item['kind'];Location=$item['location'];State=$p['state'];PlanResourceId=$p['serverFarmId']
            HttpsOnly=$p['httpsOnly'];PublicNetworkAccess=$p['publicNetworkAccess'];IdentityType=$identity['type'];ManagedIdentityObjectId=$identity['principalId']
            Runtime=$f['runtime']['name'];RuntimeVersion=$f['runtime']['version'];InstanceMemoryMB=$f['scaleAndConcurrency']['instanceMemoryMB']
            MaximumInstanceCount=$f['scaleAndConcurrency']['maximumInstanceCount'];AlwaysReadyInstances=0;DeploymentAuthentication=$f['deployment']['storage']['authentication']['type']
        }
    }
}
function Read-FunctionsTestPlan {
    $r=Invoke-FunctionsTestRequest $PlanResourceId
    $item=$r.Content | ConvertFrom-Json -AsHashtable
    $p=$item['properties']
    if($item['id'] -ine $PlanResourceId -or $item['type'] -ine 'Microsoft.Web/serverfarms' -or
        $item['sku']['name'] -ne 'FC1' -or $item['sku']['tier'] -ne 'FlexConsumption' -or
        $p['reserved'] -ne $true -or $p['numberOfSites'] -ne 1 -or
        $p['provisioningState'] -ne 'Succeeded' -or $p['status'] -ne 'Ready' -or ($item['location'] -replace '\s','') -ine $Location) {throw 'Expected single-app Linux Flex plan was not verified.'}
    [ordered]@{ResourceId=$PlanResourceId;Location=$item['location'];Sku=$item['sku']['name'];Tier=$item['sku']['tier'];Reserved=$p['reserved'];NumberOfSites=$p['numberOfSites'];PerSiteScaling=$p['perSiteScaling'];ZoneRedundant=$p['zoneRedundant']}
}
function Assert-EmptyFunctionsTestApp {
    $r=Invoke-FunctionsTestRequest "$ResourceId/functions"
    $page=$r.Content | ConvertFrom-Json -AsHashtable
    if($page['value'] -isnot [array] -or $page['value'].Count -ne 0 -or $page['nextLink']) {throw 'This management test requires a verified empty Function App.'}
}
function Wait-FunctionsTestState {
    param([string]$ExpectedState,[int]$Maximum)
    for($attempt=0;$attempt -lt 12;$attempt++) {
        $site=Read-FunctionsTestSite
        if((Get-FunctionsConfigurationSignature $site.Configuration) -cne $baselineSignature) {throw 'A protected Function App configuration changed.'}
        if($site.Snapshot.State -eq $ExpectedState -and $site.Snapshot.MaximumInstanceCount -eq $Maximum) {return $site.Snapshot}
        if($attempt -lt 11) {Start-Sleep -Seconds 5}
    }
    throw 'Expected management state was not confirmed. No automatic mutation retry.'
}
$connected=$false;$stage='Connecting'
try {
    Connect-OpsApplication $config
    $connected=$true
    $stage='Preflight'
    $baseline=Read-FunctionsTestSite
    $planBefore=Read-FunctionsTestPlan
    Assert-EmptyFunctionsTestApp
    if($baseline.Snapshot.State -ne 'Running' -or $baseline.Snapshot.MaximumInstanceCount -ne 40) {throw 'Expected Running/max 40 baseline was not verified.'}
    $baselineSignature=Get-FunctionsConfigurationSignature $baseline.Configuration
    Write-FunctionsRecord 'Baseline' @{App=$baseline.Snapshot;Plan=$planBefore;FunctionCount=0}
    $stage='Stopping'
    Write-FunctionsRecord $stage @{ResourceId=$ResourceId}
    $null=Invoke-FunctionsTestRequest "$ResourceId/stop" -Method POST
    Write-FunctionsRecord 'StoppedVerified' (Wait-FunctionsTestState 'Stopped' 40)
    $stage='Starting'
    Write-FunctionsRecord $stage @{ResourceId=$ResourceId}
    $null=Invoke-FunctionsTestRequest "$ResourceId/start" -Method POST
    Write-FunctionsRecord 'RunningVerified' (Wait-FunctionsTestState 'Running' 40)
    foreach($maximum in @(41,40)) {
        $stage=if($maximum -eq 41){'ChangingScaleLimit'}else{'RestoringScaleLimit'}
        Write-FunctionsRecord $stage @{ResourceId=$ResourceId;MaximumInstanceCount=$maximum;AlwaysReadyInstances=0}
        $patch=$baseline.Configuration | ConvertTo-Json -Depth 15 -Compress | ConvertFrom-Json -AsHashtable
        $patch['scaleAndConcurrency']['maximumInstanceCount']=$maximum
        $null=Invoke-FunctionsTestRequest $ResourceId -Method PATCH -Body @{properties=@{functionAppConfig=$patch}}
        $final=Wait-FunctionsTestState 'Running' $maximum
        Write-FunctionsRecord "$($stage)Verified" $final
    }
    $stage='FinalVerification'
    Assert-EmptyFunctionsTestApp
    $planAfter=Read-FunctionsTestPlan
    if(($planBefore | ConvertTo-Json -Compress) -cne ($planAfter | ConvertTo-Json -Compress)) {throw 'Selected plan properties changed.'}
    Write-FunctionsRecord 'Final' @{App=$final;Plan=$planAfter;FunctionCount=0}
    Write-FunctionsRecord 'Succeeded' @{AppRestored=$true;ProtectedFunctionConfigurationUnchanged=$true;SelectedPlanPropertiesUnchanged=$true;HostHealthVerified=$false;UserRevokeRequired=$true}
} catch {
    Write-FunctionsRecord 'Failed' @{Stage=$stage;ExceptionType=$_.Exception.GetType().Name;AutomaticRetryOrRollback=$false;UserReviewRequired=$true}
    throw "Stopped at $stage. See the report; no automatic retry or rollback."
} finally {
    if($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
