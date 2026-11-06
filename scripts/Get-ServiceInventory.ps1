#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('AppService','Functions','LogicApps','All')][string]$Service,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ConnectionPath,
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })][string]$Keyword,
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) })][string]$ResourceGroupName,
    [ValidateSet('Full','Summary')][string]$OutputMode = 'Full',
    [ValidateRange(1,1000)][int]$Limit = 20,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = if ($ConnectionPath) { Read-OpsConnection $ConnectionPath } else { Read-OpsConnection }
$config = Select-OpsSubscription $config $SubscriptionId
$reportPath = if ($OutputPath) { Resolve-OpsInventoryOutputPath $OutputPath } else { $null }
# Full retains the legacy subscription-wide TotalCount, including when an RG filter is supplied.
$scopeId = "/subscriptions/$($config.subscriptionId)"
$scopeKind = 'Subscription'
if ($OutputMode -eq 'Summary' -and $ResourceGroupName) {
    if ($ResourceGroupName.Length -gt 90 -or $ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]+$' -or $ResourceGroupName.EndsWith('.')) {
        throw 'A valid resource group name is required for a scoped request.'
    }
    $scopeId += "/resourceGroups/$ResourceGroupName"
    $scopeKind = 'ResourceGroup'
}
$requestScope = if ($scopeKind -eq 'ResourceGroup') {
    "/subscriptions/$($config.subscriptionId)/resourceGroups/$([uri]::EscapeDataString($ResourceGroupName))"
} else { $scopeId }
$connected = $false
try {
    Connect-OpsApplication $config
    $connected = $true
    $collections = @(
        @{Path="$requestScope/providers/Microsoft.Web/sites"; Version='2024-11-01'}
    )
    if ($Service -in @('LogicApps','All')) {
        $collections += @{Path="$requestScope/providers/Microsoft.Logic/workflows"; Version='2019-05-01'}
    }
    $rows = [Collections.Generic.List[object]]::new()
    $resourceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($collection in $collections) {
        $path = "$($collection.Path)?api-version=$($collection.Version)"
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        do {
            if (-not $seen.Add($path)) { throw '継続リンクが循環しているため停止しました。' }
            Assert-OpsContext (Get-AzContext) $config 'ServicePrincipal'
            try { $response = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction Stop }
            catch { throw 'Inventory GET failed. No complete result is available; response details are omitted.' }
            if ($response.StatusCode -ne 200) {
                throw "取得失敗 HTTP $($response.StatusCode)。空一覧として扱いません。"
            }
            try { $page = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
            catch { throw 'Invalid inventory JSON response. The response body is omitted.' }
            if ($page -isnot [System.Collections.IDictionary] -or -not $page.ContainsKey('value') -or
                $page.value -isnot [array]) { throw '一覧APIの応答形式が想定と異なります。' }
            foreach ($resource in $page.value) {
                if ($resource -isnot [System.Collections.IDictionary] -or
                    [string]::IsNullOrWhiteSpace([string]$resource['type']) -or
                    [string]::IsNullOrWhiteSpace([string]$resource['id'])) {
                    throw '一覧APIに不正なリソース情報があります。空一覧として扱いません。'
                }
                if ($null -ne $resource['kind'] -and $resource['kind'] -isnot [string]) { throw 'Invalid inventory kind.' }
                $kind = [string]$resource['kind']
                $serviceKind = Get-OpsServiceKind ([string]$resource['type']) $kind
                if ($serviceKind -eq $Service -or ($Service -eq 'All' -and $serviceKind -ne 'Other')) {
                    Assert-OpsResourceScope ([string]$resource['id']) $config.subscriptionId
                    $row = ConvertTo-OpsInventoryRow $resource
                    if ($scopeKind -eq 'ResourceGroup' -and $row.ResourceGroupName -ine $ResourceGroupName) {
                        throw 'The response contains a resource outside the requested resource group.'
                    }
                    if (-not $resourceIds.Add($row.ResourceId)) { throw 'Duplicate inventory resource across pages.' }
                    $rows.Add($row)
                }
            }
            $path = if ($page['nextLink']) { Get-OpsNextPath $page.nextLink $collection.Path } else { $null }
        } while ($path)
    }
    $selectedRows = @(Select-OpsInventoryResource -Resources $rows.ToArray() -Keyword $Keyword -ResourceGroupName $ResourceGroupName)
    $result = [ordered]@{
        RetrievedAtUtc=[DateTime]::UtcNow.ToString('o')
        TenantId=$config.tenantId
        SubscriptionId=$config.subscriptionId
        ApplicationId=$config.applicationId
        Service=$Service
        Complete=$true
        Filters=[pscustomobject]@{Keyword=$Keyword; ResourceGroupName=$ResourceGroupName}
        TotalCount=$rows.Count
        Count=$selectedRows.Count
        Resources=$selectedRows
    }
    $report = [ordered]@{SchemaVersion=1; QueryScope=[ordered]@{Kind=$scopeKind; ResourceId=$scopeId}}
    foreach ($key in $result.Keys) { $report[$key] = $result[$key] }
    if ($reportPath) { Write-OpsInventoryReport -Path $reportPath -Report $report }
    if ($OutputMode -eq 'Summary') {
        Get-OpsInventorySummary -Report $report -Limit $Limit -Source Live -ReportPath $reportPath | ConvertTo-Json -Depth 8 -Compress
    } else {
        [pscustomobject]$result | ConvertTo-Json -Depth 8
    }
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
