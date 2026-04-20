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
    LogFileDirectory, LogCandidateLimit, NameAliases.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()] [hashtable]$Config
    )

    $resolved = @{
        BackupPath           = '\\chbbopa2\CHBBBID2-backup$\FULL'
        FileExtensions       = @('.bak', '.backup')
        FilePattern          = $null
        WithReplace          = $true
        NoRecovery           = $false
        TimeoutSeconds       = 0
        DataFileDirectory    = $null
        LogFileDirectory     = $null
        LogCandidateLimit    = 50
        NameAliases          = @{}
        UseLocalStaging      = $true
        LocalStagingPath     = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup'
        OverwriteStagedFile  = $true
        CleanupLocalStaging  = $false
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
        if ($Config.ContainsKey('DatabaseRestoreLogCandidateLimit')) {
            $raw = $Config.DatabaseRestoreLogCandidateLimit
            if ($null -ne $raw) { $resolved.LogCandidateLimit = [int]$raw }
        }
        if ($Config.ContainsKey('DatabaseRestoreUseLocalStaging')) {
            $resolved.UseLocalStaging = [bool]$Config.DatabaseRestoreUseLocalStaging
        }
        if ($Config.ContainsKey('DatabaseRestoreLocalStagingPath') -and $Config.DatabaseRestoreLocalStagingPath) {
            $resolved.LocalStagingPath = [string]$Config.DatabaseRestoreLocalStagingPath
        }
        if ($Config.ContainsKey('DatabaseRestoreOverwriteStagedFile')) {
            $resolved.OverwriteStagedFile = [bool]$Config.DatabaseRestoreOverwriteStagedFile
        }
        if ($Config.ContainsKey('DatabaseRestoreCleanupLocalStaging')) {
            $resolved.CleanupLocalStaging = [bool]$Config.DatabaseRestoreCleanupLocalStaging
        }
        if ($Config.ContainsKey('DatabaseRestoreNameAliases') -and $Config.DatabaseRestoreNameAliases) {
            $aliasHash = @{}
            foreach ($k in @($Config.DatabaseRestoreNameAliases.Keys)) {
                if ([string]::IsNullOrWhiteSpace([string]$k)) { continue }
                $v = [string]$Config.DatabaseRestoreNameAliases[$k]
                if ([string]::IsNullOrWhiteSpace($v)) { continue }
                $aliasHash[([string]$k).Trim()] = $v.Trim()
            }
            $resolved.NameAliases = $aliasHash
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

function Resolve-SqlCpyRestoreDatabaseAlias {
<#
.SYNOPSIS
    Resolves a user-supplied database name to its on-share backup base name
    via the optional DatabaseRestoreNameAliases mapping.

.DESCRIPTION
    Pure string helper. When the alias hashtable contains a case-insensitive
    entry for the requested database, returns the aliased name; otherwise
    returns the input unchanged. Whitespace is trimmed.

    Aliases exist because the matcher is intentionally strict: a request
    for "timesheet" will NOT match a file named "mTimesheet 20260420 0633.bak".
    If the real backup base name differs from the logical database name in
    the user's workflow, the alias map lets the user declare the mapping
    once in config instead of renaming files or loosening the matcher.

.PARAMETER Database
    The user-supplied database name.

.PARAMETER Aliases
    Hashtable of { requestedName -> on-share base name }. May be $null or
    empty.

.OUTPUTS
    [string] - the resolved on-share base name. Same as input when no alias
    applies.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Database,
        [AllowNull()] [hashtable]$Aliases
    )

    if ([string]::IsNullOrWhiteSpace($Database)) { return $Database }
    $trimmed = $Database.Trim()
    if (-not $Aliases -or $Aliases.Count -eq 0) { return $trimmed }

    foreach ($k in @($Aliases.Keys)) {
        if ([string]::Equals([string]$k, $trimmed, [StringComparison]::OrdinalIgnoreCase)) {
            $v = [string]$Aliases[$k]
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        }
    }
    return $trimmed
}

function Get-SqlCpyRestoreStagingPlan {
<#
.SYNOPSIS
    Builds a staging plan describing the local destination path for a backup
    file that is about to be copied off a UNC share before the restore runs.

.DESCRIPTION
    Pure path-composition helper so it can be unit-tested without touching the
    filesystem. Preserves the original backup filename (including extension
    and any embedded timestamp, e.g. "mTimesheet 20260420 0633.bak") so the
    staged copy is easy to correlate with its source on the share. Does NOT
    check whether the staging folder exists - that is the caller's job, and
    is a runtime concern (the default path lives under Program Files and may
    require admin to create, though SQL Server's default Backup folder is
    almost always present on a healthy install).

    Returns a pscustomobject. The function never throws; callers should
    inspect .IsValid and .Reason to decide what to do.

.PARAMETER SourceFullName
    Full path of the source backup file (usually on the UNC share).

.PARAMETER SourceFileName
    Bare filename of the source backup (used when SourceFullName is missing or
    empty). Preserved verbatim as the staging destination filename.

.PARAMETER StagingDirectory
    Local directory to copy into. Should be readable by the SQL Server service
    account on the target (the whole reason this workaround exists). Default
    is the SQL Server 2022 default Backup folder for the MSSQLSERVER instance.

.OUTPUTS
    pscustomobject with properties:
      IsValid       - $true only when all fields could be populated.
      Reason        - short reason code: 'ok', 'no-filename',
                      'no-staging-directory'.
      SourcePath    - echo of SourceFullName (or SourceFileName if full path
                      was empty).
      SourceName    - bare filename extracted from the source.
      Destination   - composed local path (Join-Path StagingDirectory
                      SourceName) or $null when invalid.
      StagingDir    - echo of StagingDirectory.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string]$SourceFullName,
        [AllowNull()] [AllowEmptyString()] [string]$SourceFileName,
        [AllowNull()] [AllowEmptyString()] [string]$StagingDirectory
    )

    $out = [pscustomobject]@{
        IsValid     = $false
        Reason      = 'no-filename'
        SourcePath  = $SourceFullName
        SourceName  = $null
        Destination = $null
        StagingDir  = $StagingDirectory
    }

    $name = $null
    if (-not [string]::IsNullOrWhiteSpace($SourceFileName)) {
        $name = [string]$SourceFileName
    } elseif (-not [string]::IsNullOrWhiteSpace($SourceFullName)) {
        try { $name = [System.IO.Path]::GetFileName([string]$SourceFullName) } catch { $name = $null }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $out.Reason = 'no-filename'
        return $out
    }
    $out.SourceName = $name
    if ([string]::IsNullOrWhiteSpace($SourceFullName)) {
        $out.SourcePath = $name
    }

    if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
        $out.Reason = 'no-staging-directory'
        return $out
    }

    $out.Destination = Join-Path -Path $StagingDirectory -ChildPath $name
    $out.IsValid     = $true
    $out.Reason      = 'ok'
    return $out
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

    $r = Get-SqlCpyRestoreMatchReason -FileName $FileName -Database $Database
    return [bool]$r.Match
}

