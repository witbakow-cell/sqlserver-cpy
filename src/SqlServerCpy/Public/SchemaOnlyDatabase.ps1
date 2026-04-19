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

function Get-SqlCpySchemaOnlySystemSchemaNames {
<#
.SYNOPSIS
    Returns the schema names that schema-only copy must never emit because
    SQL Server ships them (or creates them automatically for built-in roles).

.DESCRIPTION
    Kept as a dedicated helper so the schema-phase fallback and any future
    callers share one list. `dbo`, `guest`, `INFORMATION_SCHEMA`, and `sys`
    are the system schemas; the `db_*` fixed-role schemas are created by SQL
    Server with the database and must not be scripted either.

.OUTPUTS
    [string[]]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'dbo'
        'guest'
        'INFORMATION_SCHEMA'
        'sys'
        'db_owner'
        'db_accessadmin'
        'db_securityadmin'
        'db_ddladmin'
        'db_backupoperator'
        'db_datareader'
        'db_datawriter'
        'db_denydatareader'
        'db_denydatawriter'
    )
}

function Format-SqlCpySchemaCreateStatement {
<#
.SYNOPSIS
    Emits a safe, re-runnable "CREATE SCHEMA [name] AUTHORIZATION [dbo]"
    batch for a given schema name.

.DESCRIPTION
    Produces the fallback statement used by the Schemas phase when SMO's
    .Script() call fails (we have seen this on dwcontrol / SQL 2022 where
    Schema.Script() throws "Script failed for Schema 'A00'" even though the
    schema has a sane dbo owner and Schema.Script() works at an interactive
    prompt). The statement is a guarded EXEC so it is safe to replay:

        IF SCHEMA_ID(N'<escaped>') IS NULL
            EXEC(N'CREATE SCHEMA [escaped] AUTHORIZATION [dbo]');

    AUTHORIZATION [dbo] is intentional: the user has explicitly asked the
    schema-only copy to ignore security, so we do NOT try to replay source
    schema ownership. That keeps the target from depending on principals
    that may not (and by design WILL not) have been copied.

    Escaping rules:
      * String-literal form: single quotes are doubled (T-SQL).
      * Bracket-identifier form: right brackets (]) are doubled.
      * All other characters (dollar signs, dots, spaces, unicode, leading
        underscores) pass through unchanged because they are legal inside
        [ ] quoted identifiers.

.PARAMETER Name
    Schema name exactly as it appears in sys.schemas.

.OUTPUTS
    [string] — a single T-SQL batch without a trailing GO (callers add GO).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Name
    )

    if ($null -eq $Name) { throw 'Schema name is required.' }
    # Reject empty / whitespace-only names defensively.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Invalid schema name '$Name' (empty or whitespace)."
    }

    $literal = $Name.Replace("'", "''")
    $bracket = $Name.Replace(']', ']]')

    # Inner single quotes (inside the EXEC(N'...')) must themselves survive
    # one extra layer of doubling because the outer string is itself a
    # single-quoted T-SQL literal.
    $bracketInsideExec = $bracket.Replace("'", "''")

    return ("IF SCHEMA_ID(N'{0}') IS NULL EXEC(N'CREATE SCHEMA [{1}] AUTHORIZATION [dbo]');" -f $literal, $bracketInsideExec)
}

