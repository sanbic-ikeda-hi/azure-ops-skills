#requires -Version 7.2
# USER-RUN ONLY. Add this PC's public certificate to an EXISTING app; do not recreate the app or change RBAC.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SandboxSubscriptionId,
    [string]$ProductionSubscriptionId,
    [Parameter(Mandatory)][string]$ApplicationId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
foreach ($value in @($TenantId,$SandboxSubscriptionId,$ApplicationId)) { Assert-OpsGuid $value }
$subscriptionIds = @($SandboxSubscriptionId)
if ($ProductionSubscriptionId) {
    Assert-OpsGuid $ProductionSubscriptionId 'ProductionSubscriptionId'
    if ($ProductionSubscriptionId -eq $SandboxSubscriptionId) { throw 'Sandboxと本番には別のサブスクリプションを指定してください。' }
    $subscriptionIds += $ProductionSubscriptionId
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
$localDirectory = Get-OpsLocalDirectory
$connectionPath = Join-Path $localDirectory 'connection.json'
$statePath = Join-Path $localDirectory 'computer-registration-state.json'
if ((Test-Path -LiteralPath $connectionPath) -or (Test-Path -LiteralPath $statePath)) {
    throw 'このPCには設定または途中状態があります。上書きせず確認してください。'
}
$connected = $false
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $TenantId -Subscription $SandboxSubscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected = $true
    Assert-OpsContext (Get-AzContext) @{tenantId=$TenantId; subscriptionId=$SandboxSubscriptionId} 'User'
    $application = Get-AzADApplication -ApplicationId $ApplicationId -ErrorAction Stop
    $principal = @(Get-AzADServicePrincipal -ApplicationId $ApplicationId -ErrorAction Stop)
    if (-not $application -or $principal.Count -ne 1) { throw '既存アプリとサービスプリンシパルを一意に確認できません。' }
    New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
    $certParams = @{
        Subject="CN=azure-ops-skills-$env:COMPUTERNAME"
        CertStoreLocation='Cert:\CurrentUser\My'
        KeyExportPolicy='NonExportable'
        KeyAlgorithm='RSA'
        KeyLength=2048
        HashAlgorithm='SHA256'
        KeyUsage='DigitalSignature'
        NotAfter=(Get-Date).AddMonths(12)
    }
    $certificate = New-SelfSignedCertificate @certParams
    $profile = [ordered]@{
        tenantId=$TenantId
        subscriptionIds=$subscriptionIds
        sandboxSubscriptionId=$SandboxSubscriptionId
        applicationId=$ApplicationId
        servicePrincipalObjectId=[string]$principal[0].Id
        certificateThumbprint=$certificate.Thumbprint
    }
    [ordered]@{stage='CertificateCreated';profile=$profile} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8
    $publicCertificate = [Convert]::ToBase64String($certificate.GetRawCertData())
    New-AzADAppCredential -ApplicationId $ApplicationId -CertValue $publicCertificate -StartDate $certificate.NotBefore -EndDate $certificate.NotAfter -ErrorAction Stop | Out-Null
    $profile | ConvertTo-Json | Set-Content -LiteralPath $connectionPath -Encoding utf8
    [ordered]@{stage='Completed';profile=$profile} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8
    @(Get-Module Az.Accounts,Az.Resources | ForEach-Object {
        [ordered]@{name=$_.Name;version=$_.Version.ToString()}
    }) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $localDirectory 'module-versions.json') -Encoding utf8
    [pscustomobject]$profile
    Write-Host 'このPCの公開証明書を追加しました。旧PCの証明書とAzure RBACは変更していません。接続確認は別途必要です。'
} catch {
    Write-Warning "登録を停止しました。再実行せず途中状態を確認してください: $statePath"
    throw
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
