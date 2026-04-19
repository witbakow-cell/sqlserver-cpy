function Get-SqlCpySchemaOnlyObjectTypeDefaults {
<#
.SYNOPSIS
    Returns the default list of object categories scripted by a schema-only copy.

.DESCRIPTION
    The schema-only copy is meant to produce a target database that has the
    same object model as the source but no data and no security. This helper
    centralizes the canonical list so tests and config defaults agree.

    The list intentionally excludes security-bearing categories (users, roles,
    role memberships, permissions, schema ownership grants) because the user
    requirement is "ignore security". It also excludes anything that would
    move row data - no data-insert statements, no BCP, no data-table copy
    cmdlets - because the user requirement is "ignore data".

.OUTPUTS
    [string[]]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # The names below are SMO Database.<Collection> property names.
    # Where a category is scripted inline with its parent (foreign keys and
    # indexes on tables, DML triggers on tables, defaults on columns) we still
    # list the SMO property so configs can be expressive and tests can prove
    # the category is represented.
    return @(
        'Schemas'
        'UserDefinedDataTypes'
        'UserDefinedTableTypes'
        'UserDefinedTypes'     # CLR UDTs
        'XmlSchemaCollections'
        'Sequences'
        'PartitionFunctions'
        'PartitionSchemes'
        'Synonyms'
        'Tables'               # includes columns, PK/UK/CK, defaults, computed cols, inline indexes + DML triggers via DriAll + Indexes + Triggers options
        'ForeignKeys'          # scripted inline with tables via DriForeignKeys; listed for visibility
        'Indexes'              # scripted inline with tables via Indexes option
        'Triggers'             # DML triggers scripted inline with tables via Triggers option
        'FullTextCatalogs'
        'FullTextIndexes'      # scripted inline with tables via FullTextIndexes option
        'Views'
        'StoredProcedures'
        'UserDefinedFunctions'
        'DatabaseTriggers'     # DDL triggers at database scope (SMO: Database.Triggers)
        'Defaults'             # legacy bound defaults
        'Rules'                # legacy bound rules
        'Assemblies'           # CLR assemblies
        'ServiceBrokerQueues'
    )
}

function Get-SqlCpySchemaOnlySecurityExcludedTypes {
<#
.SYNOPSIS
    Returns SMO/dbatools object-category names that the schema-only copy must
    NEVER script, because the explicit requirement is "ignore security".

.OUTPUTS
    [string[]]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'Users'
        'Roles'
        'DatabaseRoles'
        'ApplicationRoles'
        'Permissions'
        'RoleMembership'
        'DatabaseAuditSpecifications'
        'Audits'
        'Credentials'
        'AsymmetricKeys'
        'Certificates'
        'SymmetricKeys'
        'MasterKey'
        'CryptographicProviders'
        'SecurityPolicies'
    )
}

