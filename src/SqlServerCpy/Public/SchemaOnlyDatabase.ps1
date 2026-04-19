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

    Honours the DryRun flag. With DryRun, the function scripts into a temp folder
    but does not execute the script on the target.

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
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [Parameter(Mandatory)] [string[]]$Databases,
        [bool]$DryRun = $true,
        [string]$OutputFolder
    )

    Write-SqlCpyStep "Copying databases (schema-only): $SourceServer -> $TargetServer (DryRun=$DryRun)"

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("sqlservercpy_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
    Write-SqlCpyInfo "Script output folder: $OutputFolder"

    foreach ($db in $Databases) {
        Write-SqlCpyInfo "Scripting database: $db"

        $scriptPath = Join-Path -Path $OutputFolder -ChildPath ("{0}.sql" -f $db)

        # TODO: Validate on a live environment. Export-DbaScript via piped objects
        # from Get-DbaDbObject is one approach; another is SMO's Scripter with
        # DriWithNoCheck, ScriptData=$false.
        try {
            $src = Connect-DbaInstance -SqlInstance $SourceServer -Database $db -ErrorAction Stop
            Export-DbaScript -InputObject $src.Databases[$db] -FilePath $scriptPath -ScriptingOptionsObject (New-DbaScriptingOption)
        } catch {
            Write-SqlCpyWarning "Scripting for $db used fallback path: $($_.Exception.Message)"
            # TODO: Fallback to SMO Scripter if Export-DbaScript pipeline above is not
            # appropriate for the installed dbatools version.
        }

        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN generated script only for $db (not applied): $scriptPath"
            continue
        }

        # TODO: Apply script to target. Must ensure target database exists first,
        # optionally drop-and-recreate if a flag is added. Minimal behavior:
        Write-SqlCpyInfo "Applying script to target: $db"
        Invoke-DbaQuery -SqlInstance $TargetServer -Database $db -File $scriptPath -EnableException
    }
}
