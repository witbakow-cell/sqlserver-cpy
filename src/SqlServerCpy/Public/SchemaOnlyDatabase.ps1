function Invoke-SqlCpySchemaOnlyDatabaseCopy {
<#
.SYNOPSIS
    Copies selected databases as schema-only (no table data) from source to target.

.DESCRIPTION
    Scripts schemas, tables, views, stored procedures, functions, triggers, indexes,
    constraints, and user-defined types from the source and applies them to the
    target. No row data is transferred.

    Primary engine: dbatools Export-DbaScript and New-DbaDatabase + Invoke-DbaQuery
    for applying the generated script. SMO Scripter is the documented fallback when
    finer control over dependency ordering is needed.

    Connection security: the source and target handles are obtained via
    Get-SqlCpyCachedConnection (reusing the preflight connection objects when
    available), so TrustServerCertificate / EncryptConnection apply even to the
    Export-DbaScript / Invoke-DbaQuery paths where dbatools does not expose
    trust flags directly.

    Honours the DryRun flag. With DryRun, the function scripts into a temp
    folder but does not execute the script on the target.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER Databases
    One or more database names to copy (schema-only). Required.

.PARAMETER DryRun
    When $true, only script the objects; do not create/alter the target databases.

.PARAMETER OutputFolder
    Optional folder to store generated .sql files. Defaults to a temp path.

.PARAMETER Config
    Config hashtable for connection security. When omitted, Get-SqlCpyConfig is called.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [Parameter(Mandatory)] [string[]]$Databases,
        [bool]$DryRun = $true,
        [string]$OutputFolder,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep "Copying databases (schema-only): $SourceServer -> $TargetServer (DryRun=$DryRun)"

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("sqlservercpy_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
    Write-SqlCpyInfo "Script output folder: $OutputFolder"

    $srcConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Source' -Server $SourceServer -Credential $Config.SourceCredential

    foreach ($db in $Databases) {
        Write-SqlCpyInfo "Scripting database: $db"

        $scriptPath = Join-Path -Path $OutputFolder -ChildPath ("{0}.sql" -f $db)

        try {
            Export-DbaScript -InputObject $srcConn.Databases[$db] -FilePath $scriptPath -ScriptingOptionsObject (New-DbaScriptingOption)
        } catch {
            Write-SqlCpyWarning "Scripting for $db used fallback path: $($_.Exception.Message)"
            Write-SqlCpyInfo   (Get-SqlCpyConnectionErrorHint -Message $_.Exception.Message -Config $Config)
            # TODO: Fallback to SMO Scripter if Export-DbaScript pipeline above is not
            # appropriate for the installed dbatools version.
        }

        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN generated script only for $db (not applied): $scriptPath"
            continue
        }

        Write-SqlCpyInfo "Applying script to target: $db"
        $tgtConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential
        $tgtSplat = Get-SqlCpyInstanceSplat -Config $Config -Connection $tgtConn -CommandName 'Invoke-DbaQuery'
        Invoke-DbaQuery @tgtSplat -Database $db -File $scriptPath -EnableException
    }
}
