#requires -Version 7.2
# Offline verification. Does not authenticate, install modules, mutate Azure, or write test fixtures.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Common.ps1')
$count = 0
function Check {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:count++
}
function Rejects {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Check $rejected $Message
}

# All PowerShell files must parse before any user can run the Azure setup commands.
$scriptFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    $syntaxDetails = @($errors | ForEach-Object { $_.Message }) -join '; '
    Check ($errors.Count -eq 0) "PowerShell syntax: $($file.Name) $syntaxDetails"
}

$sub = '11111111-1111-1111-1111-111111111111'
$otherSub = '22222222-2222-2222-2222-222222222222'
$testProfile = @{subscriptionIds=@($sub);sandboxSubscriptionId=$sub}
Check ((Select-OpsSubscription $testProfile $sub).subscriptionId -eq $sub) 'Explicit allowed subscription selected'
Rejects { Select-OpsSubscription $testProfile $otherSub } 'Unlisted subscription rejected'
Check (-not $testProfile.ContainsKey('subscriptionId')) 'Selection does not change stored profile'
$resourceId = "/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/sites/test-app"
Assert-OpsResourceScope $resourceId $sub
Check $true 'Individual resource scope is allowed'
Assert-OpsResourceScope "$resourceId/slots/staging" $sub
Check $true 'Individual child resource scope is allowed'
Rejects { Assert-OpsResourceScope "/subscriptions/$sub" $sub } 'Subscription-wide change scope is rejected'
Rejects { Assert-OpsResourceScope "/subscriptions/$sub/resourceGroups/rg-test" $sub } 'RG-wide change scope is rejected'
Rejects { Assert-OpsResourceScope $resourceId $otherSub } 'Cross-subscription change scope is rejected'
Rejects { Assert-OpsResourceScope "$resourceId/*" $sub } 'Wildcard scope is rejected'
Rejects { Assert-OpsResourceScope "$resourceId?scope=all" $sub } 'Query-injected scope is rejected'
Rejects { Assert-OpsResourceScope ($resourceId + '/../other') $sub } 'Traversal scope is rejected'
Rejects { Assert-OpsGuid '00000000-0000-0000-0000-000000000000' } 'Template GUID cannot be used'

Check ((Get-OpsServiceKind 'Microsoft.Web/sites' 'functionapp,workflowapp') -eq 'LogicApps') 'Standard Logic App is not mistaken for Functions'
Check ((Get-OpsServiceKind 'Microsoft.Web/sites' 'functionapp,linux') -eq 'Functions') 'Function App classification'
Check ((Get-OpsServiceKind 'Microsoft.Web/sites' 'app,linux') -eq 'AppService') 'Web App classification'
Check ((Get-OpsServiceKind 'Microsoft.Logic/workflows' '') -eq 'LogicApps') 'Consumption Logic App classification'

$collection = "/subscriptions/$sub/providers/Microsoft.Web/sites"
Check ((Get-OpsNextPath "https://management.azure.com${collection}?api-version=2024-11-01&skiptoken=next" $collection) -like "$collection*") 'Expected next page stays on ARM collection'
Rejects { Get-OpsNextPath "https://example.invalid$collection" $collection } 'External nextLink rejected'
Rejects { Get-OpsNextPath "https://management.azure.com/subscriptions/$otherSub/providers/Microsoft.Web/sites" $collection } 'Cross-subscription nextLink rejected'
Rejects { Get-OpsNextPath "https://management.azure.com$resourceId/config/list" $collection } 'Unexpected API in nextLink rejected'
Rejects { Get-OpsNextPath "http://management.azure.com$collection" $collection } 'HTTP nextLink rejected'

