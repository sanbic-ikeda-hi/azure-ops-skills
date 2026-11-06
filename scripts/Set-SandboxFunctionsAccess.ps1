#requires -Version 7.2
# USER-RUN ONLY. Grant/revoke start, stop and site updates on one explicit Sandbox Function App.
# Plan is local only. Revoke requires the exact assignment ID returned by Grant.
[CmdletBinding()]
param(
    [ValidateSet('Plan','Grant','Revoke')][string]$Action = 'Plan',
    [string]$AssignmentId,
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][string]$PlanResourceId,
    [switch]$IncludeRestart
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection = Read-OpsConnection
$config = Select-OpsSubscription $connection $connection.sandboxSubscriptionId
Assert-OpsResourceScope $ResourceId $config.subscriptionId
Assert-OpsResourceScope $PlanResourceId $config.subscriptionId
if ($ResourceId -notmatch '^(?<group>/subscriptions/[^/]+/resourceGroups/[^/]+)/providers/Microsoft\.Web/sites/(?<site>[^/]+)$') {
    throw 'ResourceId must identify exactly one Sandbox Function App, not a slot or parent scope.'
}
$groupId = $Matches.group
$siteName = $Matches.site
if ($PlanResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/serverfarms/[^/]+$') {
    throw 'PlanResourceId must identify exactly one Sandbox App Service plan.'
}
$roleName = "Azure Ops Sandbox Functions $siteName $($config.applicationId)"
$actions = @('Microsoft.Web/sites/start/action','Microsoft.Web/sites/stop/action','Microsoft.Web/sites/write')
if ($IncludeRestart) {
    $roleName += ' Restart'
    $actions += 'Microsoft.Web/sites/restart/action'
}
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
    RoleName=$roleName; Scope=$resourceId; PlanResourceId=$PlanResourceId; AssignableScopes=@($groupId); Actions=$actions
    DataActions=@(); AutomaticallyExpires=$false; ChangesAppOrPlan=$false
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
        throw 'Existing role actions differ from the reviewed operation set.'
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
        $response = Invoke-AzRestMethod -Path "${resourceId}?api-version=2024-11-01" -Method GET -ErrorAction Stop
        if ($response.StatusCode -ne 200) { throw "Function App read failed: $(Get-OpsArmErrorSummary $response | ConvertTo-Json -Depth 5 -Compress)" }
        $site = $response.Content | ConvertFrom-Json -AsHashtable
        if ($site.id -ine $resourceId -or (Get-OpsServiceKind $site.type $site.kind) -ne 'Functions' -or
            $site.properties.serverFarmId -ine $PlanResourceId -or $site.properties.state -ne 'Running') {
            throw 'The exact running Function App and its expected plan were not verified.'
        }
        Assert-OpsContext (Get-AzContext) $config 'User'
        $planResponse = Invoke-AzRestMethod -Path "${PlanResourceId}?api-version=2024-11-01" -Method GET -ErrorAction Stop
        if ($planResponse.StatusCode -ne 200) { throw "Plan read failed: $(Get-OpsArmErrorSummary $planResponse | ConvertTo-Json -Depth 5 -Compress)" }
        $servicePlan = $planResponse.Content | ConvertFrom-Json -AsHashtable
        if ($servicePlan.id -ine $PlanResourceId -or $servicePlan.type -ine 'Microsoft.Web/serverfarms' -or
            $servicePlan.properties.provisioningState -ne 'Succeeded' -or $servicePlan.properties.status -ne 'Ready' -or
            $servicePlan.sku.name -ne 'FC1' -or $servicePlan.properties.reserved -ne $true) {
            throw 'The expected existing plan was not verified as ready.'
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
            $role.Description = 'Start, stop and update one Sandbox Function App. Site write permits broader configuration changes than this test; no secret retrieval, deletes, plan updates or RBAC administration.'
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
        Write-Host 'Granted. Keep AssignmentId for Revoke. No app or plan settings were changed. This assignment does not automatically expire.'
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