function Get-SqlCpyRestoreMatchReason {
<#
.SYNOPSIS
    Returns a structured explanation of why a backup filename matched, or
    did not match, a given database name.

.DESCRIPTION
    Pure string helper used by diagnostic logging. Unlike
    Test-SqlCpyRestoreFileMatchesDatabase (boolean), this function exposes
    the *reason* in a stable set of short codes so the action function can
    log which candidate was discarded and why.

    Reason codes:
      empty-filename         filename was null/whitespace
      empty-database         database was null/whitespace
      no-stem                filename had no stem
      exact-stem             stem equals db (match)
      prefix-underscore      stem starts with "<db>_" (match)
      prefix-dash            stem starts with "<db>-" (match)
      prefix-dot             stem starts with "<db>." (match)
      stamped                stem is "<db> yyyyMMdd HHmm" (match)
      prefix-bleed           stem starts with db but next char is not a known separator
      stamped-bad-format     stem starts with "<db> " but the rest is not yyyyMMdd HHmm
      stem-shorter-than-db   stem is shorter than db, so cannot match
      stem-mismatch          no common prefix with db

.PARAMETER FileName
    Filename only (not full path).

.PARAMETER Database
    Database name.

.OUTPUTS
    pscustomobject with properties: Match (bool), Reason (string),
    FileName, Database, Stem.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$FileName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Database
    )

    $out = [pscustomobject]@{
        Match    = $false
        Reason   = 'stem-mismatch'
        FileName = $FileName
        Database = $Database
        Stem     = $null
    }

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $out.Reason = 'empty-filename'
        return $out
    }
    if ([string]::IsNullOrWhiteSpace($Database)) {
        $out.Reason = 'empty-database'
        return $out
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $out.Stem = $stem
    if ([string]::IsNullOrEmpty($stem)) {
        $out.Reason = 'no-stem'
        return $out
    }

    $db = $Database.Trim()

    if ([string]::Equals($stem, $db, [StringComparison]::OrdinalIgnoreCase)) {
        $out.Match = $true
        $out.Reason = 'exact-stem'
        return $out
    }

    if ($stem.Length -lt $db.Length) {
        $out.Reason = 'stem-shorter-than-db'
        return $out
    }
    if ($stem.Length -eq $db.Length) {
        # Same length but exact-stem did not match, so the stems simply
        # differ. Route through stem-mismatch rather than inventing a new
        # reason code for this narrow case.
        $out.Reason = 'stem-mismatch'
        return $out
    }

    $prefix = $stem.Substring(0, $db.Length)
    if (-not [string]::Equals($prefix, $db, [StringComparison]::OrdinalIgnoreCase)) {
        $out.Reason = 'stem-mismatch'
        return $out
    }

    $sep = $stem[$db.Length]
    switch ($sep) {
        '_' { $out.Match = $true; $out.Reason = 'prefix-underscore'; return $out }
        '-' { $out.Match = $true; $out.Reason = 'prefix-dash';       return $out }
        '.' { $out.Match = $true; $out.Reason = 'prefix-dot';        return $out }
        ' ' {
            $rest = $stem.Substring($db.Length + 1)
            if ($rest -match '^\d{8}\s+\d{4}$') {
                $out.Match = $true
                $out.Reason = 'stamped'
            } else {
                $out.Reason = 'stamped-bad-format'
            }
            return $out
        }
        default {
            $out.Reason = 'prefix-bleed'
            return $out
        }
    }
}

