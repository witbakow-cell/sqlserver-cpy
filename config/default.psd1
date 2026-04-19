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
