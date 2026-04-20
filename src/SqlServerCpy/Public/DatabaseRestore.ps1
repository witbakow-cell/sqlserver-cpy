function Get-SqlCpyDatabaseRestoreConfig {
<#
.SYNOPSIS
    Returns a normalized hashtable of restore-related configuration values,
    filled with safe defaults when the incoming config omits them.

.DESCRIPTION
    Used by Invoke-SqlCpyDatabaseRestore and by tests. Consolidates default
    handling in one place so the action function can stay linear and the
    tests can exercise defaulting without SQL Server present.

.PARAMETER Config
    Config hashtable as produced by Get-SqlCpyConfig. May be $null.

.OUTPUTS
    Hashtable with keys: BackupPath, FileExtensions, FilePattern,
    WithReplace, NoRecovery, TimeoutSeconds, DataFileDirectory,
    LogFileDirectory.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()] [hashtable]$Config
    )

    $resolved = @{
        BackupPath        = '\\chbbopa2\CHBBBID2-backup$\FULL'
        FileExtensions    = @('.bak', '.backup')
        FilePattern       = $null
        WithReplace       = $true
        NoRecovery        = $false
        TimeoutSeconds    = 0
        DataFileDirectory = $null
        LogFileDirectory  = $null
    }

    if ($Config) {
        if ($Config.ContainsKey('DatabaseRestoreBackupPath') -and $Config.DatabaseRestoreBackupPath) {
            $resolved.BackupPath = [string]$Config.DatabaseRestoreBackupPath
        }
        if ($Config.ContainsKey('DatabaseRestoreFileExtensions') -and $Config.DatabaseRestoreFileExtensions) {
            $resolved.FileExtensions = @($Config.DatabaseRestoreFileExtensions)
        }
        if ($Config.ContainsKey('DatabaseRestoreFilePattern')) {
            $resolved.FilePattern = $Config.DatabaseRestoreFilePattern
        }
        if ($Config.ContainsKey('DatabaseRestoreWithReplace')) {
            $resolved.WithReplace = [bool]$Config.DatabaseRestoreWithReplace
        }
        if ($Config.ContainsKey('DatabaseRestoreNoRecovery')) {
            $resolved.NoRecovery = [bool]$Config.DatabaseRestoreNoRecovery
        }
        if ($Config.ContainsKey('DatabaseRestoreTimeoutSeconds')) {
            $resolved.TimeoutSeconds = [int]$Config.DatabaseRestoreTimeoutSeconds
        }
        if ($Config.ContainsKey('DatabaseRestoreDataFileDirectory')) {
            $resolved.DataFileDirectory = $Config.DatabaseRestoreDataFileDirectory
        }
        if ($Config.ContainsKey('DatabaseRestoreLogFileDirectory')) {
            $resolved.LogFileDirectory = $Config.DatabaseRestoreLogFileDirectory
        }
    }

    # Normalize extensions: always leading dot, lowercase.
    $normExt = @()
    foreach ($e in $resolved.FileExtensions) {
        if (-not $e) { continue }
        $s = [string]$e
        if (-not $s.StartsWith('.')) { $s = '.' + $s }
        $normExt += $s.ToLowerInvariant()
    }
    $resolved.FileExtensions = $normExt

    return $resolved
}

