#requires -Version 7.2
# Non-secret, per-Windows-user preferences. This file never connects to Azure.
Set-StrictMode -Version Latest

function New-OpsUserSettings {
    @{ schemaVersion=1; basic=@{}; targets=@(); sandbox=@{} }
}

function Assert-OpsSettingsKeys {
    param($Object, [string[]]$Allowed)
    if ($Object -isnot [System.Collections.IDictionary]) { throw 'Settings must be a JSON object.' }
    foreach ($key in $Object.Keys) {
        if ($key -cnotin $Allowed) { throw 'Unsupported settings field. Store non-secret identifiers only.' }
    }
}

function Get-OpsSandboxFields {
    param([string]$Name)
    switch ($Name) {
        LogicApps { @('resourceGroupName','workflowName','location') }
        Functions { @('resourceGroupName','functionAppName','planName','storageAccountName','location') }
        AppServiceFixture { @('resourceGroupName','planName','appName','location','sku') }
        WebAppTest { @('resourceId','planResourceId','peerResourceId','location','operatingSystem','sku') }
        FunctionsTest { @('resourceId','planResourceId','storageResourceId','managedIdentityObjectId','location') }
        default { throw 'Unknown Sandbox scenario.' }
    }
}

function Assert-OpsSettingsValue {
    param([string]$Name, $Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "A non-empty string is required: $Name" }
    switch -Regex ($Name) {
        '^(tenantId|sandboxSubscriptionId|productionSubscriptionId|applicationId|managedIdentityObjectId)$' { Assert-OpsGuid $Value $Name; break }
        '^(resourceId|planResourceId|storageResourceId|peerResourceId)$' {
            if ($Value -notmatch '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/[^/]+') { throw 'A full resource or resource group ID is required.' }
            $subscription = $Matches[1]
            Assert-OpsGuid $subscription
            if ($Value -match '^/subscriptions/[^/]+/resourceGroups/([\p{L}\p{N}_().-]{1,90})$') { Assert-OpsSettingsValue resourceGroupName $Matches[1] }
            else { Assert-OpsResourceScope $Value $subscription }
            if ($Name -eq 'planResourceId' -and $Value -notmatch '/providers/Microsoft\.Web/serverfarms/[^/]+$') { throw 'A full plan ID is required.' }
            if ($Name -eq 'storageResourceId' -and $Value -notmatch '/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}$') { throw 'A full storage account ID is required.' }
            break
        }
        '^location$' { if ($Value -notmatch '^[a-z0-9]{1,40}$') { throw 'Invalid location.' }; break }
        '^operatingSystem$' { if ($Value -cnotin @('Windows','Linux')) { throw 'Unsupported operating system.' }; break }
        '^sku$' { if ($Value -cnotin @('B1','P0v4')) { throw 'Unsupported test SKU.' }; break }
        '^storageAccountName$' { if ($Value -cnotmatch '^[a-z0-9]{3,24}$') { throw 'Invalid storage account name.' }; break }
        '^(appName|functionAppName)$' { if ($Value -cnotmatch '^[a-z0-9][a-z0-9-]{0,58}[a-z0-9]$') { throw 'Invalid app name.' }; break }
        '^(alias|displayName|resourceGroupName|workflowName|planName)$' {
            $maximum=if ($Name -eq 'resourceGroupName') {90} else {80}
            if ($Value.Length -gt $maximum -or $Value -notmatch '^[\p{L}\p{N}_.()-]+$' -or $Value.Contains('..') -or $Value.EndsWith('.')) { throw "Invalid name: $Name" }; break
        }
        default { throw 'Unsupported settings value.' }
    }
}

