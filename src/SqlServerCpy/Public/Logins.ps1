function Test-SqlCpyLoginSkipped {
<#
.SYNOPSIS
    Returns $true if a SQL login name matches any of the configured skip prefixes.

.DESCRIPTION
    Comparison is case-insensitive. The login name is normalised before the match
    by stripping any leading "<qualifier>\" segments that are not themselves one
    of the skip prefixes. This is what makes "MYDOMAIN\BUILTIN\Administrators"
    and "BUILTIN\Administrators" both match the "BUILTIN" prefix, while still
    letting a plain domain account like "MYDOMAIN\alice" fall through.

    A match is declared when, after normalisation, the remaining string is equal
    to a prefix, begins with "<prefix>\", or begins with "<prefix> " (a few rare
    legacy accounts use a space separator).

.PARAMETER LoginName
    The SQL login name as reported by Get-DbaLogin.

.PARAMETER SkipPrefixes
    Array of prefixes (e.g. 'NT AUTHORITY', 'BUILTIN'). An empty or $null array
    returns $false for every input.

.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$LoginName,
        [string[]]$SkipPrefixes
    )

    if ([string]::IsNullOrWhiteSpace($LoginName)) { return $false }
    if (-not $SkipPrefixes -or $SkipPrefixes.Count -eq 0) { return $false }

    $trimmed = $LoginName.Trim()

    # Build the candidate list to match against. The first is always the raw name.
    # If the login carries an outer qualifier like "MYDOMAIN\BUILTIN\Administrators"
    # and that qualifier is NOT itself one of the skip prefixes, also try the tail
    # ("BUILTIN\Administrators") so nested BUILTIN/NT AUTHORITY principals are
    # caught. The outer-qualifier-is-a-prefix case is handled by the direct match
    # on the raw name below ("ADIS\sqlagent" starts with "ADIS\" -> skip).
    $candidates = @($trimmed)
    if ($trimmed -match '^([^\\]+)\\(.+)$') {
        $head = $Matches[1]
        $rest = $Matches[2]
        $headIsPrefix = $false
        foreach ($p in $SkipPrefixes) {
            if (-not $p) { continue }
            if ([string]::Equals($head, $p.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                $headIsPrefix = $true
                break
            }
        }
        if (-not $headIsPrefix) { $candidates += $rest }
    }

    foreach ($candidate in $candidates) {
        foreach ($p in $SkipPrefixes) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $prefix = $p.Trim()

            if ([string]::Equals($candidate, $prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            $withSlash = $prefix + '\'
            if ($candidate.StartsWith($withSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            $withSpace = $prefix + ' '
            if ($candidate.StartsWith($withSpace, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            # Underscore-qualified service accounts like "ADIS_TeamA_ReadOnly".
            $withUnderscore = $prefix + '_'
            if ($candidate.StartsWith($withUnderscore, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    return $false
}

function Invoke-SqlCpyLoginCopy {
<#
.SYNOPSIS
    Copies SQL Server logins and associated database users from source to target.

.DESCRIPTION
    Primary engine: dbatools Copy-DbaLogin. Handles SIDs, password hashes, default
    databases, and server roles. Database-level user mappings are copied by
    Copy-DbaLogin for databases that already exist on the target.

    Honours the DryRun flag. With DryRun the function lists which logins would be
    copied but does not call Copy-DbaLogin.

    Skip prefixes: logins whose names start with any prefix in
    $Config.LoginSkipPrefixes are filtered out before the copy. The match is
    case-insensitive and tolerates leading domain qualifiers (see
    Test-SqlCpyLoginSkipped). Defaults: 'NT AUTHORITY', 'NT SERVICE', 'BUILTIN',
    'ADIS'. Skipped logins are logged individually so the user can see what was
    dropped and why.

    Connection security: a dbatools connection object opened by
    Get-SqlCpyCachedConnection carries TrustServerCertificate /
    EncryptConnection; it is passed as -SqlInstance to Get-DbaLogin and as
    -Source / -Destination to Copy-DbaLogin. This reuses the preflight
    connection and avoids "certificate chain ... not trusted" errors on
    cmdlets that do not expose trust parameters directly.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER LoginFilter
    Optional array of login names to restrict the copy. $null = all non-system logins.

.PARAMETER DryRun
    When $true, only log intended copies.

.PARAMETER Config
    Config hashtable for connection security. When omitted, Get-SqlCpyConfig is called.

.EXAMPLE
    Invoke-SqlCpyLoginCopy -SourceServer chbbbid2 -TargetServer localhost -DryRun $true
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$LoginFilter,
        [bool]$DryRun = $true,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    $skipPrefixes = @()
    if ($Config.ContainsKey('LoginSkipPrefixes') -and $Config.LoginSkipPrefixes) {
        $skipPrefixes = @($Config.LoginSkipPrefixes)
    }

    Write-SqlCpyStep "Copying logins: $SourceServer -> $TargetServer (DryRun=$DryRun)"
    if ($skipPrefixes.Count -gt 0) {
        Write-SqlCpyInfo ("Login skip prefixes in effect: {0}" -f ($skipPrefixes -join ', '))
    }

    $srcConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Source' -Server $SourceServer -Credential $Config.SourceCredential
    $tgtConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential

    $srcSplat = Get-SqlCpyInstanceSplat -Config $Config -Connection $srcConn -CommandName 'Get-DbaLogin'
    $allLogins = Get-DbaLogin @srcSplat |
        Where-Object {
            $_.Name -notlike '##*' -and $_.Name -ne 'sa' -and
            ((-not $LoginFilter) -or ($LoginFilter -contains $_.Name))
        }

    $logins  = @()
    $skipped = @()
    foreach ($l in $allLogins) {
        if (Test-SqlCpyLoginSkipped -LoginName $l.Name -SkipPrefixes $skipPrefixes) {
            $skipped += $l
        } else {
            $logins += $l
        }
    }

    foreach ($s in $skipped) {
        Write-SqlCpyInfo ("SKIP login (prefix match): {0} [{1}]" -f $s.Name, $s.LoginType)
    }
    if ($skipped.Count -gt 0) {
        Write-SqlCpyInfo ("Skipped {0} login(s) by prefix; {1} will be considered for copy." -f $skipped.Count, $logins.Count)
    }

    $copySplat = Get-SqlCpyCopySplat -Config $Config -SourceConnection $srcConn -DestinationConnection $tgtConn -CommandName 'Copy-DbaLogin'

    foreach ($l in $logins) {
        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN would copy login: $($l.Name) [$($l.LoginType)]"
        } else {
            Write-SqlCpyInfo "Copying login: $($l.Name)"
            Copy-DbaLogin @copySplat -Login $l.Name -EnableException
        }
    }
}