$unsafeResource = @{
    id=$resourceId; name='test-app'; type='Microsoft.Web/sites'; kind='app'; location='japaneast'
    tags=@{ note='DO_NOT_OUTPUT_TAG' }
    properties=@{
        state='Running'; serverFarmId='plan-reference'
        appSettings=@{Password='DO_NOT_OUTPUT_SETTING'}
        definition=@{text='DO_NOT_OUTPUT_DEFINITION'}
        accessEndpoint='https://example.invalid/?sig=DO_NOT_OUTPUT_URL'
    }
}
$safeJson = ConvertTo-OpsInventoryRow $unsafeResource | ConvertTo-Json -Depth 10
Check ($safeJson -notmatch 'DO_NOT_OUTPUT_') 'Only whitelisted inventory properties are emitted'
Check ($safeJson -match 'Running') 'Useful metadata remains in inventory'

$role = Get-Content -LiteralPath (Join-Path $root 'roles\services-reader.json') -Raw | ConvertFrom-Json
Assert-OpsReaderRole $role
Check $true 'Reader uses one Permissions entry supported by Az.Resources 10+'
Check (-not $role.PSObject.Properties['Actions']) 'No deprecated root Actions in input JSON'
Check ($role.Permissions[0].DataActions.Count -eq 0) 'No data-plane rights'
Check ($role.Permissions[0].NotActions.Count -eq 0) 'Reader does not rely on subtracting broad privileges'
foreach ($action in $role.Permissions[0].Actions) {
    Check ($action -notmatch '\*' -and $action -match '/read$') "Read-only explicit action: $action"
    Check ($action -notmatch '(?i)accesskeys|listkeys|secrets|connectionstrings|appsettings|runs|credentials') "No sensitive reader action: $action"
}
Check ($role.AssignableScopes.Count -eq 1 -and $role.AssignableScopes[0] -eq '/subscriptions/<SUBSCRIPTION_ID>') 'Reader template has no real subscription'


# Permission/schema regressions: fail before creating credentials or granting a role.
function Copy-TestRole { $role | ConvertTo-Json -Depth 8 | ConvertFrom-Json }
$legacyRole = [pscustomobject]@{
    Name=$role.Name; IsCustom=$true; Actions=@('Microsoft.Web/sites/read')
    NotActions=@(); DataActions=@(); NotDataActions=@(); AssignableScopes=$role.AssignableScopes
}
Rejects { Assert-OpsReaderRole $legacyRole } 'Old flat JSON that caused Invalid value for Permissions is rejected'
foreach ($unsafeAction in @('Microsoft.Web/sites/write','Microsoft.Web/sites/delete','*/read','Microsoft.Web/sites/config/list/action','Microsoft.Web/sites/secrets/read')) {
    $changed = Copy-TestRole
    $changed.Permissions[0].Actions += $unsafeAction
    Rejects { Assert-OpsReaderRole $changed } "Unsafe reader action rejected: $unsafeAction"
}
foreach ($field in @('NotActions','DataActions','NotDataActions')) {
    $changed = Copy-TestRole
    $changed.Permissions[0].$field = @('Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read')
    Rejects { Assert-OpsReaderRole $changed } "Unexpected $field rejected"
}
$changed = Copy-TestRole
$changed.Permissions = @($changed.Permissions[0],$changed.Permissions[0])
Rejects { Assert-OpsReaderRole $changed } 'Multiple permission entries rejected'
$changed = Copy-TestRole
$changed.Permissions[0].Actions = @()
Rejects { Assert-OpsReaderRole $changed } 'Empty permission list rejected'
$changed = Copy-TestRole
$changed.IsCustom = $false
Rejects { Assert-OpsReaderRole $changed } 'Built-in role cannot be reused'
$changed = Copy-TestRole
$changed.Permissions[0] | Add-Member -NotePropertyName Condition -NotePropertyValue 'unexpected-condition'
Rejects { Assert-OpsReaderRole $changed } 'Unexpected permission condition rejected'
$changed = Copy-TestRole
$changed.Permissions[0].Actions = @($changed.Permissions[0].Actions | Sort-Object -Descending)
Assert-OpsMatchingReaderRole $changed $role
Check $true 'Equivalent existing role can be reused regardless of action order'
$changed.Permissions[0].NotActions = $null
$changed.Permissions[0].DataActions = $null
$changed.Permissions[0].NotDataActions = $null
Assert-OpsMatchingReaderRole $changed $role
Check $true 'Null empty collections in Azure role output are supported'
$changed = Copy-TestRole
$changed.Permissions[0].Actions += 'Microsoft.Compute/virtualMachines/read'
Rejects { Assert-OpsMatchingReaderRole $changed $role } 'Existing role with extra service permission cannot be reused'
$changed = Copy-TestRole
$changed.AssignableScopes += "/subscriptions/$otherSub"
Rejects { Assert-OpsMatchingReaderRole $changed $role } 'Existing role with broader assignment scope cannot be reused'
$changed = Copy-TestRole
$changed.Name = 'Unrelated role'
Rejects { Assert-OpsMatchingReaderRole $changed $role } 'Different existing role name rejected'

