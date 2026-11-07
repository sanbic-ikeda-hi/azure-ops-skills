#requires -Version 7.2
# Live Sandbox test. Default is local plan/report only; -Execute requires prior authorization.
# Uses only the dedicated app. No creation, role changes, deletion or mutation retries.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][string]$PlanResourceId,
    [Parameter(Mandatory)][string]$PeerResourceId,
    [Parameter(Mandatory)][string]$AssignmentId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidatePattern('^[a-z0-9]+$')][string]$ExpectedLocation,
    [ValidateSet('Windows','Linux')][string]$ExpectedOperatingSystem,
    [ValidateSet('B1','P0v4')][string]$ExpectedSku,
    [switch]$Execute
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection=Read-OpsConnection
$config=Select-OpsSubscription $connection $connection.sandboxSubscriptionId
$settings=Resolve-OpsSandboxSettings -Name WebAppTest -Connection $connection -Values @{resourceId=$ResourceId;planResourceId=$PlanResourceId;peerResourceId=$PeerResourceId;location=$ExpectedLocation;operatingSystem=$ExpectedOperatingSystem;sku=$ExpectedSku}
$ExpectedLocation=$settings.location
$ExpectedOperatingSystem=$settings.operatingSystem
$ExpectedSku=$settings.sku
foreach($id in @($ResourceId,$PeerResourceId,$PlanResourceId)) {Assert-OpsResourceScope $id $config.subscriptionId}
$sitePattern='^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$'
if($ResourceId -notmatch $sitePattern -or $PeerResourceId -notmatch $sitePattern -or $ResourceId -ieq $PeerResourceId -or
    $PlanResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/serverfarms/[^/]+$') {throw 'Exact, distinct Sandbox Web App IDs and a plan ID are required.'}
$assignmentPrefix="$ResourceId/providers/Microsoft.Authorization/roleAssignments/"
if(-not $AssignmentId.StartsWith($assignmentPrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'AssignmentId must belong to the test app.'}
Assert-OpsGuid $AssignmentId.Substring($assignmentPrefix.Length) 'AssignmentId'
# Reports contain real IDs. Keep them outside the source repository and never overwrite.
$reportPath=[IO.Path]::GetFullPath($OutputPath)
$repositoryPath=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
if([IO.Path]::GetExtension($reportPath) -ine '.txt' -or $reportPath -match '[*?\[\]]' -or
    $reportPath.StartsWith($repositoryPath + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Use a new .txt report outside the source repository.'}
if((Test-Path -LiteralPath $reportPath) -or -not (Test-Path -LiteralPath (Split-Path $reportPath -Parent) -PathType Container)) {throw 'Report already exists or its directory is missing.'}
New-Item -ItemType File -Path $reportPath -ErrorAction Stop | Out-Null
function Write-TestRecord {
    param([string]$Event,$Data)
    # Callers pass only explicitly selected non-secret fields, never ARM responses/errors.
    [pscustomobject][ordered]@{AtUtc=[DateTime]::UtcNow.ToString('o');Event=$Event;Data=$Data} |
        ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $reportPath -Encoding utf8 -ErrorAction Stop
    Write-Host $Event
}
Write-TestRecord 'Plan' ([ordered]@{
    TenantId=$config.tenantId;SubscriptionId=$config.subscriptionId;ApplicationId=$config.applicationId
    ResourceId=$ResourceId;PlanResourceId=$PlanResourceId;PeerResourceId=$PeerResourceId
    ExpectedLocation=$ExpectedLocation;ExpectedOperatingSystem=$ExpectedOperatingSystem;ExpectedSku=$ExpectedSku
    UserReportedAssignmentId=$AssignmentId;Execute=[bool]$Execute
    Operations=@('Read baseline','Stop and verify Stopped','Start and verify Running','Set clientAffinityEnabled=true and verify','Restore clientAffinityEnabled=false and verify','Compare peer and plan properties')
    Scope='ARM management properties only; no HTTP content or code test. No RBAC changes or resource deletion.'
})
if(-not $Execute) {Write-Host "Report: $reportPath";return}

function Invoke-TestRequest {
    param([string]$Id,[string]$Method='GET',[hashtable]$Body)
    Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
    $parameters=@{Path="${Id}?api-version=2024-11-01";Method=$Method;ErrorAction='Stop'}
    if($Body) {$parameters.Payload=$Body | ConvertTo-Json -Depth 3 -Compress}
    $response=Invoke-AzRestMethod @parameters
    if($response.StatusCode -notin @(200,202)) {
        $summary=Get-OpsArmErrorSummary $response
        Write-TestRecord 'ArmFailure' $summary
        throw 'ARM request failed. See the sanitized report. No automatic retry.'
    }
    if($Method -eq 'GET' -and $response.StatusCode -ne 200) {throw 'GET did not return a resource.'}
    $response
}
function Read-TestSite {
    param([string]$Id)
    $response=Invoke-TestRequest $Id
    $item=$response.Content | ConvertFrom-Json -AsHashtable
    if($item.id -ine $Id -or (Get-OpsServiceKind $item.type $item.kind) -ne 'AppService' -or $item.properties.serverFarmId -ine $PlanResourceId -or
        $item.properties.clientAffinityEnabled -isnot [bool] -or $item.properties.httpsOnly -isnot [bool]) {throw 'Web App identity, plan or property types did not match.'}
    [ordered]@{
        ResourceId=$Id;State=$item.properties.state;ClientAffinityEnabled=$item.properties.clientAffinityEnabled
        HttpsOnly=$item.properties.httpsOnly;PublicNetworkAccess=$item.properties.publicNetworkAccess
        PlanResourceId=$item.properties.serverFarmId;Kind=$item.kind;Location=$item.location
    }
}
function Read-TestPlan {
    $response=Invoke-TestRequest $PlanResourceId
    $item=$response.Content | ConvertFrom-Json -AsHashtable
    if($item.id -ine $PlanResourceId -or $item.type -ine 'Microsoft.Web/serverfarms' -or
        $item.properties.provisioningState -ne 'Succeeded' -or $item.properties.status -ne 'Ready') {throw 'Plan identity or readiness did not match.'}
    [ordered]@{
        ResourceId=$PlanResourceId;Location=$item.location;Reserved=$item.properties.reserved
        Sku=$item.sku.name;Tier=$item.sku.tier;Capacity=$item.sku.capacity;NumberOfSites=$item.properties.numberOfSites
        PerSiteScaling=$item.properties.perSiteScaling;ZoneRedundant=$item.properties.zoneRedundant
    }
}
function Assert-SiteProtectedProperties {
    param($Site)
    foreach($key in @('ResourceId','HttpsOnly','PublicNetworkAccess','PlanResourceId','Kind','Location')) {
        if($Site[$key] -cne $baseline[$key]) {throw "Protected property changed: $key"}
    }
}
function Wait-TestSite {
    param([string]$State,[bool]$Affinity)
    for($attempt=0;$attempt -lt 12;$attempt++) {
        $site=Read-TestSite $ResourceId
        Assert-SiteProtectedProperties $site
        if($site.State -eq $State -and $site.ClientAffinityEnabled -eq $Affinity) {return $site}
        Start-Sleep -Seconds 5
    }
    throw 'Expected state was not confirmed within one minute. Do not retry mutations automatically.'
}
$connected=$false
$stage='Connecting'
try {
    Connect-OpsApplication $config
    $connected=$true
    $stage='Preflight'
    $baseline=Read-TestSite $ResourceId
    $peerBefore=Read-TestSite $PeerResourceId
    $planBefore=Read-TestPlan
    Write-TestRecord 'Baseline' ([ordered]@{App=$baseline;Peer=$peerBefore;Plan=$planBefore})
    if($baseline.State -ne 'Running' -or $baseline.ClientAffinityEnabled -ne $false -or
        $baseline.HttpsOnly -ne $true -or $baseline.PublicNetworkAccess -ne 'Disabled' -or
        ($baseline.Location -replace '\s','') -ine $ExpectedLocation -or
        ($planBefore.Location -replace '\s','') -ine $ExpectedLocation -or
        ($baseline.Kind -match '(^|,)linux(,|$)') -ne ($ExpectedOperatingSystem -eq 'Linux') -or
        $planBefore.Reserved -ne ($ExpectedOperatingSystem -eq 'Linux') -or $planBefore.Sku -ine $ExpectedSku -or $planBefore.Capacity -ne 1) {
        throw 'Baseline differs from the explicitly reviewed location/OS/SKU isolated-app test. No mutation was started.'
    }
    $stage='Stopping'
    Write-TestRecord $stage @{ResourceId=$ResourceId}
    $null=Invoke-TestRequest -Id "$ResourceId/stop" -Method POST
    Write-TestRecord 'StoppedVerified' (Wait-TestSite 'Stopped' $false)
    $stage='Starting'
    Write-TestRecord $stage @{ResourceId=$ResourceId}
    $null=Invoke-TestRequest -Id "$ResourceId/start" -Method POST
    Write-TestRecord 'RunningVerified' (Wait-TestSite 'Running' $false)
    $stage='EnablingAffinity'
    Write-TestRecord $stage @{ResourceId=$ResourceId;ClientAffinityEnabled=$true}
    $null=Invoke-TestRequest -Id $ResourceId -Method PATCH -Body @{properties=@{clientAffinityEnabled=$true}}
    Write-TestRecord 'AffinityEnabledVerified' (Wait-TestSite 'Running' $true)
    $stage='RestoringAffinity'
    Write-TestRecord $stage @{ResourceId=$ResourceId;ClientAffinityEnabled=$false}
    $null=Invoke-TestRequest -Id $ResourceId -Method PATCH -Body @{properties=@{clientAffinityEnabled=$false}}
    $final=Wait-TestSite 'Running' $false
    Write-TestRecord 'AffinityRestoredVerified' $final
    $stage='ComparingPeerAndPlan'
    $peerAfter=Read-TestSite $PeerResourceId
    $planAfter=Read-TestPlan
    Write-TestRecord 'Final' ([ordered]@{App=$final;Peer=$peerAfter;Plan=$planAfter})
    if(($peerBefore | ConvertTo-Json -Compress) -cne ($peerAfter | ConvertTo-Json -Compress) -or
        ($planBefore | ConvertTo-Json -Compress) -cne ($planAfter | ConvertTo-Json -Compress)) {throw 'Selected peer or plan properties changed during the test.'}
    Write-TestRecord 'Succeeded' @{AppRestored=$true;SelectedPeerPropertiesUnchanged=$true;SelectedPlanPropertiesUnchanged=$true;UserRevokeRequired=$true}
} catch {
    Write-TestRecord 'Failed' @{Stage=$stage;ExceptionType=$_.Exception.GetType().Name;AutomaticRetryOrRollback=$false;ReviewBaselineAndCurrentState=$true}
    throw
} finally {
    if($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
    Write-Host "Report: $reportPath"
}
