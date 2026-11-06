#requires -Version 7.2
# USER-RUN ONLY. Copies reviewed source to the user's common skills directory.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Destination = (Join-Path $env:USERPROFILE '.agents\skills'))
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$names = @('azure-appservice','azure-functions','azure-logicapps')
$destinationFull = [IO.Path]::GetFullPath($Destination)
$workflowSource = Join-Path $repoRoot 'docs\change-workflow.md'
if (-not (Test-Path -LiteralPath $workflowSource -PathType Leaf)) { throw '共通の変更手順がありません。' }
$authenticationSource = Join-Path $repoRoot 'docs\authentication.md'
if (-not (Test-Path -LiteralPath $authenticationSource -PathType Leaf)) { throw '共通の認証手順がありません。' }
$operationsSource = Join-Path $repoRoot 'docs\service-operations.md'
if (-not (Test-Path -LiteralPath $operationsSource -PathType Leaf)) { throw 'Service operation reference is missing.' }
$helpers = @('Common.ps1','Authentication.ps1','Get-ServiceInventory.ps1','Get-InventoryReport.ps1','Get-AppServiceQuota.ps1','ServiceOperations.ps1','Get-ServiceDetails.ps1','Invoke-ServiceOperation.ps1')
foreach ($file in $helpers) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "scripts\$file") -PathType Leaf)) { throw "ヘルパーがありません: $file" }
}
foreach ($name in $names) {
    $source = Join-Path $repoRoot "skills\$name"
    $target = Join-Path $destinationFull $name
    if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) { throw "ソースがありません: $name" }
    if (Test-Path -LiteralPath $target) {
        throw "既存スキルを自動上書きしません。差分を確認して更新してください: $target"
    }
}
foreach ($name in $names) {
    $target = Join-Path $destinationFull $name
    if ($PSCmdlet.ShouldProcess($target, '検証済みスキルと共通ヘルパーを配置')) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot "skills\$name\SKILL.md") -Destination $target
        $referenceDirectory = Join-Path $target 'references'
        New-Item -ItemType Directory -Path $referenceDirectory | Out-Null
        Copy-Item -LiteralPath $workflowSource -Destination $referenceDirectory
        Copy-Item -LiteralPath $authenticationSource -Destination $referenceDirectory
        Copy-Item -LiteralPath $operationsSource -Destination $referenceDirectory
        $scriptDirectory = Join-Path $target 'scripts'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        foreach ($file in $helpers) {
            Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\$file") -Destination $scriptDirectory
        }
    }
}
