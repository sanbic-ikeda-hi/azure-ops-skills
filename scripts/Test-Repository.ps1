#requires -Version 7.2
# Offline verification. No Azure/authentication/install; report tests use isolated TEMP fixtures.
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

# Fixed GUIDs must be deliberate test data or public Microsoft role IDs.
$publicRoleIds=@('b7e6dc6d-f1e8-4753-8033-0f276bb0955b','0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
foreach ($file in $scriptFiles) {
    $content=Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($match in [regex]::Matches($content,'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')) {
        Check ($match.Value -match '^([0-9a-f])\1{7}-\1{4}-\1{4}-\1{4}-\1{12}$' -or $match.Value -in $publicRoleIds) "Only dummy or public role GUIDs: $($file.Name)"
    }
    Check ($content -notmatch '(?i)\b[A-Z]:[\\/]+Users[\\/]+[A-Za-z0-9_.-]+[\\/]') "No personal absolute path: $($file.Name)"
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

# Resource selection determines the later permission scope: exercise data boundaries.
$inventoryRow = ConvertTo-OpsInventoryRow $unsafeResource
Check ($inventoryRow.SubscriptionId -eq $sub -and $inventoryRow.ResourceGroupName -eq 'rg-test') 'Candidate identity comes from the full resource ID'
$badResource = $unsafeResource.Clone()
$badResource.id = '/not-a-resource'
Rejects { ConvertTo-OpsInventoryRow $badResource } 'Malformed candidate identity rejected'
$badResource.id = "${resourceId}?unexpected=true"
Rejects { ConvertTo-OpsInventoryRow $badResource } 'Ambiguous candidate identity rejected'
$anotherResource = $unsafeResource.Clone()
$anotherResource.id = "/subscriptions/$sub/resourceGroups/rg-orders/providers/Microsoft.Web/sites/test-app"
$anotherRow = ConvertTo-OpsInventoryRow $anotherResource
$inventoryRows = @($inventoryRow, $anotherRow)
Check (@(Select-OpsInventoryResource -Resources $inventoryRows).Count -eq 2) 'No filters returns all candidates, including identical names in different groups'
Check (@(Select-OpsInventoryResource -Resources $inventoryRows -Keyword 'TEST-APP').Count -eq 2) 'Name keyword ignores case and does not collapse identical names'
$selected = @(Select-OpsInventoryResource -Resources $inventoryRows -Keyword 'ORDERS')
Check ($selected.Count -eq 1 -and $selected[0].ResourceId -eq $anotherRow.ResourceId) 'Keyword matches the resource group and preserves the exact ID'
$selected = @(Select-OpsInventoryResource -Resources $inventoryRows -Keyword 'test' -ResourceGroupName 'RG-TEST')
Check ($selected.Count -eq 1 -and $selected[0].ResourceId -eq $resourceId) 'Keyword and exact case-insensitive group filter are combined with AND'
Check (@(Select-OpsInventoryResource -Resources $inventoryRows -ResourceGroupName 'rg').Count -eq 0) 'Resource group filter is exact, not a prefix'
Check (@(Select-OpsInventoryResource -Resources $inventoryRows -Keyword 'orders' -ResourceGroupName 'rg-test').Count -eq 0) 'Conflicting conditions do not widen the search'
Check (@(Select-OpsInventoryResource -Resources $inventoryRows -Keyword 'missing').Count -eq 0) 'No keyword match returns an empty selection'
Check (@(Select-OpsInventoryResource -Resources @() -Keyword 'test').Count -eq 0) 'Empty inventory remains empty'
foreach ($literal in @('*', '[', '.', 'test|orders', 'DO_NOT_OUTPUT_', 'Running', 'japaneast')) {
    Check (@(Select-OpsInventoryResource -Resources $inventoryRows -Keyword $literal).Count -eq 0) "Keyword is literal and searches only name and group: $literal"
}
$ordered = @(Select-OpsInventoryResource -Resources @($anotherRow, $inventoryRow))
Check (($ordered.ResourceId -join '|') -eq ((Select-OpsInventoryResource -Resources $inventoryRows).ResourceId -join '|')) 'Input order does not change candidate ordering'
Check ($inventoryRows.Count -eq 2 -and $inventoryRows[0].ResourceId -eq $resourceId) 'Selection does not mutate source inventory'
foreach ($parameter in @('Keyword','ResourceGroupName')) {
    $invalidFilter = @{$parameter='   '}
    Rejects { & (Join-Path $PSScriptRoot 'Get-ServiceInventory.ps1') -Service Functions -SubscriptionId $sub @invalidFilter } "Blank $parameter rejected before connection"
}

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
foreach ($unsafeAction in @('Microsoft.Web/sites/write','Microsoft.Web/sites/delete','*/read','Microsoft.Web/sites/config/list/action','Microsoft.Web/sites/secrets/read','Microsoft.Web/sites/publishxml/read','Microsoft.Web/sites/publishingcredentials/read','Microsoft.Web/sites/basicPublishingCredentialsPolicies/unknown/read','Microsoft.Unknown/service/read')) {
    $changed = Copy-TestRole
    $changed.Permissions[0].Actions += $unsafeAction
    Rejects { Assert-OpsReaderRole $changed } "Unsafe reader action rejected: $unsafeAction"
}
foreach ($safeAction in @('Microsoft.Web/sites/basicPublishingCredentialsPolicies/read','Microsoft.Insights/metricDefinitions/read','Microsoft.Insights/metrics/read')) {
    $changed = Copy-TestRole
    $changed.Permissions[0].Actions += $safeAction
    Assert-OpsReaderRole $changed
    Check $true "Explicit optional metadata reader action accepted: $safeAction"
    Check ($safeAction -notin $role.Permissions[0].Actions) "Optional diagnostics do not widen the initial reader: $safeAction"
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

# Certificate lookup must fail before authentication when the OS user cannot see it.
& {
    $calls = @{connect=0}
    function Import-Module {}
    function Test-Path { return $false }
    function Connect-AzAccount { $calls.connect++ }
    Rejects { Connect-OpsApplication @{certificateThumbprint=('A' * 40)} } 'Missing user certificate stops before authentication'
    Check ($calls.connect -eq 0) 'Missing certificate never falls back to another login'
}

# Exercise the user-run creation workflow with in-memory Azure/profile mocks only.
function Test-SandboxCreationScenario {
    param([string]$Scenario)
    $calls = @{connect=0; disconnect=0; group=0; put=0; get=0; payload=$null; path=$null}
    $fakeConnection = @{
        tenantId=$sub; subscriptionIds=@($sub); sandboxSubscriptionId=$sub
        applicationId=$otherSub; servicePrincipalObjectId=$otherSub; certificateThumbprint=('A' * 40)
    } | ConvertTo-Json
    $testWorkflowId = "/subscriptions/$sub/resourceGroups/rg-azureops-sandbox-test/providers/Microsoft.Logic/workflows/la-azureops-sandbox-test"
    function Test-Path { return $true }
    function Get-Content { return $fakeConnection }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount { $calls.connect++ }
    function Disconnect-AzAccount { $calls.disconnect++ }
    function Get-AzContext {
        @{Tenant=@{Id=$sub}; Subscription=@{Id=$(if ($Scenario -eq 'WrongSubscription') {$otherSub} else {$sub})}; Account=@{Type='User'}; Environment=@{Name='AzureCloud'}}
    }
    function Get-AzResourceGroup {
        if ($Scenario -eq 'ExistingGroup') { @{ResourceGroupName='rg-azureops-sandbox-test'} }
    }
    function Get-AzResourceProvider {
        [CmdletBinding(DefaultParameterSetName='ListAvailable')]
        param(
            [Parameter(ParameterSetName='ListAvailable')][switch]$ListAvailable,
            [Parameter(Mandatory,ParameterSetName='IndividualProvider')][string[]]$ProviderNamespace
        )
        if ($ListAvailable) {
            [pscustomobject]@{ProviderNamespace='Microsoft.Storage'; RegistrationState='Registered'}
            [pscustomobject]@{ProviderNamespace='Microsoft.Logic'; RegistrationState=$(if ($Scenario -eq 'Unregistered') {'NotRegistered'} else {'Registered'})}
        } else { throw 'Preflight must include unregistered providers' }
    }
    function New-AzResourceGroup { $calls.group++ }
    function Get-AzResource {
        if ($Scenario -eq 'ExistingWorkflow') { @{ResourceId=$testWorkflowId} }
    }
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        if ($Method -eq 'PUT') {
            $calls.put++
            $calls.path = $Path
            $calls.payload = $Payload | ConvertFrom-Json -AsHashtable
            return @{StatusCode=$(if ($Scenario -eq 'PutFailure') {403} else {201})}
        }
        if ($Method -ne 'GET') { throw 'Unexpected mutation in creation test' }
        $calls.get++
        @{
            StatusCode=200
            Content=(@{
                id=$testWorkflowId; name='la-azureops-sandbox-test'; type='Microsoft.Logic/workflows'; location='japaneast'
                properties=@{state=$(if ($Scenario -eq 'EnabledResult') {'Enabled'} else {'Disabled'}); provisioningState='Succeeded'; accessEndpoint='DO_NOT_OUTPUT_ENDPOINT'}
            } | ConvertTo-Json -Depth 5)
        }
    }
    $failed = $false
    try {
        $output = & (Join-Path $PSScriptRoot 'New-SandboxLogicApp.ps1') -ResourceGroupName 'rg-azureops-sandbox-test' -WorkflowName 'la-azureops-sandbox-test' -Location 'japaneast' -Create:($Scenario -ne 'Plan') -WarningAction SilentlyContinue -WarningVariable creationWarnings 6>$null
    } catch { $failed = $true; $failureMessage = $_.Exception.Message }
    if ($Scenario -eq 'Plan') {
        Check (-not $failed -and $calls.connect -eq 0 -and $calls.group -eq 0 -and $calls.put -eq 0) 'Plan makes no connection or mutation'
        Check (($output | ConvertFrom-Json).SubscriptionId -eq $sub) 'Plan targets the configured sandbox'
        return
    }
    Check ($calls.connect -eq 1 -and $calls.disconnect -eq 1) "Creation session disconnects: $Scenario"
    if ($Scenario -eq 'Success') {
        Check (-not $failed -and $calls.group -eq 1 -and $calls.put -eq 1 -and $calls.get -eq 1) 'Create once then independently read back'
        Check ($calls.path -eq "${testWorkflowId}?api-version=2019-05-01") 'PUT targets the exact sandbox workflow'
        $body = $calls.payload
        Check ($body.properties.state -eq 'Disabled' -and $body.properties.definition.triggers.manual.type -eq 'Request') 'New workflow is disabled with no schedule'
        Check ($body.properties.definition.actions.Count -eq 1 -and $body.properties.definition.actions.Compose.type -eq 'Compose' -and
            -not $body.ContainsKey('identity') -and $body.properties.parameters.Count -eq 0) 'No connector, managed identity or connection parameters created'
        Check (($output -join '') -notmatch 'DO_NOT_OUTPUT_ENDPOINT') 'Creation output suppresses endpoint URL'
    } else {
        Check $failed "Unsafe or incomplete creation stops: $Scenario"
        if ($Scenario -in @('ExistingGroup','WrongSubscription','Unregistered')) {
            Check ($calls.group -eq 0 -and $calls.put -eq 0) "Preflight failure creates nothing: $Scenario"
            Check (($creationWarnings -join '') -match '事前確認' -and ($creationWarnings -join '') -notmatch '部分作成') "Preflight warning does not imply partial creation: $Scenario"
            if ($Scenario -eq 'Unregistered') {
                Check ($failureMessage -match 'NotRegistered') 'Unregistered Logic provider is reported even when another provider is registered'
            }
        } elseif ($Scenario -eq 'ExistingWorkflow') {
            Check ($calls.put -eq 0) 'Existing workflow is never overwritten'
        } elseif ($Scenario -eq 'PutFailure') {
            Check ($calls.put -eq 1 -and $calls.get -eq 0) 'Failed PUT is not retried or reported as verified'
        }
    }
}
foreach ($scenario in @('Plan','Success','ExistingGroup','WrongSubscription','Unregistered','ExistingWorkflow','PutFailure','EnabledResult')) {
    Test-SandboxCreationScenario $scenario
}

& (Join-Path $PSScriptRoot 'Test-SandboxLogicAppAccess.ps1')

foreach ($name in @('azure-appservice','azure-functions','azure-logicapps')) {
    $skillPath = Join-Path $root "skills\$name\SKILL.md"
    $skill = Get-Content -LiteralPath $skillPath -Raw
    Check ($skill -match "(?m)^name: $name$" -and $skill -match '(?m)^description: .+$') "Skill manifest: $name"
}
# Simulate packaging in memory: no installed skill or fixture is created.
& {
    $copies = [Collections.Generic.List[object]]::new()
    function New-Item { param($ItemType, $Path, [switch]$Force) }
    function Copy-Item {
        param($LiteralPath, $Destination)
        $copies.Add([pscustomobject]@{Source=$LiteralPath; Target=(Join-Path $Destination (Split-Path $LiteralPath -Leaf))})
    }
    $previewRoot = Join-Path $root ('.local/offline-layout-' + [guid]::NewGuid().ToString('N'))
    & (Join-Path $PSScriptRoot 'Install-Skills.ps1') -Destination $previewRoot
    Check ($copies.Count -eq 53) 'Base package has sixteen files per skill; App Service adds four helpers and one reference'
    foreach ($name in @('azure-appservice','azure-functions','azure-logicapps')) {
        $expected = @{
            'SKILL.md'="skills/$name/SKILL.md"
            'scripts/Common.ps1'='scripts/Common.ps1'
            'scripts/Authentication.ps1'='scripts/Authentication.ps1'
            'scripts/UserSettings.ps1'='scripts/UserSettings.ps1'
            'scripts/Get-UserSettings.ps1'='scripts/Get-UserSettings.ps1'
            'scripts/Set-UserSettings.ps1'='scripts/Set-UserSettings.ps1'
            'scripts/Get-ServiceInventory.ps1'='scripts/Get-ServiceInventory.ps1'
            'scripts/Get-InventoryReport.ps1'='scripts/Get-InventoryReport.ps1'
            'scripts/Get-AppServiceQuota.ps1'='scripts/Get-AppServiceQuota.ps1'
            'scripts/ServiceOperations.ps1'='scripts/ServiceOperations.ps1'
            'scripts/ConfigurationComparison.ps1'='scripts/ConfigurationComparison.ps1'
            'scripts/Get-ServiceDetails.ps1'='scripts/Get-ServiceDetails.ps1'
            'scripts/Invoke-ServiceOperation.ps1'='scripts/Invoke-ServiceOperation.ps1'
            'references/change-workflow.md'='docs/change-workflow.md'
            'references/authentication.md'='docs/authentication.md'
            'references/service-operations.md'='docs/service-operations.md'
        }
        if ($name -eq 'azure-appservice') {
            $expected['scripts/AppServiceDiagnostics.ps1']='scripts/AppServiceDiagnostics.ps1'
            $expected['scripts/Get-AppServiceDiagnostics.ps1']='scripts/Get-AppServiceDiagnostics.ps1'
            $expected['scripts/AppServiceReadiness.ps1']='scripts/AppServiceReadiness.ps1'
            $expected['scripts/Wait-AppServiceReady.ps1']='scripts/Wait-AppServiceReady.ps1'
            $expected['references/appservice-operations.md']='docs/appservice-operations.md'
        }
        $skillTarget=[IO.Path]::GetFullPath((Join-Path $previewRoot $name)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        Check (@($copies | Where-Object {([IO.Path]::GetFullPath($_.Target)).StartsWith($skillTarget,[StringComparison]::OrdinalIgnoreCase)}).Count -eq $expected.Count) "Only declared files are packaged for $name"
        foreach ($relativePath in $expected.Keys) {
            $targetPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $previewRoot $name) $relativePath))
            $copy = @($copies | Where-Object { [IO.Path]::GetFullPath($_.Target) -eq $targetPath })
            Check ($copy.Count -eq 1 -and [IO.Path]::GetFullPath($copy[0].Source) -eq [IO.Path]::GetFullPath((Join-Path $root $expected[$relativePath])) -and
                (Test-Path -LiteralPath $copy[0].Source -PathType Leaf)) "Source and packaged reference resolve: $name/$relativePath"
        }
    }
    Check (-not (Test-Path -LiteralPath $previewRoot)) 'Packaging simulation writes nothing'
    Check (-not @($copies | Where-Object { (Split-Path $_.Source -Leaf) -in @('connection.json','user-settings.json','provision-state.json') }).Count) 'Local profiles are never packaged'
}
# Installation preview and conflicts must never write or partially install another skill.
& {
    $writes=@{count=0}
    function New-Item { $writes.count++ }
    function Copy-Item { $writes.count++ }
    $previewRoot=Join-Path $root ('.local/offline-preview-' + [guid]::NewGuid().ToString('N'))
    & (Join-Path $PSScriptRoot 'Install-Skills.ps1') -Destination $previewRoot -WhatIf
    Check ($writes.count -eq 0) 'Install WhatIf performs no writes'
    foreach ($conflict in @('azure-appservice','azure-functions','azure-logicapps')) {
        function Test-Path {
            param($LiteralPath,$PathType)
            if ($LiteralPath -eq (Join-Path $previewRoot $conflict)) { return $true }
            Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        Rejects { & (Join-Path $PSScriptRoot 'Install-Skills.ps1') -Destination $previewRoot } "Existing skill is never overwritten: $conflict"
        Check ($writes.count -eq 0) "Conflict detected before any partial installation: $conflict"
    }
}
& (Join-Path $PSScriptRoot 'Test-ServiceInventory.ps1')
& (Join-Path $PSScriptRoot 'Test-InventorySummary.ps1')
& (Join-Path $PSScriptRoot 'Test-InventoryReportFile.ps1')
& (Join-Path $PSScriptRoot 'Test-ServiceOperations.ps1')
& (Join-Path $PSScriptRoot 'Test-AppServiceDiagnostics.ps1')
& (Join-Path $PSScriptRoot 'Test-AppServiceReadiness.ps1')
& (Join-Path $PSScriptRoot 'Test-ConfigurationComparison.ps1')
& (Join-Path $PSScriptRoot 'Test-UserSettings.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxAppService.ps1')
& (Join-Path $PSScriptRoot 'Test-ArmErrorSummary.ps1')
& (Join-Path $PSScriptRoot 'Test-AppServiceQuota.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxAppServiceAccess.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxWebAppCreation.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxWebAppExecution.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxFunctionAppCreation.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxFunctionsAccess.ps1')
& (Join-Path $PSScriptRoot 'Test-SandboxFunctionsExecution.ps1')
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
Write-Host "PASS: $count offline checks. These checks do not authenticate, provision roles or verify live Azure."