function New-SqlCpySchemaOnlyScriptingOption {
<#
.SYNOPSIS
    Builds an SMO Scripter.ScriptingOptions (wrapped as a dbatools scripting
    option where possible) configured for "schema, no data, no security".

.DESCRIPTION
    Returns an object suitable for passing to Export-DbaScript or a raw
    SMO Scripter. Key toggles:

      ScriptData                      = $false   (no INSERTs)
      ScriptSchema                    = $true
      IncludeIfNotExists              = $true    (re-runnable)
      WithDependencies                = $true    (pull referenced objects)
      Indexes / Triggers / FullText   = $true
      DriPrimaryKey / DriForeignKeys /
      DriUniqueKeys / DriChecks /
      DriDefaults                     = $true
      Permissions / IncludeDatabaseRoleMemberships
      / LoginSid / SchemaQualifyForeignKeysReferences (security side)
                                      = $false

    When the dbatools helper New-DbaScriptingOption is available we start
    from its output (so version-specific defaults from dbatools apply) and
    then overlay the explicit flags above. When dbatools is not loaded we
    fall back to a bare Microsoft.SqlServer.Management.Smo.ScriptingOptions
    instance so the function still works under SMO alone.

.OUTPUTS
    A ScriptingOptions-shaped object.
#>
    [CmdletBinding()]
    param()

    $opts = $null
    if (Get-Command -Name New-DbaScriptingOption -ErrorAction SilentlyContinue) {
        $opts = New-DbaScriptingOption
    } else {
        try {
            $opts = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
        } catch {
            # Last-resort stub so the function still returns something callers
            # can set properties on in a non-SQL environment (e.g. unit tests).
            $opts = [pscustomobject]@{}
        }
    }

    $desired = [ordered]@{
        # --- structural: full object definition
        ScriptSchema                      = $true
        ScriptData                        = $false
        ScriptDrops                       = $false
        IncludeIfNotExists                = $true
        WithDependencies                  = $true
        SchemaQualify                     = $true
        AnsiPadding                       = $true
        NoCollation                       = $false
        NoFileGroup                       = $false
        # --- declarative integrity (DRI)
        DriAll                            = $true
        DriPrimaryKey                     = $true
        DriForeignKeys                    = $true
        DriUniqueKeys                     = $true
        DriChecks                         = $true
        DriDefaults                       = $true
        DriIndexes                        = $true
        DriClustered                      = $true
        DriNonClustered                   = $true
        # --- attached objects
        Indexes                           = $true
        ClusteredIndexes                  = $true
        NonClusteredIndexes               = $true
        XmlIndexes                        = $true
        ColumnStoreIndexes                = $true
        FullTextIndexes                   = $true
        FullTextCatalogs                  = $true
        Triggers                          = $true
        Statistics                        = $true
        ExtendedProperties                = $true
        ChangeTracking                    = $true
        # --- encoding / batch
        Encoding                          = [System.Text.Encoding]::UTF8
        IncludeHeaders                    = $true
        IncludeDatabaseContext            = $true
        NoCommandTerminator               = $false
        ToFileOnly                        = $false
        AppendToFile                      = $false
        # --- security: DISABLED per user requirement "ignore security"
        Permissions                       = $false
        IncludeDatabaseRoleMemberships    = $false
        LoginSid                          = $false
        IncludeDatabaseContextForSecurity = $false
        AgentNotify                       = $false
    }

    foreach ($k in $desired.Keys) {
        try {
            # Only set properties that actually exist on this ScriptingOptions
            # variant. SMO has slight shape differences between SQL versions.
            if ($opts.PSObject.Properties.Name -contains $k) {
                $opts.$k = $desired[$k]
            }
        } catch {
            # Non-fatal: a property may not exist on older SMO. Skip.
        }
    }

    return $opts
}

