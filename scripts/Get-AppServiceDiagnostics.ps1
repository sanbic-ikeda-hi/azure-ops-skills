#requires -Version 7.2
# Read-only. Optional HTTP probes require an explicit Scm section and never deploy/start/change Azure.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceId,
    [ValidateSet('Authentication','PublishingPolicies','Scm')][string[]]$Section=@('Authentication'),
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ConnectionPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'AppServiceDiagnostics.ps1')
$connection=if ($ConnectionPath) {Read-OpsConnection $ConnectionPath} else {Read-OpsConnection}
$config=Select-OpsSubscription $connection $SubscriptionId
Assert-OpsServiceId $ResourceId $config
$permissionPlan=Get-OpsAppServiceDiagnosticPermissionPlan -SubscriptionId $SubscriptionId -ResourceId $ResourceId -Section $Section
$path=Resolve-OpsInventoryOutputPath $OutputPath
$stream=$null;$writer=$null;$connected=$false;$stage='Connect'
$result=[ordered]@{Schema='AzureOpsAppServiceDiagnosis/1';Source='Live';ResourceId=$ResourceId;
    Complete=$false;Succeeded=$false;Sections=@();RequiredAccess=$permissionPlan}
function Write-DiagnosisRecord {
    param([string]$Stage,[Collections.IDictionary]$Data)
    # All callers supply projected fields; no raw response or arbitrary exception is serialized.
    $record=[ordered]@{Schema='AzureOpsAppServiceDiagnosis/1';AtUtc=[DateTime]::UtcNow.ToString('o');ResourceId=$ResourceId;Stage=$Stage;Data=$Data}
    $writer.WriteLine(($record | ConvertTo-Json -Depth 16 -Compress));$writer.Flush()
}
function Add-DiagnosisFailure {
    param([string]$Name,$Failure)
    # A context mismatch is a fatal boundary, not an optional-section failure.
    Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
    $safe=Get-OpsFailureSummary $Failure
    $sectionResult=[ordered]@{Section=$Name;Retrieved=$false;Failure=$safe}
    $result.Sections+=($sectionResult)
    Write-DiagnosisRecord $Name $sectionResult
}
try {
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    Write-DiagnosisRecord 'Begin' @{Sections=$Section;ChangesAzure=$false}
    Connect-OpsApplication $config
    $connected=$true
    $stage='ReadSite'
    $site=Get-OpsServiceResource $config $ResourceId
    if ((Get-OpsServiceKind $site['type'] ([string]$site['kind'])) -ne 'AppService') {throw 'Select an App Service Web App; other services require separate verification.'}
    $result['Overview']=(ConvertTo-OpsServiceDetail $site @('Overview') @{} $null).Overview
    $result['State']=Get-OpsScalar $site['properties'] 'state'
    Write-DiagnosisRecord 'SiteVerified' @{Overview=$result.Overview;State=$result.State}
    if ('Authentication' -in $Section) {
        $stage='Authentication'
        Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
        try {
            $auth=Invoke-OpsServiceRequest $config "$ResourceId/config/authsettingsV2"
            $safe=Get-OpsAppServiceProviderSummary $auth['properties']
            $sectionResult=[ordered]@{Section=$stage;Retrieved=$true;Summary=$safe}
            $result.Sections+=($sectionResult)
            Write-DiagnosisRecord $stage $sectionResult
        } catch {Add-DiagnosisFailure $stage $_}
    }
    if ('PublishingPolicies' -in $Section) {
        foreach ($method in @('ftp','scm')) {
            $stage=if ($method -eq 'ftp') {'PublishingPolicyFtp'} else {'PublishingPolicyScm'}
            Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
            try {
                $policy=Invoke-OpsServiceRequest $config "$ResourceId/basicPublishingCredentialsPolicies/$method"
                $allow=$policy['properties']['allow']
                if ($allow -isnot [bool]) {throw 'Publishing policy does not contain a boolean allow flag.'}
                $sectionResult=[ordered]@{Section=$stage;Retrieved=$true;Allow=$allow}
                $result.Sections+=($sectionResult)
                Write-DiagnosisRecord $stage $sectionResult
            } catch {Add-DiagnosisFailure $stage $_}
        }
    }
    if ('Scm' -in $Section) {
        $stage='Network'
        Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
        try {
            $web=Invoke-OpsServiceRequest $config "$ResourceId/config/web"
            $sectionResult=[ordered]@{Section=$stage;Retrieved=$true;Summary=(Get-OpsAppServiceNetworkSummary $web['properties'])}
            $result.Sections+=($sectionResult)
            Write-DiagnosisRecord $stage $sectionResult
        } catch {Add-DiagnosisFailure $stage $_}
        # Resolve both hosts from this verified site before acquiring any token or sending HTTP.
        [void](Get-OpsAppServiceEndpoints $site)
        foreach ($endpoint in @('Main','SCM')) {
            $stage=if ($endpoint -eq 'Main') {'MainHttp'} else {'ScmHttp'}
            Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
            try {
                $safe=Invoke-OpsAppServiceHttpProbe $config $site $endpoint
                $sectionResult=[ordered]@{Section=$stage;Retrieved=$true;Summary=$safe}
                $result.Sections+=($sectionResult)
                Write-DiagnosisRecord $stage $sectionResult
            } catch {Add-DiagnosisFailure $stage $_}
        }
    }
    $result.Complete=@($result.Sections | Where-Object {-not $_.Retrieved}).Count -eq 0
    $result.Succeeded=$result.Complete
    Write-DiagnosisRecord 'Completed' @{Complete=$result.Complete;Succeeded=$result.Succeeded;SectionCount=$result.Sections.Count}
} catch {
    if ($writer) {Write-DiagnosisRecord 'Failed' @{FailedStage=$stage;Failure=(Get-OpsFailureSummary $_);Complete=$false}}
    throw "App Service diagnosis stopped at $stage. See log: $path"
} finally {
    if ($writer) {$writer.Dispose()} elseif ($stream) {$stream.Dispose()}
    if ($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
$result | ConvertTo-Json -Depth 20
if (-not $result.Complete) {throw "App Service diagnosis is incomplete. Inspect successful and failed sections in: $path"}
