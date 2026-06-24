function Get-CollectionCount {
    param($Items)

    if ($null -eq $Items) {
        return 0
    }

    return @($Items).Count
}

function Test-RuleUsesLocalPort {
    param(
        $Rule,
        [int]$Port
    )

    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $Rule -ErrorAction SilentlyContinue
    if ($null -eq $portFilter) {
        return $false
    }

    foreach ($lp in @($portFilter.LocalPort)) {
        $lpStr = [string]$lp
        if ($lpStr -eq [string]$Port) {
            return $true
        }

        if ($lpStr -match '^(\d+)-(\d+)$') {
            if ($Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) {
                return $true
            }
        }
    }

    return $false
}

function Test-RuleAllowsAnyRemote {
    param($Rule)

    $addrFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule -ErrorAction SilentlyContinue
    if ($null -eq $addrFilter) {
        return $false
    }

    $remote = @($addrFilter.RemoteAddress)
    return ($remote -contains 'Any' -or $remote -contains '*')
}

function Get-BuiltinRdpFirewallRules {
    param(
        [int]$Port,
        [string]$ExcludePrefix
    )

    $rules = [System.Collections.Generic.List[object]]::new()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($rule in @(Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue)) {
        if ($rule.DisplayName -notlike "${ExcludePrefix}*") {
            if ($seenNames.Add([string]$rule.Name)) {
                $rules.Add($rule)
            }
        }
    }

    $candidates = @(Get-NetFirewallRule -Direction Inbound -Action Allow -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -notlike "${ExcludePrefix}*" -and
            $_.DisplayName -ne "${ExcludePrefix}_BLOCK_NON_GEO"
        })

    foreach ($rule in $candidates) {
        if ((Test-RuleUsesLocalPort -Rule $rule -Port $Port) -and (Test-RuleAllowsAnyRemote -Rule $rule)) {
            if ($seenNames.Add([string]$rule.Name)) {
                $rules.Add($rule)
            }
        }
    }

    return @($rules | Sort-Object -Property Name -Unique)
}
