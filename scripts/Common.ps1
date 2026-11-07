#requires -Version 7.2
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Authentication.ps1')
. (Join-Path $PSScriptRoot 'UserSettings.ps1')

function Assert-OpsResourceScope {
    param([string]$ResourceId, [string]$SubscriptionId)
    Assert-OpsGuid $SubscriptionId 'SubscriptionId'
    $prefix = "/subscriptions/$SubscriptionId/resourceGroups/"
    if (-not $ResourceId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '対象サブスクリプション外のリソースです。'
    }
    $pattern = '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/?#%]+/providers/[A-Za-z0-9.]+(?:/[A-Za-z0-9._-]+/[^/?#%]+)+$'
    if ($ResourceId -notmatch $pattern -or $ResourceId -match '[\s*''";]' -or $ResourceId.Contains('..')) {
        throw '変更権限は個別のリソースIDに限定します。サブスクリプション・RG・曖昧なパスは使えません。'
    }
}

function Get-OpsArmErrorSummary {
    param($Response)
    # Never emit arbitrary message text, claims, parameters, headers, or the response body.
    function Read-ErrorField($Object, [string]$Name) {
        if ($Object -is [System.Collections.IDictionary]) {
            foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        } elseif ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
        return $null
    }
    $codes = [Collections.Generic.List[string]]::new()
    $extended = [Collections.Generic.List[string]]::new()
    $quota = @{}
    $state = @{parsed=$false; quotaEvidence=$false; nodes=0}
    function Read-ErrorNode($Node, [int]$Depth=0) {
        if ($Depth -gt 8 -or $state.nodes -ge 100 -or $Node -isnot [System.Collections.IDictionary]) { return }
        $state.nodes++
        foreach ($field in @('code','extendedCode')) {
            $value = Read-ErrorField $Node $field
            if ($value -is [string] -and $value -cmatch '^[A-Za-z0-9_.-]{1,128}$') {
                if ($field -eq 'code') { $codes.Add($value) } else { $extended.Add($value) }
            }
        }
        $message = Read-ErrorField $Node 'message'
        if ($message -is [string] -and $message.Length -le 32768 -and
            $message -match 'Operation\s+cannot\s+be\s+completed\s+without\s+additional\s+quota') {
            $state.quotaEvidence=$true
            # Only well-known numeric fields are retained, including zero. No free-form text.
            $patterns = @{
                CurrentLimit='Current\s+Limit\s*\([^\r\n)]{1,64}\)\s*:\s*(\d{1,9})\b'
                CurrentUsage='Current\s+Usage\s*:\s*(\d{1,9})\b'
                Required='Amount\s+required\s+for\s+this\s+deployment\s*\([^\r\n)]{1,64}\)\s*:\s*(\d{1,9})\b'
                MinimumNewLimit='New\s+Limit\s+that\s+you\s+should\s+request\s+to\s+enable\s+this\s+deployment\s*:\s*(\d{1,9})\b'
            }
            foreach ($name in $patterns.Keys) { if ($message -match $patterns[$name]) { $quota[$name]=[int]$Matches[1] } }
        }
        foreach ($field in @('error','details','innererror','errorEntity')) {
            $child = Read-ErrorField $Node $field
            foreach ($entry in @($child)) { Read-ErrorNode $entry ($Depth+1) }
        }
    }
    $content = Read-ErrorField $Response 'Content'
    if ($content -is [string] -and $content.Length -le 1048576) {
        try {
            $body = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($body -is [System.Collections.IDictionary]) { $state.parsed=$true; Read-ErrorNode $body }
        } catch { $state.parsed=$false }
    }
    $category = 'Unknown'
    if ($state.quotaEvidence -or @($codes | Where-Object { $_ -in @('SubscriptionIsOverQuotaForSku','InternalSubscriptionIsOverQuotaForSku','QuotaExceeded') }).Count) { $category='Quota' }
    elseif (@($codes | Where-Object { $_ -in @('MissingSubscriptionRegistration','NoRegisteredProviderFound') }).Count) { $category='ProviderRegistration' }
    elseif (@($codes | Where-Object { $_ -in @('InvalidAuthenticationToken','ExpiredAuthenticationToken','AuthenticationFailed') }).Count) { $category='Authentication' }
    elseif (@($codes | Where-Object { $_ -in @('AuthorizationFailed','LinkedAuthorizationFailed','DenyAssignmentAuthorizationFailed') }).Count) { $category='Authorization' }
    $status=0
    $rawStatus=Read-ErrorField $Response 'StatusCode'
    if ($rawStatus -is [Net.HttpStatusCode]) {$status=[int]$rawStatus}
    else {[void][int]::TryParse([string]$rawStatus,[ref]$status)}
    [pscustomobject][ordered]@{
        HttpStatus=$status; ErrorCodes=@($codes | Select-Object -Unique)
        ExtendedCodes=@($extended | Select-Object -Unique); CategoryHint=$category
        Quota=$quota; BodyParsed=$state.parsed; MessageOmitted=$true
    }
}

