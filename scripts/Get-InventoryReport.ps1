#requires -Version 7.2
# Read a saved, allowlisted inventory report. No profile, certificate or Azure connection is used.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [ValidateRange(0,2147483647)][int]$Skip = 0,
    [ValidateRange(1,1000)][int]$Limit = 20
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$report = Read-OpsInventoryReport -Path $Path
Get-OpsInventorySummary -Report $report -Skip $Skip -Limit $Limit -Source SavedReport -ReportPath ([IO.Path]::GetFullPath($Path)) |
    ConvertTo-Json -Depth 8 -Compress