function Get-SqlCpyRestoreClosestCandidate {
<#
.SYNOPSIS
    Returns a heuristic "closest" candidate filename for diagnostic logging
    when no file matched a requested database name.

.DESCRIPTION
    Purely informational: scans a candidate list for the entry whose stem
    shares the longest case-insensitive common prefix with the requested
    database name, or whose stem contains the database name as a
    substring. Breaks ties by filename length (shorter first) for
    deterministic output. Never influences the real matcher - the output
    is written to a WARN line so the user can see a probable alias
    candidate (e.g. "timesheet" -> "mTimesheet 20260420 0633.bak").

.PARAMETER Database
    Requested database name.

.PARAMETER CandidateFiles
    Enumeration of objects with a Name property.

.OUTPUTS
    The best-guess candidate object, or $null when none is plausible.
#>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Database,
        [object[]]$CandidateFiles
    )

    if (-not $CandidateFiles -or $CandidateFiles.Count -eq 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($Database)) { return $null }
    $dbL = $Database.Trim().ToLowerInvariant()
    if ($dbL.Length -lt 2) { return $null }

    $scored = foreach ($f in $CandidateFiles) {
        if (-not $f -or -not $f.Name) { continue }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension([string]$f.Name)
        if ([string]::IsNullOrEmpty($stem)) { continue }
        $stemL = $stem.ToLowerInvariant()

        $common = 0
        $max = [Math]::Min($stemL.Length, $dbL.Length)
        while ($common -lt $max -and $stemL[$common] -eq $dbL[$common]) { $common++ }

        $contains = $stemL.IndexOf($dbL, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $score = $common
        if ($contains) { $score += $dbL.Length }  # strong bonus for substring hit

        [pscustomobject]@{
            File     = $f
            Score    = $score
            NameLen  = $stem.Length
        }
    }

    $best = $scored |
        Where-Object { $_.Score -gt 0 } |
        Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'NameLen'; Descending = $false } |
        Select-Object -First 1

    if ($best) { return $best.File }
    return $null
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
      3. If DryRun is set, log what WOULD be copied and restored (database,
         source file, staging destination if enabled, timestamp) and move on.
      4. If DatabaseRestoreUseLocalStaging is $true (default), copy the
         selected backup to DatabaseRestoreLocalStagingPath using the current
         PowerShell process identity. Then hand the LOCAL path to
         Restore-DbaDatabase. This is the SQL-service-account workaround: on
         a hidden UNC share like "\\host\foo-backup$\FULL" the interactive
         shell may have Kerberos access while the SQL Server service account
         does not, producing "File ... does not exist or access denied. The
         SQL Server service account may not have access to the source
         directory" from Read-DbaBackupHeader. Staging the file under the
         server's default Backup folder sidesteps that without ACL changes.
         A copy failure is non-fatal for the batch: the database is logged
         and skipped, and the loop continues with the next.
      5. Otherwise (staging disabled OR staging preflight failed) invoke
         Restore-DbaDatabase directly against the UNC path.
      6. Call Restore-DbaDatabase with WithReplace / NoRecovery /
         DestinationDataDirectory / DestinationLogDirectory /
         StatementTimeout as configured.
      7. If DatabaseRestoreCleanupLocalStaging is $true and the restore
         succeeded, delete the staged copy. Failed restores never trigger
         cleanup so the file is available for retry.

    Diagnostic logging:
      * The resolved UNC backup path is logged verbatim so the reader can
        see the exact string that will be handed to Test-Path.
      * Whether Test-Path succeeded or failed against the configured path
        is logged explicitly, because a $ character in a hidden share name
        is a common source of confusion (it is fine in the path string;
        share permissions / account context are the usual culprits).
      * The total count of files enumerated in the folder and a capped
        preview of candidate filenames (with extension, timestamp and
        length) is logged so the user can see what the tool actually saw.
        The preview cap is controlled by
        DatabaseRestoreLogCandidateLimit (default 50).
      * For each requested database, every candidate's match decision is
        logged with a short reason code ("exact-stem", "prefix-bleed",
        "stamped", "stamped-bad-format", "stem-mismatch",
        "ext-excluded", "pattern-excluded"). When the request produced no
        match, the closest plausible candidate is surfaced as a hint so
        the user can see whether an alias is needed (e.g. "timesheet" ->
        "mTimesheet 20260420 0633.bak") without loosening the matcher.
      * Strict matching is NOT relaxed. To accept a logical name that does
        not match the on-share base name, configure
        DatabaseRestoreNameAliases in the psd1 config (e.g.
        @{ timesheet = 'mTimesheet' }). No alias is applied unless
        explicitly configured.

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

    # Echo the exact path string so nothing is hidden: if any PowerShell
    # escaping or quoting mangled the "$" in the hidden share name, the
    # value logged here will differ from the user's expectation and make
    # the problem visible immediately.
    Write-SqlCpyInfo ("Backup path (raw): [{0}]" -f $rc.BackupPath)
    Write-SqlCpyInfo ("Backup path length: {0} chars" -f $rc.BackupPath.Length)
    Write-SqlCpyInfo ("Accepted extensions: {0}" -f ($rc.FileExtensions -join ', '))
    if ($rc.FilePattern) {
        Write-SqlCpyInfo ("File pattern filter: {0}" -f $rc.FilePattern)
    } else {
        Write-SqlCpyInfo "File pattern filter: <none>"
    }
    if ($rc.NameAliases -and $rc.NameAliases.Count -gt 0) {
        $aliasPairs = foreach ($k in @($rc.NameAliases.Keys)) {
            "{0} -> {1}" -f $k, $rc.NameAliases[$k]
        }
        Write-SqlCpyInfo ("Name aliases configured: {0}" -f ($aliasPairs -join '; '))
    } else {
        Write-SqlCpyInfo "Name aliases configured: <none>"
    }

    # Local-staging preflight. Copy-then-restore exists because the SQL Server
    # service account reads the RESTORE source, not the interactive PowerShell
    # user; a hidden UNC share (e.g. "\\host\foo-backup$\FULL") may be
    # reachable via Kerberos from the shell but invisible to the service
    # account. Staging to a local folder under the server's default Backup
    # directory sidesteps that mismatch without reconfiguring ACLs.
    $stagingReady = $false
    if ($rc.UseLocalStaging) {
        Write-SqlCpyInfo ("Local staging: ENABLED (copy-then-restore)")
        Write-SqlCpyInfo ("Local staging path (raw): [{0}]" -f $rc.LocalStagingPath)
        Write-SqlCpyInfo ("Local staging overwrite existing: {0}; cleanup after restore: {1}" -f $rc.OverwriteStagedFile, $rc.CleanupLocalStaging)
        Write-SqlCpyInfo ("Local staging rationale: SQL Server service account reads the RESTORE source path, not the current PowerShell user. The staging folder should therefore be a local path the SQL Server service account can read (the server's default Backup directory is a safe pick).")
        if ([string]::IsNullOrWhiteSpace($rc.LocalStagingPath)) {
            Write-SqlCpyWarning ("Local staging enabled but DatabaseRestoreLocalStagingPath is empty; disabling staging for this run and falling back to direct UNC restore.")
            $rc.UseLocalStaging = $false
        } elseif (Test-Path -LiteralPath $rc.LocalStagingPath) {
            Write-SqlCpyInfo ("Local staging Test-Path: OK")
            $stagingReady = $true
        } else {
            Write-SqlCpyWarning ("Local staging Test-Path: MISSING for [{0}]; attempting to create (may require admin for Program Files paths)." -f $rc.LocalStagingPath)
            if ($DryRun) {
                Write-SqlCpyInfo ("DRYRUN would create staging directory [{0}]" -f $rc.LocalStagingPath)
                $stagingReady = $true
            } else {
                try {
                    New-Item -ItemType Directory -Path $rc.LocalStagingPath -Force -ErrorAction Stop | Out-Null
                    Write-SqlCpyInfo ("Local staging directory created: [{0}]" -f $rc.LocalStagingPath)
                    $stagingReady = $true
                } catch {
                    Write-SqlCpyError ("Failed to create local staging directory [{0}]: {1}. Staging disabled for this run; restore will use the UNC path directly and may fail under the SQL Server service account." -f $rc.LocalStagingPath, $_.Exception.Message)
                    $rc.UseLocalStaging = $false
                }
            }
        }
    } else {
        Write-SqlCpyInfo ("Local staging: DISABLED (restore will use the UNC path directly; ensure the SQL Server service account can read it)")
    }

    $pathReachable = Test-Path -LiteralPath $rc.BackupPath
    if ($pathReachable) {
        Write-SqlCpyInfo ("Backup path Test-Path: OK")
    } else {
        Write-SqlCpyWarning ("Backup path Test-Path: FAILED against [{0}]. Individual database lookups will still be attempted." -f $rc.BackupPath)
        Write-SqlCpyWarning ("Hint: the `$ character in hidden share names is valid in the path string. If Test-Path fails, check (a) the PowerShell host account has read access to the hidden share, (b) the server name resolves from this host, (c) the share '-backup`$' exists and is not disabled. Try from the same shell: Test-Path -LiteralPath '{0}' and Get-ChildItem -LiteralPath '{0}' | Select -First 5" -f $rc.BackupPath)
    }

    # Enumerate the folder once up-front so we can log what we found there
    # regardless of per-database matching, and so every database uses the
    # same snapshot of the filesystem (cheap correctness win, and makes
    # the diagnostic output deterministic across the loop).
    $allFiles = @()
    if ($pathReachable) {
        try {
            $allFiles = @(Get-ChildItem -Path $rc.BackupPath -File -ErrorAction Stop)
        } catch {
            Write-SqlCpyWarning ("Get-ChildItem on [{0}] failed: {1}" -f $rc.BackupPath, $_.Exception.Message)
            $allFiles = @()
        }
    }

    Write-SqlCpyInfo ("Folder enumeration: {0} file(s) visible in backup path" -f $allFiles.Count)

    if ($allFiles.Count -eq 0 -and $pathReachable) {
        Write-SqlCpyWarning ("Backup path [{0}] is reachable but contains no files. Check whether the scheduled backup job is writing to the expected share." -f $rc.BackupPath)
    }

    if ($allFiles.Count -gt 0) {
        $limit = [int]$rc.LogCandidateLimit
        if ($limit -lt 0) { $limit = 0 }
        $shown = if ($limit -eq 0) { $allFiles.Count } else { [Math]::Min($limit, $allFiles.Count) }
        Write-SqlCpyInfo ("Folder contents (showing {0} of {1}; cap via DatabaseRestoreLogCandidateLimit):" -f $shown, $allFiles.Count)
        for ($i = 0; $i -lt $shown; $i++) {
            $f = $allFiles[$i]
            $ext = [System.IO.Path]::GetExtension($f.Name)
            $lwt = ''
            $len = ''
            try { if ($f.LastWriteTime) { $lwt = ([datetime]$f.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss') } } catch { }
            try { if ($f.Length)        { $len = [string]$f.Length } } catch { }
            Write-SqlCpyInfo ("  [{0,3}] {1}  (ext={2}, LastWriteTime={3}, Length={4})" -f ($i + 1), $f.Name, $ext, $lwt, $len)
        }
        if ($allFiles.Count -gt $shown) {
            Write-SqlCpyInfo ("  ... {0} more file(s) not shown (raise DatabaseRestoreLogCandidateLimit to see them)" -f ($allFiles.Count - $shown))
        }
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

    # Build the extension lookup once so per-file diagnostics and the main
    # matcher agree on which extensions count.
    $extSet = @{}
    foreach ($e in $rc.FileExtensions) {
        if (-not $e) { continue }
        $s = [string]$e
        if (-not $s.StartsWith('.')) { $s = '.' + $s }
        $extSet[$s.ToLowerInvariant()] = $true
    }

    foreach ($rawDb in $Databases) {
        $rawDb = [string]$rawDb
        if ([string]::IsNullOrWhiteSpace($rawDb)) { continue }
        $requested = $rawDb.Trim()
        $resolved  = Resolve-SqlCpyRestoreDatabaseAlias -Database $requested -Aliases $rc.NameAliases

        if (-not [string]::Equals($requested, $resolved, [StringComparison]::OrdinalIgnoreCase)) {
            Write-SqlCpyInfo ("Match target for '{0}': requested name is aliased to '{1}' via DatabaseRestoreNameAliases; files will be matched against '{1}'." -f $requested, $resolved)
        } else {
            Write-SqlCpyInfo ("Match target for '{0}': no alias configured; files will be matched strictly against '{0}'." -f $requested)
        }

        # Per-candidate diagnostic log. Walks the same snapshot used by
        # Find-SqlCpyDatabaseBackupFile and attributes each discard to a
        # short reason, so "why was this skipped?" is answerable from the
        # log alone.
        $matchedFiles = @()
        if ($allFiles.Count -gt 0) {
            foreach ($f in $allFiles) {
                if (-not $f -or -not $f.Name) { continue }
                $ext = [System.IO.Path]::GetExtension($f.Name)
                if (-not $ext -or -not $extSet.ContainsKey($ext.ToLowerInvariant())) {
                    Write-SqlCpyInfo ("  discard '{0}': ext-excluded ({1} not in accepted extensions)" -f $f.Name, $ext)
                    continue
                }
                if ($rc.FilePattern -and ($f.Name -notlike $rc.FilePattern)) {
                    Write-SqlCpyInfo ("  discard '{0}': pattern-excluded (does not match {1})" -f $f.Name, $rc.FilePattern)
                    continue
                }
                $reason = Get-SqlCpyRestoreMatchReason -FileName $f.Name -Database $resolved
                if ($reason.Match) {
                    $stamp = Get-SqlCpyRestoreBackupTimestamp -FileName $f.Name -Database $resolved
                    $stampText = if ($stamp) { $stamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '<no stamp>' }
                    Write-SqlCpyInfo ("  candidate '{0}': MATCH ({1}), stamped={2}" -f $f.Name, $reason.Reason, $stampText)
                    $matchedFiles += $f
                } else {
                    Write-SqlCpyInfo ("  discard '{0}': {1}" -f $f.Name, $reason.Reason)
                }
            }
        }

        # Delegate the real selection (with stamped-first sort) to
        # Find-SqlCpyDatabaseBackupFile so diagnostics stay consistent
        # with the production matcher. Passing -CandidateFiles reuses our
        # snapshot and avoids re-enumerating the share.
        $candidates = if ($allFiles.Count -gt 0) {
            Find-SqlCpyDatabaseBackupFile `
                -BackupPath     $rc.BackupPath `
                -Database       $resolved `
                -FileExtensions $rc.FileExtensions `
                -FilePattern    $rc.FilePattern `
                -CandidateFiles $allFiles
        } else {
            Find-SqlCpyDatabaseBackupFile `
                -BackupPath     $rc.BackupPath `
                -Database       $resolved `
                -FileExtensions $rc.FileExtensions `
                -FilePattern    $rc.FilePattern
        }

        if (-not $candidates -or $candidates.Count -eq 0) {
            if ($allFiles.Count -eq 0) {
                Write-SqlCpyWarning ("backup not found for database {0} in path {1}; skipping" -f $requested, $rc.BackupPath)
                if (-not $pathReachable) {
                    Write-SqlCpyWarning ("Root cause likely not the matcher: backup path is unreachable. Verify UNC accessibility from this PowerShell host's account and that the hidden share ('-backup`$') grants read to that account. The '`$' in the share name is fine in the path string.")
                } else {
                    Write-SqlCpyWarning ("Path is reachable but empty or unreadable for the current account. Hidden shares with '`$' require an explicit permission grant; single-quote the path in config to avoid shell interpolation.")
                }
            } else {
                $closest = Get-SqlCpyRestoreClosestCandidate -Database $resolved -CandidateFiles $allFiles
                if ($closest) {
                    Write-SqlCpyWarning ("No exact/stamped match for '{0}' in {1}. Closest candidate appears to be '{2}'. Matching is strict - configure DatabaseRestoreNameAliases (e.g. @{{ {0} = '{3}' }}) or request the on-share base name directly." -f $requested, $rc.BackupPath, $closest.Name, [System.IO.Path]::GetFileNameWithoutExtension($closest.Name))
                } else {
                    Write-SqlCpyWarning ("backup not found for database {0} in path {1}; skipping (folder had {2} file(s) but none matched; no plausible close candidate)" -f $requested, $rc.BackupPath, $allFiles.Count)
                }
            }
            continue
        }

        $chosen = $candidates[0]
        $chosenPath = if ($chosen.PSObject.Properties['FullName'] -and $chosen.FullName) { $chosen.FullName } else { Join-Path -Path $rc.BackupPath -ChildPath $chosen.Name }
        $chosenStamp = $null
        if ($chosen.PSObject.Properties['LastWriteTime']) { $chosenStamp = $chosen.LastWriteTime }

        if ($candidates.Count -gt 1) {
            Write-SqlCpyInfo ("{0}: {1} candidate backup(s) found; selected newest stamped backup: {2}" -f $requested, $candidates.Count, $chosen.Name)
        } else {
            Write-SqlCpyInfo ("{0}: 1 candidate backup found; selected: {1}" -f $requested, $chosen.Name)
        }

        # Decide whether we will restore from the UNC path directly or from a
        # locally-staged copy. Staging is the SQL-service-account workaround
        # documented at the top of the function.
        $useStagingForThisDb = $rc.UseLocalStaging -and $stagingReady
        $restorePath         = $chosenPath
        $stagedCopyMade      = $false
        $stagingPlan         = $null

        if ($rc.UseLocalStaging -and -not $stagingReady -and -not $DryRun) {
            Write-SqlCpyWarning ("{0}: local staging was requested but is not ready (see earlier warnings); falling back to direct UNC restore for this database. The restore may fail if the SQL Server service account cannot read [{1}]." -f $requested, $chosenPath)
        }

        if ($useStagingForThisDb) {
            $chosenName = $null
            if ($chosen.PSObject.Properties['Name']) { $chosenName = [string]$chosen.Name }
            $stagingPlan = Get-SqlCpyRestoreStagingPlan -SourceFullName $chosenPath -SourceFileName $chosenName -StagingDirectory $rc.LocalStagingPath

            if (-not $stagingPlan.IsValid) {
                Write-SqlCpyWarning ("{0}: could not compose staging destination (reason={1}); falling back to direct UNC restore." -f $requested, $stagingPlan.Reason)
                $useStagingForThisDb = $false
            } else {
                $sizeText = '<unknown>'
                if ($chosen.PSObject.Properties['Length'] -and $chosen.Length) {
                    try { $sizeText = '{0:N0} bytes' -f [long]$chosen.Length } catch { $sizeText = [string]$chosen.Length }
                }
                Write-SqlCpyInfo ("{0}: staging plan: copy '{1}' ({2}) -> '{3}' (overwrite={4})" -f $requested, $stagingPlan.SourcePath, $sizeText, $stagingPlan.Destination, $rc.OverwriteStagedFile)
                $restorePath = $stagingPlan.Destination
            }
        }

        if ($DryRun) {
            $stampText = if ($chosenStamp) { $chosenStamp.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown timestamp' }
            if ($useStagingForThisDb -and $stagingPlan -and $stagingPlan.IsValid) {
                Write-SqlCpyInfo ("DRYRUN would copy {0} -> {1} (no bytes moved in dry-run)" -f $stagingPlan.SourcePath, $stagingPlan.Destination)
                Write-SqlCpyInfo ("DRYRUN would restore {0} from {1} as {0} ({2})" -f $requested, $stagingPlan.Destination, $stampText)
                if ($rc.CleanupLocalStaging) {
                    Write-SqlCpyInfo ("DRYRUN would delete staged file {0} after successful restore (cleanup enabled)" -f $stagingPlan.Destination)
                } else {
                    Write-SqlCpyInfo ("DRYRUN would retain staged file {0} after restore (cleanup disabled)" -f $stagingPlan.Destination)
                }
            } else {
                Write-SqlCpyInfo ("DRYRUN would restore {0} from {1} as {0} ({2})" -f $requested, $chosenPath, $stampText)
            }
            continue
        }

        # Real copy (only when staging is active and we are past the DryRun gate).
        if ($useStagingForThisDb -and $stagingPlan -and $stagingPlan.IsValid) {
            $dstExists = Test-Path -LiteralPath $stagingPlan.Destination
            if ($dstExists -and -not $rc.OverwriteStagedFile) {
                Write-SqlCpyWarning ("{0}: staged file already exists at [{1}] and DatabaseRestoreOverwriteStagedFile is `$false; skipping copy and skipping restore to avoid using a stale copy." -f $requested, $stagingPlan.Destination)
                continue
            }
            try {
                Write-SqlCpyInfo ("{0}: copying backup to staging as current PowerShell user (not the SQL Server service account)." -f $requested)
                Copy-Item -LiteralPath $stagingPlan.SourcePath -Destination $stagingPlan.Destination -Force:([bool]$rc.OverwriteStagedFile) -ErrorAction Stop
                $stagedCopyMade = $true
                $copiedSize = $null
                try { $copiedSize = (Get-Item -LiteralPath $stagingPlan.Destination -ErrorAction Stop).Length } catch { $copiedSize = $null }
                if ($null -ne $copiedSize) {
                    Write-SqlCpyInfo ("{0}: staging copy complete: {1} ({2:N0} bytes)" -f $requested, $stagingPlan.Destination, [long]$copiedSize)
                } else {
                    Write-SqlCpyInfo ("{0}: staging copy complete: {1}" -f $requested, $stagingPlan.Destination)
                }
            } catch {
                Write-SqlCpyError ("{0}: staging copy FAILED ({1} -> {2}): {3}. Skipping restore for this database and continuing with the next." -f $requested, $stagingPlan.SourcePath, $stagingPlan.Destination, $_.Exception.Message)
                continue
            }
        }

        $restoreSplat = @{
            SqlInstance    = $tgtConn
            Path           = $restorePath
            DatabaseName   = $requested
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

        # Best-effort integrity / metadata check against whatever path is about
        # to feed the restore. When staging is active this hits the local copy,
        # which avoids the "does not exist or access denied" warning the SQL
        # service account emits on hidden UNC shares.
        if (Get-Command -Name Read-DbaBackupHeader -ErrorAction SilentlyContinue) {
            try {
                $hdr = Read-DbaBackupHeader -SqlInstance $tgtConn -Path $restorePath -ErrorAction Stop | Select-Object -First 1
                if ($hdr -and $hdr.DatabaseName -and -not [string]::Equals([string]$hdr.DatabaseName, $requested, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-SqlCpyWarning ("{0}: backup header reports DatabaseName='{1}' (different from requested). Proceeding with restore as '{0}' because -DatabaseName overrides the backup's embedded name." -f $requested, $hdr.DatabaseName)
                }
            } catch {
                Write-SqlCpyWarning ("{0}: Read-DbaBackupHeader failed ({1}); continuing." -f $requested, $_.Exception.Message)
            }
        }

        Write-SqlCpyInfo ("Restoring {0} <- {1}" -f $requested, $restorePath)
        $restoreOk = $false
        try {
            Restore-DbaDatabase @restoreSplat | Out-Null
            Write-SqlCpyInfo ("Restore complete: {0}" -f $requested)
            $restoreOk = $true
        } catch {
            Write-SqlCpyError ("Restore failed for {0}: {1}" -f $requested, $_.Exception.Message)
            # Do not throw - continue with remaining databases, matching the
            # "missing backup is not fatal" spirit of this action.
        }

        # Cleanup: only delete the staged file when cleanup is enabled AND the
        # restore actually succeeded. Keeping the file after a failed restore
        # is deliberate so the user can inspect / retry without re-copying.
        if ($stagedCopyMade -and $rc.CleanupLocalStaging) {
            if ($restoreOk) {
                try {
                    Remove-Item -LiteralPath $stagingPlan.Destination -Force -ErrorAction Stop
                    Write-SqlCpyInfo ("{0}: staged file deleted after successful restore: {1}" -f $requested, $stagingPlan.Destination)
                } catch {
                    Write-SqlCpyWarning ("{0}: staged file cleanup failed for [{1}]: {2}. Leaving file in place; continuing." -f $requested, $stagingPlan.Destination, $_.Exception.Message)
                }
            } else {
                Write-SqlCpyWarning ("{0}: restore failed; leaving staged file [{1}] in place for inspection/retry regardless of DatabaseRestoreCleanupLocalStaging." -f $requested, $stagingPlan.Destination)
            }
        }
    }
}
