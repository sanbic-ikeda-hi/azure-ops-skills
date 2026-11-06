#requires -Version 7.2
# USER-RUN ONLY. Grant/revoke two operations on the fixed Sandbox test workflow.
# Plan is local only. Revoke requires the exact assignment ID returned by Grant.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Grant','Revoke')][string]$Action = 'Plan',
    [string]$AssignmentId,
    [ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$ResourceGroupName='rg-azureops-sandbox-test',
    [ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$WorkflowName='la-azureops-sandbox-test'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection = Read-OpsConnection
$config = Select-OpsSubscription $connection $connection.sandboxSubscriptionId
$groupId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$ResourceGroupName"
$resourceId = "$groupId/providers/Microsoft.Logic/workflows/$WorkflowName"
Assert-OpsResourceScope $resourceId $config.subscriptionId
$roleName = "Azure Ops Sandbox Logic State $($config.applicationId)"
if ($ResourceGroupName -ne 'rg-azureops-sandbox-test' -or $WorkflowName -ne 'la-azureops-sandbox-test') {
    $roleName += " $ResourceGroupName $WorkflowName"
}
$actions = @('Microsoft.Logic/workflows/enable/action','Microsoft.Logic/workflows/disable/action')
$assignmentPrefix = "$resourceId/providers/Microsoft.Authorization/roleAssignments/"
if ($Action -eq 'Revoke') {
    if (-not $AssignmentId -or -not $AssignmentId.StartsWith($assignmentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Grantが出力した、この試験リソースのAssignmentIdを指定してください。'
    }
    Assert-OpsGuid $AssignmentId.Substring($assignmentPrefix.Length) 'AssignmentId'
} elseif ($AssignmentId) { throw 'AssignmentIdはRevokeでのみ指定してください。' }
$plan = [pscustomobject][ordered]@{
    Action=$Action; TenantId=$config.tenantId; SubscriptionId=$config.subscriptionId
    ApplicationId=$config.applicationId; ObjectId=$config.servicePrincipalObjectId
    RoleName=$roleName; Scope=$resourceId; AssignableScopes=@($groupId); Actions=$actions
}
$plan | ConvertTo-Json -Depth 5
if ($Action -eq 'Plan') { return }
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -MinimumVersion 10.0.0 -ErrorAction Stop

function Assert-TestRole {
    param($Role)
    if (-not $Role -or $Role.IsCustom -ne $true -or $Role.Name -cne $roleName -or
        @($Role.AssignableScopes).Count -ne 1 -or $Role.AssignableScopes[0] -ine $groupId -or
        @($Role.Permissions).Count -ne 1) { throw '既存ロールが試験計画と異なります。更新せず停止します。' }
    $permission = $Role.Permissions[0]
    if ((@($permission.Actions | Sort-Object) -join '|') -ine (@($actions | Sort-Object) -join '|')) {
        throw '既存ロールの操作が有効化・無効化の2件と一致しません。'
    }
    foreach ($name in @('NotActions','DataActions','NotDataActions')) {
        if (@($permission.$name | Where-Object { $null -ne $_ }).Count) { throw '想定外の権限定義があります。' }
    }
    foreach ($name in @('Condition','ConditionVersion')) {
        if ($permission.PSObject.Properties[$name] -and $permission.$name) { throw '条件付きロールは使用しません。' }
    }
}

function Assert-TestAssignment {
    param($Assignment, [string]$RoleId)
    if ($Assignment.Scope -ine $resourceId -or $Assignment.ObjectId -ine $config.servicePrincipalObjectId -or
        [string]$Assignment.RoleDefinitionId -ine $RoleId -or
        -not $Assignment.RoleAssignmentId.StartsWith($assignmentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ロール割当のリソース・アプリ・ロールIDが計画と一致しません。'
    }
    Assert-OpsGuid $Assignment.RoleAssignmentId.Substring($assignmentPrefix.Length) 'RoleAssignmentId'
}

$connected = $false
$stage = 'NotStarted'
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $config.tenantId -Subscription $config.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected = $true
    Assert-OpsContext (Get-AzContext) $config 'User'
    $principals = @(Get-AzADServicePrincipal -ApplicationId $config.applicationId -ErrorAction Stop)
    if ($principals.Count -ne 1 -or [string]$principals[0].Id -ine $config.servicePrincipalObjectId -or
        [string]$principals[0].AppId -ine $config.applicationId) { throw '専用アプリのObjectIdを照合できません。' }
    $roles = @(Get-AzRoleDefinition -Name $roleName -Scope $groupId -ErrorAction Stop)
    if ($roles.Count -gt 1) { throw '同名ロールが複数あります。' }
    $role = if ($roles.Count) { $roles[0] } else { $null }

    if ($Action -eq 'Grant') {
        Assert-OpsContext (Get-AzContext) $config 'User'
        $response = Invoke-AzRestMethod -Path "${resourceId}?api-version=2019-05-01" -Method GET -ErrorAction Stop
        if ($response.StatusCode -ne 200) { throw "試験リソースの確認失敗 HTTP $($response.StatusCode)" }
        $workflow = $response.Content | ConvertFrom-Json -AsHashtable
        if ($workflow.id -ine $resourceId -or $workflow.type -ine 'Microsoft.Logic/workflows' -or
            $workflow.properties.state -ne 'Disabled' -or $workflow.properties.provisioningState -ne 'Succeeded') {
            throw '対象のID・種別・Disabled・Succeededを確認できません。'
        }
        # Report applicable assignments without changing any existing or inherited grant.
        $existing = @(Get-AzRoleAssignment -ObjectId $config.servicePrincipalObjectId -Scope $resourceId -ErrorAction Stop)
        $existing | Select-Object RoleAssignmentId, RoleDefinitionId, Scope | ConvertTo-Json -Depth 4
        if ($role) {
            Assert-TestRole $role
            if (@($existing | Where-Object RoleDefinitionId -EQ $role.Id).Count) {
                throw 'この試験ロールは既に割り当てられています。再付与・既存割当の自動解除はしません。'
            }
        } else {
            $role = New-Object Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition
            $role.Name = $roleName
            $role.Description = 'Enable and disable the Sandbox test workflow only. No edits, runs, secrets or deletes.'
            $role.IsCustom = $true
            $role.AssignableScopes = @($groupId)
            $permission = New-Object Microsoft.Azure.Commands.Resources.Models.Authorization.PSPermission
            $permission.Actions = $actions
            $permission.NotActions = @(); $permission.DataActions = @(); $permission.NotDataActions = @()
            $role.Permissions = @($permission)
            Assert-OpsContext (Get-AzContext) $config 'User'
            $stage = 'CreatingRole'
            $role = New-AzRoleDefinition -Role $role -ErrorAction Stop
            $stage = 'RoleCreated'
            Assert-TestRole $role
        }
        Assert-OpsGuid ([string]$role.Id) 'RoleId'
        [pscustomobject]@{RoleId=[string]$role.Id; Scope=$resourceId} | ConvertTo-Json
        Assert-OpsContext (Get-AzContext) $config 'User'
        $stage = 'AssigningRole'
        $assignment = New-AzRoleAssignment -ObjectId $config.servicePrincipalObjectId -RoleDefinitionId $role.Id -Scope $resourceId -ErrorAction Stop
        $stage = 'RoleAssigned'
        Assert-TestAssignment $assignment ([string]$role.Id)
        [pscustomobject]@{AssignmentId=$assignment.RoleAssignmentId; RoleId=[string]$role.Id; ObjectId=$config.servicePrincipalObjectId; Scope=$resourceId} | ConvertTo-Json
        Write-Host 'Granted. Keep AssignmentId for Revoke. No workflow state was changed.'
    } else {
        if (-not $role) { throw '対象ロールを確認できません。解除せず停止します。' }
        $assignments = @(Get-AzRoleAssignment -ObjectId $config.servicePrincipalObjectId -RoleDefinitionId $role.Id -Scope $resourceId -AtScope -ErrorAction Stop |
            Where-Object RoleAssignmentId -EQ $AssignmentId)
        if ($assignments.Count -ne 1) { throw '指定した割当を1件に照合できません。解除せず停止します。' }
        Assert-TestAssignment $assignments[0] ([string]$role.Id)
        Assert-OpsContext (Get-AzContext) $config 'User'
        $stage = 'RevokingAssignment'
        Remove-AzRoleAssignment -InputObject $assignments[0] -ErrorAction Stop
        $stage = 'AssignmentRevoked'
        Assert-OpsContext (Get-AzContext) $config 'User'
        $remaining = @(Get-AzRoleAssignment -ObjectId $config.servicePrincipalObjectId -RoleDefinitionId $role.Id -Scope $resourceId -AtScope -ErrorAction Stop |
            Where-Object RoleAssignmentId -EQ $AssignmentId)
        if ($remaining.Count) { throw '解除後も割当が返っています。反映状況を確認し、自動再試行はしません。' }
        [pscustomobject]@{RevokedAssignmentId=$AssignmentId; Scope=$resourceId; AssignmentAbsent=$true} | ConvertTo-Json
        Write-Host 'Assignment removed. The role definition and existing reader assignments remain. RBAC propagation can take time.'
    }
} catch {
    Write-Warning "権限設定を停止しました。段階: $stage。自動再実行・ロール定義の更新・他の割当の解除はしません。"
    throw
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