function Test-SqlCpyRestoreFileMatchesDatabase {
<#
.SYNOPSIS
    Returns $true when a backup filename looks like it belongs to the named
    database.

.DESCRIPTION
    Pure string helper so it can be unit-tested without SQL Server. Matches
    are case-insensitive and accept common backup naming conventions:

        mydb.bak
        MYDB_FULL_20240101.bak
        mydb-2024-01-01.bak
        mydb_backup_2024_01_01_120000.bak
        mydb 20260420 0633.bak              (timestamped FULL share layout)

    The rule: the stem (filename minus extension) must either equal the
    database name, start with "<database>_", start with "<database>-",
    start with "<database>." (case-insensitive), or match the timestamped
    layout used by the backup share, i.e. "<database> <yyyyMMdd> <HHmm>".
    A bare substring match is intentionally NOT enough to avoid false
    positives like "mydb2.bak" matching database "mydb" or
    "mydb2 20260420 0633.bak" matching "mydb".

.PARAMETER FileName
    Filename only (not full path).

.PARAMETER Database
    Database name.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FileName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Database
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Database)) { return $false }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ([string]::IsNullOrEmpty($stem)) { return $false }

    $db = $Database.Trim()
    if ([string]::Equals($stem, $db, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    if ($stem.Length -gt $db.Length) {
        $prefix = $stem.Substring(0, $db.Length)
        if ([string]::Equals($prefix, $db, [StringComparison]::OrdinalIgnoreCase)) {
            $sep = $stem[$db.Length]
            if ($sep -eq '_' -or $sep -eq '-' -or $sep -eq '.') { return $true }
            # Timestamped layout: "<db> <yyyyMMdd> <HHmm>"
            if ($sep -eq ' ') {
                $rest = $stem.Substring($db.Length + 1)
                if ($rest -match '^\d{8}\s+\d{4}$') { return $true }
            }
        }
    }

    return $false
}

function Get-SqlCpyRestoreBackupTimestamp {
<#
.SYNOPSIS
    Parses the trailing "<yyyyMMdd> <HHmm>" timestamp of a stamped backup
    filename and returns a [datetime], or $null if the filename does not
    follow the stamped layout.

.DESCRIPTION
    Pure string helper for tests and for the newest-first sort in
    Find-SqlCpyDatabaseBackupFile. Used to prefer the newest timestamp
    baked into the filename itself over filesystem LastWriteTime when the
    stamped layout is in use.

.PARAMETER FileName
    Filename only (not full path).

.PARAMETER Database
    Database name the stem must start with (case-insensitive) for the
    timestamp to be returned.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FileName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Database
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Database)) { return $null }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ([string]::IsNullOrEmpty($stem)) { return $null }

    $db = $Database.Trim()
    if ($stem.Length -le ($db.Length + 1)) { return $null }
    $prefix = $stem.Substring(0, $db.Length)
    if (-not [string]::Equals($prefix, $db, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($stem[$db.Length] -ne ' ') { return $null }

    $rest = $stem.Substring($db.Length + 1)
    if ($rest -notmatch '^(\d{8})\s+(\d{4})$') { return $null }

    $datePart = $Matches[1]
    $timePart = $Matches[2]
    $parsed = [datetime]::MinValue
    $fmt = 'yyyyMMdd HHmm'
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $ok = [datetime]::TryParseExact(
        ("{0} {1}" -f $datePart, $timePart),
        $fmt,
        $culture,
        [System.Globalization.DateTimeStyles]::AssumeLocal,
        [ref]$parsed)
    if (-not $ok) { return $null }
    return $parsed
}

function Find-SqlCpyDatabaseBackupFile {
<#
.SYNOPSIS
    Returns the candidate backup files for one database under a given path,
    newest first. Pure filesystem enumeration - no SQL access required.

.DESCRIPTION
    Enumerates files directly in -BackupPath (non-recursive by default, to
    match the "FULL" share layout), filters by extension, optional filename
    glob, and database-name matching via
    Test-SqlCpyRestoreFileMatchesDatabase. Returns candidates sorted by
    LastWriteTime descending, so callers can simply take the first entry to
    pick "the newest matching full backup".

.PARAMETER BackupPath
    UNC or local directory holding backup files.

.PARAMETER Database
    Database name to match.

.PARAMETER FileExtensions
    Accepted extensions (leading dot, lowercase preferred). Passing $null or
    an empty array returns no matches.

.PARAMETER FilePattern
    Optional -like glob applied to the filename.

.PARAMETER Recurse
    When $true, descends into subdirectories. Default $false.

.PARAMETER CandidateFiles
    Test-only override: instead of calling Get-ChildItem, use this supplied
    collection. Each element must have Name and LastWriteTime (and
    optionally FullName) properties. Lets tests exercise the filter without
    touching the filesystem.

.OUTPUTS
    Array of file info objects (or the simulated objects), newest first.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BackupPath,
        [Parameter(Mandatory)] [string]$Database,
        [string[]]$FileExtensions = @('.bak', '.backup'),
        [AllowNull()] [string]$FilePattern,
        [switch]$Recurse,
        [object[]]$CandidateFiles
    )

    if (-not $FileExtensions -or $FileExtensions.Count -eq 0) { return @() }

    $extSet = @{}
    foreach ($e in $FileExtensions) {
        if (-not $e) { continue }
        $s = [string]$e
        if (-not $s.StartsWith('.')) { $s = '.' + $s }
        $extSet[$s.ToLowerInvariant()] = $true
    }

    $files = @()
    if ($PSBoundParameters.ContainsKey('CandidateFiles')) {
        $files = @($CandidateFiles)
    } else {
        if (-not (Test-Path -LiteralPath $BackupPath)) { return @() }
        $gci = @{ Path = $BackupPath; File = $true; ErrorAction = 'SilentlyContinue' }
        if ($Recurse) { $gci['Recurse'] = $true }
        $files = @(Get-ChildItem @gci)
    }

    $matched = @()
    foreach ($f in $files) {
        if (-not $f -or -not $f.Name) { continue }
        $ext = [System.IO.Path]::GetExtension($f.Name)
        if (-not $ext) { continue }
        if (-not $extSet.ContainsKey($ext.ToLowerInvariant())) { continue }
        if ($FilePattern -and ($f.Name -notlike $FilePattern)) { continue }
        if (-not (Test-SqlCpyRestoreFileMatchesDatabase -FileName $f.Name -Database $Database)) { continue }
        $matched += $f
    }

    # Prefer the newest timestamp baked into the filename when present
    # (FULL share layout is "<db> yyyyMMdd HHmm.bak"). Fall back to
    # LastWriteTime for entries whose name does not carry a stamp. Use an
    # ordering key that is stable across both cases: (stampedTicks,
    # lastWriteTicks). Stamp-less files get stampedTicks = 0 so any
    # stamped file sorts ahead of them, which matches user intent to
    # prefer explicit timestamps over filesystem mtime.
    $decorated = foreach ($f in $matched) {
        $stamp = Get-SqlCpyRestoreBackupTimestamp -FileName $f.Name -Database $Database
        $stampTicks = if ($stamp) { $stamp.Ticks } else { 0L }
        $mtimeTicks = 0L
        if ($f.PSObject.Properties['LastWriteTime'] -and $f.LastWriteTime) {
            try { $mtimeTicks = ([datetime]$f.LastWriteTime).Ticks } catch { $mtimeTicks = 0L }
        }
        [pscustomobject]@{
            File       = $f
            StampTicks = [long]$stampTicks
            MtimeTicks = [long]$mtimeTicks
        }
    }

    return @(
        $decorated |
            Sort-Object -Property StampTicks, MtimeTicks -Descending |
            ForEach-Object { $_.File }
    )
}

