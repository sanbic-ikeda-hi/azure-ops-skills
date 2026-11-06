#requires -Version 7.2
# USER-RUN ONLY. Copies reviewed source to the user's common skills directory.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Destination = (Join-Path $env:USERPROFILE '.agents\skills'))
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$names = @('azure-appservice','azure-functions','azure-logicapps')
$destinationFull = [IO.Path]::GetFullPath($Destination)
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
    if ($PSCmdlet.ShouldProcess($target, '検証済みスキルと読み取り専用ヘルパーを配置')) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot "skills\$name\SKILL.md") -Destination $target
        $scriptDirectory = Join-Path $target 'scripts'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        foreach ($file in @('Common.ps1','Get-ServiceInventory.ps1')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\$file") -Destination $scriptDirectory
        }
    }
}
