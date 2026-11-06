#requires -Version 7.2
# Offline RBAC tests. All Azure and authentication operations are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$count=0
$sub='11111111-1111-1111-1111-111111111111'
$otherSub='22222222-2222-2222-2222-222222222222'
function Check { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"}; $script:count++ }
function Test-WebAccessScenario {
    param([string]$Scenario)
    $calls = @{connect=0; disconnect=0; role=0; grant=0; revoke=0; removed=$null; roleBody=$null; grantScope=$null}
    $fakeConnection = @{
        tenantId=$sub; subscriptionIds=@($sub); sandboxSubscriptionId=$sub
        applicationId=$otherSub; servicePrincipalObjectId=$otherSub; certificateThumbprint=('A' * 40)
    } | ConvertTo-Json
    $groupScope = "/subscriptions/$sub/resourceGroups/rg-test"
    $appScope = "$groupScope/providers/Microsoft.Web/sites/test-app"
    $planScope = "$groupScope/providers/Microsoft.Web/serverfarms/test-plan"
    $roleId = '33333333-3333-3333-3333-333333333333'
    $assignmentId = "$appScope/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-4444-444444444444"
    $otherAssignmentId = "$appScope/providers/Microsoft.Authorization/roleAssignments/55555555-5555-5555-5555-555555555555"
    $expectedActions = @('Microsoft.Web/sites/start/action','Microsoft.Web/sites/stop/action','Microsoft.Web/sites/write')
    $restart=$Scenario -in @('GrantRestart','RevokeRestart')
    if ($restart) {$expectedActions += 'Microsoft.Web/sites/restart/action'}
    $testRole = [pscustomobject]@{
        Name="Azure Ops Sandbox Web test-app $otherSub"; Id=$roleId; IsCustom=$true; AssignableScopes=@($groupScope)
        Permissions=@([pscustomobject]@{Actions=$expectedActions; NotActions=@(); DataActions=@(); NotDataActions=@()})
    }
    if ($restart) {$testRole.Name += ' Restart'}
    if ($Scenario -eq 'RoleMismatch') { $testRole.Permissions[0].Actions += 'Microsoft.Web/sites/delete' }
    if ($Scenario -eq 'DataActionRole') { $testRole.Permissions[0].DataActions=@('*') }
    if ($Scenario -eq 'BroadRoleScope') { $testRole.AssignableScopes=@("/subscriptions/$sub") }
    $testAssignment = [pscustomobject]@{RoleAssignmentId=$assignmentId; RoleDefinitionId=$roleId; ObjectId=$otherSub; Scope=$appScope}
    $otherAssignment = [pscustomobject]@{RoleAssignmentId=$otherAssignmentId; RoleDefinitionId=$roleId; ObjectId=$otherSub; Scope=$appScope}
    if ($Scenario -eq 'RevokeWrongObject') { $testAssignment.ObjectId=$sub }
    if ($Scenario -eq 'RevokeWrongScope') { $testAssignment.Scope=$groupScope }
    function Test-Path { return $true }
    function Get-Content { return $fakeConnection }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount { $calls.connect++ }
    function Disconnect-AzAccount { $calls.disconnect++ }
    function Get-AzContext {
        @{Tenant=@{Id=$sub}; Subscription=@{Id=$(if ($Scenario -eq 'WrongSubscription') {$otherSub} else {$sub})}; Account=@{Type='User'}; Environment=@{Name='AzureCloud'}}
    }
    function Get-AzADServicePrincipal {
        [pscustomobject]@{Id=$(if ($Scenario -eq 'WrongPrincipal') {$sub} else {$otherSub}); AppId=$otherSub}
    }
    function Get-AzRoleDefinition { if ($Scenario -notin @('GrantNew','GrantRestart')) { $testRole } }
    function New-Object {
        param([string]$TypeName)
        if ($TypeName.EndsWith('.PSRoleDefinition')) {
            return [pscustomobject]@{Name=$null; Description=$null; IsCustom=$false; AssignableScopes=@(); Permissions=@()}
        }
        if ($TypeName.EndsWith('.PSPermission')) {
            return [pscustomobject]@{Actions=@(); NotActions=@(); DataActions=@(); NotDataActions=@()}
        }
        throw 'Unexpected type in RBAC scenario'
    }
    function New-AzRoleDefinition {
        param($Role)
        $calls.role++; $calls.roleBody=$Role
        $testRole
    }
    function Invoke-AzRestMethod {
        param($Path,$Method)
        if ($Method -ne 'GET') {throw 'RBAC helper must never write app or plan settings'}
        if ($Path -eq "${planScope}?api-version=2024-11-01") {
            return @{StatusCode=200;Content=(@{
                id=$planScope;type='Microsoft.Web/serverfarms'
                properties=@{provisioningState='Succeeded';status=$(if ($Scenario -eq 'PlanNotReady') {'Pending'} else {'Ready'})}
            } | ConvertTo-Json -Depth 5)}
        }
        if ($Path -ne "${appScope}?api-version=2024-11-01") {throw 'Unexpected resource target'}
        if ($Scenario -eq 'ReadDenied') {return @{StatusCode=403;Content='DO_NOT_OUTPUT_BODY'}}
        @{StatusCode=200; Content=(@{
            id=$appScope; type='Microsoft.Web/sites';kind=$(if ($Scenario -eq 'FunctionApp') {'functionapp'} else {'app'})
            properties=@{state=$(if ($Scenario -eq 'StoppedApp') {'Stopped'} else {'Running'});serverFarmId=$(if ($Scenario -eq 'WrongPlan') {'other-plan'} else {$planScope})}
        } | ConvertTo-Json -Depth 5)}
    }
    function Get-AzRoleAssignment {
        if ($Scenario.StartsWith('Revoke')) {
            $otherAssignment
            if ($Scenario -ne 'RevokeMissing' -and ($calls.revoke -eq 0 -or $Scenario -eq 'RevokeStale')) { $testAssignment }
        } elseif ($Scenario -eq 'ExistingAssignment') { $testAssignment }
        else { [pscustomobject]@{RoleAssignmentId='existing-reader'; RoleDefinitionId=$sub; Scope="/subscriptions/$sub"} }
    }
    function New-AzRoleAssignment {
        param($ObjectId,$RoleDefinitionId,$Scope)
        $calls.grant++; $calls.grantScope=$Scope
        if ($Scenario -eq 'GrantFailure') { throw 'Simulated authorization failure' }
        if ($ObjectId -ne $otherSub -or $RoleDefinitionId -ne $roleId) { throw 'Unexpected principal or role' }
        $testAssignment
    }
    function Remove-AzRoleAssignment {
        param($InputObject)
        $calls.revoke++; $calls.removed=$InputObject.RoleAssignmentId
    }
    $invoke = @{Action=$(if ($Scenario -eq 'Plan') {'Plan'} elseif ($Scenario.StartsWith('Revoke')) {'Revoke'} else {'Grant'}); WarningAction='SilentlyContinue';ResourceId=$appScope;PlanResourceId=$planScope}
    if ($restart) {$invoke.IncludeRestart=$true}
    if ($Scenario -eq 'OtherSubscription') { $invoke.ResourceId=$appScope.Replace($sub,$otherSub) }
    if ($Scenario -eq 'Slot') { $invoke.ResourceId="$appScope/slots/staging" }
    if ($Scenario -eq 'InvalidPlan') { $invoke.PlanResourceId=$appScope }
    if ($invoke.Action -eq 'Revoke') {
        $invoke.AssignmentId = if ($Scenario -eq 'RevokeBadScope') {"/subscriptions/$otherSub/providers/Microsoft.Authorization/roleAssignments/$roleId"} else {$assignmentId}
    }
    $failed=$false
    try { $output = & (Join-Path $PSScriptRoot 'Set-SandboxAppServiceAccess.ps1') @invoke 6>$null } catch { $failed=$true }
    if ($Scenario -eq 'Plan') {
        Check (-not $failed -and $calls.connect -eq 0 -and $calls.role -eq 0 -and $calls.grant -eq 0) 'Access plan performs no authentication or mutation'
        $plan=$output | ConvertFrom-Json
        Check ($plan.Scope -eq $appScope -and ($plan.Actions -join '|') -eq ($expectedActions -join '|')) 'Access plan targets one Web App and only three operations'
    } elseif ($Scenario -in @('RevokeBadScope','OtherSubscription','Slot','InvalidPlan')) {
        Check ($failed -and $calls.connect -eq 0 -and $calls.revoke -eq 0) 'Invalid revoke ID stops before authentication'
    } else {
        Check ($calls.connect -eq 1 -and $calls.disconnect -eq 1) "Access session disconnects: $Scenario"
        if ($Scenario -in @('GrantNew','GrantExistingRole','GrantRestart')) {
            Check (-not $failed -and $calls.grant -eq 1 -and $calls.grantScope -eq $appScope -and $calls.revoke -eq 0) "Grant is scoped to exactly the test Web App: $Scenario"
            if ($Scenario -in @('GrantNew','GrantRestart')) {
                Check ($calls.role -eq 1 -and ($calls.roleBody.Permissions[0].Actions -join '|') -eq ($expectedActions -join '|') -and
                    $calls.roleBody.AssignableScopes[0] -eq $groupScope) 'New role has exactly the proposed operations and assignable RG'
            } else { Check ($calls.role -eq 0) 'Matching existing role is reused without update' }
            Check (($output -join '') -match [regex]::Escape($assignmentId)) 'Grant outputs exact assignment ID for later revoke'
        } elseif ($Scenario -in @('RevokeSuccess','RevokeRestart')) {
            Check (-not $failed -and $calls.revoke -eq 1 -and $calls.removed -eq $assignmentId -and $calls.role -eq 0 -and $calls.grant -eq 0) 'Revoke removes only the supplied and verified assignment'
        } elseif ($Scenario -eq 'RevokeStale') {
            Check ($failed -and $calls.revoke -eq 1) 'Unconfirmed revoke stops without retry or false success'
        } elseif ($Scenario -eq 'GrantFailure') {
            Check ($failed -and $calls.grant -eq 1 -and $calls.revoke -eq 0) 'Failed grant does not retry or remove another assignment'
        } else {
            Check ($failed -and $calls.role -eq 0 -and $calls.grant -eq 0 -and $calls.revoke -eq 0) "Unsafe access request stops before mutation: $Scenario"
        }
    }
}
foreach ($scenario in @('Plan','GrantNew','GrantExistingRole','GrantRestart','RevokeRestart','WrongSubscription','WrongPrincipal','StoppedApp','RoleMismatch','DataActionRole','BroadRoleScope','FunctionApp','WrongPlan','PlanNotReady','ReadDenied','ExistingAssignment','GrantFailure','RevokeBadScope','RevokeSuccess','RevokeMissing','RevokeWrongObject','RevokeWrongScope','RevokeStale','OtherSubscription','Slot','InvalidPlan')) {
    Test-WebAccessScenario $scenario
}


Write-Host "PASS: $count Web App access checks (offline)."