function Invoke-SqlCpyDatabaseRestore {
<#
.SYNOPSIS
    Restores one or more databases on the target SQL Server from backup files
    sitting on a configured UNC path.

.DESCRIPTION
    This is the restore-based alternative to Invoke-SqlCpySchemaOnlyDatabaseCopy.
    Unlike the schema-only path (which scripts object definitions without data),
    THIS ACTION RESTORES FULL DATABASES INCLUDING DATA on the target. That is
    the whole point - a file-based move for cases where the schema-only path
    has proven unreliable.

    Assumptions:
      * Another process (not this tool) drops backup files onto the configured
        UNC share. This function does NOT create backups.
      * The share typically holds FULL backups only. Default extensions
        (.bak, .backup) reflect that; transaction logs are NOT picked up and
        no log-chain replay is attempted.
      * Primary engine: dbatools Restore-DbaDatabase. A missing dbatools
        installation is a hard error and is reported up-front.
      * Connection security (TrustServerCertificate / EncryptConnection /
        ConnectionTimeout) is taken from the cached target connection built
        by Get-SqlCpyCachedConnection, consistent with the rest of the module.
      * Source server is NOT contacted by this action. The backup files on
        the share are the authoritative source.

    Behaviour for each selected database:
      1. Find candidate backup files under -BackupPath that match the
         database name and the configured extensions. Pick the newest.
      2. If none found, emit a WARN line and skip; continue with the next
         database. Missing backups are NOT fatal.
      3. If DryRun is set, log what WOULD be restored (database, file,
         timestamp) and move on.
      4. Otherwise invoke Restore-DbaDatabase with WithReplace /
         NoRecovery / DestinationDataDirectory / DestinationLogDirectory /
         StatementTimeout as configured.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER Databases
    Database names to restore. When omitted, uses Config.DatabaseRestoreList.

.PARAMETER BackupPath
    UNC (or local) path holding backup files. When omitted, uses
    Config.DatabaseRestoreBackupPath, which defaults to
    \\chbbopa2\CHBBBID2-backup$\FULL.

.PARAMETER DryRun
    When $true, only log the intended restores.

.PARAMETER Config
    Config hashtable. Defaults to Get-SqlCpyConfig.

.EXAMPLE
    Invoke-SqlCpyDatabaseRestore -TargetServer localhost -Databases @('dwcontrol')
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$Databases,
        [string]$BackupPath,
        [bool]$DryRun = $true,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }
    $rc = Get-SqlCpyDatabaseRestoreConfig -Config $Config

    if ($PSBoundParameters.ContainsKey('BackupPath') -and $BackupPath) {
        $rc.BackupPath = $BackupPath
    }

    if (-not $Databases -or $Databases.Count -eq 0) {
        if ($Config.ContainsKey('DatabaseRestoreList') -and $Config.DatabaseRestoreList) {
            $Databases = @($Config.DatabaseRestoreList)
        }
    }
    if (-not $Databases -or $Databases.Count -eq 0) {
        Write-SqlCpyWarning 'No databases specified for restore; nothing to do.'
        return
    }

    Write-SqlCpyStep ("Restoring databases to $TargetServer from $($rc.BackupPath) (DryRun=$DryRun)")
    Write-SqlCpyInfo ("Restore action RESTORES FULL DATABASES WITH DATA (not schema-only).")

    if (-not (Test-Path -LiteralPath $rc.BackupPath)) {
        Write-SqlCpyWarning ("Backup path not reachable: $($rc.BackupPath). Individual database lookups will still be attempted.")
    }

    $haveDbatools = [bool](Get-Command -Name Restore-DbaDatabase -ErrorAction SilentlyContinue)
    if (-not $haveDbatools -and -not $DryRun) {
        throw "dbatools Restore-DbaDatabase is not available in this session. Install-Module dbatools (see DEPENDENCIES.md) and retry."
    }

    # Build target connection only when we are actually going to restore.
    $tgtConn = $null
    if (-not $DryRun) {
        $tgtConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential
    }

    foreach ($db in $Databases) {
        $db = [string]$db
        if ([string]::IsNullOrWhiteSpace($db)) { continue }

        $candidates = Find-SqlCpyDatabaseBackupFile `
            -BackupPath     $rc.BackupPath `
            -Database       $db `
            -FileExtensions $rc.FileExtensions `
            -FilePattern    $rc.FilePattern

        if (-not $candidates -or $candidates.Count -eq 0) {
            Write-SqlCpyWarning ("backup not found for database $db in path $($rc.BackupPath); skipping")
            continue
        }

        $chosen = $candidates[0]
        $chosenPath = if ($chosen.PSObject.Properties['FullName'] -and $chosen.FullName) { $chosen.FullName } else { Join-Path -Path $rc.BackupPath -ChildPath $chosen.Name }
        $chosenStamp = $null
        if ($chosen.PSObject.Properties['LastWriteTime']) { $chosenStamp = $chosen.LastWriteTime }

        if ($candidates.Count -gt 1) {
            Write-SqlCpyInfo ("{0}: {1} candidate backup(s) found; picking newest: {2}" -f $db, $candidates.Count, $chosen.Name)
        }

        if ($DryRun) {
            $stampText = if ($chosenStamp) { $chosenStamp.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown timestamp' }
            Write-SqlCpyInfo ("DRYRUN would restore {0} from {1} as {0} ({2})" -f $db, $chosenPath, $stampText)
            continue
        }

        $restoreSplat = @{
            SqlInstance    = $tgtConn
            Path           = $chosenPath
            DatabaseName   = $db
            EnableException = $true
        }
        if ($rc.WithReplace) { $restoreSplat['WithReplace'] = $true }
        if ($rc.NoRecovery)  { $restoreSplat['NoRecovery']  = $true }
        if ($rc.DataFileDirectory) { $restoreSplat['DestinationDataDirectory'] = $rc.DataFileDirectory }
        if ($rc.LogFileDirectory)  { $restoreSplat['DestinationLogDirectory']  = $rc.LogFileDirectory  }

        # Route a statement timeout in only if the cmdlet version exposes one.
        $paramSet = Get-SqlCpyCommandParameter -Name 'Restore-DbaDatabase'
        if ($paramSet -and $rc.TimeoutSeconds -gt 0) {
            $tn = Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates @('StatementTimeout','ConnectionTimeout','Timeout')
            if ($tn) { $restoreSplat[$tn] = [int]$rc.TimeoutSeconds }
        }

        # Best-effort integrity / metadata check.
        if (Get-Command -Name Read-DbaBackupHeader -ErrorAction SilentlyContinue) {
            try {
                $hdr = Read-DbaBackupHeader -SqlInstance $tgtConn -Path $chosenPath -ErrorAction Stop | Select-Object -First 1
                if ($hdr -and $hdr.DatabaseName -and -not [string]::Equals([string]$hdr.DatabaseName, $db, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-SqlCpyWarning ("{0}: backup header reports DatabaseName='{1}' (different from requested). Proceeding with restore as '{0}' because -DatabaseName overrides the backup's embedded name." -f $db, $hdr.DatabaseName)
                }
            } catch {
                Write-SqlCpyWarning ("{0}: Read-DbaBackupHeader failed ({1}); continuing." -f $db, $_.Exception.Message)
            }
        }

        Write-SqlCpyInfo ("Restoring {0} <- {1}" -f $db, $chosenPath)
        try {
            Restore-DbaDatabase @restoreSplat | Out-Null
            Write-SqlCpyInfo ("Restore complete: {0}" -f $db)
        } catch {
            Write-SqlCpyError ("Restore failed for {0}: {1}" -f $db, $_.Exception.Message)
            # Do not throw - continue with remaining databases, matching the
            # "missing backup is not fatal" spirit of this action.
        }
    }
}
