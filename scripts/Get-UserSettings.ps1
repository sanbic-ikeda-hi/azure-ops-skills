#requires -Version 7.2
# Read-only local discovery. No Azure connection, certificate lookup or implicit save.
[CmdletBinding()]
param(
    [ValidateSet('Read','Setup','RegisterComputer')][string]$Purpose='Read',
    [ValidateNotNullOrEmpty()][string]$Alias,
    [ValidateSet('LogicApps','Functions','AppServiceFixture','WebAppTest','FunctionsTest')][string]$SandboxName
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$settings = Read-OpsUserSettings
$connectionPath = Join-Path (Get-OpsLocalDirectory) 'connection.json'
$connection = if (Test-Path -LiteralPath $connectionPath -PathType Leaf) { Read-OpsConnection $connectionPath } else { $null }
$basic = Get-OpsEffectiveBasic $settings $connection
$required = @('tenantId','sandboxSubscriptionId')
if ($Purpose -eq 'RegisterComputer') { $required += 'applicationId' }
$missing = @($required | Where-Object { -not $basic.ContainsKey($_) } | ForEach-Object { "basic.$_" })
if ($Purpose -eq 'Read' -and -not $connection) { $missing += 'connection.json (user-run setup or computer registration)' }
$targets = @(if ($Alias) { Resolve-OpsRegisteredTarget $settings $Alias } else { $settings.targets })
$sandbox = @{}
if ($SandboxName) {
    if ($settings.sandbox.Contains($SandboxName)) { $sandbox = $settings.sandbox[$SandboxName] }
    $missing += @(Get-OpsSandboxFields $SandboxName | Where-Object { -not $sandbox.Contains($_) } | ForEach-Object { "sandbox.$SandboxName.$_" })
}
[ordered]@{
    SchemaVersion=1; Basic=$basic; ConnectionPresent=[bool]$connection
    MissingFields=$missing; Targets=$targets; TargetAmbiguous=($targets.Count -gt 1)
    Sandbox=$sandbox; Source='LocalSettings'; AzureVerified=$false
} | ConvertTo-Json -Depth 12
