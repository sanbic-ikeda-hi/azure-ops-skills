#requires -Version 7.2
# Offline: mock ARM, certificate sign-in, report writes and waits. No external effects.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$checks=0
function Verify-Execution {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Test-ExecutionScenario {
    param([string]$Scenario,[string]$TestOS='Windows',[string]$TestSku='P0v4',[string]$TestLocation='westus3')
    $sub='11111111-1111-1111-1111-111111111111';$principal='22222222-2222-2222-2222-222222222222'
    $root="/subscriptions/$sub/resourceGroups/test-rg/providers/Microsoft.Web"
    $appId="$root/sites/test-app";$peerId="$root/sites/peer-app";$planId="$root/serverfarms/test-plan"
    $assignment="$appId/providers/Microsoft.Authorization/roleAssignments/33333333-3333-3333-3333-333333333333"
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$principal;servicePrincipalObjectId=$principal;certificateThumbprint=('A'*40)} | ConvertTo-Json
    $report=Join-Path $env:TEMP 'azureops-offline-mocked-report.txt'
    $calls=@{connect=0;disconnect=0;files=0;get=0;peer=0;sleep=0;writes=[Collections.Generic.List[string]]::new();records=[Collections.Generic.List[string]]::new()}
    $simulatedApp=@{running='Running';affinity=($Scenario -eq 'WrongBaseline');pending=0}
    function Test-Path {
        param($LiteralPath,$PathType)
        if($LiteralPath -eq $report){return ($Scenario -eq 'ExistingReport')}
        return $true
    }
    function Get-Content {$profile}
    function Get-Item {[pscustomobject]@{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)}}
    function New-Item {param($ItemType,$Path) if($ItemType -ne 'File' -or $Path -ne $report){throw 'Unexpected file write'};$calls.files++}
    function Add-Content {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)][string]$Value,$LiteralPath,$Encoding)
        process {
            if($LiteralPath -ne $report -or $Encoding -ne 'utf8'){throw 'Unexpected report destination/encoding'}
            if($Scenario -eq 'OutputFailure'){throw 'Simulated report write failure'}
            $calls.records.Add($Value)
        }
    }
    function Import-Module {}
    function Disable-AzContextAutosave {}
    function Connect-AzAccount {param([switch]$ServicePrincipal) if(-not $ServicePrincipal){throw 'Only dedicated app sign-in allowed'};$calls.connect++}
    function Disconnect-AzAccount {$calls.disconnect++}
    function Get-AzContext {@{Tenant=@{Id=$sub};Subscription=@{Id=$sub};Account=@{Type='ServicePrincipal';Id=$(if($Scenario -eq 'WrongIdentity'){$sub}else{$principal})};Environment=@{Name='AzureCloud'}}}
    function Start-Sleep {$calls.sleep++}
    function Invoke-AzRestMethod {
        param($Path,$Method,$Payload)
        $id=$Path.Split('?')[0]
        if($Method -ne 'GET') {
            if($id -notin @($appId,"$appId/stop","$appId/start")){throw 'Mutation outside test app'}
            $calls.writes.Add("$Method $id")
            if($Scenario -eq 'StopDenied' -and $id -like '*/stop'){return @{StatusCode=403;Content='DO_NOT_OUTPUT_RAW_ERROR'}}
            if($Scenario -eq 'StartFailure' -and $id -like '*/start'){return @{StatusCode=409;Content='DO_NOT_OUTPUT_RAW_ERROR'}}
            if($Method -eq 'POST' -and $id -like '*/stop') {$simulatedApp.running='Stopped'}
            elseif($Method -eq 'POST' -and $id -like '*/start') {$simulatedApp.running='Running'}
            elseif($Method -eq 'PATCH' -and $id -eq $appId) {
                if($Scenario -eq 'PatchFailure'){return @{StatusCode=409;Content='DO_NOT_OUTPUT_RAW_ERROR'}}
                $body=$Payload | ConvertFrom-Json -AsHashtable
                if($body.Count -ne 1 -or $body.properties.Count -ne 1 -or -not $body.properties.ContainsKey('clientAffinityEnabled')) {throw 'PATCH must only change client affinity'}
                $simulatedApp.affinity=$body.properties.clientAffinityEnabled
            } else {throw 'Unexpected mutation'}
            if($Scenario -eq 'Pending'){$simulatedApp.pending=1}
            return @{StatusCode=200}
        }
        $calls.get++
        if($id -eq $planId) {
            $item=@{id=$planId;type='Microsoft.Web/serverfarms';location=$(if($Scenario -eq 'WrongLocation'){'eastus'}else{$TestLocation});sku=@{name=$(if($Scenario -eq 'WrongSku'){'B1'}else{$TestSku});tier='PremiumV4';capacity=$(if($Scenario -eq 'PlanChanged' -and $calls.writes.Count -gt 0){2}else{1})};properties=@{provisioningState='Succeeded';status='Ready';reserved=$(if($Scenario -eq 'WrongOS'){$TestOS -ne 'Linux'}else{$TestOS -eq 'Linux'});numberOfSites=2;perSiteScaling=$false;zoneRedundant=$false}}
        } elseif($id -in @($appId,$peerId)) {
            if($id -eq $peerId){$calls.peer++}
            $pending=$id -eq $appId -and $simulatedApp.pending -gt 0
            if($pending){$simulatedApp.pending--}
            $item=@{id=$id;type='Microsoft.Web/sites';kind=$(if($TestOS -eq 'Linux' -or $Scenario -eq 'WrongKind'){'app,linux'}else{'app'});location=$TestLocation;properties=@{
                serverFarmId=$planId;state=$(if($id -eq $peerId){'Running'}elseif($pending -or ($Scenario -eq 'Timeout' -and $calls.writes.Count -gt 0)){'Starting'}else{$simulatedApp.running})
                clientAffinityEnabled=$(if($id -eq $peerId){-not($Scenario -eq 'PeerChanged' -and $calls.peer -gt 1)}else{$simulatedApp.affinity})
                httpsOnly=(-not($Scenario -eq 'ProtectedChanged' -and $calls.writes.Count -gt 0 -and $id -eq $appId))
                publicNetworkAccess=$(if($id -eq $peerId){'Enabled'}else{'Disabled'});hostNames=@('DO_NOT_OUTPUT_HOST');connectionStrings=@('DO_NOT_OUTPUT_SETTINGS')
            }}
        } else {throw 'Unexpected GET'}
        @{StatusCode=200;Content=($item | ConvertTo-Json -Depth 6)}
    }
    $args=@{ResourceId=$appId;PlanResourceId=$planId;PeerResourceId=$peerId;AssignmentId=$assignment;OutputPath=$report;ExpectedLocation=$TestLocation;ExpectedOperatingSystem=$TestOS;ExpectedSku=$TestSku;Execute=($Scenario -ne 'Plan')}
    if($Scenario -eq 'RepositoryReport'){$args.OutputPath=Join-Path $PSScriptRoot 'unsafe-report.txt'}
    if($Scenario -eq 'OtherAssignment'){$args.AssignmentId=$assignment.Replace('/test-app/','/other-app/')}
    if($Scenario -eq 'SamePeer'){$args.PeerResourceId=$appId}
    $failed=$false;$failure=''
    try {& (Join-Path $PSScriptRoot 'Invoke-SandboxWebAppTest.ps1') @args 6>$null} catch {$failed=$true;$failure=$_.Exception.Message}
    $success=$Scenario -in @('Plan','Success','Pending')
    Verify-Execution ($failed -ne $success) "Expected result: $Scenario $failure"
    Verify-Execution ($calls.connect -eq $calls.disconnect) "Dedicated app disconnected: $Scenario"
    $records=@($calls.records | ForEach-Object {$_ | ConvertFrom-Json -AsHashtable})
    Verify-Execution (($calls.records -join '') -notmatch 'DO_NOT_OUTPUT_') "Report excludes raw errors and settings: $Scenario"
    if($Scenario -in @('Plan','ExistingReport','RepositoryReport','OtherAssignment','SamePeer','OutputFailure')) {
        Verify-Execution ($calls.connect -eq 0 -and $calls.get -eq 0 -and $calls.writes.Count -eq 0) "Preview/report problems stop before Azure: $Scenario"
    } elseif($success) {
        Verify-Execution (($calls.writes -join '|') -eq "POST $appId/stop|POST $appId/start|PATCH $appId|PATCH $appId") "Only approved mutations in order: $Scenario"
        Verify-Execution ($simulatedApp.running -eq 'Running' -and $simulatedApp.affinity -eq $false -and $records[-1].Event -eq 'Succeeded') "Restore and report success: $Scenario"
        Verify-Execution (@($records | Where-Object Event -Like '*Verified').Count -eq 4) "Each mutation has a verified report: $Scenario"
        if($Scenario -eq 'Pending'){Verify-Execution ($calls.sleep -eq 4) 'Poll GET for eventual state without retrying writes'}
    } else {
        Verify-Execution ($records[-1].Event -eq 'Failed' -and -not @($records | Where-Object Event -EQ 'Succeeded').Count) "Failure is recorded without false success: $Scenario"
        $expectedWrites=switch($Scenario){'StopDenied'{1};'StartFailure'{2};'PatchFailure'{3};'ProtectedChanged'{1};'Timeout'{1};'PeerChanged'{4};'PlanChanged'{4};default{0}}
        Verify-Execution ($calls.writes.Count -eq $expectedWrites) "No mutation retries or automatic rollback: $Scenario"
    }
}
foreach($scenario in @('Plan','Success','Pending','WrongBaseline','WrongIdentity','WrongLocation','WrongOS','WrongSku','WrongKind','StopDenied','StartFailure','PatchFailure','ProtectedChanged','Timeout','PeerChanged','PlanChanged','ExistingReport','RepositoryReport','OtherAssignment','SamePeer','OutputFailure')) {Test-ExecutionScenario $scenario}
Test-ExecutionScenario -Scenario Success -TestOS Linux -TestSku B1 -TestLocation centralus
Write-Host "PASS: $checks live-test orchestration/report checks (offline)."
