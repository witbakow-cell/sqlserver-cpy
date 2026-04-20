@{
    # Default configuration for sqlserver-cpy.
    # Copy this file to config/local.psd1 for machine-specific overrides;
    # local.psd1 is gitignored.

    SourceServer = 'chbbbid2'
    TargetServer = 'localhost'

    # When $true, destructive operations on the target are skipped and only logged.
    DryRun = $true

    # Optional credential names (consumed upstream by the TUI; not stored here).
    SourceCredential = $null
    TargetCredential = $null

    # Connection security.
    #
    # Newer SQL Server client stacks (Microsoft.Data.SqlClient >= 4.0, used by recent
    # dbatools releases) default to Encrypt=Mandatory. Against a server that presents a
    # self-signed or internally issued certificate this raises:
    #
    #   "The certificate chain was issued by an authority that is not trusted"
    #
    # and the connection fails (or, in Get-DbaSpConfigure, emits a WARNING and returns
    # no rows). See DECISIONS_AND_CAVEATS.txt for the full rationale.
    #
    # Defaults below are picked for the typical scaffold / admin-migration use case
    # (local, on-prem, Windows auth, internal CA or self-signed certs):
    #   EncryptConnection      = $true   - still request TLS
    #   TrustServerCertificate = $true   - do NOT validate the chain
    #
    # SECURITY TRADEOFF:
    #   TrustServerCertificate = $true disables hostname / CA chain validation and is
    #   vulnerable to an active MITM on the SQL TDS traffic. This is acceptable for
    #   local / lab / admin bootstrap flows - which is what this tool is for - but it
    #   is NOT acceptable against production over untrusted networks. For that case,
    #   flip TrustServerCertificate to $false in config/local.psd1 and install a
    #   properly chained server certificate on the SQL Server.
    EncryptConnection      = $true
    TrustServerCertificate = $true

    # Connection timeout (seconds) passed through to dbatools / SMO. Practical default
    # for local/LAN migrations; raise for higher-latency links.
    ConnectionTimeoutSeconds = 15

    # Per-area selections. Set to $false to skip an area in the TUI default run.
    Areas = @{
        ServerConfiguration = $true
        Logins              = $true
        AgentJobs           = $true
        SsisCatalog         = $true
        SsrsCatalog         = $true
        SchemaOnlyDatabases = $true
        DatabaseRestore     = $true
    }

    # -- Restore-from-backup action (separate from the schema-only copy) -----
    #
    # The restore-based database move is an ALTERNATIVE to the schema-only
    # scripting task for cases where the latter has proven unreliable. It
    # restores FULL databases (including DATA) on the target SQL Server from
    # backup files that another process has already dropped onto a shared
    # UNC path. sqlserver-cpy itself does NOT create backups.
    #
    # UNC path below is the default share the user specified. In PowerShell
    # string form backslashes must be doubled; the resolved UNC path is
    # \\chbbopa2\CHBBBID2-backup$\FULL .
    DatabaseRestoreBackupPath = '\\chbbopa2\CHBBBID2-backup$\FULL'

    # Databases to restore by default. Empty array = none; the TUI will prompt.
    DatabaseRestoreList = @()

    # Backup file matching.
    #   DatabaseRestoreFileExtensions - accepted backup file extensions (case
    #                                   insensitive, leading dot optional).
    #                                   FULL backup share: default to .bak and
    #                                   .backup; transaction logs are NOT
    #                                   picked up because there is no log-chain
    #                                   replay in this action.
    #   DatabaseRestoreFilePattern    - optional glob applied to the filename
    #                                   (not the full path) in addition to the
    #                                   extension filter. $null = no extra
    #                                   filter. Example: '*_FULL_*'.
    DatabaseRestoreFileExtensions = @('.bak', '.backup')
    DatabaseRestoreFilePattern    = $null

    # Restore behaviour.
    #   DatabaseRestoreWithReplace    - pass -WithReplace to Restore-DbaDatabase
    #                                   so an existing database of the same name
    #                                   on the target is overwritten. Documented
    #                                   and INTENTIONAL for a move operation.
    #   DatabaseRestoreNoRecovery     - leave the database in RESTORING state
    #                                   after the restore (for adding further
    #                                   log backups). Default $false = database
    #                                   is brought online.
    #   DatabaseRestoreTimeoutSeconds - per-database restore timeout; passed as
    #                                   StatementTimeout to dbatools where the
    #                                   cmdlet exposes it. 0 = no timeout.
    DatabaseRestoreWithReplace    = $true
    DatabaseRestoreNoRecovery     = $false
    DatabaseRestoreTimeoutSeconds = 0

    # File relocation on the target. $null = let Restore-DbaDatabase pick
    # defaults (target server's default data/log paths). Override only if the
    # target's default paths are unsuitable.
    #   DatabaseRestoreDataFileDirectory - destination folder for .mdf/.ndf
    #   DatabaseRestoreLogFileDirectory  - destination folder for .ldf
    DatabaseRestoreDataFileDirectory = $null
    DatabaseRestoreLogFileDirectory  = $null

    # Diagnostics: cap the number of per-file preview lines that the restore
    # action writes to the log when it enumerates the backup folder up-front.
    # The full file count is always logged; this only bounds the preview.
    # Set to 0 to show every file (can be noisy on large shares). Default 50
    # is enough to diagnose "my database name did not match" cases like
    # `mTimesheet 20260420 0633.bak` vs a request for `timesheet`.
    DatabaseRestoreLogCandidateLimit = 50

    # Optional aliases from the user-facing database name to the base name
    # the backup file on the share actually uses. The restore matcher is
    # strict on purpose (a request for "timesheet" will NOT match
    # "mTimesheet 20260420 0633.bak") so that "mydb" does not leak into
    # "mydb2" etc. If your share uses a prefix convention like the example,
    # declare the alias here rather than loosening the matcher:
    #
    #   DatabaseRestoreNameAliases = @{
    #       timesheet  = 'mTimesheet'
    #       purchasing = 'mPurchasing'
    #   }
    #
    # Keys are compared case-insensitively. Values should be the exact stem
    # prefix used in the backup filenames on the share. An empty hashtable
    # (the default) disables aliasing entirely.
    DatabaseRestoreNameAliases = @{}

    # -- Local staging (copy-then-restore) -----------------------------------
    #
    # Restore-DbaDatabase / Read-DbaBackupHeader run the RESTORE on the target
    # SQL Server, which means the SQL Server SERVICE ACCOUNT reads the backup
    # path (not the current PowerShell user). A hidden UNC share like
    # \\chbbopa2\CHBBBID2-backup$\FULL may be reachable from the interactive
    # PowerShell session (admin Kerberos) but NOT from the SQL Server service
    # account, producing:
    #
    #   [Read-DbaBackupHeader] File \\chbbopa2\CHBBBID2-backup$\FULL\<file>.bak
    #   does not exist or access denied. The SQL Server service account may
    #   not have access to the source directory.
    #
    # Workaround: copy the selected backup from the UNC share to a LOCAL path
    # on the target server first (performed by sqlserver-cpy as the current
    # PowerShell user, which already has UNC access), then point the restore
    # at the local copy. SQL Server's own service account reads the local
    # file, which is normally inside its own default Backup folder.
    #
    #   DatabaseRestoreUseLocalStaging      - $true enables copy-then-restore.
    #                                         Default $true because the user's
    #                                         restore target is localhost and
    #                                         the SQL service account is the
    #                                         well-known culprit here. Set to
    #                                         $false to restore directly from
    #                                         the UNC path (the original
    #                                         behaviour).
    #   DatabaseRestoreLocalStagingPath     - destination folder for the
    #                                         copied backup. Default is
    #                                         SQL Server 2022's default Backup
    #                                         directory for MSSQLSERVER, which
    #                                         the service account can always
    #                                         read. Override if your target
    #                                         uses a different instance
    #                                         version or name.
    #   DatabaseRestoreOverwriteStagedFile  - $true overwrites an existing
    #                                         file at the staged path; $false
    #                                         skips the copy (and restore) and
    #                                         logs a WARN. Default $true: a
    #                                         stale copy from a previous run
    #                                         is not helpful.
    #   DatabaseRestoreCleanupLocalStaging  - $false leaves the staged file in
    #                                         place after a successful
    #                                         restore (safer for review and
    #                                         retry); $true deletes it. Copy
    #                                         failures and failed restores
    #                                         never trigger cleanup.
    DatabaseRestoreUseLocalStaging     = $true
    DatabaseRestoreLocalStagingPath    = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup'
    DatabaseRestoreOverwriteStagedFile = $true
    DatabaseRestoreCleanupLocalStaging = $false

    # Databases to copy as schema-only (no data). Empty array = none selected by default.
    SchemaOnlyDatabaseList = @()

    # Schema-only copy: object categories to include. $null / empty = use the
    # defaults from Get-SqlCpySchemaOnlyObjectTypeDefaults (full object model
    # excluding data and security). Override in local.psd1 only to narrow the
    # scope - the defaults are designed to produce a faithful empty clone.
    SchemaOnlyIncludeObjectTypes = $null

    # Schema-only copy: security objects are ALWAYS excluded regardless of
    # this flag, per the user's explicit "ignore security" requirement. The
    # flag is kept for documentation visibility; setting it to $false does NOT
    # re-enable scripting of users/roles/permissions.
    SchemaOnlyExcludeSecurity = $true

    # Schema-only copy: mute the standalone 14_FullTextCatalogs phase.
    # Default $false = the phase is skipped silently and no '14_FullTextCatalogs'
    # step appears in the normal run log. Full-text INDEXES are still scripted
    # inline with their parent tables via the FullTextIndexes scripting option,
    # so this flag only affects the per-catalog definition pass.
    # Set to $true to re-enable the phase (e.g. when the target needs standalone
    # CREATE FULLTEXT CATALOG statements and the Full-Text Search feature is
    # installed). See DECISIONS_AND_CAVEATS.txt for the rationale.
    SchemaOnlyIncludeFullTextCatalogs = $false

    # Schema-only copy: how the Tables phase emits scripts.
    #   'InProcess'  - (default) iterate tables one at a time in the main
    #                  runspace, reusing the already-connected SMO database.
    #                  Logs before/after each table with [schema].[table]
    #                  object_id=... and elapsed seconds. No hard per-table
    #                  timeout (a hung single table would hang the phase).
    #                  This mode has much lower overhead than 'Isolated' and
    #                  is the right default for healthy sources.
    #   'FastPerTable' - alias for 'InProcess'.
    #   'PerTable'   - alias for 'InProcess' (kept for backward compatibility
    #                  with earlier configs that used the old name). The
    #                  previous meaning of 'PerTable' was isolated/timeout
    #                  per table; that behaviour is now 'Isolated'.
    #   'Isolated'   - opt-in: iterate tables one at a time, run each
    #                  $table.Script() in a child PowerShell runspace, and
    #                  apply SchemaOnlyTableScriptTimeoutSeconds per table.
    #                  Use when a single pathological table hangs SMO (e.g.
    #                  the sys.indexes metadata query never returns). This
    #                  mode is dramatically slower (tens of seconds to a few
    #                  minutes of overhead per table for runspace setup and
    #                  SMO re-serialization) and should only be enabled when
    #                  needed.
    #   'Collection' - legacy behaviour: iterate $db.Tables in one go. Faster
    #                  in aggregate but a single pathological table can block
    #                  the whole phase with no progress output.
    SchemaOnlyTableScriptMode = 'InProcess'

    # Schema-only copy: tables to skip during the Tables phase. Entries are
    # matched case-insensitively and accept any of these forms:
    #   '[schema].[table]'   -- bracketed, e.g. '[integra].[Execution]'
    #   'schema.table'       -- plain, e.g. 'integra.Execution'
    #   'table'              -- bare name (schema defaults to dbo unless
    #                           qualified; matches any schema as a fallback)
    #   '<object_id>'        -- numeric sys.objects.object_id, e.g. 295672101
    # Example for the two known-hanging tables on dwcontrol:
    #   SchemaOnlyExcludeTables = @('[integra].[Execution]', '[integra].[Application]')
    # Skipped tables are logged and recorded in _skipped_tables.txt under the
    # per-database artifacts folder so they cannot be silently omitted.
    SchemaOnlyExcludeTables = @()

    # Schema-only copy: timeout applied per table when
    # SchemaOnlyTableScriptMode = 'Isolated'. The table script call runs in
    # an isolated PowerShell runspace; if .Script($opts) does not return
    # inside this many seconds the runspace is stopped, the table is
    # recorded in the skip report, and the phase continues. Best-effort -
    # SMO/.NET may still be blocked on native socket I/O inside the stopped
    # runspace, but the main thread is freed and the run completes.
    #
    # IMPORTANT: this setting has NO EFFECT in the default 'InProcess' mode.
    # A hard per-table timeout requires the isolated mode's child runspace.
    SchemaOnlyTableScriptTimeoutSeconds = 300

    # SSIS catalog scope. $null = all folders.
    SsisFolders = $null

    # Login copy: skip logins whose names start with any of these prefixes (case-
    # insensitive). Matching is performed on the login name with any leading server
    # or domain qualifier ("<domain>\") stripped, so "MYDOMAIN\BUILTIN\Administrators"
    # and "BUILTIN\Administrators" both match the "BUILTIN" prefix.
    #
    # Rationale:
    #   - NT AUTHORITY\* and NT SERVICE\* are machine-local principals on the target.
    #   - BUILTIN\* is a Windows local-group prefix that is reissued by the target OS.
    #   - ADIS is a site-local service-account prefix the user does not want migrated.
    # Copying any of these tends to either fail outright or produce a login that does
    # not resolve on the destination. Skip them and log clearly.
    LoginSkipPrefixes = @(
        'NT AUTHORITY'
        'NT SERVICE'
        'BUILTIN'
        'ADIS'
    )

    # SSRS (SQL Server Reporting Services) copy settings.
    #
    # Architecture: the SSRS copy action talks to the ReportServer web service
    # (ReportService2010 SOAP endpoint) on both source and target. It does NOT
    # copy the ReportServer / ReportServerTempDB catalog databases directly.
    # Doing that over SOAP keeps the copy portable across SSRS versions and
    # avoids dragging along encrypted columns keyed to the source machine.
    #
    # Defaults match the typical scaffold layout: source is the existing report
    # server on 'chbbbid2', target is a local SSRS instance on the migration
    # workstation. Override via config/local.psd1 or the TUI.
    SourceSsrsUri = 'http://chbbbid2/ReportServer'
    TargetSsrsUri = 'http://localhost/ReportServer'

    # Optional: path scope for the copy. $null = copy everything under '/'.
    # Example: '/Finance' copies only the Finance folder subtree.
    SsrsRootPath = '/'

    # Fine-grained toggles. The explicit user requirement is NOT to skip any
    # class of SSRS asset by default, so all of these default to $true. Flip
    # individual flags only if a given asset type is known to be unsupported
    # in your target environment (e.g. subscriptions on a fresh install with
    # no SMTP configured).
    CopySsrsFolders       = $true
    CopySsrsReports       = $true
    CopySsrsDatasets      = $true
    CopySsrsDataSources   = $true
    CopySsrsResources     = $true
    CopySsrsSecurity      = $true   # item-level policies
    CopySsrsRoles         = $true   # system + catalog role definitions
    CopySsrsSubscriptions = $true   # best-effort; may fail on data-driven subs
    CopySsrsSchedules     = $true
    CopySsrsKpis          = $true   # mobile reports / KPIs where REST is available

    # Extra server configuration items to check that sp_configure does not expose.
    # Each entry is a free-form label; the implementation maps labels to checks.
    ExtendedServerChecks = @(
        'TempDbFileLayout'
        'TraceFlags'
        'DefaultCollation'
    )
}
