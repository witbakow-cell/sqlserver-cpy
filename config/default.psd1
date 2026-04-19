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
