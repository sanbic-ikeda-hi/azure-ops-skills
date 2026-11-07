#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ConfigurationComparison.ps1')
$checks=0
function Check($ok,$name){if(-not $ok){throw $name};$script:checks++}
function Reject($code,$name){$failed=$false;try{& $code}catch{$failed=$true};Check $failed $name}
$id='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.Web/sites/test'
Check (@(Get-OpsConfigurationDifference @{ResourceId=$id} @{ResourceId=$id.ToUpperInvariant()}).Count -eq 0) 'ARM casing'
Check (@(Get-OpsConfigurationDifference @{ResourceId=$id} @{ResourceId=($id+'-other')}).Count -eq 1) 'Other resource refused'
Reject {ConvertTo-OpsArmId '/subscriptions/bad/resourceGroups/x/providers/Microsoft.Web/sites/x'} 'Invalid ID'
Check (@(Get-OpsConfigurationDifference @{value='ABC'} @{value='abc'}).Count -eq 1) 'Ordinary values remain case sensitive'
Check (@(Get-OpsConfigurationDifference @{} @{value=$null}).Count -eq 1) 'Missing is distinct from null'
foreach($pair in @(@{a=@();b=$null},@{a=@('a');b='a'},@{a=,@('a');b=@('a')})){
 Check (@(Get-OpsConfigurationDifference @{v=$pair.a} @{v=$pair.b}).Count -eq 1) 'Array shapes retained'
}
$a=@{userAssignedIdentities=@{$id=@{principalId='first';clientId='client'}}}
$b=@{userAssignedIdentities=@{$id.ToUpperInvariant()=@{principalId='first';clientId='client'}}}
Check (@(Get-OpsConfigurationDifference $a $b).Count -eq 0) 'Identity ARM reference casing'
$b.userAssignedIdentities[$id.ToUpperInvariant()].principalId='different'
Check (@(Get-OpsConfigurationDifference $a $b).Count -eq 1) 'Principal checked separately'
$r1=@{id='22222222-2222-2222-2222-222222222222';value='Edit';isEnabled=$true;allowedMemberTypes=@('User');displayName='Edit';description='Edit'}
$r2=@{id='33333333-3333-3333-3333-333333333333';value='Generate';isEnabled=$true;allowedMemberTypes=@('Application');displayName='Generate';description='Generate'}
Check (Get-OpsAppRoleComparison @($r1,$r2) @($r2,$r1)).Matches 'Role order ignored'
foreach($field in @('value','isEnabled','allowedMemberTypes','description','displayName')){
 $bad=$r1.Clone();$bad[$field]=switch($field){isEnabled{$false};allowedMemberTypes{,@('Application')};default{'changed'}}
 Check (-not (Get-OpsAppRoleComparison @($r1,$r2) @($bad,$r2)).Matches) "Role field: $field"
}
Check (-not (Get-OpsAppRoleComparison @($r1,$r2) @($r1)).Matches) 'Missing role'
Reject {Get-OpsAppRoleComparison @($r1) @($r1,$r1)} 'Duplicate role'
Check (@(Get-OpsConfigurationDifference @{web=@{redirectUriSettings=@()}} @{web=@{redirectUriSettings=@(@{index=1;uri='DO_NOT_PRINT'})}}) -contains 'web.redirectUriSettings') 'Service supplement requires review'
# Known-shaped property names are not values; dynamic URI keys are masked.
$diff=@(Get-OpsConfigurationDifference @{'https://DO_NOT_PRINT'=1} @{'https://DO_NOT_PRINT'=2})
Check (($diff -join '') -notmatch 'DO_NOT_PRINT') 'Dynamic key not logged'
Check (-not (Get-OpsPropertyReview @{unknown=1} @('known')).Known) 'Unknown schema requires review'
Check (Get-OpsPropertyReview @{metadata=1;known=2} @('known') @('metadata')).Known 'Read metadata explicitly classified'
Write-Output "PASS: $checks comparison checks; no cloud requests."