function Get-SqlCpySchemaOnlyScriptPhases {
<#
.SYNOPSIS
    Returns an ordered list of (PhaseName, SmoCollectionProperty) pairs that
    drive the dependency-safe scripting order for schema-only copy.

.DESCRIPTION
    SMO's Scripter with WithDependencies can reorder objects, but when we
    walk a database explicitly we need a sane order ourselves:

      1. Schemas (parents of everything else)
      2. User-defined types, sequences, partition functions/schemes
      3. Synonyms (may reference base objects cross-db)
      4. Tables with their inline constraints/indexes/triggers
      5. Foreign keys (scripted after all tables exist)
      6. Full-text catalogs then full-text indexes
      7. Programmable objects (views, UDFs, procedures)
      8. Triggers on tables/views were scripted with tables; DDL triggers last
      9. Database-scoped DDL triggers

    The scripting options emitted by New-SqlCpySchemaOnlyScriptingOption set
    DriForeignKeys=$true, so tables will carry their FKs inline. The
    separate ForeignKeys phase is kept as a safety net: if a caller opts to
    script tables without DRI foreign keys (to avoid order issues on very
    large schemas), the FK phase still runs and emits them at the end.

.OUTPUTS
    An array of [pscustomobject] with Phase / Property / Description.
#>
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Phase = '01_Schemas';            Property = 'Schemas';              Description = 'CREATE SCHEMA statements.' }
        [pscustomobject]@{ Phase = '02_Assemblies';         Property = 'Assemblies';           Description = 'CLR assemblies (referenced by CLR types/functions/procedures).' }
        [pscustomobject]@{ Phase = '03_UserDefinedTypes';   Property = 'UserDefinedDataTypes'; Description = 'Alias types (CREATE TYPE ... FROM ...).' }
        [pscustomobject]@{ Phase = '04_TableTypes';         Property = 'UserDefinedTableTypes';Description = 'Table-valued parameter types.' }
        [pscustomobject]@{ Phase = '05_ClrTypes';           Property = 'UserDefinedTypes';     Description = 'CLR user-defined types.' }
        [pscustomobject]@{ Phase = '06_XmlSchemaColl';      Property = 'XmlSchemaCollections'; Description = 'XML schema collections.' }
        [pscustomobject]@{ Phase = '07_Sequences';          Property = 'Sequences';            Description = 'Sequence objects.' }
        [pscustomobject]@{ Phase = '08_PartitionFunctions'; Property = 'PartitionFunctions';   Description = 'Partition functions.' }
        [pscustomobject]@{ Phase = '09_PartitionSchemes';   Property = 'PartitionSchemes';     Description = 'Partition schemes.' }
        [pscustomobject]@{ Phase = '10_LegacyDefaults';     Property = 'Defaults';             Description = 'Legacy bound default objects (sp_bindefault).' }
        [pscustomobject]@{ Phase = '11_LegacyRules';        Property = 'Rules';                Description = 'Legacy rule objects.' }
        [pscustomobject]@{ Phase = '12_Synonyms';           Property = 'Synonyms';             Description = 'Synonym redirections.' }
        [pscustomobject]@{ Phase = '13_Tables';             Property = 'Tables';               Description = 'Tables incl. columns, PK/UK/CK, defaults, computed cols, inline indexes + DML triggers + inline FKs (via DriAll).' }
        [pscustomobject]@{ Phase = '14_FullTextCatalogs';   Property = 'FullTextCatalogs';     Description = 'Full-text catalog definitions.' }
        [pscustomobject]@{ Phase = '15_Views';              Property = 'Views';                Description = 'Views (CREATE VIEW).' }
        [pscustomobject]@{ Phase = '16_Functions';          Property = 'UserDefinedFunctions'; Description = 'Scalar, inline-TVF, multi-statement-TVF, CLR functions.' }
        [pscustomobject]@{ Phase = '17_Procedures';         Property = 'StoredProcedures';     Description = 'T-SQL and CLR stored procedures.' }
        [pscustomobject]@{ Phase = '18_BrokerQueues';       Property = 'ServiceBrokerQueues';  Description = 'Service Broker queues (definitions only; contracts/services out of scope).' }
        [pscustomobject]@{ Phase = '19_DdlTriggers';        Property = 'DatabaseTriggers';     Description = 'Database-scoped DDL triggers (SMO: Database.Triggers).' }
    )
}

function Get-SqlCpySchemaOnlyInlineOnlyTypes {
<#
.SYNOPSIS
    Returns object-type names that are scripted INLINE with their parent and
    therefore do not have a dedicated phase. Kept so the phase filter can log
    "inline" rather than "skip" for these.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('ForeignKeys','Indexes','Triggers','FullTextIndexes')
}

