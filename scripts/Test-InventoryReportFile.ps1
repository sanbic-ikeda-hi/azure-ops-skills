#requires -Version 7.2
# Az is mocked. Temporary UTF-8 reports are created under TEMP and removed at the end.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$checks=0
function Verify { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "FAIL: $Message"};$script:checks++ }
function Rejects { param([scriptblock]$Action,[string]$Message) $failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Verify $failed $Message }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('azureops-inventory-offline-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
try {
    $reportPath=Join-Path $testRoot 'inventory.txt'
    $sub='11111111-1111-1111-1111-111111111111'
    $profile=@{tenantId=$sub;subscriptionIds=@($sub);sandboxSubscriptionId=$sub;applicationId=$sub
        servicePrincipalObjectId=$sub;certificateThumbprint=('A'*40)}|ConvertTo-Json
    $calls=@{connect=0;disconnect=0;requests=0}
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
    function Connect-AzAccount { $calls.connect++ }
    function Disconnect-AzAccount { $calls.disconnect++ }
    function Get-AzContext { @{Tenant=@{Id=$sub};Subscription=@{Id=$sub};Account=@{Type='ServicePrincipal';Id=$sub};Environment=@{Name='AzureCloud'}} }
    $apiFailure=$false
    function Invoke-AzRestMethod {
        param($Path,$Method)
        if($Method -ne 'GET'){throw 'Read only'};$calls.requests++
        if($apiFailure){return @{StatusCode=403;Content='DO_NOT_OUTPUT_ERROR'}}
        $resources=@(foreach($n in 1..25){@{id="/subscriptions/$sub/resourceGroups/rg-test/providers/Microsoft.Web/sites/web-$n"
            name="web-$n";type='Microsoft.Web/sites';kind='app';location='japaneast';tags=@{secret='DO_NOT_OUTPUT_TAG'}
            properties=@{state='Running';appSettings=@{secret='DO_NOT_OUTPUT_SECRET'}}}})
        @{StatusCode=200;Content=(@{value=$resources}|ConvertTo-Json -Depth 8)}
    }
    $parameters=@{Service='AppService';SubscriptionId=$sub;ConnectionPath='mock-profile';OutputMode='Summary';Limit=2;OutputPath=$reportPath}
    $summary=& (Join-Path $PSScriptRoot 'Get-ServiceInventory.ps1') @parameters | ConvertFrom-Json
    Verify ($summary.Count -eq 25 -and $summary.ReturnedCount -eq 2 -and $summary.ReportPath -eq $reportPath) 'Summary points to all saved matches'
    $savedBytes=[IO.File]::ReadAllBytes($reportPath)
    $savedText=[Text.UTF8Encoding]::new($false,$true).GetString($savedBytes)
    Verify ($savedText -notmatch 'DO_NOT_OUTPUT_') 'Saved file excludes raw and secret-bearing properties'
    $saved=$savedText|ConvertFrom-Json
    Verify ($saved.Count -eq 25 -and $saved.Resources.Count -eq 25) 'Display limit does not truncate the file'
    Verify ($savedBytes[0] -eq 123) 'UTF-8 JSON report has no BOM'
    $requestsBefore=$calls.requests;$connectionsBefore=$calls.connect
    $page=& (Join-Path $PSScriptRoot 'Get-InventoryReport.ps1') -Path $reportPath -Skip 20 -Limit 3 | ConvertFrom-Json
    Verify ($page.Source -eq 'SavedReport' -and $page.ReturnedCount -eq 3 -and $page.Offset -eq 20) 'Actual saved file can be paged'
    Verify ($calls.requests -eq $requestsBefore -and $calls.connect -eq $connectionsBefore) 'Saved report does not connect or request Azure'
    Rejects {& (Join-Path $PSScriptRoot 'Get-ServiceInventory.ps1') @parameters} 'Existing file is rejected before authentication'
    Verify ($calls.connect -eq $connectionsBefore -and [IO.File]::ReadAllText($reportPath) -ceq $savedText) 'Existing report remains intact'
    Rejects {Resolve-OpsInventoryOutputPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'inventory.txt')} 'Repository output rejected'
    Rejects {Resolve-OpsInventoryOutputPath (Join-Path $testRoot 'inventory.json')} 'Non-text extension rejected'
    Rejects {Resolve-OpsInventoryOutputPath 'relative.txt'} 'Relative output path rejected'
    Rejects {Resolve-OpsInventoryOutputPath (Join-Path $testRoot 'missing/report.txt')} 'Missing parent directory rejected'
    $nestedRepo=Join-Path $testRoot 'worktree';$null=New-Item -ItemType Directory -Path $nestedRepo
    $null=New-Item -ItemType File -Path (Join-Path $nestedRepo '.git')
    Rejects {Resolve-OpsInventoryOutputPath (Join-Path $nestedRepo 'report.txt')} 'Other Git worktree output rejected'
    $apiFailure=$true;$parameters.OutputPath=Join-Path $testRoot 'failed.txt'
    Rejects {& (Join-Path $PSScriptRoot 'Get-ServiceInventory.ps1') @parameters} 'Failed fetch cannot produce a successful report'
    Verify (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $parameters.OutputPath)) 'No file saved for incomplete acquisition'
    Verify ($calls.connect -eq $calls.disconnect) 'All established mock sessions are disconnected'
    $utf8Path=Join-Path $testRoot 'utf8.txt'
    Write-OpsInventoryReport -Path $utf8Path -Report @{Message='日本語の保存確認'}
    Verify ([Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($utf8Path)).Contains('日本語の保存確認')) 'Japanese text is preserved as UTF-8'
} finally {
    # Verify the exact disposable directory before recursive cleanup; never derive targets from its contents.
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^azureops-inventory-offline-[0-9a-f]{32}$'){throw 'Unsafe test cleanup path'}
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "PASS: $checks inventory file checks (offline; temporary reports cleaned up)."
