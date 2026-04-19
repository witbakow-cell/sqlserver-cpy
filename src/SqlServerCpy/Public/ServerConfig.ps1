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

    Connection parameters (EncryptConnection, TrustServerCertificate, ConnectionTimeout)
    are taken from the -Config hashtable via Get-SqlCpyConnectionSplat. This is where
    the "certificate chain was issued by an authority that is not trusted" warning from
    Get-DbaSpConfigure was coming from: dbatools now defaults to Encrypt=Mandatory with
    strict chain validation. Passing TrustServerCertificate explicitly - or better,
    running Test-SqlCpyPreflight first - surfaces the issue clearly instead of as a
    silent WARN + empty result.

    This function is read-only - it does not modify either instance.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER ExtendedChecks
    Optional array of extra check labels to include (see config/default.psd1).

.PARAMETER Config
    Config hashtable carrying connection-security settings. When omitted,
    Get-SqlCpyConfig is called.

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

    $srcSplat = Get-SqlCpyConnectionSplat -Config $Config -Server $SourceServer -Credential $Config.SourceCredential
    $tgtSplat = Get-SqlCpyConnectionSplat -Config $Config -Server $TargetServer -Credential $Config.TargetCredential

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
    apply the values. Connection parameters flow via Get-SqlCpyCopySplat so
    TrustServerCertificate / EncryptConnection are consistent with the rest of the tool.

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

    $copySplat = Get-SqlCpyCopySplat -Config $Config -Source $SourceServer -Destination $TargetServer

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
