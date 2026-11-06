#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateCount(1,20)][string[]]$ResourceId,
    [ValidateSet('Overview','Runtime','Network','Identity','Plan','Structure')][string[]]$Section=@('Overview'),
    [ValidateRange(1,100)][int]$Limit=20,
    [string]$ConnectionPath,
    [string]$OutputPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ServiceOperations.ps1')
$connection=if ($ConnectionPath) {Read-OpsConnection $ConnectionPath} else {Read-OpsConnection}
$config=Select-OpsSubscription $connection $SubscriptionId
foreach ($id in $ResourceId) {Assert-OpsServiceId $id $config}
$path=if ($OutputPath) {Resolve-OpsInventoryOutputPath $OutputPath} else {$null}
$connected=$false
try {
    Connect-OpsApplication $config
    $connected=$true
    $plans=@{};$rows=@()
    foreach ($id in @($ResourceId | Select-Object -Unique)) {
        $item=Get-OpsServiceResource $config $id
        $p=$item['properties'];$web=@{};$plan=$null
        if ($item['type'] -ieq 'Microsoft.Web/sites' -and ('Network' -in $Section -or ('Runtime' -in $Section -and -not $p['functionAppConfig']))) {
            $web=(Invoke-OpsServiceRequest $config "$id/config/web")['properties']
        }
        if ('Plan' -in $Section -and $p['serverFarmId']) {
            $planId=[string]$p['serverFarmId']
            Assert-OpsResourceScope $planId $config.subscriptionId
            if ($planId -notmatch '/providers/Microsoft\.Web/serverfarms/[^/]+$') {throw 'Unexpected plan association.'}
            if (-not $plans.ContainsKey($planId)) {
                $plans[$planId]=Invoke-OpsServiceRequest $config $planId
                if ($plans[$planId]['type'] -ine 'Microsoft.Web/serverfarms') {throw 'Unexpected plan resource type.'}
            }
            $plan=$plans[$planId]
        }
        $rows+=ConvertTo-OpsServiceDetail $item $Section $web $plan $Limit
    }
    $result=[ordered]@{Schema='AzureOpsServiceDetails/1';Source='Live';RetrievedAtUtc=[DateTime]::UtcNow.ToString('o');TenantId=$config.tenantId;SubscriptionId=$config.subscriptionId;Sections=$Section;Complete=$true;Count=$rows.Count;Resources=$rows}
    if ($path) {Write-OpsInventoryReport -Path $path -Report $result}
    $result | ConvertTo-Json -Depth 20
} finally {if ($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}}
