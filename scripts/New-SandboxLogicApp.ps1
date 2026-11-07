#requires -Version 7.2
# USER-RUN ONLY. Creates one new test RG and one disabled Consumption workflow.
# Without -Create, prints the plan only. No RBAC changes or automatic retry/deletion.
[CmdletBinding()]
param(
    [switch]$Create,
    [ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$ResourceGroupName,
    [ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$WorkflowName,
    [ValidatePattern('^[a-z0-9]+$')][string]$Location
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection = Read-OpsConnection
$config = Select-OpsSubscription $connection $connection.sandboxSubscriptionId
$settings = Resolve-OpsSandboxSettings -Name LogicApps -Connection $connection -Values @{resourceGroupName=$ResourceGroupName;workflowName=$WorkflowName;location=$Location}
$ResourceGroupName=$settings.resourceGroupName
$WorkflowName=$settings.workflowName
$Location=$settings.location
$groupId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$ResourceGroupName"
$resourceId = "$groupId/providers/Microsoft.Logic/workflows/$WorkflowName"
Assert-OpsResourceScope $resourceId $config.subscriptionId
$plan = [pscustomobject][ordered]@{
    TenantId = $config.tenantId
    SubscriptionId = $config.subscriptionId
    ResourceGroupId = $groupId
    ResourceId = $resourceId
    Location = $Location
    Service = 'LogicApps Consumption'
    State = 'Disabled'
    Trigger = 'HTTP Request (no scheduled execution)'
    Action = 'Compose a fixed test string (no external connection)'
}
if (-not $Create) {
    $plan | ConvertTo-Json
    return
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -MinimumVersion 10.0.0 -ErrorAction Stop
$payload = @{
    location = $Location
    tags = @{purpose='azure-ops-skills-sandbox'}
    properties = @{
        state = 'Disabled'
        definition = @{
            '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
            contentVersion = '1.0.0.0'
            parameters = @{}
            triggers = @{manual=@{type='Request'; kind='Http'; inputs=@{schema=@{}}}}
            actions = @{Compose=@{type='Compose'; inputs='azure-ops-skills sandbox test'; runAfter=@{}}}
            outputs = @{}
        }
        parameters = @{}
    }
} | ConvertTo-Json -Depth 12
$connected = $false
$stage = 'NotStarted'
try {
    $plan | ConvertTo-Json
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $config.tenantId -Subscription $config.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    $connected = $true
    Assert-OpsContext (Get-AzContext) $config 'User'
    $groups = @(Get-AzResourceGroup -ErrorAction Stop)
    if (@($groups | Where-Object ResourceGroupName -EQ $ResourceGroupName).Count) {
        throw '同名RGがあります。この初回試験用スクリプトは既存RGを使用・更新しません。再実行せず現状を確認してください。'
    }
    $provider = @(Get-AzResourceProvider -ListAvailable -ErrorAction Stop |
        Where-Object ProviderNamespace -EQ 'Microsoft.Logic')
    if (-not @($provider | Where-Object RegistrationState -EQ 'Registered').Count) {
        $registrationState = if ($provider.Count) { ($provider.RegistrationState | Sort-Object -Unique) -join ', ' } else { 'Unknown' }
        throw "Microsoft.Logicの登録完了を確認できません（状態: $registrationState）。自動登録せず停止しました。docs/sandbox-test.mdの登録手順を確認してください。"
    }
    Assert-OpsContext (Get-AzContext) $config 'User'
    $stage = 'CreatingResourceGroup'
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{purpose='azure-ops-skills-sandbox'} -ErrorAction Stop | Out-Null
    $stage = 'ResourceGroupCreated'
    $existing = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    if (@($existing | Where-Object ResourceId -EQ $resourceId).Count) {
        throw '同名のLogic Appが存在します。上書きせず停止しました。'
    }
    Assert-OpsContext (Get-AzContext) $config 'User'
    $stage = 'CreatingWorkflow'
    $result = Invoke-AzRestMethod -Path "${resourceId}?api-version=2019-05-01" -Method PUT -Payload $payload -ErrorAction Stop
    if ($result.StatusCode -notin @(200,201)) { throw "作成結果 HTTP $($result.StatusCode)。再実行せず現状を確認してください。" }
    $stage = 'WorkflowCreated'
    Assert-OpsContext (Get-AzContext) $config 'User'
    $result = Invoke-AzRestMethod -Path "${resourceId}?api-version=2019-05-01" -Method GET -ErrorAction Stop
    if ($result.StatusCode -ne 200) { throw "作成後の確認 HTTP $($result.StatusCode)" }
    $workflow = $result.Content | ConvertFrom-Json -AsHashtable
    if ($workflow.id -ine $resourceId -or $workflow.properties.state -ne 'Disabled' -or
        $workflow.properties.provisioningState -ne 'Succeeded') {
        throw '作成後のID・無効状態・プロビジョニング成功を確認できません。再実行せず確認してください。'
    }
    # Allowlisted metadata only: never print the definition or endpoint URL.
    ConvertTo-OpsInventoryRow $workflow | ConvertTo-Json -Depth 5
    Write-Host 'Created and verified: disabled Consumption workflow. No write role was granted to the dedicated app.'
} catch {
    if ($stage -eq 'NotStarted') {
        Write-Warning "事前確認で停止しました。この実行ではRG・Logic Appの作成処理を開始していません。対象: $resourceId"
    } else {
        Write-Warning "試験作成を停止しました。段階: $stage。部分作成の可能性があります。自動再実行・削除はしません。対象: $resourceId"
    }
    throw
} finally {
    if ($connected) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
}
