#requires -Version 7.2
# Explicit read-only verification; never restarts, deploys or changes configuration.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SubscriptionId,[Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][ValidatePattern('^/[A-Za-z0-9/_-]*$')][string]$HealthPath,
    [Parameter(Mandatory)][string]$OutputPath,[string]$ConnectionPath,
    [ValidateRange(1,1800)][int]$OverallSeconds=300,[ValidateRange(1,120)][int]$RequestSeconds=10,
    [ValidateRange(1,60)][int]$IntervalSeconds=5,[ValidateRange(1,10)][int]$ConsecutiveSuccesses=2,
    [ValidateRange(200,299)][int]$ExpectedStatus=200,[string]$ExpectedJsonStatus='',
    [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'AppServiceDiagnostics.ps1')
. (Join-Path $PSScriptRoot 'AppServiceReadiness.ps1')
$connection=if($ConnectionPath){Read-OpsConnection $ConnectionPath}else{Read-OpsConnection}
$config=Select-OpsSubscription $connection $SubscriptionId
Assert-OpsServiceId $ResourceId $config
if($HealthPath.StartsWith('//') -or $HealthPath.Contains('..')){throw 'Invalid health path.'}
$path=Resolve-OpsInventoryOutputPath $OutputPath
$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
$writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false));$connected=$false
function Write-Readiness($data){$writer.WriteLine((@{Schema='AzureOpsReadiness/1';ResourceId=$ResourceId;AtUtc=[DateTime]::UtcNow.ToString('o');Data=$data}|ConvertTo-Json -Depth 12 -Compress));$writer.Flush()}
try {
    Write-Readiness @{Stage='Begin';ChangesAzure=$false;OverallSeconds=$OverallSeconds;RequestSeconds=$RequestSeconds;IntervalSeconds=$IntervalSeconds;ConsecutiveSuccesses=$ConsecutiveSuccesses}
    Connect-OpsApplication $config;$connected=$true
    $site=Get-OpsServiceResource $config $ResourceId
    if((Get-OpsServiceKind $site['type'] ([string]$site['kind'])) -ne 'AppService'){throw 'Select an App Service Web App.'}
    if($site.properties['enabled'] -ne $true -or $site.properties['state'] -ne 'Running'){throw 'Management state is not running and enabled.'}
    $hosts=Get-OpsAppServiceEndpoints $site
    Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
    $result=Wait-OpsAppServiceReady -Uri ("https://"+$hosts.MainHost+$HealthPath) -OverallSeconds $OverallSeconds -RequestSeconds $RequestSeconds -IntervalSeconds $IntervalSeconds -ConsecutiveSuccesses $ConsecutiveSuccesses -ExpectedStatus $ExpectedStatus -ExpectedJsonStatus $ExpectedJsonStatus -CancellationToken $CancellationToken -Record {param($e) Write-Readiness $e}
    Write-Readiness @{Stage='Completed';Result=$result}
    if(-not $result.ReadyObserved){throw 'Readiness not observed.'}
}catch{Write-Readiness @{Stage='Failed';Failure=(Get-OpsFailureSummary $_)};throw "Readiness check stopped. See: $path"}
finally{if($connected){Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue|Out-Null};$writer.Dispose()}
