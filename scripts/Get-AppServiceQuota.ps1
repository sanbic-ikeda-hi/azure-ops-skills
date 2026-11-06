#requires -Version 7.2
# USER-RUN ONLY. Explicit user sign-in for quota inspection; GET only, no role changes.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [ValidateCount(1,10)][ValidatePattern('^[a-z0-9]+$')]
    [string[]]$Location=@('eastus','westus2','centralus','northeurope','westeurope','southeastasia'),
    [switch]$Plan
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$config=Select-OpsSubscription (Read-OpsConnection) $SubscriptionId
$locations=@($Location | Select-Object -Unique)
if ($Plan) {
    [pscustomobject]@{TenantId=$config.tenantId;SubscriptionId=$config.subscriptionId;Locations=$locations;AccountType='User';Method='GET';ChangesResourcesOrPermissions=$false} | ConvertTo-Json
    return
}
Import-Module Az.Accounts -ErrorAction Stop
$connected=$false
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $config.tenantId -Subscription $config.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected=$true
    Assert-OpsContext (Get-AzContext) $config 'User'
    $regions=[Collections.Generic.List[object]]::new()
    foreach ($region in $locations) {
        $collection="/subscriptions/$($config.subscriptionId)/providers/Microsoft.Web/locations/$region/usages"
        $path="${collection}?api-version=2025-05-01"
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $rows=[Collections.Generic.List[object]]::new()
        do {
            if (-not $seen.Add($path)) {throw 'Quota pagination loop. No complete result will be emitted.'}
            Assert-OpsContext (Get-AzContext) $config 'User'
            $response=Invoke-AzRestMethod -Path $path -Method GET -ErrorAction Stop
            if ($response.StatusCode -ne 200) {throw "Quota read failed in ${region}: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)"}
            $page=$response.Content | ConvertFrom-Json -AsHashtable
            if ($page -isnot [System.Collections.IDictionary] -or $page['value'] -isnot [array]) {throw 'Unexpected quota collection. Do not treat it as zero usage.'}
            foreach ($item in $page.value) {
                if ($item -isnot [System.Collections.IDictionary] -or $item['name'] -isnot [System.Collections.IDictionary] -or
                    [string]::IsNullOrWhiteSpace([string]$item.name['value']) -or
                    $item['currentValue'] -isnot [ValueType] -or $item['limit'] -isnot [ValueType]) {throw 'Incomplete quota entry.'}
                $used=0L; $limit=0L
                if (-not [long]::TryParse([string]$item.currentValue,[ref]$used) -or -not [long]::TryParse([string]$item.limit,[ref]$limit) -or $used -lt 0) {throw 'Invalid quota counters.'}
                $rows.Add([pscustomobject]@{
                    Name=[string]$item.name.value; Unit=[string]$item['unit']; Used=$used; Limit=$limit
                    Remaining=$(if ($limit -ge 0) {[decimal]$limit-[decimal]$used} else {$null})
                })
            }
            $path=if ($page['nextLink']) {Get-OpsNextPath $page.nextLink $collection} else {$null}
        } while ($path)
        $regions.Add([pscustomobject]@{Location=$region;HasQuotaData=($rows.Count -gt 0);Quotas=$rows.ToArray()})
    }
    [pscustomobject][ordered]@{
        RetrievedAtUtc=[DateTime]::UtcNow.ToString('o');SubscriptionId=$config.subscriptionId
        Complete=$true;Regions=$regions.ToArray()
        Note='Reported quotas only. Missing SKU data is unknown, not zero or unlimited. Positive quota does not guarantee regional capacity or creation.'
    } | ConvertTo-Json -Depth 8
} finally {
    if ($connected) {Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null}
}
