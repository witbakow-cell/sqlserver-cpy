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
        SchemaOnlyDatabases = $true
    }

    # Databases to copy as schema-only (no data). Empty array = none selected by default.
    SchemaOnlyDatabaseList = @()

    # SSIS catalog scope. $null = all folders.
    SsisFolders = $null

    # Extra server configuration items to check that sp_configure does not expose.
    # Each entry is a free-form label; the implementation maps labels to checks.
    ExtendedServerChecks = @(
        'TempDbFileLayout'
        'TraceFlags'
        'DefaultCollation'
    )
}
