#requires -Version 7.2
Set-StrictMode -Version Latest

function Get-OpsLocalDirectory {
    if (-not $env:LOCALAPPDATA) { throw 'Windows の LOCALAPPDATA が必要です。' }
    Join-Path $env:LOCALAPPDATA 'AzureOpsSkills'
}

function Assert-OpsGuid {
    param([string]$Value, [string]$Label = 'ID')
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
        throw "$Label に有効な GUID が必要です。"
    }
}

function Assert-OpsResourceScope {
    param([string]$ResourceId, [string]$SubscriptionId)
    Assert-OpsGuid $SubscriptionId 'SubscriptionId'
    $prefix = "/subscriptions/$SubscriptionId/resourceGroups/"
    if (-not $ResourceId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '対象サブスクリプション外のリソースです。'
    }
    $pattern = '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/?#%]+/providers/[A-Za-z0-9.]+(?:/[A-Za-z0-9._-]+/[^/?#%]+)+$'
    if ($ResourceId -notmatch $pattern -or $ResourceId -match '[\s*''";]' -or $ResourceId.Contains('..')) {
        throw '変更権限は個別のリソースIDに限定します。サブスクリプション・RG・曖昧なパスは使えません。'
    }
}

function Read-OpsConnection {
    param([string]$Path = (Join-Path (Get-OpsLocalDirectory) 'connection.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "接続設定がありません。管理者向け初期設定を実施してください: $Path"
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $allowed = @('tenantId','subscriptionIds','sandboxSubscriptionId','applicationId','servicePrincipalObjectId','certificateThumbprint')
    foreach ($key in $config.Keys) {
        if ($key -notin $allowed) { throw '接続設定に未対応の項目があります。秘密情報は保存しないでください。' }
    }
    foreach ($key in $allowed) {
        if (-not $config.ContainsKey($key)) { throw "接続設定に $key が必要です。" }
    }
    foreach ($key in @('tenantId','applicationId','servicePrincipalObjectId','sandboxSubscriptionId')) {
        Assert-OpsGuid $config[$key] $key
    }
    if ($config.subscriptionIds -isnot [array] -or $config.subscriptionIds.Count -eq 0) {
        throw 'subscriptionIds は1つ以上のIDの配列にしてください。'
    }
    foreach ($id in $config.subscriptionIds) { Assert-OpsGuid $id 'subscriptionIds' }
    if ($config.sandboxSubscriptionId -notin $config.subscriptionIds) {
        throw 'Sandboxは許可済みサブスクリプションのいずれかを指定してください。'
    }
    if ($config.certificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw '証明書の拇印が不正です。' }
    return $config
}

function Select-OpsSubscription {
    param([hashtable]$Config,[string]$SubscriptionId)
    Assert-OpsGuid $SubscriptionId 'SubscriptionId'
    if ($SubscriptionId -notin $Config.subscriptionIds) { throw '許可済み設定にないサブスクリプションです。' }
    $selected = $Config.Clone()
    $selected.subscriptionId = $SubscriptionId
    return $selected
}

function Assert-OpsContext {
    param($Context, [hashtable]$Config, [ValidateSet('User','ServicePrincipal')][string]$AccountType)
    if (-not $Context -or $Context.Tenant.Id -ne $Config.tenantId -or
        $Context.Subscription.Id -ne $Config.subscriptionId -or
        $Context.Account.Type -ne $AccountType -or $Context.Environment.Name -ne 'AzureCloud') {
        throw '接続先または認証種別が想定と異なるため停止しました。'
    }
    if ($AccountType -eq 'ServicePrincipal' -and $Context.Account.Id -ne $Config.applicationId) {
        throw '専用アプリ以外の接続は使えません。'
    }
}

function Connect-OpsApplication {
    param([hashtable]$Config)
    Import-Module Az.Accounts -ErrorAction Stop
    $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($Config.certificateThumbprint)" -ErrorAction Stop
    if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date) -or $cert.NotBefore -gt (Get-Date)) {
        throw '証明書が利用できません。登録・更新手順を確認してください。'
    }
    Disable-AzContextAutosave -Scope Process | Out-Null
    $parameters = @{
        ServicePrincipal = $true
        Tenant = $Config.tenantId
        Subscription = $Config.subscriptionId
        ApplicationId = $Config.applicationId
        CertificateThumbprint = $Config.certificateThumbprint
        Scope = 'Process'
        SkipContextPopulation = $true
        ErrorAction = 'Stop'
    }
    Connect-AzAccount @parameters | Out-Null
    Assert-OpsContext (Get-AzContext) $Config 'ServicePrincipal'
}

function Get-OpsServiceKind {
    param([string]$Type, [string]$Kind)
    if ($Type -ieq 'Microsoft.Logic/workflows') { return 'LogicApps' }
    if ($Type -ine 'Microsoft.Web/sites') { return 'Other' }
    $parts = @($Kind.ToLowerInvariant().Split(',') | ForEach-Object { $_.Trim() })
    if ('workflowapp' -in $parts) { return 'LogicApps' }
    if ('functionapp' -in $parts) { return 'Functions' }
    if ('app' -in $parts) { return 'AppService' }
    return 'Other'
}

