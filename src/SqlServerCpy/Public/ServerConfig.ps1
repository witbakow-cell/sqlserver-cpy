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

    Trust/encrypt behaviour: this function does NOT pass TrustServerCertificate /
    EncryptConnection to Get-DbaSpConfigure directly, because that cmdlet does not
    expose those parameters in dbatools 2.x. Instead it obtains a pre-built
    Connect-DbaInstance connection object (via Get-SqlCpyCachedConnection, which
    reuses the handle opened by Test-SqlCpyPreflight) and passes THAT as
    -SqlInstance. dbatools then reuses the open connection - including its
    TrustServerCertificate setting - without needing command-level trust flags.

    This is the fix for the "certificate chain was issued by an authority that
    is not trusted" failure observed on chbbbid2, which the earlier
    parameter-filtering fix could not repair on its own because the filter
    correctly dropped -TrustServerCertificate (Get-DbaSpConfigure does not
    expose it) and therefore silently dropped trust too.

    This function is read-only - it does not modify either instance.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER ExtendedChecks
    Optional array of extra check labels to include (see config/default.psd1).

.PARAMETER Config
    Config hashtable carrying connection-security settings and, after a
    successful Test-SqlCpyPreflight, cached source/target connection objects
    under the keys _SourceConnection / _TargetConnection. When omitted,
    Get-SqlCpyConfig is called and fresh connections are opened.

.OUTPUTS
    PSCustomObject records, one per differing item.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$ExtendedChecks,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep "Comparing server configuration: $SourceServer -> $TargetServer"

    $srcConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Source' -Server $SourceServer -Credential $Config.SourceCredential
    $tgtConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential

    $srcSplat = Get-SqlCpyInstanceSplat -Config $Config -Connection $srcConn -CommandName 'Get-DbaSpConfigure'
    $tgtSplat = Get-SqlCpyInstanceSplat -Config $Config -Connection $tgtConn -CommandName 'Get-DbaSpConfigure'

    try {
        $src = Get-DbaSpConfigure @srcSplat -EnableException
    } catch {
        Write-SqlCpyError "Get-DbaSpConfigure failed on source '$SourceServer': $($_.Exception.Message)"
        Write-SqlCpyInfo  (Get-SqlCpyConnectionErrorHint -Message $_.Exception.Message -Config $Config)
        throw
    }
    try {
        $tgt = Get-DbaSpConfigure @tgtSplat -EnableException
    } catch {
        Write-SqlCpyError "Get-DbaSpConfigure failed on target '$TargetServer': $($_.Exception.Message)"
        Write-SqlCpyInfo  (Get-SqlCpyConnectionErrorHint -Message $_.Exception.Message -Config $Config)
        throw
    }

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

    As with Invoke-SqlCpyServerConfigCompare, trust/encrypt settings are carried by
    pre-built Connect-DbaInstance connection objects rather than command-level
    flags that Copy-DbaSpConfigure does not expose.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER DryRun
    When $true, only log intended changes.

.PARAMETER Config
    Config hashtable (for connection security). When omitted, Get-SqlCpyConfig is called.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [bool]$DryRun = $true,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep "Applying server configuration: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    $diff = Invoke-SqlCpyServerConfigCompare -SourceServer $SourceServer -TargetServer $TargetServer -Config $Config

    if (-not $diff) {
        Write-SqlCpyInfo 'No differences detected.'
        return
    }

    $srcConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Source' -Server $SourceServer -Credential $Config.SourceCredential
    $tgtConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential
    $copySplat = Get-SqlCpyCopySplat -Config $Config -SourceConnection $srcConn -DestinationConnection $tgtConn -CommandName 'Copy-DbaSpConfigure'

    foreach ($d in $diff) {
        $msg = "{0}: {1} -> {2}" -f $d.Name, $d.TargetValue, $d.SourceValue
        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN would set $msg"
        } else {
            Write-SqlCpyInfo "Applying $msg"
            Copy-DbaSpConfigure @copySplat -ConfigName $d.Name -EnableException
        }
    }
}