# Resume only after all identity stages completed, using identifiers already recorded locally.
$resumeState = @{
    tenantId=$sub; applicationId=$otherSub; applicationObjectId=$sub
    servicePrincipalObjectId=$otherSub; sandboxSubscriptionId=$sub
    subscriptionIds=@($sub); certificateThumbprint=('A' * 40); stage='ServicePrincipalCreated'
}
Assert-OpsResumeState $resumeState
Check $true 'Failed role creation can resume with the existing identity'
foreach ($stage in @('NotStarted','CertificateCreated','ApplicationCreated','PublicCertificateRegistered')) {
    $changedState = $resumeState.Clone()
    $changedState.stage = $stage
    Rejects { Assert-OpsResumeState $changedState } "Incomplete identity stage cannot resume: $stage"
}
foreach ($stage in @('ReaderRoleCreated',"ReaderAssigned:$sub",'Completed')) {
    $changedState = $resumeState.Clone()
    $changedState.stage = $stage
    $changedState.readerRoleId = $otherSub
    Assert-OpsResumeState $changedState
    Check $true "Completed provisioning step can be checked without recreating the identity: $stage"
}
$changedState = $resumeState.Clone()
$changedState.Remove('applicationObjectId')
Rejects { Assert-OpsResumeState $changedState } 'Missing recorded application object rejected'
$changedState = $resumeState.Clone()
$changedState.subscriptionIds = @($otherSub)
Rejects { Assert-OpsResumeState $changedState } 'Sandbox outside recorded target list rejected'
$changedState = $resumeState.Clone()
$changedState.certificateThumbprint = '../other'
Rejects { Assert-OpsResumeState $changedState } 'Invalid certificate selector rejected'
$changedState = $resumeState.Clone()
$changedState.stage = "ReaderAssigned:$otherSub"
$changedState.readerRoleId = $otherSub
Rejects { Assert-OpsResumeState $changedState } 'Assignment checkpoint outside target subscriptions rejected'
$changedState = $resumeState.Clone()
$changedState.stage = 'ReaderRoleCreated'
Rejects { Assert-OpsResumeState $changedState } 'Completed role checkpoint without a role ID rejected'

foreach ($name in @('azure-appservice','azure-functions','azure-logicapps')) {
    $skillPath = Join-Path $root "skills\$name\SKILL.md"
    $skill = Get-Content -LiteralPath $skillPath -Raw
    Check ($skill -match "(?m)^name: $name$" -and $skill -match '(?m)^description: .+$') "Skill manifest: $name"
}
# Supplement to .gitignore, not a comprehensive secret scanner. Fail with file name only.
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
    if ($file.FullName -match '[\\/](\.git|\.local|artifacts|evidence|output)[\\/]') { continue }
    Check ($file.Extension -notin @('.pfx','.p12','.pem','.key','.cer','.crt')) "No credential file: $($file.Name)"
    if ($file.Extension -in @('.md','.ps1','.json') -or $file.Name -eq '.gitignore') {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        Check ($content -notmatch '(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----$') "No private-key block: $($file.Name)"
        Check ($content -notmatch '(?i)"(?:clientSecret|password|access_token|refresh_token)"\s*:\s*"[^"]+"') "No credential value: $($file.Name)"
    }
}
Write-Host "PASS: $count offline checks. Azure authentication, role provisioning and live retrieval remain unverified."
