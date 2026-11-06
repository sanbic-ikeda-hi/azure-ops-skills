#requires -Version 7.2
<#
USER-RUN ONLY. Creates an app, a nonexportable local certificate and a read-only role assignment.
No client secret, Microsoft Graph application permission, write role or PIM is configured.
If a step fails, stop and inspect provision-state.json; never blindly rerun or auto-delete.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SandboxSubscriptionId,
    [string]$ProductionSubscriptionId,
    [ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$DisplayName = 'azure-ops-skills'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-OpsGuid $TenantId 'TenantId'
Assert-OpsGuid $SandboxSubscriptionId 'SandboxSubscriptionId'
$subscriptionIds = @($SandboxSubscriptionId)
if ($ProductionSubscriptionId) {
    Assert-OpsGuid $ProductionSubscriptionId 'ProductionSubscriptionId'
    if ($ProductionSubscriptionId -eq $SandboxSubscriptionId) { throw 'Sandboxと本番には別のサブスクリプションを指定してください。' }
    $subscriptionIds += $ProductionSubscriptionId
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -MinimumVersion 10.0.0 -ErrorAction Stop
$roleTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\roles\services-reader.json') -Raw | ConvertFrom-Json
Assert-OpsReaderRole $roleTemplate
Get-Command New-SelfSignedCertificate -ErrorAction Stop | Out-Null
$localDirectory = Get-OpsLocalDirectory
$connectionPath = Join-Path $localDirectory 'connection.json'
$statePath = Join-Path $localDirectory 'provision-state.json'
if ((Test-Path -LiteralPath $connectionPath) -or (Test-Path -LiteralPath $statePath)) {
    throw '初期設定または途中状態が存在します。再実行せず状態を確認してください。別PCは Register-Computer.ps1 を使います。'
}
$state = [ordered]@{ tenantId=$TenantId; subscriptionIds=$subscriptionIds; sandboxSubscriptionId=$SandboxSubscriptionId; stage='NotStarted' }
function Save-ProvisionState {
    param([string]$Stage)
    $state.stage = $Stage
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8
}
$connected = $false
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $TenantId -Subscription $SandboxSubscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected = $true
    Assert-OpsContext (Get-AzContext) @{tenantId=$TenantId; subscriptionId=$SandboxSubscriptionId} 'User'
    $existing = @(Get-AzADApplication -DisplayName $DisplayName -ErrorAction Stop | Where-Object DisplayName -CEQ $DisplayName)
    if ($existing.Count) { throw '同名アプリが存在します。新規作成せず、対象のApplicationIdを確認してください。' }
    New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
    $certificateParameters = @{
        Subject = "CN=$DisplayName-$env:COMPUTERNAME"
        CertStoreLocation = 'Cert:\CurrentUser\My'
        KeyExportPolicy = 'NonExportable'
        KeyAlgorithm = 'RSA'
        KeyLength = 2048
        HashAlgorithm = 'SHA256'
        KeyUsage = 'DigitalSignature'
        NotAfter = (Get-Date).AddMonths(12)
    }
    $certificate = New-SelfSignedCertificate @certificateParameters
    $state.certificateThumbprint = $certificate.Thumbprint
    $state.certificateExpiresUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
    Save-ProvisionState 'CertificateCreated'
    $application = New-AzADApplication -DisplayName $DisplayName -SignInAudience AzureADMyOrg -ErrorAction Stop
    $state.applicationId = [string]$application.AppId
    $state.applicationObjectId = [string]$application.Id
    Save-ProvisionState 'ApplicationCreated'
    # This is the PUBLIC certificate, held in memory. The private key never leaves the Windows certificate store.
    $publicCertificate = [Convert]::ToBase64String($certificate.GetRawCertData())
    New-AzADAppCredential -ApplicationId $application.AppId -CertValue $publicCertificate -StartDate $certificate.NotBefore -EndDate $certificate.NotAfter -ErrorAction Stop | Out-Null
    Save-ProvisionState 'PublicCertificateRegistered'
    # Existing-application parameter set: no automatically generated password or role assignment.
    $principal = New-AzADServicePrincipal -ApplicationId $application.AppId -ErrorAction Stop
    $state.servicePrincipalObjectId = [string]$principal.Id
    Save-ProvisionState 'ServicePrincipalCreated'
    $scopes = @($subscriptionIds | ForEach-Object { "/subscriptions/$_" })
    $role = $roleTemplate
    $role.AssignableScopes = $scopes
    $role.Name = "Azure Ops Services Reader $($application.AppId)"
    $existingRole = @(Get-AzRoleDefinition -Name $role.Name -ErrorAction Stop)
    if ($existingRole.Count) {
        throw '同名カスタムロールが存在します。既存ロールを自動更新せず停止します。'
    }
    $rolePath = Join-Path $localDirectory 'services-reader.local.json'
    $role | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rolePath -Encoding utf8
    $createdRole = New-AzRoleDefinition -InputFile $rolePath -ErrorAction Stop
    $state.readerRoleId = [string]$createdRole.Id
    Save-ProvisionState 'ReaderRoleCreated'
    $state.readerAssignmentIds = @()
    foreach ($subId in $subscriptionIds) {
        Set-AzContext -Tenant $TenantId -Subscription $subId -Scope Process -ErrorAction Stop | Out-Null
        Assert-OpsContext (Get-AzContext) @{tenantId=$TenantId; subscriptionId=$subId} 'User'
        $assignment = New-AzRoleAssignment -ObjectId $principal.Id -RoleDefinitionId $createdRole.Id -Scope "/subscriptions/$subId" -ErrorAction Stop
        $state.readerAssignmentIds += [string]$assignment.RoleAssignmentId
        Save-ProvisionState "ReaderAssigned:$subId"
    }
    $profile = [ordered]@{
        tenantId=$TenantId
        subscriptionIds=$subscriptionIds
        sandboxSubscriptionId=$SandboxSubscriptionId
        applicationId=[string]$application.AppId
        servicePrincipalObjectId=[string]$principal.Id
        certificateThumbprint=$certificate.Thumbprint
    }
    $profile | ConvertTo-Json | Set-Content -LiteralPath $connectionPath -Encoding utf8
    $versions = @(Get-Module Az.Accounts,Az.Resources | ForEach-Object {
        [ordered]@{name=$_.Name; version=$_.Version.ToString()}
    })
    $versions | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $localDirectory 'module-versions.json') -Encoding utf8
    Save-ProvisionState 'Completed'
    # Only nonsecret identifiers are displayed.
    [pscustomobject]$profile
    Write-Host "読み取りロールを割り当てました。実際の接続・読み取りは別途確認が必要です: $connectionPath"
} catch {
    Write-Warning "初期設定を停止しました。部分的に作成済みの可能性があります。自動再実行・削除はしません。状態: $statePath"
    throw
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
