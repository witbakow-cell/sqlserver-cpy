function Invoke-SqlCpyAgentJobCopy {
<#
.SYNOPSIS
    Copies SQL Server Agent jobs from source to target.

.DESCRIPTION
    Primary engine: dbatools Copy-DbaAgentJob. This also brings across job steps,
    schedules, operators, and categories via the related cmdlets when -Force or
    explicit parameters are used.

    Honours the DryRun flag.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER JobFilter
    Optional array of job names to restrict the copy.

.PARAMETER DryRun
    When $true, only log intended copies.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$JobFilter,
        [bool]$DryRun = $true
    )

    Write-SqlCpyStep "Copying SQL Agent jobs: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    # TODO: Validate on a live environment. Consider copying Operators / Schedules /
    # Categories first via Copy-DbaAgentOperator, Copy-DbaAgentSchedule, etc.
    $jobs = Get-DbaAgentJob -SqlInstance $SourceServer |
        Where-Object { (-not $JobFilter) -or ($JobFilter -contains $_.Name) }

    foreach ($j in $jobs) {
        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN would copy job: $($j.Name) [Enabled=$($j.IsEnabled)]"
        } else {
            Write-SqlCpyInfo "Copying job: $($j.Name)"
            Copy-DbaAgentJob -Source $SourceServer -Destination $TargetServer -Job $j.Name -EnableException
        }
    }
}
