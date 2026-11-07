#requires -Version 7.2
# Explicit non-secret registration only. Never writes connection.json or changes Azure permissions.
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory,ValueFromPipeline)][string]$Json)
process {
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot 'Common.ps1')
    try { $patch = $Json | ConvertFrom-Json -AsHashtable }
    catch { throw 'Invalid settings JSON. Do not include or share credentials.' }
    $path = Join-Path (Get-OpsLocalDirectory) 'user-settings.json'
    if ($PSCmdlet.ShouldProcess($path, 'Merge explicitly confirmed non-secret user settings')) {
        Write-OpsUserSettings -Patch $patch | Out-Null
        Write-Output 'User settings saved. Azure connection and permissions were not changed.'
    }
}