function Get-SqlCpySchemaScriptLines {
<#
.SYNOPSIS
    Returns T-SQL lines for a single schema object, with a safe fallback.

.DESCRIPTION
    The Schemas phase historically called `$schema.Script($options)` like
    every other object. On a real source (SQL 2022 / dbatools 2.1.24 /
    dwcontrol) that single-argument call throws
        Exception calling "Script" with "1" argument(s):
        "Script failed for Schema 'A00'."
    for every schema, even schemas where the user can reproduce
    `$schema.Script()` and `$schema.Script($options)` interactively.

    The bug is not SQL metadata (owners, ACLs, compatibility level are
    fine) — it is something in the generic scripter pipeline (options
    combination, dependency discovery, or an internal SMO state leak on
    the collection walk). The fix is narrow: try .Script($options), then
    .Script() with no args, then fall back to a manual
    "CREATE SCHEMA [name] AUTHORIZATION [dbo]" statement from the schema's
    Name. Because the schema-only copy is explicitly security-free, using
    AUTHORIZATION [dbo] is correct rather than a regression.

.PARAMETER Schema
    SMO Schema object (from $db.Schemas).

.PARAMETER ScriptingOptions
    Optional ScriptingOptions to try first.

.PARAMETER WarningSink
    Optional scriptblock that receives a warning string. The caller uses
    this to route fallbacks through Write-SqlCpyWarning so operators see
    why the manual path fired. Called as `& $WarningSink $msg`.

.OUTPUTS
    [string[]] — one or more T-SQL lines (no trailing GO).
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Schema,
        $ScriptingOptions,
        [scriptblock]$WarningSink
    )

    $name = $null
    try { $name = [string]$Schema.Name } catch { $name = $null }
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Schema object has no readable Name property.'
    }

    $lastError = $null

    if ($ScriptingOptions) {
        try {
            $lines = $Schema.Script($ScriptingOptions)
            if ($lines) { return @($lines) }
        } catch {
            $lastError = $_.Exception
        }
    }

    try {
        $lines = $Schema.Script()
        if ($lines) { return @($lines) }
    } catch {
        $lastError = $_.Exception
    }

    # Manual fallback. Log why we fell back so operators can investigate
    # the SMO-side failure without losing the schema in the output.
    if ($WarningSink) {
        $inner = ''
        if ($lastError) {
            $inner = $lastError.Message
            if ($lastError.InnerException) {
                $inner += ' | inner: ' + $lastError.InnerException.Message
            }
        }
        & $WarningSink ("    schema [{0}]: SMO .Script() failed, using manual CREATE SCHEMA fallback (AUTHORIZATION [dbo], security ignored by design). Detail: {1}" -f $name, $inner)
    }

    return ,(Format-SqlCpySchemaCreateStatement -Name $name)
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

