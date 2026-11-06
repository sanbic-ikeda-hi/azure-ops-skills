#requires -Version 7.2
<#
USER-RUN ONLY. Resume role provisioning for the EXISTING identity recorded on this PC.
No application, service principal or certificate is created or replaced. No retries or automatic deletion.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$localDirectory = Get-OpsLocalDirectory
$statePath = Join-Path $localDirectory 'provision-state.json'
$connectionPath = Join-Path $localDirectory 'connection.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw '途中状態がありません。新規初期設定とは別の処理です。' }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
Assert-OpsResumeState $state
if (Test-Path -LiteralPath $connectionPath) {
    throw '接続設定がすでに存在します。上書きせず、現在の接続確認または状態確認を行ってください。'
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -MinimumVersion 10.0.0 -ErrorAction Stop
$role = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\roles\services-reader.json') -Raw | ConvertFrom-Json
Assert-OpsReaderRole $role
$role.Name = "Azure Ops Services Reader $($state.applicationId)"
$role.AssignableScopes = @($state.subscriptionIds | ForEach-Object { "/subscriptions/$_" })
$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($state.certificateThumbprint)" -ErrorAction Stop
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or $certificate.NotBefore -gt (Get-Date)) {
    throw '作成済み証明書が利用できません。再作成せず停止します。'
}
function Save-ProvisionState {
    param([string]$Stage)
    $state.stage = $Stage
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8
}
$connected = $false
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    $connect = @{
        Tenant=$state.tenantId
        Subscription=$state.sandboxSubscriptionId
        Scope='Process'
        ErrorAction='Stop'
    }
    Connect-AzAccount @connect | Out-Null
    $connected = $true
    Assert-OpsContext (Get-AzContext) @{tenantId=$state.tenantId;subscriptionId=$state.sandboxSubscriptionId} 'User'
    $application = Get-AzADApplication -ApplicationId $state.applicationId -ErrorAction Stop
    $principals = @(Get-AzADServicePrincipal -ApplicationId $state.applicationId -ErrorAction Stop)
    if (-not $application -or [string]$application.Id -ne $state.applicationObjectId -or $principals.Count -ne 1) {
        throw '作成済みアプリを進行記録と照合できません。'
    }
    if ([string]$principals[0].Id -ne $state.servicePrincipalObjectId -or
        [string]$principals[0].AppId -ne $state.applicationId) {
        throw 'エンタープライズアプリが進行記録と異なります。'
    }

    # Check whether a preceding attempt created the role despite missing its local success record.
    $existing = @(Get-AzRoleDefinition -Name $role.Name -ErrorAction Stop)
    if ($existing.Count -gt 1) { throw '同名ロールが複数存在します。' }
    if ($existing.Count -eq 1) {
        Assert-OpsMatchingReaderRole $existing[0] $role
        $createdRole = $existing[0]
        if ($state.ContainsKey('readerRoleId') -and $state.readerRoleId -and
            [string]$createdRole.Id -ne $state.readerRoleId) {
            throw '既存ロールIDが進行記録と異なります。'
        }
    } else {
        if ($state.ContainsKey('readerRoleId') -and $state.readerRoleId) {
            throw '記録済みロールを取得できません。削除や反映遅延を確認し、再作成せず停止します。'
        }
        $rolePath = Join-Path $localDirectory 'services-reader.local.json'
        $role | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rolePath -Encoding utf8
        $createdRole = New-AzRoleDefinition -InputFile $rolePath -ErrorAction Stop
    }
    Assert-OpsMatchingReaderRole $createdRole $role
    $state.readerRoleId = [string]$createdRole.Id
    Save-ProvisionState 'ReaderRoleCreated'
    if (-not $state.ContainsKey('readerAssignmentIds')) { $state.readerAssignmentIds = @() }

    foreach ($subId in $state.subscriptionIds) {
        Set-AzContext -Tenant $state.tenantId -Subscription $subId -Scope Process -ErrorAction Stop | Out-Null
        Assert-OpsContext (Get-AzContext) @{tenantId=$state.tenantId;subscriptionId=$subId} 'User'
        $scope = "/subscriptions/$subId"
        $assignmentQuery = @{
            ObjectId=$state.servicePrincipalObjectId
            RoleDefinitionId=$createdRole.Id
            Scope=$scope
            AtScope=$true
            ErrorAction='Stop'
        }
        $assignments = @(Get-AzRoleAssignment @assignmentQuery)
        if ($assignments.Count -gt 1) { throw '同じロールの割当が複数存在します。' }
        if ($assignments.Count -eq 1) {
            $assignment = $assignments[0]
            if ([string]$assignment.Scope -ine $scope -or [string]$assignment.ObjectId -ne $state.servicePrincipalObjectId) {
                throw '取得したロール割当の対象が想定と異なります。'
            }
        } else {
            $assignment = New-AzRoleAssignment -ObjectId $state.servicePrincipalObjectId -RoleDefinitionId $createdRole.Id -Scope $scope -ErrorAction Stop
        }
        $assignmentId = [string]$assignment.RoleAssignmentId
        if ($assignmentId -notin $state.readerAssignmentIds) { $state.readerAssignmentIds += $assignmentId }
        Save-ProvisionState "ReaderAssigned:$subId"
    }
    $profile = [ordered]@{
        tenantId=$state.tenantId
        subscriptionIds=$state.subscriptionIds
        sandboxSubscriptionId=$state.sandboxSubscriptionId
        applicationId=$state.applicationId
        servicePrincipalObjectId=$state.servicePrincipalObjectId
        certificateThumbprint=$state.certificateThumbprint
    }
    $profile | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $connectionPath -Encoding utf8
    @(Get-Module Az.Accounts,Az.Resources | ForEach-Object {
        [ordered]@{name=$_.Name;version=$_.Version.ToString()}
    }) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $localDirectory 'module-versions.json') -Encoding utf8
    Save-ProvisionState 'Completed'
    [pscustomobject]$profile
    Write-Host '読み取り権限の設定を完了しました。専用アプリでの実際の取得は次に確認してください。'
} catch {
    Write-Warning "再開処理を停止しました。自動再試行・削除はしません。直前のエラーと途中状態を確認してください: $statePath"
    throw
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
