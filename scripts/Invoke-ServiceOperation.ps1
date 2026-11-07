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
    [switch]$Verify,
    [string]$ConnectionPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ServiceOperations.ps1')
$connection=if ($ConnectionPath) {Read-OpsConnection $ConnectionPath} else {Read-OpsConnection}
$config=Select-OpsSubscription $connection $SubscriptionId
Assert-OpsServiceId $ResourceId $config
$reportPath=Resolve-OpsInventoryOutputPath $OutputPath
$reviewed=$null
if ($Execute -and $Verify) {throw 'Choose Execute or read-only Verify.'}
if ($Execute -or $Verify) {
    if (-not $ReviewedPlanPath -or -not [IO.Path]::IsPathFullyQualified($ReviewedPlanPath)) {throw 'Execute requires an absolute reviewed plan path.'}
    if ((Get-Item -LiteralPath $ReviewedPlanPath -ErrorAction Stop).Length -gt 131072) {throw 'Reviewed plan is too large.'}
    try {$reviewed=Get-Content -LiteralPath $ReviewedPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable}
    catch {throw 'Cannot read the reviewed plan. Contents omitted.'}
} elseif ($ReviewedPlanPath) {throw 'ReviewedPlanPath requires Execute or Verify.'}
$connected=$false;$stream=$null;$writer=$null
$result=[ordered]@{Schema='AzureOpsOperationResult/1';Source='Live';ResourceId=$ResourceId;Operation=$Operation;Stage='Preflight';Succeeded=$false;MutationSubmitted=$false;Failure=$null}
$result['Events']=@()
function Add-OperationEvent([string]$Stage,[Collections.IDictionary]$Data) {
    $result.Events+=@{AtUtc=[DateTime]::UtcNow.ToString('o');Stage=$Stage;Data=$Data}
    Save-OperationRecord
}
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
    if($Verify){
        if($reviewed['Schema'] -ne 'AzureOpsOperationPlan/1' -or $reviewed['Source'] -ne 'Live' -or
            $reviewed['TenantId'] -ine $config.tenantId -or $reviewed['SubscriptionId'] -ine $config.subscriptionId -or
            $reviewed['ApplicationId'] -ine $config.applicationId -or
            (ConvertTo-OpsArmId $reviewed['ResourceId']) -cne (ConvertTo-OpsArmId $ResourceId) -or
            $reviewed['Operation'] -cne $Operation -or $reviewed['Value'] -cne $Value){throw 'Verification baseline mismatch.'}
        $result.Stage='Verifying';$result['Plan']=$reviewed
        $after=Get-OpsServiceSnapshot $item
        if($reviewed['ExpectedAfter'] -isnot [Collections.IDictionary]){throw 'This older plan lacks ExpectedAfter. Inspect manually; do not resubmit.'}
        $expected=$reviewed.ExpectedAfter|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable
        $actual=$after|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable
        $expected.Remove('provisioningState');$actual.Remove('provisioningState')
        $differences=@(Get-OpsConfigurationDifference $expected $actual)
        if($differences.Count){$result['DifferentProperties']=$differences;throw 'Verification differs from original expected state.'}
        $result['After']=$after;$result.Stage='Verified';$result.Succeeded=$true
        $result['Verification']='Read-only comparison against original plan. Application, sign-in and process restart not verified.'
        Add-OperationEvent 'ReadOnlyVerification' @{MutationSubmitted=$false}
        return
    }
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
        Add-OperationEvent 'MutationAttempted' @{AcceptanceObserved=$false}
        $result['HttpStatus']=Invoke-OpsServiceRequest $config ($ResourceId+$spec.Suffix) $spec.Method $spec.Body
        Add-OperationEvent 'RequestAccepted' @{HttpStatus=$result.HttpStatus}
        $result.Stage='Verifying'
        $after=$null
        for ($attempt=0;$attempt -lt 12;$attempt++) {
            $after=Get-OpsServiceSnapshot (Get-OpsServiceResource $config $ResourceId)
            Add-OperationEvent 'ManagementObserved' @{Attempt=($attempt+1);State=$after['state'];ApplicationReadyVerified=$false}
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
    $ex=$_.Exception.GetBaseException()
    if($ex.Data.Contains('DifferentProperties')){$result['DifferentProperties']=@($ex.Data['DifferentProperties'])}
    $result['AcceptanceObserved']=@($result.Events|Where-Object Stage -eq 'RequestAccepted').Count -gt 0
    $result['HttpStatus']=$result.FailureDetails.HttpStatus
    throw "Operation stopped at $($result.Stage). See result: $reportPath"
} finally {
    if ($writer) {
        try {
            if ($Execute -or $Verify -or $result.Failure) {
                $result['RecordedAtUtc']=[DateTime]::UtcNow.ToString('o')
                Save-OperationRecord
            }
        } finally {$writer.Dispose()}
    } elseif ($stream) {$stream.Dispose()}
    if ($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
$result | ConvertTo-Json -Depth 25
