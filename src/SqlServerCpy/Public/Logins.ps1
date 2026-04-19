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

    Write-SqlCpyStep "Copying logins: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    $srcConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Source' -Server $SourceServer -Credential $Config.SourceCredential
    $tgtConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential

    $srcSplat = Get-SqlCpyInstanceSplat -Config $Config -Connection $srcConn -CommandName 'Get-DbaLogin'
    $logins = Get-DbaLogin @srcSplat |
        Where-Object {
            $_.Name -notlike '##*' -and $_.Name -ne 'sa' -and
            ((-not $LoginFilter) -or ($LoginFilter -contains $_.Name))
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