function Get-OpsServiceKind {
    param([string]$Type, [string]$Kind)
    if ($Type -ieq 'Microsoft.Logic/workflows') { return 'LogicApps' }
    if ($Type -ine 'Microsoft.Web/sites') { return 'Other' }
    $parts = @($Kind.ToLowerInvariant().Split(',') | ForEach-Object { $_.Trim() })
    if ('workflowapp' -in $parts) { return 'LogicApps' }
    if ('functionapp' -in $parts) { return 'Functions' }
    if ('app' -in $parts) { return 'AppService' }
    return 'Other'
}

function ConvertTo-OpsInventoryRow {
    param([System.Collections.IDictionary]$Resource)
    $resourceId = [string]$Resource['id']
    if ($resourceId -notmatch '^/subscriptions/(?<subscription>[0-9a-f-]{36})/resourceGroups/(?<group>[^/]+)/providers/') {
        throw '一覧のリソースIDからサブスクリプションとリソースグループを確認できません。'
    }
    $subscriptionId = $Matches.subscription
    $resourceGroupName = $Matches.group
    Assert-OpsResourceScope $resourceId $subscriptionId
    $properties = $Resource['properties']
    if (-not $properties) { $properties = @{} }
    $identity = $Resource['identity']
    if (-not $identity) { $identity = @{} }
    if ($properties -isnot [System.Collections.IDictionary] -or $identity -isnot [System.Collections.IDictionary]) {
        throw 'Inventory metadata must be an object.'
    }
    foreach ($value in @($Resource['name'],$Resource['type'],$Resource['kind'],$Resource['location'],
        $properties['state'],$properties['provisioningState'],$properties['serverFarmId'],
        $properties['publicNetworkAccess'],$identity['type'])) {
        if ($null -ne $value -and $value -isnot [string]) { throw 'Inventory text metadata must be a string.' }
    }
    if ($null -ne $properties['httpsOnly'] -and $properties['httpsOnly'] -isnot [bool]) {
        throw 'Inventory HTTPS metadata must be a boolean.'
    }
    # Allowlist only. Never return definitions, parameters, tags, URLs, app settings or the raw response.
    [pscustomobject][ordered]@{
        ResourceId = $resourceId
        SubscriptionId = $subscriptionId
        ResourceGroupName = $resourceGroupName
        Name = $Resource['name']
        Type = $Resource['type']
        Kind = $Resource['kind']
        Location = $Resource['location']
        State = $properties['state']
        ProvisioningState = $properties['provisioningState']
        PlanResourceId = $properties['serverFarmId']
        HttpsOnly = $properties['httpsOnly']
        PublicNetworkAccess = $properties['publicNetworkAccess']
        IdentityType = $identity['type']
    }
}

