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

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER LoginFilter
    Optional array of login names to restrict the copy. $null = all non-system logins.

.PARAMETER DryRun
    When $true, only log intended copies.

.EXAMPLE
    Invoke-SqlCpyLoginCopy -SourceServer chbbbid2 -TargetServer localhost -DryRun $true
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$LoginFilter,
        [bool]$DryRun = $true
    )

    Write-SqlCpyStep "Copying logins: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    # TODO: Validate on a live environment. The logins list path below is defensive -
    # tune filters (sa, ##MS_*) based on target policy.
    $logins = Get-DbaLogin -SqlInstance $SourceServer |
        Where-Object {
            $_.Name -notlike '##*' -and $_.Name -ne 'sa' -and
            ((-not $LoginFilter) -or ($LoginFilter -contains $_.Name))
        }

    foreach ($l in $logins) {
        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN would copy login: $($l.Name) [$($l.LoginType)]"
        } else {
            Write-SqlCpyInfo "Copying login: $($l.Name)"
            Copy-DbaLogin -Source $SourceServer -Destination $TargetServer -Login $l.Name -EnableException
        }
    }
}
