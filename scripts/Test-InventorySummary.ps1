#requires -Version 7.2
# Offline checks. Az and report storage are mocked; no files, credentials or Azure resources are changed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$checks = 0
function Verify {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Test-SummaryScenario {
    param([string]$Scenario)
    $sub='11111111-1111-1111-1111-111111111111'; $app='22222222-2222-2222-2222-222222222222'
    $profile=@{tenantId=$sub; subscriptionIds=@($sub); sandboxSubscriptionId=$sub; applicationId=$app
        servicePrincipalObjectId=$app; certificateThumbprint=('A'*40)} | ConvertTo-Json
    $calls=@{connect=0;disconnect=0;context=0; paths=[Collections.Generic.List[string]]::new()}
    function Get-Content { $profile }
    function Test-Path { $true }
    function Get-Item { @{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)} }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount { param([switch]$ServicePrincipal,$Tenant,$Subscription,$ApplicationId,$Scope,[switch]$SkipContextPopulation)
        if (-not $ServicePrincipal -or $Scope -ne 'Process' -or -not $SkipContextPopulation) { throw 'Dedicated process connection required' }; $calls.connect++ }
    function Disconnect-AzAccount { $calls.disconnect++ }
    function Get-AzContext {
        $calls.context++
        @{Tenant=@{Id=$sub};Subscription=@{Id=$sub};Account=@{Type='ServicePrincipal';Id=$app};Environment=@{Name='AzureCloud'}}
    }
    function New-Row {
        param([string]$Name,[string]$Kind,[string]$Type='Microsoft.Web/sites',[string]$Group='rg-test')
        @{id="/subscriptions/$sub/resourceGroups/$Group/providers/$Type/$Name";name=$Name;kind=$Kind;type=$Type;location='japaneast'
          tags=@{value='DO_NOT_OUTPUT_TAG'};properties=@{state='Running';definition='DO_NOT_OUTPUT_DEFINITION';appSettings=@{key='DO_NOT_OUTPUT_SECRET'}}}
    }
    $scoped=$Scenario -in @('ResourceGroup','WrongGroup','ScopeEscape','EncodedGroup')
    $group=if($Scenario -eq 'EncodedGroup'){'rg_(test)'}else{'rg-test'}
    $base="/subscriptions/$sub" + $(if($scoped){"/resourceGroups/$([uri]::EscapeDataString($group))"}else{''})
    $web="$base/providers/Microsoft.Web/sites"; $logic="$base/providers/Microsoft.Logic/workflows"
    function Invoke-AzRestMethod {
        param($Path,$Method)
        if ($Method -ne 'GET') { throw 'Only GET is allowed' }; $calls.paths.Add($Path)
        if($Path -eq "${logic}?api-version=2019-05-01") {
            return @{StatusCode=200;Content=(@{value=@((New-Row 'consumption' '' 'Microsoft.Logic/workflows' $group))}|ConvertTo-Json -Depth 8)}
        }
        if($Path -notin @("${web}?api-version=2024-11-01","${web}?api-version=2024-11-01&skiptoken=two")){throw 'Unexpected request path'}
        $second=$Path.EndsWith('skiptoken=two')
        if($Scenario -eq 'Failure' -and $second){return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
        if($Scenario -eq 'BadJson'){return @{StatusCode=200;Content='{"value": DO_NOT_OUTPUT_BROKEN'}}
        if($Scenario -eq 'RequestException'){throw 'DO_NOT_OUTPUT_REQUEST_EXCEPTION'}
        $rows=@()
        if($Scenario -ne 'Empty') {
            $start=if($second){16}else{1}; $end=if($second){30}else{15}
            if($Scenario -eq 'Large'){$start=if($second){501}else{1};$end=if($second){1000}else{500}}
            $rows=@(foreach($n in $start..$end){New-Row ('web-{0:d2}' -f $n) 'app,linux' 'Microsoft.Web/sites' $group})
            if(-not $second){$rows+=@((New-Row 'function' 'functionapp,linux' 'Microsoft.Web/sites' $group),(New-Row 'standard' 'functionapp,workflowapp' 'Microsoft.Web/sites' $group))}
        }
        if($Scenario -eq 'NestedSecret' -and -not $second){$rows[0].properties.state=@{value='DO_NOT_OUTPUT_NESTED'}}
        if($Scenario -eq 'WrongGroup' -and -not $second){$rows[0].id=$rows[0].id.Replace('/rg-test/','/rg-other/')}
        if($Scenario -eq 'Duplicate' -and $second){$rows[0]=New-Row 'web-01' 'app,linux'}
        $page=@{value=$rows}
        if(-not $second -and $Scenario -ne 'Empty'){
            $page.nextLink="https://management.azure.com${web}?api-version=2024-11-01&skiptoken=two"
            if($Scenario -eq 'ScopeEscape'){$page.nextLink=$page.nextLink.Replace('/resourceGroups/rg-test','')}
        }
        @{StatusCode=200;Content=($page|ConvertTo-Json -Depth 8)}
    }
    $parameters=@{Service='AppService';SubscriptionId=$sub;OutputMode='Summary'}
    if($scoped){$parameters.ResourceGroupName=$group}
    if($Scenario -eq 'All'){$parameters.Service='All'}
    if($Scenario -eq 'CustomLimit'){$parameters.Limit=3}
    if($Scenario -eq 'Filtered'){$parameters.Keyword='web-30'}
    if($Scenario -eq 'NoMatch'){$parameters.Keyword='not-present'}
    if($Scenario -eq 'InvalidGroup'){$parameters.ResourceGroupName='../escape'}
    if($Scenario -eq 'Legacy'){$parameters.Remove('OutputMode');$parameters.ResourceGroupName='rg-test'}
    $output=[Collections.Generic.List[object]]::new();$failed=$false;$message=''
    try{& (Join-Path $PSScriptRoot 'Get-ServiceInventory.ps1') @parameters|ForEach-Object{$output.Add($_)}}catch{$failed=$true;$message=$_.Exception.Message}
    $success=$Scenario -notin @('Failure','NestedSecret','WrongGroup','ScopeEscape','InvalidGroup','Duplicate','BadJson','RequestException')
    Verify ($failed -ne $success) "Outcome: $Scenario"
    Verify (($output -join '') -notmatch 'DO_NOT_OUTPUT_' -and $message -notmatch 'DO_NOT_OUTPUT_') "Projection: $Scenario"
    Verify ($calls.connect -eq $calls.disconnect) "Disconnected: $Scenario"
    if(-not $success){Verify ($output.Count -eq 0) "No partial result: $Scenario";return}
    $result=($output -join '')|ConvertFrom-Json
    $total=if($Scenario -eq 'Empty'){0}elseif($Scenario -eq 'All'){33}elseif($Scenario -eq 'Large'){1000}else{30}
    $count=if($Scenario -eq 'Filtered'){1}elseif($Scenario -eq 'NoMatch'){0}else{$total}
    Verify ($result.Complete -and $result.TotalCount -eq $total -and $result.Count -eq $count) "Complete counts: $Scenario"
    if($Scenario -eq 'Legacy'){
        Verify ($result.Resources.Count -eq 30 -and $null -eq $result.PSObject.Properties['ReturnedCount']) 'Full default remains unbounded with the legacy schema'
        Verify ($result.PSObject.Properties.Name.Count -eq 10) 'Legacy top-level fields unchanged'
    }else{
        $limit=if($Scenario -eq 'CustomLimit'){3}else{20};$shown=[Math]::Min($count,$limit)
        Verify ($result.ReturnedCount -eq $shown -and $result.Resources.Count -eq $shown) "Display bound: $Scenario"
        Verify ($result.DisplayTruncated -eq ($shown -lt $count) -and $result.Source -eq 'Live') "Presentation and freshness: $Scenario"
        Verify ($result.QueryScope.Kind -eq $(if($scoped){'ResourceGroup'}else{'Subscription'})) "Scope semantics: $Scenario"
        if($shown){Verify ($null -eq $result.Resources[0].PSObject.Properties['SubscriptionId']) 'Common context is not repeated per summary row'}
        if($Scenario -eq 'Large'){Verify (($output -join '').Length -lt 12000) 'Large inventory produces a bounded summary, not a thousand-row dump'}
    }
    Verify ($calls.paths.Count -eq $(if($Scenario -eq 'Empty'){1}elseif($Scenario -eq 'All'){3}else{2})) "Shared collections read once: $Scenario"
    if($scoped){Verify (@($calls.paths|Where-Object{$_ -notlike '*/resourceGroups/*'}).Count -eq 0) 'RG queries never enumerate subscription-wide'}
    if($Scenario -eq 'All'){
        Verify ($result.Resources[0].Service -eq 'LogicApps') 'All uses service classification'
        Verify ($calls.context -eq 4 -and $calls.connect -eq 1) 'One connection with validation before every page'
    }
}
foreach($scenario in @('Default','CustomLimit','All','ResourceGroup','EncodedGroup','Filtered','NoMatch','Empty','Legacy','Large',
    'Failure','NestedSecret','WrongGroup','ScopeEscape','InvalidGroup','Duplicate','BadJson','RequestException')){Test-SummaryScenario $scenario}

# Saved reports are read in a separate invocation. Any attempt to use a profile or Az fails.
function Test-SavedReport {
    param([string]$Scenario)
    $sub='11111111-1111-1111-1111-111111111111'
    $rows=@(foreach($n in 1..31){@{ResourceId="/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/sites/web-$n"
        Name="web-$n";Type='Microsoft.Web/sites';Kind='app';Location='japaneast';State='Running';extra='DO_NOT_OUTPUT_ROW'}})
    $saved=@{SchemaVersion=1;RetrievedAtUtc='2020-01-01T00:00:00Z';TenantId=$sub;SubscriptionId=$sub;ApplicationId=$sub
        Service='AppService';Complete=$true;TotalCount=31;Count=31;Resources=$rows;extra='DO_NOT_OUTPUT_HEADER'
        QueryScope=@{Kind='Subscription';ResourceId="/subscriptions/$sub";extra='DO_NOT_OUTPUT_SCOPE'}
        Filters=@{Keyword=$null;ResourceGroupName=$null;extra='DO_NOT_OUTPUT_FILTER'}}
    switch($Scenario){
        'Incomplete'{$saved.Complete=$false}
        'BadCounts'{$saved.Count=30}
        'CrossScope'{$saved.Resources[0].ResourceId=$saved.Resources[0].ResourceId.Replace($sub,'22222222-2222-2222-2222-222222222222')}
        'NestedSecret'{$saved.Resources[0].State=@{secret='DO_NOT_OUTPUT_NESTED'}}
    }
    $json=$saved|ConvertTo-Json -Depth 8
    if($Scenario -eq 'BadJson'){$json='{"secret":"DO_NOT_OUTPUT_BROKEN"'}
    function Get-Content {param($LiteralPath) if($LiteralPath -ne 'saved-report.txt'){throw 'Profile read forbidden'}; $json}
    function Import-Module {throw 'Azure module load forbidden'}
    function Connect-AzAccount {throw 'Azure connection forbidden'}
    function Invoke-AzRestMethod {throw 'Azure request forbidden'}
    $output=[Collections.Generic.List[object]]::new();$failed=$false;$message=''
    try{& (Join-Path $PSScriptRoot 'Get-InventoryReport.ps1') -Path 'saved-report.txt' -Skip 20 -Limit 5|ForEach-Object{$output.Add($_)}}catch{$failed=$true;$message=$_.Exception.Message}
    Verify ($failed -eq ($Scenario -ne 'Valid')) "Saved report outcome: $Scenario"
    Verify (($output -join '') -notmatch 'DO_NOT_OUTPUT_' -and $message -notmatch 'DO_NOT_OUTPUT_') "Saved report and errors are projected: $Scenario"
    if(-not $failed){
        $result=($output -join '')|ConvertFrom-Json
        Verify ($result.Source -eq 'SavedReport' -and ([DateTimeOffset]$result.RetrievedAtUtc).Year -eq 2020) 'Old snapshot is explicitly identified, not refreshed'
        Verify ($result.Count -eq 31 -and $result.ReturnedCount -eq 5 -and $result.NextOffset -eq 25 -and $result.Resources[0].Index -eq 21) 'Saved report paging retains full counts and indexes'
    }else{Verify ($output.Count -eq 0) 'Invalid report never emits rows'}
}
foreach($scenario in @('Valid','Incomplete','BadCounts','CrossScope','NestedSecret','BadJson')){Test-SavedReport $scenario}
Write-Host "PASS: $checks inventory summary and saved-report checks (offline)."