function Test-SqlCpySchemaOnlyTableExcluded {
<#
.SYNOPSIS
    Returns $true when a table should be skipped by the schema-only Tables
    phase, given the configured SchemaOnlyExcludeTables list.

.DESCRIPTION
    Accepted entry forms (case-insensitive):
      '[schema].[table]'  -- bracketed, e.g. '[integra].[Execution]'
      'schema.table'      -- plain,     e.g. 'integra.Execution'
      'table'             -- bare name; matches any schema
      '<object_id>'       -- sys.objects.object_id as integer or string

    Matching rules:
      * Schema and table names are compared with OrdinalIgnoreCase.
      * Bracket characters ([ and ]) are stripped from list entries and from
        the candidate names before comparison. This keeps users from having
        to reason about escaping in the psd1.
      * Leading / trailing whitespace on list entries is trimmed.
      * A bare table name (no schema) matches any schema. This is a
        deliberate convenience for the common case where the hanging table
        is unique across schemas.
      * A numeric entry matches ObjectId. Zero / negative numbers never
        match. Parsing is invariant-culture so commas/dots in locale do not
        interfere.

.PARAMETER SchemaName
    Schema name of the candidate table (e.g. 'integra').

.PARAMETER TableName
    Table name of the candidate table (e.g. 'Execution').

.PARAMETER ObjectId
    Optional SMO ObjectId / sys.objects.object_id of the candidate table.
    Pass 0 when not available.

.PARAMETER ExcludeList
    Array of entries from config (SchemaOnlyExcludeTables). $null / empty =>
    nothing is excluded.

.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$SchemaName,
        [string]$TableName,
        [long]$ObjectId = 0,
        [string[]]$ExcludeList
    )

    if (-not $ExcludeList -or $ExcludeList.Count -eq 0) { return $false }

    $schema = if ($null -ne $SchemaName) { $SchemaName.Trim() } else { '' }
    $table  = if ($null -ne $TableName)  { $TableName.Trim()  } else { '' }

    foreach ($raw in $ExcludeList) {
        if ($null -eq $raw) { continue }
        $entry = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }

        # object_id numeric match.
        $oid = 0L
        if ([long]::TryParse($entry, [System.Globalization.NumberStyles]::Integer,
                             [System.Globalization.CultureInfo]::InvariantCulture,
                             [ref]$oid)) {
            if ($oid -gt 0 -and $ObjectId -gt 0 -and $oid -eq $ObjectId) {
                return $true
            }
            # Pure number that did not match object_id is never a name match.
            continue
        }

        # Strip brackets once for comparison. Users may write '[integra].[Execution]',
        # 'integra.Execution', or a mix.
        $clean = $entry.Replace('[', '').Replace(']', '').Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }

        $parts = $clean.Split('.', 2)
        if ($parts.Count -eq 2) {
            $sPart = $parts[0].Trim()
            $tPart = $parts[1].Trim()
            if ([string]::IsNullOrWhiteSpace($tPart)) { continue }
            if ([string]::Equals($sPart, $schema, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals($tPart, $table,  [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } else {
            # Bare name: match any schema.
            if ([string]::Equals($clean, $table, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }

    return $false
}

function Invoke-SqlCpyScriptObjectWithTimeout {
<#
.SYNOPSIS
    Runs $item.Script($options) in an isolated runspace with a wall-clock
    timeout. Returns the script lines on success; throws on timeout or error.

.DESCRIPTION
    PowerShell/SMO synchronous calls cannot safely be interrupted inside the
    caller's runspace. To let a hung table scripting call (observed on
    [integra].[Execution] / [integra].[Application] where SMO's metadata
    query against sys.indexes does not return) be abandoned without hanging
    the whole TUI, we execute the call in a child runspace and stop that
    runspace when TimeoutSeconds elapses.

    Best-effort caveats:
      * Stopping a runspace is cooperative for managed code and best-effort
        for native I/O. If SMO is blocked inside the SqlClient socket read
        the underlying TCP call may linger in the background until the OS
        tears the process down, but the main runspace is freed and the
        schema-only run continues.
      * The SMO ScriptingOptions object carries no thread affinity in the
        shapes we use (schema-only, no data), so passing it into the child
        runspace is safe.
      * The SMO item (e.g. Table) is also shared across runspaces. SMO does
        not document thread safety, but .Script() is a read path against
        already-fetched metadata; in practice it works, and the alternative
        (spinning up a new Connect-DbaInstance per table) is far more
        expensive and itself vulnerable to the same underlying hang.

.PARAMETER Item
    Required. SMO object exposing .Script($options).

.PARAMETER Options
    Optional ScriptingOptions to pass to .Script(). $null => .Script() no-arg.

.PARAMETER TimeoutSeconds
    Required. Wall-clock timeout before the child runspace is aborted.

.OUTPUTS
    [string[]] script lines.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Item,
        $Options,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) { throw "TimeoutSeconds must be > 0 (got $TimeoutSeconds)." }

    $ps = [System.Management.Automation.PowerShell]::Create()
    try {
        [void]$ps.AddScript({
            param($item, $opts)
            if ($opts) { return ,@($item.Script($opts)) }
            return ,@($item.Script())
        })
        [void]$ps.AddArgument($Item)
        [void]$ps.AddArgument($Options)

        $async = $ps.BeginInvoke()
        $waited = $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        if (-not $waited) {
            try { $ps.Stop() } catch { }
            throw ("Script call timed out after {0}s" -f $TimeoutSeconds)
        }

        $result = $ps.EndInvoke($async)

        if ($ps.HadErrors) {
            $errText = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join ' | '
            throw ("Script call raised errors: {0}" -f $errText)
        }

        $out = @()
        foreach ($r in $result) {
            if ($null -eq $r) { continue }
            if ($r -is [System.Collections.IEnumerable] -and -not ($r -is [string])) {
                foreach ($line in $r) { $out += ,[string]$line }
            } else {
                $out += ,[string]$r
            }
        }
        return ,$out
    } finally {
        try { $ps.Dispose() } catch { }
    }
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
                -IncludeObjectTypes $IncludeObjectTypes `
                -Config           $Config
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

.PARAMETER Config
    Optional config hashtable. When supplied, honours
    SchemaOnlyTableScriptMode, SchemaOnlyExcludeTables, and
    SchemaOnlyTableScriptTimeoutSeconds for the Tables phase. When omitted,
    the Tables phase uses the legacy whole-collection path (no per-table
    timeout, no skip list).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$CombinedPath,
        [Parameter(Mandatory)] [string[]]$IncludeObjectTypes,
        [hashtable]$Config
    )

    # Resolve per-table scripting knobs (all optional, safe defaults).
    $tableMode    = 'PerTable'
    $excludeList  = @()
    $tableTimeout = 300
    if ($Config) {
        if ($Config.ContainsKey('SchemaOnlyTableScriptMode') -and $Config.SchemaOnlyTableScriptMode) {
            $tableMode = [string]$Config.SchemaOnlyTableScriptMode
        }
        if ($Config.ContainsKey('SchemaOnlyExcludeTables') -and $Config.SchemaOnlyExcludeTables) {
            $excludeList = @($Config.SchemaOnlyExcludeTables)
        }
        if ($Config.ContainsKey('SchemaOnlyTableScriptTimeoutSeconds') -and
            $Config.SchemaOnlyTableScriptTimeoutSeconds) {
            $parsed = 0
            if ([int]::TryParse([string]$Config.SchemaOnlyTableScriptTimeoutSeconds, [ref]$parsed) -and $parsed -gt 0) {
                $tableTimeout = $parsed
            }
        }
    }

    $skipReportPath = Join-Path -Path $OutputFolder -ChildPath '_skipped_tables.txt'
    $skipReport     = New-Object System.Collections.Generic.List[string]
    $skipReport.Add(("-- sqlserver-cpy schema-only: skipped tables report for {0}" -f $DatabaseName)) | Out-Null
    $skipReport.Add(("-- Generated : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) | Out-Null
    $skipReport.Add(("-- Mode      : {0}"  -f $tableMode)) | Out-Null
    $skipReport.Add(("-- Timeout   : {0}s" -f $tableTimeout)) | Out-Null
    if ($excludeList.Count -gt 0) {
        $skipReport.Add(("-- ExcludeList: {0}" -f ($excludeList -join ', '))) | Out-Null
    } else {
        $skipReport.Add("-- ExcludeList: (empty)") | Out-Null
    }
    $skipReport.Add('') | Out-Null

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
                $sysSchemas = Get-SqlCpySchemaOnlySystemSchemaNames
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

        $warnSink = { param($msg) Write-SqlCpyWarning $msg }

        $phaseSkipped = 0
        $phaseTimedOut = 0
        $phaseExcluded = 0

        foreach ($item in $phaseItems) {
            $itemLabel = $null
            $itemSchema = $null
            $itemObjectId = 0L
            try {
                if ($item.PSObject.Properties.Name -contains 'Schema') {
                    $itemSchema = [string]$item.Schema
                }
                if ($item.PSObject.Properties.Name -contains 'ObjectId') {
                    try { $itemObjectId = [long]$item.ObjectId } catch { $itemObjectId = 0L }
                }
                if ($itemSchema) {
                    $itemLabel = ('[{0}].[{1}]' -f $itemSchema, $item.Name)
                } else {
                    $itemLabel = ('[{0}]' -f $item.Name)
                }
            } catch {
                $itemLabel = '<unknown>'
            }

            # Tables phase: exclusion list + optional per-table timeout.
            $useTimeout = $false
            if ($phase.Property -eq 'Tables') {
                if (Test-SqlCpySchemaOnlyTableExcluded -SchemaName $itemSchema -TableName ([string]$item.Name) -ObjectId $itemObjectId -ExcludeList $excludeList) {
                    Write-SqlCpyWarning ("    [table] exclude {0} (object_id={1}) - per SchemaOnlyExcludeTables" -f $itemLabel, $itemObjectId)
                    $skipReport.Add(("EXCLUDE {0} object_id={1}" -f $itemLabel, $itemObjectId)) | Out-Null
                    $phaseExcluded++
                    continue
                }
                if ($tableMode -eq 'PerTable') {
                    Write-SqlCpyInfo ("    [table] scripting {0} object_id={1} (timeout={2}s)" -f $itemLabel, $itemObjectId, $tableTimeout)
                    $useTimeout = $true
                }
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($phase.Property -eq 'Schemas') {
                    # Schemas take the dedicated helper. SMO's generic
                    # Script($options) path was observed to throw for every
                    # schema on SQL 2022 / dbatools 2.1.24 even when owners
                    # are plain [dbo]; the helper tries .Script($options),
                    # then .Script(), then a manual CREATE SCHEMA ...
                    # AUTHORIZATION [dbo] (security intentionally ignored).
                    $lines = Get-SqlCpySchemaScriptLines -Schema $item -ScriptingOptions $scriptingOptions -WarningSink $warnSink
                } elseif ($useTimeout) {
                    $lines = Invoke-SqlCpyScriptObjectWithTimeout -Item $item -Options $scriptingOptions -TimeoutSeconds $tableTimeout
                } else {
                    # SMO every object exposes .Script() returning a StringCollection.
                    $lines = $item.Script($scriptingOptions)
                }
                $sw.Stop()
                if ($null -eq $lines) {
                    if ($phase.Property -eq 'Tables') {
                        Write-SqlCpyInfo ("    [table] done {0} in {1:n2}s - empty script" -f $itemLabel, $sw.Elapsed.TotalSeconds)
                    }
                    continue
                }
                foreach ($l in $lines) {
                    Add-Content -LiteralPath $phasePath -Value $l -Encoding UTF8
                }
                Add-Content -LiteralPath $phasePath -Value 'GO' -Encoding UTF8
                $scripted++
                if ($phase.Property -eq 'Tables') {
                    Write-SqlCpyInfo ("    [table] done {0} in {1:n2}s ({2} lines)" -f $itemLabel, $sw.Elapsed.TotalSeconds, @($lines).Count)
                }
            } catch {
                $sw.Stop()
                # Encrypted modules raise when .Script() tries to decrypt the body.
                # Surface the object name and keep going - this is called out in
                # DECISIONS_AND_CAVEATS.txt. Include inner exception when present
                # so operators can see the real SMO error.
                $detail = $_.Exception.Message
                if ($_.Exception.InnerException) {
                    $detail += ' | inner: ' + $_.Exception.InnerException.Message
                }
                $timedOut = ($detail -match 'timed out after')
                if ($phase.Property -eq 'Tables') {
                    if ($timedOut) {
                        Write-SqlCpyWarning ("    [table] TIMEOUT {0} object_id={1} after {2:n2}s - skipped; add to SchemaOnlyExcludeTables to silence" -f $itemLabel, $itemObjectId, $sw.Elapsed.TotalSeconds)
                        $skipReport.Add(("TIMEOUT {0} object_id={1} after {2:n2}s" -f $itemLabel, $itemObjectId, $sw.Elapsed.TotalSeconds)) | Out-Null
                        $phaseTimedOut++
                    } else {
                        Write-SqlCpyWarning ("    [table] ERROR {0} object_id={1} after {2:n2}s: {3}" -f $itemLabel, $itemObjectId, $sw.Elapsed.TotalSeconds, $detail)
                        $skipReport.Add(("ERROR   {0} object_id={1} after {2:n2}s: {3}" -f $itemLabel, $itemObjectId, $sw.Elapsed.TotalSeconds, $detail)) | Out-Null
                        $phaseSkipped++
                    }
                } else {
                    Write-SqlCpyWarning ("    skip {0} [{1}]: {2}" -f $item.Name, $phase.Property, $detail)
                }
            }
        }

        if ($phase.Property -eq 'Tables') {
            Write-SqlCpyInfo ("  [done] {0}: scripted {1} / {2} (excluded={3}, timeout={4}, errors={5})" -f $phase.Phase, $scripted, $phaseItems.Count, $phaseExcluded, $phaseTimedOut, $phaseSkipped)
        } else {
            Write-SqlCpyInfo ("  [done] {0}: scripted {1} / {2}" -f $phase.Phase, $scripted, $phaseItems.Count)
        }
        $totalObjects += $scripted

        # Append this phase to the combined file.
        $phaseText = Get-Content -LiteralPath $phasePath -Raw
        Add-Content -LiteralPath $CombinedPath -Value $phaseText -Encoding UTF8
    }

    # Emit the per-database skip / timeout / exclude report. Always write the
    # file so operators can see at a glance that the Tables phase completed
    # without omissions even when the list is empty.
    try {
        Set-Content -LiteralPath $skipReportPath -Value ($skipReport -join [Environment]::NewLine) -Encoding UTF8
        Write-SqlCpyInfo ("Tables skip/timeout report: {0}" -f $skipReportPath)
    } catch {
        Write-SqlCpyWarning ("Could not write skip report '{0}': {1}" -f $skipReportPath, $_.Exception.Message)
    }

    Write-SqlCpyInfo ("Schema-only export complete for {0}: {1} objects, artifacts at {2}" -f $DatabaseName, $totalObjects, $OutputFolder)
}
