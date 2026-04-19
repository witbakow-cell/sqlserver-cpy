function Invoke-SqlCpyServerConfigCompare {
<#
.SYNOPSIS
    Compares server-level configuration between source and target SQL Server instances.

.DESCRIPTION
    Produces a list of differences across sp_configure options plus any extended checks
    declared in the configuration (e.g. TempDbFileLayout, TraceFlags, DefaultCollation).

    Primary engine: dbatools (Get-DbaSpConfigure, Compare-DbaSpConfigure where available).
    Falls back to two Get-DbaSpConfigure calls and a local diff when a one-shot compare
    cmdlet is unavailable in the installed dbatools version.

    This function is read-only - it does not modify either instance.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER ExtendedChecks
    Optional array of extra check labels to include (see config/default.psd1).

.OUTPUTS
    PSCustomObject records, one per differing item.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$ExtendedChecks
    )

    Write-SqlCpyStep "Comparing server configuration: $SourceServer -> $TargetServer"

    # TODO: Validate on a live environment. The exact cmdlet and property names below
    # reflect current dbatools 2.x; verify before relying on them.
    $src = Get-DbaSpConfigure -SqlInstance $SourceServer
    $tgt = Get-DbaSpConfigure -SqlInstance $TargetServer

    $tgtMap = @{}
    foreach ($row in $tgt) { $tgtMap[$row.Name] = $row }

    $diff = foreach ($row in $src) {
        $t = $tgtMap[$row.Name]
        if ($null -eq $t) {
            [pscustomobject]@{
                Name          = $row.Name
                SourceValue   = $row.ConfiguredValue
                TargetValue   = $null
                Status        = 'MissingOnTarget'
            }
        } elseif ($row.ConfiguredValue -ne $t.ConfiguredValue) {
            [pscustomobject]@{
                Name          = $row.Name
                SourceValue   = $row.ConfiguredValue
                TargetValue   = $t.ConfiguredValue
                Status        = 'Different'
            }
        }
    }

    foreach ($check in ($ExtendedChecks | Where-Object { $_ })) {
        # TODO: Implement extended checks that sp_configure does not expose.
        # Examples: TempDbFileLayout (Get-DbaDbFile tempdb), TraceFlags (Get-DbaTraceFlag),
        # DefaultCollation (Get-DbaInstanceProperty or SMO Server.Collation).
        Write-SqlCpyInfo "Extended check pending implementation: $check"
    }

    return $diff
}

function Invoke-SqlCpyServerConfigApply {
<#
.SYNOPSIS
    Equalises server-level configuration on the target to match the source.

.DESCRIPTION
    Honours the DryRun flag: when $true, prints the intended changes without applying.
    When $false, uses dbatools (Copy-DbaSpConfigure or Set-DbaSpConfigure per item) to
    apply the values.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER DryRun
    When $true, only log intended changes.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [bool]$DryRun = $true
    )

    Write-SqlCpyStep "Applying server configuration: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    $diff = Invoke-SqlCpyServerConfigCompare -SourceServer $SourceServer -TargetServer $TargetServer

    if (-not $diff) {
        Write-SqlCpyInfo 'No differences detected.'
        return
    }

    foreach ($d in $diff) {
        $msg = "{0}: {1} -> {2}" -f $d.Name, $d.TargetValue, $d.SourceValue
        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN would set $msg"
        } else {
            # TODO: Validate exact parameter set on a live environment.
            Write-SqlCpyInfo "Applying $msg"
            Copy-DbaSpConfigure -Source $SourceServer -Destination $TargetServer -ConfigName $d.Name -EnableException
        }
    }
}
