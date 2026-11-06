#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('AppService','Functions','LogicApps')][string]$Service,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ConnectionPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = if ($ConnectionPath) { Read-OpsConnection $ConnectionPath } else { Read-OpsConnection }
$config = Select-OpsSubscription $config $SubscriptionId
$connected = $false
try {
    Connect-OpsApplication $config
    $connected = $true
    $collections = @(
        @{Path="/subscriptions/$($config.subscriptionId)/providers/Microsoft.Web/sites"; Version='2024-11-01'}
    )
    if ($Service -eq 'LogicApps') {
        $collections += @{Path="/subscriptions/$($config.subscriptionId)/providers/Microsoft.Logic/workflows"; Version='2019-05-01'}
    }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($collection in $collections) {
        $path = "$($collection.Path)?api-version=$($collection.Version)"
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        do {
            if (-not $seen.Add($path)) { throw '継続リンクが循環しているため停止しました。' }
            Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
            $response = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction Stop
            if ($response.StatusCode -ne 200) {
                throw "取得失敗 HTTP $($response.StatusCode)。空一覧として扱いません。"
            }
            $page = $response.Content | ConvertFrom-Json -AsHashtable
            if (-not $page.ContainsKey('value')) { throw '一覧APIの応答形式が想定と異なります。' }
            foreach ($resource in $page.value) {
                $kind = [string]$resource['kind']
                if ((Get-OpsServiceKind ([string]$resource['type']) $kind) -eq $Service) {
                    $rows.Add((ConvertTo-OpsInventoryRow $resource))
                }
            }
            $path = if ($page['nextLink']) { Get-OpsNextPath $page.nextLink $collection.Path } else { $null }
        } while ($path)
    }
    [pscustomobject][ordered]@{
        RetrievedAtUtc=[DateTime]::UtcNow.ToString('o')
        TenantId=$config.tenantId
        SubscriptionId=$config.subscriptionId
        ApplicationId=$config.applicationId
        Service=$Service
        Complete=$true
        Count=$rows.Count
        Resources=$rows.ToArray()
    } | ConvertTo-Json -Depth 8
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
