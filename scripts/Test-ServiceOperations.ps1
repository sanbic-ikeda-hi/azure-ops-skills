#requires -Version 7.2
# Offline: mock sign-in/certificate/ARM; real UTF-8 reports only in a unique TEMP directory.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ServiceOperations.ps1')
$checks=0
function Verify {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Rejects {param([scriptblock]$Work,[string]$Message) $failed=$false;try {& $Work | Out-Null}catch {$failed=$true};Verify $failed $Message}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('azureops-operations-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
function Test-OperationScenario {
    param([string]$Scenario)
    $sub='11111111-1111-1111-1111-111111111111';$operator='22222222-2222-2222-2222-222222222222'
    $fixtureId="/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/sites/test-app"
    $planId="/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/serverfarms/test-plan"
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$operator;servicePrincipalObjectId=$operator;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $calls=@{connect=0;disconnect=0;get=0;write=0;planGet=0;configGet=0;paths=[Collections.Generic.List[string]]::new()}
    $operation='Stop';$value='';$kind='app,linux';$type='Microsoft.Web/sites';$state='Running'
    switch($Scenario) {
        'Start' {$operation='Start';$state='Stopped'}
        'Restart' {$operation='Restart'}
        'Enable' {$operation='Enable';$type='Microsoft.Logic/workflows';$kind='';$state='Disabled'}
        'Disable' {$operation='Disable';$type='Microsoft.Logic/workflows';$kind='';$state='Enabled'}
        'Affinity' {$operation='SetClientAffinity';$value='true'}
        'Https' {$operation='SetHttpsOnly';$value='false'}
        'PublicAccess' {$operation='SetPublicNetworkAccess';$value='Enabled'}
        {$_ -in @('Flex','FlexLow','FlexInvalid','FlexDetails')} {$operation='SetFlexMaximumInstanceCount';$value='41';$kind='functionapp,linux'}
        'Standard' {$kind='functionapp,workflowapp'}
        'InvalidValue' {$operation='SetHttpsOnly';$value='yes'}
        'NoOp' {$state='Stopped'}
    }
    if($type -eq 'Microsoft.Logic/workflows') {$fixtureId=$fixtureId.Replace('Microsoft.Web/sites','Microsoft.Logic/workflows')}
    if($Scenario -eq 'FlexLow') {$value='1'}
    if($Scenario -eq 'FlexInvalid') {$value='1001'}
    $site=@{id=$fixtureId;name='test-app';type=$type;kind=$kind;location='westus3';identity=@{type='SystemAssigned';principalId=$operator;tenantId=$sub};tags=@{secret='DO_NOT_OUTPUT_TAG'};properties=@{state=$state;enabled=$true;scmSiteAlsoStopped=$false;provisioningState='Succeeded';serverFarmId=$planId;reserved=$true;httpsOnly=$true;publicNetworkAccess='Disabled';clientAffinityEnabled=$false;secret='DO_NOT_OUTPUT_PROPERTY'}}
    if($kind -eq 'functionapp,linux') {
        $site.properties.functionAppConfig=@{runtime=@{name='node';version='22'};deployment=@{storage=@{type='blobContainer';value='DO_NOT_OUTPUT_STORAGE';authentication=@{type='SystemAssignedIdentity'}}};siteUpdateStrategy=@{type='Recreate'};scaleAndConcurrency=@{maximumInstanceCount=40;instanceMemoryMB=2048;alwaysReady=@(@{name='http';instanceCount=0});triggers=@{http=@{perInstanceConcurrency=8}}}}
    }
    if($type -eq 'Microsoft.Logic/workflows') {
        $site.properties.Remove('serverFarmId')
        $site.properties.definition=@{triggers=@{http=@{type='Request';inputs='DO_NOT_OUTPUT_TRIGGER'}};actions=@{compose=@{type='Compose';inputs='DO_NOT_OUTPUT_ACTION'}}}
        $site.properties.parameters=@{connection='DO_NOT_OUTPUT_CONNECTION'}
    }
    function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding)
        if($LiteralPath -eq 'mock-profile'){return $profile}
        Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
    }
    function Test-Path {param($LiteralPath,$PathType)
        if($LiteralPath -eq 'mock-profile' -or $LiteralPath -like 'Cert:*'){return $true}
        Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
    }
    function Get-Item {param($LiteralPath,[switch]$Force)
        if($LiteralPath -like 'Cert:*'){return @{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)}}
        Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
    }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {param([switch]$ServicePrincipal,$Scope) if(-not $ServicePrincipal -or $Scope -ne 'Process'){throw 'Wrong auth'};$calls.connect++}
    function Disconnect-AzAccount {$calls.disconnect++}
    function Start-Sleep {}
    function Get-AzContext {
        $account=if($Scenario -eq 'WrongContext' -and $calls.get -ge 3){$sub}else{$operator}
        @{Tenant=@{Id=$sub};Subscription=@{Id=$sub};Account=@{Type='ServicePrincipal';Id=$account};Environment=@{Name='AzureCloud'}}
    }
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        try {
        $calls.paths.Add($Path);$requestId=$Path.Split('?')[0]
        if($Method -ne 'GET') {
            $calls.write++
            if($Scenario -eq 'WriteDenied'){return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
            if($Scenario -eq 'WriteThrown403'){
                $exception=[Exception]::new('DO_NOT_OUTPUT_EXCEPTION')
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=[Net.HttpStatusCode]::Forbidden})
                $record=[Management.Automation.ErrorRecord]::new($exception,'Mock',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
                $record.ErrorDetails=[Management.Automation.ErrorDetails]::new('{"error":{"code":"AuthorizationFailed","message":"DO_NOT_OUTPUT_BODY"}}')
                throw $record
            }
            if($Scenario -eq 'NoConverge'){return @{StatusCode=202}}
            if($Method -eq 'POST') {
                if($requestId -notin @("$fixtureId/start","$fixtureId/stop","$fixtureId/restart","$fixtureId/enable","$fixtureId/disable")){throw 'Unexpected action'}
                $site.properties.state=switch($requestId.Split('/')[-1]) {'start' {'Running'} 'stop' {'Stopped'} 'restart' {'Running'} 'enable' {'Enabled'} 'disable' {'Disabled'}}
            } elseif($Method -eq 'PATCH' -and $requestId -eq $fixtureId) {
                $body=$Payload | ConvertFrom-Json -AsHashtable
                if($body.Keys.Count -ne 1 -or $body.properties.Keys.Count -ne 1){throw 'Payload is not narrow'}
                if($body.properties['functionAppConfig']) {
                    $f=$body.properties.functionAppConfig
                    if($f.deployment.storage.value -ne 'DO_NOT_OUTPUT_STORAGE' -or $f.siteUpdateStrategy.type -ne 'Recreate' -or $f.scaleAndConcurrency.triggers.http.perInstanceConcurrency -ne 8){throw 'Flex fields were lost'}
                }
                foreach($key in $body.properties.Keys){$site.properties[$key]=$body.properties[$key]}
            } else {throw 'Unexpected mutation'}
            if($Scenario -eq 'ProtectedChanged') {$site.properties.httpsOnly=$false}
            return @{StatusCode=200}
        }
        if($requestId -eq $planId){$calls.planGet++;return @{StatusCode=200;Content=(@{id=$planId;type='Microsoft.Web/serverfarms';location='westus3';sku=@{name='P0v4';tier='PremiumV4';capacity=1};properties=@{reserved=$true;numberOfSites=2;status='Ready'}}|ConvertTo-Json -Depth 8)}}
        if($requestId -like '*/config/web') {
            $calls.configGet++
            return @{StatusCode=200;Content=(@{id=$requestId;properties=@{linuxFxVersion='DOCKER|DO_NOT_OUTPUT_CONTAINER';appSettings='DO_NOT_OUTPUT_SETTINGS';minTlsVersion='1.2';ftpsState='Disabled';ipSecurityRestrictions=@(@{headers='DO_NOT_OUTPUT_HEADERS'})}} | ConvertTo-Json -Depth 10)}
        }
        if($requestId -ne $fixtureId -and $requestId -ne ($fixtureId+'2')){throw 'Unexpected GET'}
        $calls.get++
        if($Scenario -eq 'ReadDenied'){return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
        if($Scenario -eq 'BadJson'){return @{StatusCode=200;Content='DO_NOT_OUTPUT_JSON'}}
        if($Scenario -eq 'RequestException'){throw 'DO_NOT_OUTPUT_EXCEPTION'}
        if(($Scenario -eq 'ChangedBefore' -and $calls.get -eq 2) -or ($Scenario -eq 'ChangedImmediately' -and $calls.get -eq 3)) {$site.properties.httpsOnly=$false}
        $copy=$site | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable
        $copy.id=$requestId
        if($Scenario -eq 'WrongResponse') {$copy.id=$fixtureId+'-other'}
        @{StatusCode=200;Content=($copy | ConvertTo-Json -Depth 25)}
        } catch {$calls['mockError']=$_.Exception.Message;throw}
    }
    $planFile=Join-Path $directory ($Scenario+'-plan.txt');$resultFile=Join-Path $directory ($Scenario+'-result.txt')
    $parameters=@{SubscriptionId=$sub;ResourceId=$fixtureId;Operation=$operation;Value=$value;ConnectionPath='mock-profile';OutputPath=$planFile}
    $scriptFile=Join-Path $PSScriptRoot 'Invoke-ServiceOperation.ps1'
    $planFailures=@('Standard','InvalidValue','FlexInvalid','ReadDenied','BadJson','RequestException','WrongResponse')
    if($Scenario -in $planFailures) {
        $errorMessage=''
        try {& $scriptFile @parameters | Out-Null}catch {$errorMessage=$_.Exception.Message}
        Verify ([bool]$errorMessage -and $calls.write -eq 0) "Plan rejects unsafe input: $Scenario"
        Verify ($errorMessage -notmatch 'DO_NOT_OUTPUT_') "Errors are sanitized: $Scenario"
    } elseif($Scenario -in @('Details','FlexDetails','Overview','Enable')) {
        $ids=@(if($Scenario -eq 'Details'){$fixtureId;$fixtureId+'2'}else{$fixtureId})
        $detailParameters=@{SubscriptionId=$sub;ResourceId=$ids;ConnectionPath='mock-profile';OutputPath=$resultFile}
        if($Scenario -ne 'Overview'){$detailParameters.Section=@('Overview','Runtime','Network','Identity','Plan','Structure')}
        try {$details=& (Join-Path $PSScriptRoot 'Get-ServiceDetails.ps1') @detailParameters | ConvertFrom-Json}
        catch {throw "Details $Scenario failed: $($_.Exception.Message); mock: $($calls['mockError'])"}
        Verify ($details.Complete -and $details.Count -eq $ids.Count) "Details complete: $Scenario"
        Verify ($calls.write -eq 0 -and $calls.planGet -le 1) "No mutations; shared plan read once: $Scenario"
        if($Scenario -eq 'Details'){Verify ($calls.configGet -eq 2 -and $details.Resources[0].Runtime.linuxFxVersion -eq 'OmittedNonCodeStack') 'Config reused across selected sections; container omitted'}
        if($Scenario -eq 'Overview'){Verify ($calls.configGet -eq 0 -and $calls.planGet -eq 0 -and $calls.get -eq 1) 'Default detail fetches only the one target resource'}
        if($Scenario -ne 'Enable'){
            Verify ($calls.connect -eq $calls.disconnect) "Details disconnect: $Scenario"
            Verify ((Microsoft.PowerShell.Management\Get-Content -LiteralPath $resultFile -Raw) -notmatch 'DO_NOT_OUTPUT_') "Details saved projection: $Scenario"
            return
        }
    }
    if($Scenario -notin $planFailures) {
        $plan=& $scriptFile @parameters | ConvertFrom-Json -AsHashtable
        Verify ($plan.Schema -eq 'AzureOpsOperationPlan/1' -and $calls.write -eq 0 -and $plan.PermissionScope -eq $fixtureId) "Read-only plan and individual permission scope: $Scenario"
        if($Scenario -eq 'Expired'){$plan.RetrievedAtUtc=[DateTime]::UtcNow.AddHours(-2).ToString('o')}
        if($Scenario -eq 'WrongPlanTarget'){$plan.ResourceId=$fixtureId+'2'}
        if($Scenario -eq 'ExtraBefore'){$plan.Before.extra='DO_NOT_OUTPUT_TAMPER'}
        if($Scenario -in @('Expired','WrongPlanTarget','ExtraBefore')){$plan|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $planFile -Encoding utf8}
        if($Scenario -eq 'Enable'){$resultFile=Join-Path $directory 'Enable-execution.txt'}
        $parameters.OutputPath=$resultFile;$parameters.Execute=$true;$parameters.ReviewedPlanPath=$planFile
        if($Scenario -eq 'DifferentValue'){$parameters.Operation='SetHttpsOnly';$parameters.Value='false'}
        $failed=$false;$failureMessage=''
        try {& $scriptFile @parameters | Out-Null}catch {$failed=$true;$failureMessage=$_.Exception.Message}
        $expectedFailure=$Scenario -in @('ChangedBefore','ChangedImmediately','WrongContext','WriteDenied','WriteThrown403','NoConverge','ProtectedChanged','Expired','WrongPlanTarget','ExtraBefore','DifferentValue')
        Verify ($failed -eq $expectedFailure) "Execution outcome: $Scenario ($failureMessage; mock: $($calls['mockError']))"
        $saved=Microsoft.PowerShell.Management\Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        Verify ($saved.Succeeded -ne $expectedFailure) "Saved result is truthful: $Scenario"
        $expectedWrites=if($Scenario -in @('ChangedBefore','ChangedImmediately','WrongContext','Expired','WrongPlanTarget','ExtraBefore','DifferentValue','NoOp')){0}else{1}
        Verify ($calls.write -eq $expectedWrites) "Single write or rejection without retry: $Scenario"
        if($Scenario -in @('WriteDenied','WriteThrown403')){
            Verify ($saved.HttpStatus -eq 403 -and $saved.FailureDetails.HttpStatus -eq 403) 'Returned and thrown write failures retain status in the saved operation result'
            Verify ($saved.FailureDetails.CategoryHint -eq $(if($Scenario -eq 'WriteThrown403'){'Authorization'}else{'Unknown'})) 'Failure category requires structured evidence'
            Verify ($failureMessage -notmatch 'DO_NOT_OUTPUT_') 'Write exception output is sanitized'
        }
    }
    Verify ($calls.connect -eq $calls.disconnect) "Disconnect: $Scenario"
    foreach($path in @($planFile,$resultFile)) {
        if(Microsoft.PowerShell.Management\Test-Path -LiteralPath $path){
            $text=Microsoft.PowerShell.Management\Get-Content -LiteralPath $path -Raw
            if($Scenario -ne 'ExtraBefore' -or $path -ne $planFile){Verify ($text -notmatch 'DO_NOT_OUTPUT_') "No secrets in report: $Scenario"}
        }
    }
}
try {
    $many=@{}
    foreach($n in 1..1000){$many["step-$n"]=@{type='Compose';inputs='DO_NOT_OUTPUT_PAYLOAD'}}
    $projected=ConvertTo-OpsServiceDetail @{id='mock';type='Microsoft.Logic/workflows';properties=@{state='Disabled';definition=@{triggers=@{};actions=$many}}} @('Structure') @{} $null 3
    Verify ($projected.Structure.actions.Count -eq 1000 -and $projected.Structure.actions.Items.Count -eq 3 -and $projected.Structure.actions.DisplayTruncated) 'Large workflow structures respect display limits and retain total counts'
    Verify (($projected | ConvertTo-Json -Depth 20) -notmatch 'DO_NOT_OUTPUT_') 'Workflow inputs are not serialized'
    foreach($scenario in @('Stop','Start','Restart','Enable','Disable','Affinity','Https','PublicAccess','Flex','FlexLow','FlexInvalid','Standard','InvalidValue','NoOp','ChangedBefore','ChangedImmediately','WrongContext','ReadDenied','WriteDenied','WriteThrown403','NoConverge','ProtectedChanged','Expired','WrongPlanTarget','ExtraBefore','DifferentValue','WrongResponse','BadJson','RequestException','Details','FlexDetails','Overview')) {Test-OperationScenario $scenario}
    $config=@{subscriptionId='11111111-1111-1111-1111-111111111111'}
    Rejects {Assert-OpsServiceId '/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/rg/providers/Microsoft.Web/sites/app' $config} 'Cross-subscription rejected'
    Rejects {Assert-OpsServiceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Web/sites/app/slots/staging' $config} 'Slot rejected'
    Write-Host "PASS: $checks service detail/operation checks. Azure was mocked; real reports used TEMP only."
} finally {
    $resolved=[IO.Path]::GetFullPath($directory)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^azureops-operations-test-[0-9a-f]{32}$'){throw 'Unsafe test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