function Assert-OpsUserSettings {
    param($Settings)
    Assert-OpsSettingsKeys $Settings @('schemaVersion','basic','targets','sandbox')
    foreach ($key in @('schemaVersion','basic','targets','sandbox')) {
        if (-not $Settings.Contains($key)) { throw 'Incomplete settings document.' }
    }
    if ($Settings.schemaVersion -isnot [long] -and $Settings.schemaVersion -isnot [int]) { throw 'Invalid settings schema version.' }
    if ($Settings.schemaVersion -ne 1) { throw 'Unsupported settings schema version.' }
    Assert-OpsSettingsKeys $Settings.basic @('tenantId','sandboxSubscriptionId','productionSubscriptionId','applicationId','displayName')
    foreach ($key in $Settings.basic.Keys) { Assert-OpsSettingsValue $key $Settings.basic[$key] }
    if ($Settings.basic.Contains('sandboxSubscriptionId') -and $Settings.basic.Contains('productionSubscriptionId') -and
        $Settings.basic.sandboxSubscriptionId -ieq $Settings.basic.productionSubscriptionId) { throw 'Sandbox and production must be different.' }
    if ($Settings.targets -isnot [array]) { throw 'targets must be an array.' }
    $aliases = @()
    foreach ($target in $Settings.targets) {
        Assert-OpsSettingsKeys $target @('alias','kind','service','resourceId','location','planResourceId','storageResourceId')
        foreach ($key in @('alias','kind','resourceId')) { if (-not $target.Contains($key)) { throw 'Incomplete registered target.' } }
        if ($target.kind -cnotin @('Resource','ResourceGroup')) { throw 'Unsupported target kind.' }
        if ($target.alias -iin $aliases) { throw 'Duplicate target alias.' }
        $aliases += $target.alias
        foreach ($key in $target.Keys) {
            if ($key -notin @('kind','service')) { Assert-OpsSettingsValue $key $target[$key] }
        }
        $isGroup = $target.resourceId -match '^/subscriptions/[^/]+/resourceGroups/[^/]+$'
        if ($isGroup -ne ($target.kind -ceq 'ResourceGroup')) { throw 'Target kind and ID do not match.' }
        if ($target.kind -ceq 'Resource' -and -not $target.Contains('service')) { throw 'A resource target needs a service.' }
        if ($target.Contains('service') -and $target.service -cnotin @('AppService','Functions','LogicApps')) { throw 'Unsupported target service.' }
        if ($target.Contains('service') -and $target.kind -ceq 'Resource') {
            $expected = if ($target.service -ceq 'LogicApps') { '/providers/(Microsoft\.Web/sites|Microsoft\.Logic/workflows)/' } else { '/providers/Microsoft\.Web/sites/' }
            if ($target.resourceId -notmatch $expected) { throw 'Target service and resource type do not match.' }
        }
    }
    Assert-OpsSettingsKeys $Settings.sandbox @('LogicApps','Functions','AppServiceFixture','WebAppTest','FunctionsTest')
    foreach ($name in $Settings.sandbox.Keys) {
        Assert-OpsSettingsKeys $Settings.sandbox[$name] (Get-OpsSandboxFields $name)
        foreach ($key in $Settings.sandbox[$name].Keys) { Assert-OpsSettingsValue $key $Settings.sandbox[$name][$key] }
    }
}