function Select-OpsInventoryResource {
    param(
        [AllowEmptyCollection()][object[]]$Resources = @(),
        [string]$Keyword,
        [string]$ResourceGroupName
    )
    # Filter only allowlisted metadata after all pages have been collected.
    # User text is literal: never interpret it as a regex, wildcard or query.
    $Resources | Where-Object {
        (-not $ResourceGroupName -or [string]::Equals($_.ResourceGroupName, $ResourceGroupName, [StringComparison]::OrdinalIgnoreCase)) -and
        (-not $Keyword -or
            ([string]$_.Name).IndexOf($Keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$_.ResourceGroupName).IndexOf($Keyword, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object ResourceId
}

function Resolve-OpsInventoryOutputPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'OutputPath must be an absolute path.' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $packageRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
    if ([IO.Path]::GetExtension($fullPath) -ine '.txt' -or
        $fullPath.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Use a new .txt file outside the repository or installed skill directory.'
    }
    if (Test-Path -LiteralPath $fullPath) { throw 'The inventory report already exists; it will not be overwritten.' }
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'The output directory must already exist.' }
    $directory = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    while ($null -ne $directory) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Report directories must not use junctions or symbolic links.' }
        if (Test-Path -LiteralPath (Join-Path $directory.FullName '.git')) { throw 'Inventory reports must be outside Git worktrees.' }
        $directory = $directory.Parent
    }
    return $fullPath
}

function Write-OpsInventoryReport {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Report)
    $fullPath = Resolve-OpsInventoryOutputPath $Path
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Report | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine)
    # CreateNew also rejects a competing file created after the preflight check.
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}

function Get-OpsInventorySummary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report,
        [ValidateRange(1,1000)][int]$Limit = 20,
        [ValidateRange(0,2147483647)][int]$Skip = 0,
        [ValidateSet('Live','SavedReport')][string]$Source = 'Live',
        [string]$ReportPath
    )
    $selected = @($Report.Resources | Select-Object -Skip $Skip -First $Limit)
    $index = $Skip
    $summaryRows = @(
        foreach ($row in $selected) {
            $index++
            [pscustomobject][ordered]@{
                Index=$index; ResourceId=$row.ResourceId; Name=$row.Name
                Service=(Get-OpsServiceKind $row.Type $row.Kind); Kind=$row.Kind
                ResourceGroupName=$row.ResourceGroupName; Location=$row.Location; State=$row.State
            }
        }
    )
    [pscustomobject][ordered]@{
        Source=$Source; RetrievedAtUtc=$Report.RetrievedAtUtc
        TenantId=$Report.TenantId; SubscriptionId=$Report.SubscriptionId; Service=$Report.Service
        QueryScope=$Report.QueryScope; Filters=$Report.Filters; Complete=$Report.Complete
        TotalCount=$Report.TotalCount; Count=$Report.Count; ReturnedCount=$summaryRows.Count
        Offset=$Skip; DisplayTruncated=($summaryRows.Count -lt $Report.Count)
        NextOffset=$(if ($index -lt $Report.Count) { $index } else { $null })
        ReportPath=$ReportPath; Resources=$summaryRows
    }
}

