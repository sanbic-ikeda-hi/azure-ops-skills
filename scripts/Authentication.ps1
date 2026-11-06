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
    $certificatePath = "Cert:\CurrentUser\My\$($Config.certificateThumbprint)"
    if (-not (Test-Path -LiteralPath $certificatePath)) {
        throw '指定証明書が現在のWindows実行ユーザーのストアにありません。whoamiで実行主体を確認してください。別ユーザーの隔離環境なら正規の承認付き実行、またはユーザーによる実行が必要です。証明書を再作成・移動せず停止します。'
    }
    $cert = Get-Item -LiteralPath $certificatePath -ErrorAction Stop
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
    try {
        Assert-OpsContext (Get-AzContext) $Config 'ServicePrincipal'
    } catch {
        # The caller cannot mark this connection as established until this function returns.
        Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
        throw
    }
}