function Read-OpsUserSettings {
    param([string]$Path = (Join-Path (Get-OpsLocalDirectory) 'user-settings.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return New-OpsUserSettings }
    try { $settings = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
    catch { throw 'Cannot read user-settings.json. Inspect JSON locally; do not share credentials or raw content.' }
    Assert-OpsUserSettings $settings
    return $settings
}

function Assert-OpsUserSettingsConnection {
    param([System.Collections.IDictionary]$Settings, [hashtable]$Connection)
    if (-not $Connection) { return }
    foreach ($key in @('tenantId','sandboxSubscriptionId','applicationId')) {
        if ($Settings.basic.Contains($key) -and $Settings.basic[$key] -ine $Connection[$key]) { throw "Saved settings conflict with connection.json: $key" }
    }
    if ($Settings.basic.Contains('productionSubscriptionId') -and $Settings.basic.productionSubscriptionId -notin $Connection.subscriptionIds) { throw 'Saved production subscription is not allowed by connection.json.' }
    foreach ($target in $Settings.targets) {
        foreach ($key in @('resourceId','planResourceId','storageResourceId')) {
            if ($target.Contains($key)) {
                $subscription = ($target[$key] -split '/')[2]
                if ($subscription -notin $Connection.subscriptionIds) { throw 'Registered target is outside the allowed subscriptions.' }
                if ($key -ne 'resourceId' -and $subscription -ine ($target.resourceId -split '/')[2]) { throw 'Related resources must be in the target subscription.' }
            }
        }
    }
    foreach ($scenario in $Settings.sandbox.Values) {
        foreach ($key in @('resourceId','planResourceId','storageResourceId','peerResourceId')) {
            if ($scenario.Contains($key) -and ($scenario[$key] -split '/')[2] -ine $Connection.sandboxSubscriptionId) { throw 'Sandbox settings must identify the Sandbox subscription.' }
        }
    }
}

function Get-OpsEffectiveBasic {
    param([System.Collections.IDictionary]$Settings, [hashtable]$Connection)
    Assert-OpsUserSettingsConnection $Settings $Connection
    $basic = @{}
    foreach ($key in $Settings.basic.Keys) { $basic[$key] = $Settings.basic[$key] }
    if ($Connection) {
        foreach ($key in @('tenantId','sandboxSubscriptionId','applicationId')) { $basic[$key] = $Connection[$key] }
        $production = @($Connection.subscriptionIds | Where-Object { $_ -ine $Connection.sandboxSubscriptionId })
        if (-not $basic.ContainsKey('productionSubscriptionId') -and $production.Count -eq 1) { $basic.productionSubscriptionId = $production[0] }
    }
    if (-not $basic.ContainsKey('displayName')) { $basic.displayName = 'azure-ops-skills' }
    return $basic
}

function Resolve-OpsRegisteredTarget {
    param([System.Collections.IDictionary]$Settings, [string]$Alias)
    $exact = @($Settings.targets | Where-Object { $_.alias -ieq $Alias })
    if ($exact.Count) { return $exact }
    @($Settings.targets | Where-Object { $_.alias.IndexOf($Alias, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object alias)
}

function Complete-OpsUserSettingsWrite {
    param([string]$TemporaryPath, [string]$Path)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($TemporaryPath, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($TemporaryPath, $Path) }
}

function Write-OpsUserSettings {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Patch,
        [string]$Path = (Join-Path (Get-OpsLocalDirectory) 'user-settings.json'),
        [string]$ConnectionPath = (Join-Path (Split-Path $Path -Parent) 'connection.json')
    )
    Assert-OpsSettingsKeys $Patch @('schemaVersion','basic','targets','sandbox')
    $repository = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFullPath($Path).StartsWith($repository,[StringComparison]::OrdinalIgnoreCase)) { throw 'User settings must be outside the source or installed skill directory.' }
    $directory = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    # Serialize read/merge/replace across skill copies and processes. No authentication data is stored.
    $lock = [IO.File]::Open("$Path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $temporaryPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        $settings = Read-OpsUserSettings $Path
        if ($Patch.Contains('schemaVersion')) { $settings.schemaVersion = $Patch.schemaVersion }
        if ($Patch.Contains('basic')) {
            Assert-OpsSettingsKeys $Patch.basic @('tenantId','sandboxSubscriptionId','productionSubscriptionId','applicationId','displayName')
            foreach ($key in $Patch.basic.Keys) { $settings.basic[$key] = $Patch.basic[$key] }
        }
        if ($Patch.Contains('targets')) {
            if ($Patch.targets -isnot [array]) { throw 'targets must be an array.' }
            $aliases = @()
            foreach ($target in $Patch.targets) {
                if ($target -isnot [System.Collections.IDictionary] -or -not $target.Contains('alias')) { throw 'A target alias is required.' }
                if ($target.alias -iin $aliases) { throw 'Duplicate target alias in update.' }
                $aliases += $target.alias
                $settings.targets = @($settings.targets | Where-Object { $_.alias -ine $target.alias }) + @($target)
            }
        }
        if ($Patch.Contains('sandbox')) {
            Assert-OpsSettingsKeys $Patch.sandbox @('LogicApps','Functions','AppServiceFixture','WebAppTest','FunctionsTest')
            foreach ($name in $Patch.sandbox.Keys) {
                Assert-OpsSettingsKeys $Patch.sandbox[$name] (Get-OpsSandboxFields $name)
                if (-not $settings.sandbox.Contains($name)) { $settings.sandbox[$name] = @{} }
                foreach ($key in $Patch.sandbox[$name].Keys) { $settings.sandbox[$name][$key] = $Patch.sandbox[$name][$key] }
            }
        }
        Assert-OpsUserSettings $settings
        if (Test-Path -LiteralPath $ConnectionPath -PathType Leaf) { Assert-OpsUserSettingsConnection $settings (Read-OpsConnection $ConnectionPath) }
        $json = $settings | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Complete-OpsUserSettingsWrite $temporaryPath $Path
        return $settings
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        $lock.Dispose()
    }
}

function Resolve-OpsSetupBasic {
    param([hashtable]$Values, [switch]$RegisterComputer, [switch]$NonInteractive)
    $settings = Read-OpsUserSettings
    $basic = Get-OpsEffectiveBasic $settings $null
    foreach ($key in $Values.Keys) { if ($Values[$key]) { $basic[$key] = $Values[$key] } }
    $required = @('tenantId','sandboxSubscriptionId')
    if ($RegisterComputer) { $required += 'applicationId' }
    $missing = @($required | Where-Object { -not $basic.ContainsKey($_) })
    if ($NonInteractive -and $missing.Count) { throw "Missing settings: $($missing -join ', '). No Azure operation was started." }
    foreach ($key in $missing) {
        $basic[$key] = Read-Host "Missing setting: $key"
        Assert-OpsSettingsValue $key $basic[$key]
        Write-OpsUserSettings -Patch @{basic=@{$key=$basic[$key]}} | Out-Null
    }
    $validation = New-OpsUserSettings
    $validation.basic = $basic
    Assert-OpsUserSettings $validation
    # A copied profile may identify an existing app. Never recreate it as a new app.
    if (-not $RegisterComputer -and $basic.ContainsKey('applicationId')) { throw 'An existing applicationId is recorded. Use Register-Computer.ps1 or inspect setup recovery.' }
    $basic | ConvertTo-Json | Write-Host
    if (-not $NonInteractive -and (Read-Host 'Save these basic settings and continue the user-run setup? [y/N]') -cne 'y') { throw 'Setup cancelled before Azure operations.' }
    Write-OpsUserSettings -Patch @{basic=$basic} | Out-Null
    return $basic
}

function Resolve-OpsSandboxSettings {
    param([string]$Name, [hashtable]$Values, [hashtable]$Connection, [switch]$ExplicitOnly)
    $required = @(Get-OpsSandboxFields $Name)
    $resolved = @{}
    foreach ($key in $required) { if ($Values.ContainsKey($key) -and $Values[$key]) { $resolved[$key] = $Values[$key] } }
    $missing = @($required | Where-Object { -not $resolved.ContainsKey($_) })
    if ($missing.Count -and -not $ExplicitOnly) {
        $settings = Read-OpsUserSettings
        Assert-OpsUserSettingsConnection $settings $Connection
        if ($settings.sandbox.Contains($Name)) {
            foreach ($key in $missing) { if ($settings.sandbox[$Name].Contains($key)) { $resolved[$key] = $settings.sandbox[$Name][$key] } }
        }
    }
    $missing = @($required | Where-Object { -not $resolved.ContainsKey($_) })
    if ($missing.Count) { throw "Missing Sandbox settings ($Name): $($missing -join ', '). Ask the user; no fixed target is assumed." }
    if ($resolved.ContainsKey('location')) { $resolved.location=$resolved.location.ToLowerInvariant() }
    $validation = New-OpsUserSettings
    $validation.sandbox[$Name] = $resolved
    Assert-OpsUserSettings $validation
    Assert-OpsUserSettingsConnection $validation $Connection
    return $resolved
}
