#requires -Version 7.2
# Plan by default. Execute requires a fresh reviewed plan and the same explicit target/operation/value.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][ValidateSet('Start','Stop','Restart','Enable','Disable','SetHttpsOnly','SetPublicNetworkAccess','SetClientAffinity','SetFlexMaximumInstanceCount')][string]$Operation,
    [string]$Value='',
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ReviewedPlanPath,
    [switch]$Execute,
    [string]$ConnectionPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ServiceOperations.ps1')
$connection=if ($ConnectionPath) {Read-OpsConnection $ConnectionPath} else {Read-OpsConnection}
$config=Select-OpsSubscription $connection $SubscriptionId
Assert-OpsServiceId $ResourceId $config
$reportPath=Resolve-OpsInventoryOutputPath $OutputPath
$reviewed=$null
if ($Execute) {
    if (-not $ReviewedPlanPath -or -not [IO.Path]::IsPathFullyQualified($ReviewedPlanPath)) {throw 'Execute requires an absolute reviewed plan path.'}
    if ((Get-Item -LiteralPath $ReviewedPlanPath -ErrorAction Stop).Length -gt 131072) {throw 'Reviewed plan is too large.'}
    try {$reviewed=Get-Content -LiteralPath $ReviewedPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable}
    catch {throw 'Cannot read the reviewed plan. Contents omitted.'}
} elseif ($ReviewedPlanPath) {throw 'ReviewedPlanPath is used only with Execute.'}
$connected=$false;$stream=$null;$writer=$null
$result=[ordered]@{Schema='AzureOpsOperationResult/1';Source='Live';ResourceId=$ResourceId;Operation=$Operation;Stage='Preflight';Succeeded=$false;MutationSubmitted=$false;Failure=$null}
function Save-OperationRecord {
    # Persist stage before the write. A killed process leaves an explicit in-progress record.
    $writer.Flush();$stream.Position=0;$stream.SetLength(0)
    $writer.Write(($result | ConvertTo-Json -Depth 25));$writer.Flush()
}
try {
    # Reserve a new result before connecting or mutating. Never overwrite evidence.
    $stream=[IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    Save-OperationRecord
    Connect-OpsApplication $config
    $connected=$true
    $item=Get-OpsServiceResource $config $ResourceId
    $plan=New-OpsOperationPlan $config $item $Operation $Value
    if (-not $Execute) {
        $writer.Flush();$stream.Position=0;$stream.SetLength(0)
        $writer.Write(($plan | ConvertTo-Json -Depth 20));$writer.Flush()
        $plan | ConvertTo-Json -Depth 20
        return
    }
    Assert-OpsReviewedPlan $reviewed $plan
    $result['Plan']=$plan
    # A second GET immediately before submission catches drift during preflight.
    $fresh=Get-OpsServiceResource $config $ResourceId
    $current=New-OpsOperationPlan $config $fresh $Operation $Value
    Assert-OpsReviewedPlan $reviewed $current
    $spec=Get-OpsOperationSpec $fresh $Operation $Value
    if ($Operation -ne 'Restart' -and $spec.Before[$spec.Field] -eq $spec.Desired) {
        $result.Stage='AlreadyDesired';$result.Succeeded=$true;$result['After']=$spec.Before
    } else {
        $result.Stage='Submitting';$result.MutationSubmitted=$true
        Save-OperationRecord
        $result['HttpStatus']=Invoke-OpsServiceRequest $config ($ResourceId+$spec.Suffix) $spec.Method $spec.Body
        $result.Stage='Verifying'
        $after=$null
        for ($attempt=0;$attempt -lt 12;$attempt++) {
            $after=Get-OpsServiceSnapshot (Get-OpsServiceResource $config $ResourceId)
            if ($after[$spec.Field] -eq $spec.Desired) {break}
            if ($attempt -lt 11) {Start-Sleep -Seconds 5}
        }
        Assert-OpsOperationResult $spec.Before $after $spec
        $result['After']=$after;$result.Stage='Verified';$result.Succeeded=$true
    }
    $result['Verification']=if ($Operation -eq 'Restart') {'Restart request accepted and ARM state observed. Process restart and host health not verified.'} else {'ARM management state verified. Application and trigger health not tested.'}
} catch {
    # Our own errors are bounded; do not persist arbitrary exception/ARM message text.
    $result.Failure='Operation stopped. Inspect scope, reviewed plan and current state; no retry or rollback was performed.'
    $result['FailureDetails']=Get-OpsFailureSummary $_
    $result['HttpStatus']=$result.FailureDetails.HttpStatus
    throw "Operation stopped at $($result.Stage). See result: $reportPath"
} finally {
    if ($writer) {
        try {
            if ($Execute -or $result.Failure) {
                $result['RecordedAtUtc']=[DateTime]::UtcNow.ToString('o')
                Save-OperationRecord
            }
        } finally {$writer.Dispose()}
    } elseif ($stream) {$stream.Dispose()}
    if ($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
$result | ConvertTo-Json -Depth 25
