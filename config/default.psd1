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
    }

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