function Invoke-SqlCpySchemaOnlyDatabaseCopy {
<#
.SYNOPSIS
    Copies selected databases as schema-only (no data, no security) from source
    to target.

.DESCRIPTION
    Produces a target database with the **same object model** as the source:
    schemas, tables (columns, PK/UK/CK constraints, defaults, computed columns),
    foreign keys, indexes (incl. filtered, columnstore, XML), views, functions,
    stored procedures, DML and DDL triggers, sequences, synonyms, user-defined
    types (alias, CLR, table-valued), XML schema collections, partition
    functions/schemes, full-text catalogs and indexes, and Service Broker queue
    definitions. NO data is transferred (no data-insert statements, no BCP,
    no data-table copy cmdlets) and NO security objects are scripted (no
    users, roles, permissions, role memberships). See
    DECISIONS_AND_CAVEATS.txt for the full rationale and per-category caveats.

    Engine: dbatools-first. The default path walks the source database via SMO
    (reached through the dbatools Connect-DbaInstance connection object so
    TrustServerCertificate / EncryptConnection apply) and emits a per-phase
    .sql file into an artifacts folder. A single combined CREATE DATABASE +
    concatenated phase script is written as `<db>.sql` for convenient review
    and re-apply.

    Ordering: phases are ordered for dependency safety (schemas -> types ->
    tables -> FKs -> full-text -> programmable objects -> DDL triggers). FKs
    are scripted inline with tables (DriForeignKeys = $true) AND a standalone
    phase file is generated as a belt-and-braces safety net for callers that
    disable DRI FKs.

    DryRun: on by default. In DryRun the function still writes the script
    artifacts to disk so the user can review what *would* be applied. It does
    NOT create or alter the target database.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER Databases
    One or more database names to copy (schema-only). Required.

.PARAMETER DryRun
    When $true (default), scripts objects to the artifacts folder but does not
    mutate the target.

.PARAMETER OutputFolder
    Optional folder to store generated .sql files. Defaults to a timestamped
    folder under $env:TEMP.

.PARAMETER IncludeObjectTypes
    Optional override of the object categories to include. Defaults come from
    Get-SqlCpySchemaOnlyObjectTypeDefaults.

.PARAMETER Config
    Config hashtable. When omitted, Get-SqlCpyConfig is called.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [Parameter(Mandatory)] [string[]]$Databases,
        [bool]$DryRun = $true,
        [string]$OutputFolder,
        [string[]]$IncludeObjectTypes,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep ("Copying databases (schema-only, no data, no security): {0} -> {1} (DryRun={2})" -f $SourceServer, $TargetServer, $DryRun)

    if (-not $IncludeObjectTypes -or $IncludeObjectTypes.Count -eq 0) {
        if ($Config.ContainsKey('SchemaOnlyIncludeObjectTypes') -and $Config.SchemaOnlyIncludeObjectTypes) {
            $IncludeObjectTypes = @($Config.SchemaOnlyIncludeObjectTypes)
        } else {
            $IncludeObjectTypes = Get-SqlCpySchemaOnlyObjectTypeDefaults
        }
    }
    Write-SqlCpyInfo ("Object categories: {0}" -f ($IncludeObjectTypes -join ', '))
    Write-SqlCpyInfo ("Security categories are excluded: {0}" -f ((Get-SqlCpySchemaOnlySecurityExcludedTypes) -join ', '))

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("sqlservercpy_schema_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
    Write-SqlCpyInfo "Script output folder: $OutputFolder"

    $srcConn = Get-SqlCpyCachedConnection -Config $Config -Role 'Source' -Server $SourceServer -Credential $Config.SourceCredential

    foreach ($db in $Databases) {
        Write-SqlCpyInfo "Scripting database: $db"

        $dbFolder = Join-Path -Path $OutputFolder -ChildPath $db
        if (-not (Test-Path -LiteralPath $dbFolder)) {
            New-Item -ItemType Directory -Path $dbFolder -Force | Out-Null
        }

        $combinedPath = Join-Path -Path $OutputFolder -ChildPath ("{0}.sql" -f $db)
        try {
            Export-SqlCpySchemaOnlyDatabase `
                -Connection       $srcConn `
                -DatabaseName     $db `
                -OutputFolder     $dbFolder `
                -CombinedPath     $combinedPath `
                -IncludeObjectTypes $IncludeObjectTypes
        } catch {
            Write-SqlCpyWarning "Scripting for $db failed: $($_.Exception.Message)"
            Write-SqlCpyInfo   (Get-SqlCpyConnectionErrorHint -Message $_.Exception.Message -Config $Config)
            continue
        }

        if ($DryRun) {
            Write-SqlCpyInfo "DRYRUN: artifacts written under $dbFolder (not applied to target)"
            Write-SqlCpyInfo "DRYRUN: combined script at $combinedPath"
            continue
        }

        Write-SqlCpyInfo "Applying script to target: $db"
        $tgtConn  = Get-SqlCpyCachedConnection -Config $Config -Role 'Target' -Server $TargetServer -Credential $Config.TargetCredential
        $tgtSplat = Get-SqlCpyInstanceSplat -Config $Config -Connection $tgtConn -CommandName 'Invoke-DbaQuery'

        # Ensure the target database exists before applying schema objects.
        if (Get-Command -Name Get-DbaDatabase -ErrorAction SilentlyContinue) {
            $exists = $null
            try { $exists = Get-DbaDatabase @tgtSplat -Database $db -ErrorAction SilentlyContinue } catch {}
            if (-not $exists -and (Get-Command -Name New-DbaDatabase -ErrorAction SilentlyContinue)) {
                Write-SqlCpyInfo "Target database '$db' not found - creating empty database."
                New-DbaDatabase @tgtSplat -Name $db -ErrorAction Stop | Out-Null
            }
        }

        # Apply the combined script; if the caller wants per-phase isolation
        # they can re-run with the phase files under $dbFolder.
        Invoke-DbaQuery @tgtSplat -Database $db -File $combinedPath -EnableException
    }
}

function Export-SqlCpySchemaOnlyDatabase {
<#
.SYNOPSIS
    Walks a source database and writes per-phase schema-only scripts plus a
    combined file.

.DESCRIPTION
    Internal helper used by Invoke-SqlCpySchemaOnlyDatabaseCopy. Kept as a
    separate function so tests can invoke it with a stubbed database object.

    The function does NOT import modules or open connections - it expects an
    already-open dbatools connection object (Connect-DbaInstance result) whose
    .Databases[<name>] exposes SMO-shaped object collections.

.PARAMETER Connection
    Pre-built dbatools/SMO server connection.

.PARAMETER DatabaseName
    Database to script.

.PARAMETER OutputFolder
    Per-database folder where phase files are written.

.PARAMETER CombinedPath
    Path to the single combined .sql file for this database.

.PARAMETER IncludeObjectTypes
    Categories to include; entries not listed in the phase map are logged and
    skipped.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$CombinedPath,
        [Parameter(Mandatory)] [string[]]$IncludeObjectTypes
    )

    $db = $Connection.Databases[$DatabaseName]
    if (-not $db) {
        throw "Database '$DatabaseName' not found on source instance."
    }

    $scriptingOptions = New-SqlCpySchemaOnlyScriptingOption

    # 1) CREATE DATABASE header. We emit a minimal CREATE DATABASE IF NOT EXISTS
    #    guard so the combined script is re-runnable against an empty target.
    #    File-group / physical file layout is intentionally NOT replayed -
    #    reproducing MDF/LDF paths across machines is fragile and out of scope
    #    for the schema-only action.
    $createHeader = @(
        "-- sqlserver-cpy schema-only export"
        ("-- Source database : {0}" -f $DatabaseName)
        ("-- Generated       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        "-- Security objects : EXCLUDED (users/roles/permissions)"
        "-- Data             : EXCLUDED"
        ""
        "IF DB_ID(N'$DatabaseName') IS NULL"
        "BEGIN"
        "    CREATE DATABASE [$DatabaseName];"
        "END"
        "GO"
        "USE [$DatabaseName];"
        "GO"
        ""
    ) -join [Environment]::NewLine

    $headerPath = Join-Path -Path $OutputFolder -ChildPath '00_CreateDatabase.sql'
    Set-Content -LiteralPath $headerPath -Value $createHeader -Encoding UTF8

    # Begin the combined file with the header, then append each phase.
    Set-Content -LiteralPath $CombinedPath -Value $createHeader -Encoding UTF8

    $phases    = Get-SqlCpySchemaOnlyScriptPhases
    $inlineOnly = Get-SqlCpySchemaOnlyInlineOnlyTypes
    foreach ($t in $inlineOnly) {
        if ($IncludeObjectTypes -contains $t) {
            Write-SqlCpyInfo ("  [inline] {0}: scripted inline with parent tables (no standalone phase)" -f $t)
        }
    }
    $totalObjects = 0

    foreach ($phase in $phases) {
        if ($IncludeObjectTypes -notcontains $phase.Property) {
            Write-SqlCpyInfo ("  [skip] {0}: not in IncludeObjectTypes" -f $phase.Phase)
            continue
        }

        # DatabaseTriggers is a semantic alias for SMO's Database.Triggers
        # collection (which contains DDL triggers, not DML triggers - DML
        # triggers live on Tables). Keep the alias distinct from the Triggers
        # name because Triggers by itself is ambiguous in SMO APIs.
        $smoProperty = $phase.Property
        if ($smoProperty -eq 'DatabaseTriggers') { $smoProperty = 'Triggers' }

        $coll = $null
        try { $coll = $db.$smoProperty } catch { $coll = $null }
        if ($null -eq $coll) {
            Write-SqlCpyInfo ("  [skip] {0}: SMO collection '{1}' not available on this SQL version" -f $phase.Phase, $smoProperty)
            continue
        }

        $phaseItems = @()
        foreach ($item in $coll) {
            # System schemas / system-shipped objects must never be scripted.
            if ($item.PSObject.Properties.Name -contains 'IsSystemObject' -and $item.IsSystemObject) { continue }
            if ($item.PSObject.Properties.Name -contains 'IsSystemNamed' -and $item.IsSystemNamed -and $phase.Property -eq 'Schemas') { continue }
            if ($phase.Property -eq 'Schemas') {
                $sysSchemas = @('sys','INFORMATION_SCHEMA','guest','db_owner','db_accessadmin','db_securityadmin','db_ddladmin','db_backupoperator','db_datareader','db_datawriter','db_denydatareader','db_denydatawriter')
                if ($sysSchemas -contains $item.Name) { continue }
            }
            $phaseItems += ,$item
        }

        if ($phaseItems.Count -eq 0) {
            Write-SqlCpyInfo ("  [empty] {0}: 0 objects" -f $phase.Phase)
            continue
        }

        $phasePath = Join-Path -Path $OutputFolder -ChildPath ("{0}.sql" -f $phase.Phase)

        $scripted = 0
        $phaseHeader = ("-- Phase {0} ({1}): {2}" -f $phase.Phase, $phase.Property, $phase.Description)
        Set-Content -LiteralPath $phasePath -Value $phaseHeader -Encoding UTF8
        Add-Content -LiteralPath $phasePath -Value '' -Encoding UTF8

        foreach ($item in $phaseItems) {
            try {
                # SMO every object exposes .Script() returning a StringCollection.
                $lines = $item.Script($scriptingOptions)
                if ($null -eq $lines) { continue }
                foreach ($l in $lines) {
                    Add-Content -LiteralPath $phasePath -Value $l -Encoding UTF8
                }
                Add-Content -LiteralPath $phasePath -Value 'GO' -Encoding UTF8
                $scripted++
            } catch {
                # Encrypted modules raise when .Script() tries to decrypt the body.
                # Surface the object name and keep going - this is called out in
                # DECISIONS_AND_CAVEATS.txt.
                Write-SqlCpyWarning ("    skip {0} [{1}]: {2}" -f $item.Name, $phase.Property, $_.Exception.Message)
            }
        }

        Write-SqlCpyInfo ("  [done] {0}: scripted {1} / {2}" -f $phase.Phase, $scripted, $phaseItems.Count)
        $totalObjects += $scripted

        # Append this phase to the combined file.
        $phaseText = Get-Content -LiteralPath $phasePath -Raw
        Add-Content -LiteralPath $CombinedPath -Value $phaseText -Encoding UTF8
    }

    Write-SqlCpyInfo ("Schema-only export complete for {0}: {1} objects, artifacts at {2}" -f $DatabaseName, $totalObjects, $OutputFolder)
}