function Read-OpsInventoryReport {
    param([Parameter(Mandatory)][string]$Path)
    # Only this saved-report format is accepted. Never display an arbitrary JSON file or its parse error.
    try { $data = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'The saved inventory report could not be read as JSON.' }
    if ($data -isnot [System.Collections.IDictionary] -or $data['SchemaVersion'] -ne 1 -or
        $data['Complete'] -isnot [bool] -or -not $data['Complete'] -or $data['Resources'] -isnot [array] -or
        $data['Service'] -notin @('AppService','Functions','LogicApps','All')) { throw 'Unsupported or incomplete inventory report.' }
    foreach ($field in @('TenantId','SubscriptionId','ApplicationId')) { Assert-OpsGuid $data[$field] 'Report identifier' }
    $timestamp = [DateTimeOffset]::MinValue
    # Newer ConvertFrom-Json versions deserialize ISO timestamps as DateTime by default.
    if ($data['RetrievedAtUtc'] -is [DateTime] -or $data['RetrievedAtUtc'] -is [DateTimeOffset]) {
        $timestamp = [DateTimeOffset]$data['RetrievedAtUtc']
    } elseif ($data['RetrievedAtUtc'] -isnot [string] -or -not [DateTimeOffset]::TryParse($data['RetrievedAtUtc'], [ref]$timestamp)) {
        throw 'Invalid inventory retrieval timestamp.'
    }
    if ($data['Count'] -isnot [int] -or $data['TotalCount'] -isnot [int]) {
        # ConvertFrom-Json may produce Int64 depending on the PowerShell version.
        if (($data['Count'] -isnot [int] -and $data['Count'] -isnot [long]) -or
            ($data['TotalCount'] -isnot [int] -and $data['TotalCount'] -isnot [long])) { throw 'Invalid inventory counts.' }
    }
    if ($data['Count'] -lt 0 -or $data['Count'] -ne $data.Resources.Count -or $data.TotalCount -lt $data['Count']) {
        throw 'Inventory report counts do not match the saved resources.'
    }
    $scope = $data['QueryScope']; $filters = $data['Filters']
    if ($scope -isnot [System.Collections.IDictionary] -or $filters -isnot [System.Collections.IDictionary] -or
        $scope['Kind'] -notin @('Subscription','ResourceGroup') -or $scope['ResourceId'] -isnot [string]) {
        throw 'Invalid inventory query scope.'
    }
    $subscriptionScope = "/subscriptions/$($data.SubscriptionId)"
    if (($scope.Kind -eq 'Subscription' -and $scope.ResourceId -ine $subscriptionScope) -or
        ($scope.Kind -eq 'ResourceGroup' -and ($scope.ResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/?#%]+$' -or
        -not $scope.ResourceId.StartsWith($subscriptionScope + '/resourceGroups/', [StringComparison]::OrdinalIgnoreCase)))) {
        throw 'Inventory query scope does not match its subscription.'
    }
    foreach ($field in @('Keyword','ResourceGroupName')) {
        if ($null -ne $filters[$field] -and $filters[$field] -isnot [string]) { throw 'Invalid inventory filters.' }
    }
    $rows = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $data.Resources) {
        if ($row -isnot [System.Collections.IDictionary]) { throw 'Invalid inventory row.' }
        Assert-OpsResourceScope $row['ResourceId'] $data.SubscriptionId
        # Re-project the saved row; extra fields in a modified file cannot reach output.
        $safe = ConvertTo-OpsInventoryRow @{
            id=$row['ResourceId']; name=$row['Name']; type=$row['Type']; kind=$row['Kind']; location=$row['Location']
            identity=@{type=$row['IdentityType']}
            properties=@{state=$row['State']; provisioningState=$row['ProvisioningState']; serverFarmId=$row['PlanResourceId']
                httpsOnly=$row['HttpsOnly']; publicNetworkAccess=$row['PublicNetworkAccess']}
        }
        $serviceKind = Get-OpsServiceKind $safe.Type $safe.Kind
        if ($serviceKind -eq 'Other' -or ($data.Service -ne 'All' -and $serviceKind -ne $data.Service) -or
            ($scope.Kind -eq 'ResourceGroup' -and "$subscriptionScope/resourceGroups/$($safe.ResourceGroupName)" -ine $scope.ResourceId) -or
            -not $ids.Add($safe.ResourceId)) { throw 'Inventory row does not match the report scope or service.' }
        $rows.Add($safe)
    }
    # Header projection is as important as row projection: no arbitrary saved fields are returned.
    return [ordered]@{
        SchemaVersion=1; RetrievedAtUtc=$timestamp.ToUniversalTime().ToString('o')
        TenantId=$data.TenantId; SubscriptionId=$data.SubscriptionId; ApplicationId=$data.ApplicationId
        Service=$data.Service; Complete=$true
        QueryScope=[ordered]@{Kind=$scope.Kind; ResourceId=$scope.ResourceId}
        Filters=[ordered]@{Keyword=$filters['Keyword']; ResourceGroupName=$filters['ResourceGroupName']}
        TotalCount=$data.TotalCount; Count=$data['Count']; Resources=$rows.ToArray()
    }
}