function ConvertTo-OpsInventoryRow {
    param([System.Collections.IDictionary]$Resource)
    $properties = $Resource['properties']
    if (-not $properties) { $properties = @{} }
    $identity = $Resource['identity']
    if (-not $identity) { $identity = @{} }
    # Allowlist only. Never return definitions, parameters, tags, URLs, app settings or the raw response.
    [pscustomobject][ordered]@{
        ResourceId = $Resource['id']
        Name = $Resource['name']
        Type = $Resource['type']
        Kind = $Resource['kind']
        Location = $Resource['location']
        State = $properties['state']
        ProvisioningState = $properties['provisioningState']
        PlanResourceId = $properties['serverFarmId']
        HttpsOnly = $properties['httpsOnly']
        PublicNetworkAccess = $properties['publicNetworkAccess']
        IdentityType = $identity['type']
    }
}

function Get-OpsNextPath {
    param([string]$NextLink, [string]$CollectionPath)
    $uri = $null
    if (-not [uri]::TryCreate($NextLink, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
        $uri.AbsolutePath -ine $CollectionPath) {
        throw '想定外の継続リンクを拒否しました。'
    }
    return $uri.PathAndQuery
}


function Assert-OpsReaderRole {
    param($Role)
    if (-not $Role.PSObject.Properties['Permissions'] -or @($Role.Permissions).Count -ne 1) {
        throw 'Az.Resources 10以降の形式が必要です。Permissions配列に1つの権限定義を指定してください。'
    }
    if ($Role.IsCustom -isnot [bool] -or -not $Role.IsCustom) { throw '読み取り専用カスタムロールが必要です。' }
    $permission = $Role.Permissions[0]
    foreach ($property in @('Actions','NotActions','DataActions','NotDataActions')) {
        if (-not $permission.PSObject.Properties[$property]) { throw "Permissionsに$property が必要です。" }
    }
    if (@($permission.Actions).Count -eq 0) { throw '読み取り操作が空です。' }
    foreach ($action in $permission.Actions) {
        if ($action -notmatch '/read$' -or $action -match '(?i)\*|accesskeys|listkeys|secrets|connectionstrings|appsettings|runs|credentials') {
            throw '読み取りロールに未許可の操作があります。'
        }
    }
    foreach ($property in @('NotActions','DataActions','NotDataActions')) {
        if (@($permission.$property | Where-Object { $null -ne $_ }).Count -ne 0) {
            throw '読み取りロールには除外操作やデータプレーンの権限を含めません。'
        }
    }
    foreach ($property in @('Condition','ConditionVersion')) {
        if ($permission.PSObject.Properties[$property] -and $permission.$property) {
            throw '想定外の条件付きロールを自動利用しません。'
        }
    }
}

function Assert-OpsMatchingReaderRole {
    param($Actual,$Expected)
    Assert-OpsReaderRole $Actual
    Assert-OpsReaderRole $Expected
    if ($Actual.Name -cne $Expected.Name) { throw '既存ロールの名前が一致しません。' }
    $actualActions = @($Actual.Permissions[0].Actions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $expectedActions = @($Expected.Permissions[0].Actions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $actualScopes = @($Actual.AssignableScopes | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() } | Sort-Object)
    $expectedScopes = @($Expected.AssignableScopes | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() } | Sort-Object)
    if (($actualActions -join '|') -cne ($expectedActions -join '|') -or
        ($actualScopes -join '|') -cne ($expectedScopes -join '|')) {
        throw '既存ロールの権限または割当可能範囲が異なります。自動更新せず停止します。'
    }
}

function Assert-OpsResumeState {
    param([hashtable]$State)
    foreach ($key in @('tenantId','applicationId','applicationObjectId','servicePrincipalObjectId','sandboxSubscriptionId')) {
        if (-not $State.ContainsKey($key)) { throw "途中状態に$key がありません。" }
        Assert-OpsGuid $State[$key] $key
    }
    if (-not $State.ContainsKey('subscriptionIds') -or $State.subscriptionIds -isnot [array] -or
        $State.subscriptionIds.Count -eq 0 -or $State.sandboxSubscriptionId -notin $State.subscriptionIds) {
        throw '途中状態のサブスクリプション一覧が不正です。'
    }
    foreach ($id in $State.subscriptionIds) { Assert-OpsGuid $id 'subscriptionIds' }
    if (-not $State.ContainsKey('certificateThumbprint') -or $State.certificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw '途中状態の証明書の拇印が不正です。'
    }
    if (-not $State.ContainsKey('stage') -or $State.stage -notmatch '^(ServicePrincipalCreated|ReaderRoleCreated|ReaderAssigned:[0-9a-f-]{36}|Completed)$') {
        throw 'アプリとサービスプリンシパルの作成完了後の状態だけを再開できます。'
    }
    if ($State.stage.StartsWith('ReaderAssigned:') -and $State.stage.Substring(15) -notin $State.subscriptionIds) {
        throw '途中状態の割当先が対象サブスクリプションに含まれていません。'
    }
    if ($State.ContainsKey('readerRoleId') -and $State.readerRoleId) {
        Assert-OpsGuid $State.readerRoleId 'readerRoleId'
    } elseif ($State.stage -ne 'ServicePrincipalCreated') {
        throw 'ロール作成後の状態にはreaderRoleIdが必要です。'
    }
}
