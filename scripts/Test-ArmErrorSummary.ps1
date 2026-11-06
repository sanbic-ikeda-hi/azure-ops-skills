#requires -Version 7.2
# Offline: synthetic failures only; never use real activity logs as test fixtures.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$checks=0
function Verify-ErrorSummary([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
foreach ($pair in @(
    @('Unauthorized','Unknown'), @('InvalidAuthenticationToken','Authentication'),
    @('AuthorizationFailed','Authorization'), @('MissingSubscriptionRegistration','ProviderRegistration'),
    @('SubscriptionIsOverQuotaForSku','Quota')
)) {
    $body=@{error=@{code=$pair[0];message='DO_NOT_OUTPUT_MESSAGE';details=@(@{code='NestedCode';message='DO_NOT_OUTPUT_DETAIL'})};claims=@{sample='DO_NOT_OUTPUT_CLAIM'}} | ConvertTo-Json -Depth 6
    $summary=Get-OpsArmErrorSummary ([pscustomobject]@{StatusCode=401;Content=$body;Headers=@{Authorization='DO_NOT_OUTPUT_HEADER'}})
    Verify-ErrorSummary ($summary.CategoryHint -eq $pair[1] -and $summary.HttpStatus -eq 401) "Classify by evidence, not HTTP alone: $($pair[0])"
    Verify-ErrorSummary ($summary.BodyParsed -and 'NestedCode' -in $summary.ErrorCodes) 'Nested ARM error codes are preserved'
    Verify-ErrorSummary (($summary | ConvertTo-Json -Depth 5) -notmatch 'DO_NOT_OUTPUT_') 'Messages, claims, headers and arbitrary fields are omitted'
}
foreach ($content in @('', '<html>DO_NOT_OUTPUT_BODY</html>', 'null', '[]')) {
    $summary=Get-OpsArmErrorSummary @{StatusCode=502;Content=$content}
    Verify-ErrorSummary (-not $summary.BodyParsed -and $summary.CategoryHint -eq 'Unknown' -and $summary.HttpStatus -eq 502) 'Invalid body is handled without masking HTTP status'
}
$summary=Get-OpsArmErrorSummary @{StatusCode=403}
Verify-ErrorSummary (-not $summary.BodyParsed -and $summary.CategoryHint -eq 'Unknown') 'Missing body does not invent an authorization cause'
$summary=Get-OpsArmErrorSummary @{StatusCode=400;Content='{"Code":"invalid code with DO_NOT_OUTPUT_TEXT", "ExtendedCode":"70007", "Details": [{"ErrorEntity":{"Code":"Unauthorized","Parameters":["DO_NOT_OUTPUT_PARAMETER"]}}]}'}
Verify-ErrorSummary ($summary.ExtendedCodes[0] -eq '70007' -and $summary.ErrorCodes.Count -eq 1 -and $summary.ErrorCodes[0] -eq 'Unauthorized') 'App Service error entity is supported; non-code text is excluded'
Verify-ErrorSummary (($summary | ConvertTo-Json -Depth 5) -notmatch 'DO_NOT_OUTPUT_') 'Provider parameters and malformed code fields are not emitted'
Write-Host "PASS: $checks ARM error summary checks (offline)."