function Get-OpsNextPath {
    param([string]$NextLink, [string]$CollectionPath)
    $uri = $null
    if (-not [uri]::TryCreate($NextLink, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
        $uri.AbsolutePath -ine $CollectionPath) {
        throw '想定外の継続リンクを拒否しました。'
    }
    return $uri.PathAndQuery
}


function Get-OpsApprovedReaderActions {
    # Explicit management metadata only. Optional diagnostic rights are not granted by this list.
    @(
        'Microsoft.Resources/subscriptions/read',
        'Microsoft.Resources/subscriptions/resourceGroups/read',
        'Microsoft.Web/sites/read',
        'Microsoft.Web/sites/config/read',
        'Microsoft.Web/sites/slots/read',
        'Microsoft.Web/sites/slots/config/read',
        'Microsoft.Web/sites/functions/read',
        'Microsoft.Web/sites/workflows/read',
        'Microsoft.Web/serverfarms/read',
        'Microsoft.Web/connections/read',
        'Microsoft.Logic/workflows/read',
        'Microsoft.Web/sites/basicPublishingCredentialsPolicies/read',
        'Microsoft.Insights/metricDefinitions/read',
        'Microsoft.Insights/metrics/read'
    )
}

function Get-OpsFailureSummary {
    param($Failure)
    # Project only fixed categories and an HTTP number, never an exception message/type/body.
    $exception = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
    $summary = $null
    if ($exception -is [Exception] -and $exception.Data.Contains('AzureOpsFailure')) {
        $summary = $exception.Data['AzureOpsFailure']
    } else {
        $response = $null
        if ($null -ne $exception -and $exception.PSObject.Properties['Response']) { $response = $exception.Response }
        $status = $null
        if ($null -ne $response -and $response.PSObject.Properties['StatusCode']) { $status = $response.StatusCode }
        $content = $null
        if ($Failure -is [Management.Automation.ErrorRecord] -and $null -ne $Failure.ErrorDetails) {
            # The SDK error body is inspected in memory only; arbitrary text is never returned.
            $content = $Failure.ErrorDetails.Message
        }
        $summary = Get-OpsArmErrorSummary @{StatusCode=$status;Content=$content}
    }
    $http = 0
    if ($summary -is [Collections.IDictionary]) {
        $status = $summary['HttpStatus']; $category = $summary['CategoryHint']
    } else {
        $status = if ($null -ne $summary -and $summary.PSObject.Properties['HttpStatus']) { $summary.HttpStatus } else { $null }
        $category = if ($null -ne $summary -and $summary.PSObject.Properties['CategoryHint']) { $summary.CategoryHint } else { $null }
    }
    if ($status -is [Net.HttpStatusCode]) {$http=[int]$status}
    else {[void][int]::TryParse([string]$status,[ref]$http)}
    if ($category -notin @('Quota','ProviderRegistration','Authentication','Authorization')) { $category='Unknown' }
    [ordered]@{HttpStatus=$(if ($http -ge 100 -and $http -le 599) {$http} else {$null});CategoryHint=$category;DetailsOmitted=$true}
}

function Assert-OpsReaderRole {
    param($Role)
    if (-not $Role.PSObject.Properties['Permissions'] -or @($Role.Permissions).Count -ne 1) {
        throw 'Az.Resources 10以降の形式が必要です。Permissions配列に1つの権限定義を指定してください。'
    }
    if ($Role.IsCustom -isnot [bool] -or -not $Role.IsCustom) { throw '読み取り専用カスタムロールが必要です。' }
    $permission = $Role.Permissions[0]
    foreach ($property in @('Actions','NotActions','DataActions','NotDataActions')) {
        if (-not $permission.PSObject.Properties[$property]) { throw "Permissionsに$property が必要です。" }
    }
    if (@($permission.Actions).Count -eq 0) { throw '読み取り操作が空です。' }
    foreach ($action in $permission.Actions) {
        if ($action -isnot [string] -or $action -notin @(Get-OpsApprovedReaderActions)) {
            throw '読み取りロールに未許可の操作があります。'
        }
    }
    foreach ($property in @('NotActions','DataActions','NotDataActions')) {
        if (@($permission.$property | Where-Object { $null -ne $_ }).Count -ne 0) {
            throw '読み取りロールには除外操作やデータプレーンの権限を含めません。'
        }
    }
    foreach ($property in @('Condition','ConditionVersion')) {
        if ($permission.PSObject.Properties[$property] -and $permission.$property) {
            throw '想定外の条件付きロールを自動利用しません。'
        }
    }
}

function Assert-OpsMatchingReaderRole {
    param($Actual,$Expected)
    Assert-OpsReaderRole $Actual
    Assert-OpsReaderRole $Expected
    if ($Actual.Name -cne $Expected.Name) { throw '既存ロールの名前が一致しません。' }
    $actualActions = @($Actual.Permissions[0].Actions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $expectedActions = @($Expected.Permissions[0].Actions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $actualScopes = @($Actual.AssignableScopes | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() } | Sort-Object)
    $expectedScopes = @($Expected.AssignableScopes | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() } | Sort-Object)
    if (($actualActions -join '|') -cne ($expectedActions -join '|') -or
        ($actualScopes -join '|') -cne ($expectedScopes -join '|')) {
        throw '既存ロールの権限または割当可能範囲が異なります。自動更新せず停止します。'
    }
}

function Assert-OpsResumeState {
    param([hashtable]$State)
    foreach ($key in @('tenantId','applicationId','applicationObjectId','servicePrincipalObjectId','sandboxSubscriptionId')) {
        if (-not $State.ContainsKey($key)) { throw "途中状態に$key がありません。" }
        Assert-OpsGuid $State[$key] $key
    }
    if (-not $State.ContainsKey('subscriptionIds') -or $State.subscriptionIds -isnot [array] -or
        $State.subscriptionIds.Count -eq 0 -or $State.sandboxSubscriptionId -notin $State.subscriptionIds) {
        throw '途中状態のサブスクリプション一覧が不正です。'
    }
    foreach ($id in $State.subscriptionIds) { Assert-OpsGuid $id 'subscriptionIds' }
    if (-not $State.ContainsKey('certificateThumbprint') -or $State.certificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw '途中状態の証明書の拇印が不正です。'
    }
    if (-not $State.ContainsKey('stage') -or $State.stage -notmatch '^(ServicePrincipalCreated|ReaderRoleCreated|ReaderAssigned:[0-9a-f-]{36}|Completed)$') {
        throw 'アプリとサービスプリンシパルの作成完了後の状態だけを再開できます。'
    }
    if ($State.stage.StartsWith('ReaderAssigned:') -and $State.stage.Substring(15) -notin $State.subscriptionIds) {
        throw '途中状態の割当先が対象サブスクリプションに含まれていません。'
    }
    if ($State.ContainsKey('readerRoleId') -and $State.readerRoleId) {
        Assert-OpsGuid $State.readerRoleId 'readerRoleId'
    } elseif ($State.stage -ne 'ServicePrincipalCreated') {
        throw 'ロール作成後の状態にはreaderRoleIdが必要です。'
    }
}
