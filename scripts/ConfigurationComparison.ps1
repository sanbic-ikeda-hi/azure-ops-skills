#requires -Version 7.2
# Pure comparisons. Never persist values or make API requests.
function ConvertTo-OpsComparable {
    param($Value,[string]$Field='')
    if ($Value -is [Collections.IDictionary]) {
        $r=[ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            $name=[string]$key
            if ($Field -eq 'userAssignedIdentities') { $name=ConvertTo-OpsArmId $name }
            if ($r.Contains($name)) {throw 'Duplicate normalized configuration key.'}
            $r[$name]=ConvertTo-OpsComparable $Value[$key] ([string]$key)
        }
        # Normalize key order again after ID normalization.
        $sorted=[ordered]@{};foreach($key in @($r.Keys|Sort-Object -CaseSensitive)){$sorted[$key]=$r[$key]}
        return $sorted
    }
    if ($Value -is [array]) {
        $items=[Collections.Generic.List[object]]::new()
        foreach($v in $Value){$items.Add((ConvertTo-OpsComparable $v $Field))}
        return ,$items.ToArray()
    }
    if ($null -ne $Value -and $Field -in @('ResourceId','PermissionScope','serverFarmId')) {return ConvertTo-OpsArmId $Value}
    return $Value
}
function ConvertTo-OpsArmId {
    param([string]$Value)
    if ($Value -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/?#%]+/providers/[A-Za-z0-9.]+/[^/?#%]+/[^/?#%]+(?:/[^/?#%]+/[^/?#%]+)*$' -or $Value.Contains('..')) {
        throw 'Invalid ARM resource ID. Value omitted.'
    }
    $sub=($Value -split '/')[2];$parsed=[guid]::Empty
    if(-not [guid]::TryParse($sub,[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'Invalid ARM subscription ID.'}
    return $Value.ToLowerInvariant()
}
function Get-OpsConfigurationDifference {
    param($Expected,$Actual)
    $left=ConvertTo-OpsComparable $Expected;$right=ConvertTo-OpsComparable $Actual
    function Compare-OpsNode($a,$b,[string]$Path) {
        if($a -is [Collections.IDictionary] -and $b -is [Collections.IDictionary]) {
            foreach($k in @(@($a.Keys)+@($b.Keys)|Sort-Object -Unique -CaseSensitive)) {
                # Dynamic keys (including resource IDs) must not leak through a difference path.
                $safe=if($k -cmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$'){$k}else{'[entry]'}
                $next=if($Path){$Path+'.'+$safe}else{$safe}
                if(-not $a.Contains($k) -or -not $b.Contains($k)){$next}else{Compare-OpsNode $a[$k] $b[$k] $next}
            }
        } elseif((ConvertTo-Json -InputObject $a -Depth 70 -Compress) -cne (ConvertTo-Json -InputObject $b -Depth 70 -Compress)) {
            if($Path){$Path}else{'[root]'}
        }
    }
    @(Compare-OpsNode $left $right '' | Sort-Object -Unique)
}
function Get-OpsAppRoleComparison {
    param([AllowNull()][object[]]$Expected,[AllowNull()][object[]]$Actual)
    function Project-OpsRoles($Roles) {
        $seen=@{};$values=@{};$result=@()
        foreach($role in $Roles) {
            if($role -isnot [Collections.IDictionary]){throw 'Invalid appRole shape.'}
            $id=[guid]::Empty
            if(-not [guid]::TryParse([string]$role['id'],[ref]$id) -or $id -eq [guid]::Empty -or $seen.ContainsKey($id.ToString())){throw 'Missing or duplicate appRole ID.'}
            $seen[$id.ToString()]=$true
            if($role['value'] -isnot [string] -or $values.ContainsKey($role['value']) -or $role['isEnabled'] -isnot [bool]){throw 'Invalid or duplicate appRole value.'}
            $values[$role['value']]=$true
            if($role['allowedMemberTypes'] -isnot [array] -or @($role['allowedMemberTypes']).Count -eq 0 -or
                @($role['allowedMemberTypes']|Select-Object -Unique).Count -ne $role['allowedMemberTypes'].Count -or
                @($role['allowedMemberTypes']|Where-Object {$_ -cnotin @('User','Application')}).Count){throw 'Invalid appRole member types.'}
            foreach($key in $role.Keys){if($key -cnotin @('id','value','isEnabled','allowedMemberTypes','description','displayName','origin')){throw 'Unknown appRole property. Inspect property names before updating.'}}
            foreach($key in @('description','displayName')){if($role[$key] -isnot [string]){throw 'Incomplete appRole.'}}
            $result+=,@{id=$id.ToString();value=$role['value'];isEnabled=$role['isEnabled'];description=$role['description'];displayName=$role['displayName'];allowedMemberTypes=@($role['allowedMemberTypes']|Sort-Object -CaseSensitive)}
        }
        return ,@($result|Sort-Object id)
    }
    $e=Project-OpsRoles $Expected;$a=Project-OpsRoles $Actual
    $differences=@(Get-OpsConfigurationDifference @{appRoles=$e} @{appRoles=$a})
    @{Matches=($differences.Count -eq 0);DifferentProperties=$differences;ExpectedCount=$e.Count;ActualCount=$a.Count}
}
function Get-OpsPropertyReview {
    param([Collections.IDictionary]$Properties,[string[]]$WritableProperty,[string[]]$ObservedProperty=@())
    $unknown=@($Properties.Keys|Where-Object {$_ -cnotin $WritableProperty -and $_ -cnotin $ObservedProperty})
    @{Known=($unknown.Count -eq 0);UnknownPropertyNames=@($unknown|ForEach-Object {if($_ -cmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$'){$_}else{'[unrecognized]'}});ObservedPropertyNames=@($Properties.Keys|Where-Object {$_ -cin $ObservedProperty})}
}
