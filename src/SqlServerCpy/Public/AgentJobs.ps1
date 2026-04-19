function Invoke-SqlCpyAgentJobCopy {
<#
.SYNOPSIS
    Copies SQL Server Agent jobs from source to target.

.DESCRIPTION
    Primary engine: dbatools Copy-DbaAgentJob. This also brings across job steps,
    schedules, operators, and categories via the related cmdlets when -Force or
    explicit parameters are used.

    Honours the DryRun flag. Connection security parameters flow via
    Get-SqlCpyConnectionSplat / Get-SqlCpyCopySplat.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER JobFilter
    Optional array of job names to restrict the copy.

.PARAMETER DryRun
    When $true, only log intended copies.

.PARAMETER Config
    Config hashtable for connection security. When omitted, Get-SqlCpyConfig is called.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$JobFilter,
        [bool]$DryRun = $true,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep "Copying SQL Agent jobs: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    $srcSplat = Get-SqlCpyConnectionSplat -Config $Config -Server $SourceServer -Credential $Config.SourceCredential
    $jobs = Get-DbaAgentJob @srcSplat |
        Where-Object { (-not $JobFilter) -or ($JobFilter -contains $_.Name) }

    $copySplat = Get-SqlCpyCopySplat -Config $Config -Source $SourceServer -Destination $TargetServer

    foreach ($j in $jobs) {
        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN would copy job: $($j.Name) [Enabled=$($j.IsEnabled)]"
        } else {
            Write-SqlCpyInfo "Copying job: $($j.Name)"
            Copy-DbaAgentJob @copySplat -Job $j.Name -EnableException
        }
    }
}
