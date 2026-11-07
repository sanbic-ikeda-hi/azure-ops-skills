#requires -Version 7.2
# Offline: isolated TEMP files and dummy IDs; never reads the real user's profile or Azure.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$checks=0
function Verify-Settings { param([bool]$Condition,[string]$Message) if (-not $Condition) {throw "FAIL: $Message"}; $script:checks++ }
function Reject-Settings { param([scriptblock]$Action,[string]$Message) $failed=$false; try { & $Action | Out-Null } catch {$failed=$true}; Verify-Settings $failed $Message }
$originalLocalAppData=$env:LOCALAPPDATA
$fixtureRoot=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('azureops-settings-' + [guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=$fixtureRoot
try {
    $directory=Get-OpsLocalDirectory
    $path=Join-Path $directory 'user-settings.json'
    $connectionPath=Join-Path $directory 'connection.json'
    $sub='11111111-1111-1111-1111-111111111111'
    $production='22222222-2222-2222-2222-222222222222'
    $tenant='33333333-3333-3333-3333-333333333333'
    $application='44444444-4444-4444-4444-444444444444'
    $outside='55555555-5555-5555-5555-555555555555'
    $resource="/subscriptions/$sub/resourceGroups/test-rg/providers/Microsoft.Web/sites/test-app"
    $plan="/subscriptions/$sub/resourceGroups/test-rg/providers/Microsoft.Web/serverfarms/test-plan"
    $status=& (Join-Path $PSScriptRoot 'Get-UserSettings.ps1') -Purpose RegisterComputer | ConvertFrom-Json -AsHashtable
    Verify-Settings ($status.MissingFields.Count -eq 3 -and -not $status.ConnectionPresent) 'Missing inputs are reported without Azure or generated IDs'
    Verify-Settings (-not (Test-Path -LiteralPath $directory)) 'Read-only discovery creates no files'
    Reject-Settings {Resolve-OpsSetupBasic -Values @{} -NonInteractive} 'Non-interactive setup rejects missing inputs'
    Verify-Settings (-not (Test-Path -LiteralPath $directory)) 'Missing non-interactive setup does not save'
    Write-OpsUserSettings @{basic=@{tenantId=$tenant}} | Out-Null
    Verify-Settings ((Read-OpsUserSettings).basic.tenantId -eq $tenant) 'Partial input survives reload'
    Write-OpsUserSettings @{basic=@{sandboxSubscriptionId=$sub;productionSubscriptionId=$production}} | Out-Null
    Verify-Settings ((Read-OpsUserSettings).basic.tenantId -eq $tenant) 'Partial update preserves earlier values'
    $connection=@{tenantId=$tenant;subscriptionIds=@($sub,$production);sandboxSubscriptionId=$sub;applicationId=$application;servicePrincipalObjectId=$application;certificateThumbprint=('A'*40)}
    $connection | ConvertTo-Json | Set-Content -LiteralPath $connectionPath -Encoding utf8
    $connectionBefore=Get-Content -LiteralPath $connectionPath -Raw
    $status=& (Join-Path $PSScriptRoot 'Get-UserSettings.ps1') | ConvertFrom-Json -AsHashtable
    Verify-Settings ($status.Basic.applicationId -eq $application -and $status.MissingFields.Count -eq 0 -and -not $status.AzureVerified) 'Existing connection supplies IDs without claiming live verification'
    Verify-Settings (-not (Read-OpsUserSettings).basic.Contains('applicationId')) 'Discovery does not duplicate generated connection data'
    $before=Get-Content -LiteralPath $path -Raw
    foreach ($patch in @(@{password='test-only'},@{basic=@{tenantId=$outside}},@{basic=@{productionSubscriptionId=$outside}},@{basic=@{sandboxSubscriptionId=$production}},@{schemaVersion=2},@{basic=@{tenantId='invalid'}})) {
        Reject-Settings {Write-OpsUserSettings $patch} 'Invalid, secret-like or conflicting update rejected'
        Verify-Settings ((Get-Content -LiteralPath $path -Raw) -ceq $before) 'Rejected update preserves existing bytes'
    }
    $target=@{alias='orders';kind='Resource';service='AppService';resourceId=$resource;planResourceId=$plan;location='westus3'}
    Write-OpsUserSettings @{targets=@($target)} | Out-Null
    $other=$target.Clone(); $other.alias='orders-west'
    Write-OpsUserSettings @{targets=@($other)} | Out-Null
    $settings=Read-OpsUserSettings
    Verify-Settings (@(Resolve-OpsRegisteredTarget $settings 'orders').Count -eq 1) 'Exact alias takes priority over partial matches'
    Verify-Settings (@(Resolve-OpsRegisteredTarget $settings 'order').Count -eq 2) 'Ambiguous aliases return both candidates'
    Verify-Settings (@(Resolve-OpsRegisteredTarget $settings 'missing').Count -eq 0) 'Unknown alias never selects a default'
    $badTarget=$target.Clone(); $badTarget.alias='ORDERS'
    Reject-Settings {Write-OpsUserSettings @{targets=@($target,$badTarget)}} 'Duplicate aliases rejected within a patch'
    $badTarget=$target.Clone(); $badTarget.resourceId=$resource.Replace($sub,$outside)
    Reject-Settings {Write-OpsUserSettings @{targets=@($badTarget)}} 'Unauthorized target subscription rejected'
    $badTarget=$target.Clone(); $badTarget.kind='ResourceGroup'
    Reject-Settings {Write-OpsUserSettings @{targets=@($badTarget)}} 'Resource target cannot masquerade as a resource group'
    $badTarget=$target.Clone(); $badTarget.resourceId += '?secret=test'
    Reject-Settings {Write-OpsUserSettings @{targets=@($badTarget)}} 'URLs and query strings cannot be saved as resource IDs'
    $before=Get-Content -LiteralPath $path -Raw
    & {
        function Complete-OpsUserSettingsWrite {throw 'Simulated atomic replacement failure'}
        Reject-Settings {Write-OpsUserSettings @{basic=@{displayName='test-app'}}} 'Save failure is surfaced'
    }
    Verify-Settings ((Get-Content -LiteralPath $path -Raw) -ceq $before) 'Failed replacement preserves the original file'
    Verify-Settings (@(Get-ChildItem -LiteralPath $directory -File | Where-Object Name -notin @('connection.json','user-settings.json','user-settings.json.lock')).Count -eq 0) 'Staging file is removed after failure'
    Write-OpsUserSettings @{sandbox=@{LogicApps=@{resourceGroupName='test-rg';workflowName='test-workflow';location='westus3'}}} | Out-Null
    $resolved=Resolve-OpsSandboxSettings -Name LogicApps -Values @{location='centralus'} -Connection $connection
    Verify-Settings ($resolved.location -eq 'centralus' -and $resolved.workflowName -eq 'test-workflow') 'Explicit values override saved test conditions'
    Reject-Settings {Resolve-OpsSandboxSettings -Name LogicApps -Values @{} -Connection $connection -ExplicitOnly} 'Destructive workflow cannot resolve saved targets'
    Reject-Settings {Write-OpsUserSettings @{sandbox=@{WebAppTest=@{resourceId=$resource.Replace($sub,$production)}}}} 'Sandbox settings cannot identify production'
    $before=Get-Content -LiteralPath $path -Raw
    & (Join-Path $PSScriptRoot 'Set-UserSettings.ps1') -Json '{"basic":{"displayName":"preview"}}' -WhatIf | Out-Null
    Verify-Settings ((Get-Content -LiteralPath $path -Raw) -ceq $before) 'Setter WhatIf makes no change'
    Verify-Settings ((Get-Content -LiteralPath $connectionPath -Raw) -ceq $connectionBefore) 'User settings never alter connection permissions'
    $settings.basic.tenantId=$outside
    $settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8
    Reject-Settings {& (Join-Path $PSScriptRoot 'Get-UserSettings.ps1')} 'A manually conflicting profile is rejected on discovery'
    # Old connection alone still supports discovery and explicit operations.
    $env:LOCALAPPDATA=Join-Path $fixtureRoot 'legacy'
    $legacyDirectory=Get-OpsLocalDirectory
    New-Item -ItemType Directory -Path $legacyDirectory | Out-Null
    $connection | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyDirectory 'connection.json') -Encoding utf8
    $status=& (Join-Path $PSScriptRoot 'Get-UserSettings.ps1') | ConvertFrom-Json -AsHashtable
    Verify-Settings ($status.ConnectionPresent -and $status.MissingFields.Count -eq 0) 'Old connection works without user-settings.json'
    Reject-Settings {& (Join-Path $PSScriptRoot 'Initialize-AzureOps.ps1') -NonInteractive} 'Existing setup stops before creating anything'
    $env:LOCALAPPDATA=Join-Path $fixtureRoot 'checkpoint'
    New-Item -ItemType Directory -Path (Get-OpsLocalDirectory) | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path (Get-OpsLocalDirectory) 'provision-state.json') -Encoding utf8
    Reject-Settings {& (Join-Path $PSScriptRoot 'Register-Computer.ps1') -NonInteractive} 'Partial setup is not silently replaced by computer registration'
    $env:LOCALAPPDATA=Join-Path $fixtureRoot 'bootstrap'
    & {
        function Read-Host {throw 'Non-interactive mode must not prompt'}
        $resolved=Resolve-OpsSetupBasic -Values @{tenantId=$tenant;sandboxSubscriptionId=$sub;displayName='test-registration'} -NonInteractive 6>$null
        Verify-Settings ($resolved.tenantId -eq $tenant -and (Read-OpsUserSettings).basic.displayName -eq 'test-registration') 'Explicit complete setup inputs are saved before Azure'
        $resolved=Resolve-OpsSetupBasic -Values @{applicationId=$application} -RegisterComputer -NonInteractive 6>$null
        Verify-Settings ($resolved.sandboxSubscriptionId -eq $sub -and $resolved.applicationId -eq $application) 'Computer registration reuses saved basic values'
        Reject-Settings {Resolve-OpsSetupBasic -Values @{} -NonInteractive} 'An existing app is never recreated as a new app'
    }
    Reject-Settings {Write-OpsUserSettings @{basic=@{tenantId=$tenant}} -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'user-settings.json')} 'Settings cannot be written into the repository'
} finally {
    $env:LOCALAPPDATA=$originalLocalAppData
    $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not ([IO.Path]::GetFullPath($fixtureRoot)).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $fixtureRoot -Leaf) -notmatch '^azureops-settings-[0-9a-f]{32}$') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
Write-Host "PASS: $checks user-settings checks (offline; isolated dummy data)."
