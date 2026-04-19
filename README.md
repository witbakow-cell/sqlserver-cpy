# sqlserver-cpy

PowerShell scaffold for moving Microsoft SQL Server assets from one machine to another.

This is an **initial scaffold**. Core orchestration, logging, UI, and configuration are wired up,
but the SQL-server-specific transfer operations are marked with `TODO` and need validation against
live SQL Server environments before being used in production.

## Scope

The project targets the following asset categories:

- SQL Server Agent jobs
- SSISDB catalog configuration (folders, references, permissions)
- SSIS projects and environments
- **SSRS (Reporting Services) assets: reports, datasets, data sources,
  resources, folders, item-level security, role definitions, shared
  schedules, subscriptions, and KPIs/mobile reports**
- SQL Server users and logins
- Selected database schemas (schema-only, no data)
- SQL Server server-level configuration (compare and equalize)

SSAS (Analysis Services) migration is **documented as a planned extension** and is not implemented
in this initial scaffold. See `docs/SSAS_PLANNED.md`.

## Defaults

- Source server: `chbbbid2`
- Target server: `localhost`

Override these through the interactive TUI or by editing `config/default.psd1`
(or a copy, e.g. `config/local.psd1`, which is gitignored).

## Connection security

Recent SQL Server client stacks (Microsoft.Data.SqlClient 4+, used by current `dbatools`
releases) default to `Encrypt=Mandatory` with strict certificate-chain validation. On a
server that presents a self-signed or internally issued certificate this surfaces as:

```
WARNING: [HH:mm:ss][Get-DbaSpConfigure] Failure | The certificate chain was issued by
an authority that is not trusted
```

followed by an empty result. `sqlserver-cpy` handles this centrally through three config
keys in `config/default.psd1`:

| Key                        | Default  | Meaning |
|----------------------------|----------|---------|
| `EncryptConnection`        | `$true`  | Request TLS on the TDS connection. |
| `TrustServerCertificate`   | `$true`  | Skip CA/chain validation. **Scaffold/admin default.** |
| `ConnectionTimeoutSeconds` | `15`     | Connection timeout passed to dbatools / SMO. |

These flow into every `dbatools` cmdlet the tool calls through `Get-SqlCpyConnectionSplat`
/ `Get-SqlCpyCopySplat`, so you only configure them once.

### dbatools parameter compatibility

`dbatools` cmdlets do **not** all expose the same connection parameters. Most notably,
`-TrustServerCertificate` / `-EncryptConnection` and `-ConnectionTimeout` exist on
`Connect-DbaInstance` and `Invoke-DbaQuery` but **not** on `Get-DbaSpConfigure`,
`Copy-DbaSpConfigure`, `Get-DbaLogin`, `Copy-DbaLogin`, `Get-DbaAgentJob`,
`Copy-DbaAgentJob`, or `Copy-DbaSsisCatalog` in the 2.x line. Two symptoms came out
of this asymmetry:

1. Unconditionally splatting `-ConnectionTimeout` onto every cmdlet failed with
   `A parameter cannot be found that matches parameter name 'ConnectionTimeout'.`
2. Dynamically filtering the splat fixed (1) but silently **dropped
   `-TrustServerCertificate`**, so `Get-DbaSpConfigure` fell back to strict chain
   validation and failed with _"The certificate chain was issued by an authority
   that is not trusted"_ on servers with self-signed / internal CA certs (e.g.
   `chbbbid2`).

The robust fix is to apply `TrustServerCertificate = $true` through a
`Connect-DbaInstance` **connection object** and pass that object as `-SqlInstance`
(or `-Source` / `-Destination`) to downstream cmdlets. Those cmdlets reuse the
already-open connection, inheriting its trust and encryption decision without
needing their own trust parameters. This is what `sqlserver-cpy` now does:

- `Test-SqlCpyPreflight` opens connection objects via `Get-SqlCpyDbaConnection`
  and caches them on the `$Config` hashtable as `_SourceConnection` and
  `_TargetConnection`.
- Migration and compare functions (`Invoke-SqlCpyServerConfigCompare`,
  `Invoke-SqlCpyLoginCopy`, `Invoke-SqlCpyAgentJobCopy`,
  `Invoke-SqlCpySsisCatalogCopy`, `Invoke-SqlCpySchemaOnlyDatabaseCopy`) call
  `Get-SqlCpyCachedConnection` to retrieve those handles and pass them through
  `Get-SqlCpyInstanceSplat` / `Get-SqlCpyCopySplat`.
- A successful preflight therefore guarantees Step 1 (_Compare server
  configuration_) and every later step uses the **same** TLS/trust behaviour
  preflight validated.

`Get-SqlCpyConnectionSplat` / `Get-SqlCpyCopySplat` still exist for raw-name
calls and still filter against `Get-Command`. The preferred path for new code is
the connection-object one. See
[`DEPENDENCIES.md`](DEPENDENCIES.md#dbatools-parameter-compatibility) for the
full list of parameter-name candidates the helpers try (`ConnectionTimeout`,
`ConnectTimeout`, `StatementTimeout`).

### Security tradeoff

`TrustServerCertificate = $true` is the default because this tool is intended for local
admin-bootstrap migrations (typically Windows auth, LAN, self-signed cert on the SQL
Server). It disables hostname / CA chain validation and is therefore **vulnerable to an
active MITM attack on TDS traffic**. That is acceptable for a lab or one-off admin
migration; it is **not acceptable for production over untrusted networks**.

For production, flip it off in `config/local.psd1`:

```powershell
@{ TrustServerCertificate = $false }
```

and install a properly chained server certificate on the SQL Server instance. The
preflight step will then give you an actionable error instead of a silent warning.

### Configuring the default `chbbbid2 -> localhost` case

In most scaffold sessions the two defaults are already what you want. To make it explicit,
create `config/local.psd1` next to `config/default.psd1`:

```powershell
@{
    SourceServer           = 'chbbbid2'
    TargetServer           = 'localhost'
    EncryptConnection      = $true
    TrustServerCertificate = $true   # scaffold / admin convenience; see warning above
    ConnectionTimeoutSeconds = 15
}
```

Then run the TUI, pick option **9) Preflight** to confirm both servers are reachable
with these settings, and only after that proceed to **1) Compare server configuration**.

You can also adjust the same three values live from the TUI via option **8) Change
connection security**.

## Dependency strategy

The architecture decision for this project is **dbatools-first**. Use `dbatools` cmdlets
as the primary engine wherever they cover the scenario cleanly. Fall back to the official
`SqlServer` PowerShell module or directly to SMO/AMO/TOM assemblies when `dbatools` does
not expose the surface you need.

See [DEPENDENCIES.md](DEPENDENCIES.md) for the full list of external modules and DLLs.

## Getting started

```powershell
# From the repo root, in a PowerShell 5.1+ or PowerShell 7+ session on Windows:
./Start-SqlServerCopy.ps1
```

The launcher will:

1. Import the `SqlServerCpy` module from `src/SqlServerCpy`.
2. Load configuration from `config/default.psd1` (merged with any `config/local.psd1`).
3. Start the interactive console menu (TUI).
4. On uncaught runtime errors, show an error screen that offers to copy the full error
   to the clipboard (best-effort, via `Set-Clipboard`) or write it to a timestamped file.

## Repo layout

```
.
├── Start-SqlServerCopy.ps1      # Root launcher
├── config/
│   └── default.psd1             # Example configuration (source=chbbbid2, target=localhost)
├── src/
│   └── SqlServerCpy/
│       ├── SqlServerCpy.psd1    # Module manifest
│       ├── SqlServerCpy.psm1    # Module loader
│       └── Public/              # Public functions (one topic per file)
├── docs/
│   ├── FUNCTION_INDEX.md        # Index of public functions with short descriptions
│   └── SSAS_PLANNED.md          # Planned SSAS extension design
├── tests/
│   └── Syntax.Tests.ps1         # Lightweight syntax / import checks
├── DEPENDENCIES.md              # External modules, DLLs, versions
├── DECISIONS_AND_CAVEATS.txt    # Architectural choices, observations, caveats
└── README.md
```

## Login copy: skipped prefixes

The login copy step filters out principals that are machine-local or otherwise
not portable. The default list lives in `config/default.psd1` under
`LoginSkipPrefixes`:

```powershell
LoginSkipPrefixes = @(
    'NT AUTHORITY'
    'NT SERVICE'
    'BUILTIN'
    'ADIS'
)
```

Matching is case-insensitive. A single leading `<domain>\` qualifier is
stripped before comparison, so `MYDOMAIN\BUILTIN\Administrators` still matches
`BUILTIN`. Skipped logins are logged individually so you can see exactly what
was dropped. Override the list in `config/local.psd1` if you need to include
(or further exclude) a prefix.

## SSRS (Reporting Services) copy

Option **6) Copy SSRS assets** in the TUI migrates an entire SSRS catalog over
the **ReportService2010 SOAP** API (plus REST v2.0 for KPIs where the target
exposes it). It does **not** copy the ReportServer / ReportServerTempDB
catalog databases directly: that path is version-specific and pulls in
symmetric keys that are bound to the source machine.

The copy attempts, in order:

1. Role definitions (system + catalog)
2. Shared schedules
3. Folder tree
4. Shared data sources
5. Shared datasets
6. Resources (images, xlsx, pdf, …)
7. Reports (and linked reports; shared references are rebound)
8. Item-level security (policies) for every copied item
9. Subscriptions (best-effort)
10. KPIs / mobile reports via REST (SSRS 2016+)

Defaults:

```powershell
SourceSsrsUri = 'http://chbbbid2/ReportServer'
TargetSsrsUri = 'http://localhost/ReportServer'
SsrsRootPath  = '/'
```

Per-asset toggles (`CopySsrsFolders`, `CopySsrsReports`, `CopySsrsDatasets`,
`CopySsrsDataSources`, `CopySsrsResources`, `CopySsrsSecurity`,
`CopySsrsRoles`, `CopySsrsSubscriptions`, `CopySsrsSchedules`,
`CopySsrsKpis`) all default to `$true` because the explicit requirement is
not to skip any class of SSRS asset. Flip them off in `config/local.psd1` if
a given class does not apply.

Known caveats (also in `DECISIONS_AND_CAVEATS.txt`):

- Stored credentials on data sources and the delivery credentials on
  subscriptions are encrypted with the source server's symmetric key and are
  **not portable over SOAP**. The scaffold copies the item with blank
  credential fields and logs a WARN line so you can re-enter them on the
  target (or use an SSRS encryption-key backup/restore).
- `CreateSubscription` needs the subscription owner to exist on the target.
  Copy logins first.
- Data-driven subscriptions (`CreateDataDrivenSubscription`) and some older
  KPI shapes may not round-trip cleanly; the scaffold logs these as WARN and
  keeps going.

Running the SSRS copy requires a PowerShell host with `New-WebServiceProxy`
(Windows PowerShell 5.1, or PowerShell 7.x on Windows).

## Schema-only database copy

Option **7) Copy selected databases (schema-only, no data)** produces a
target database with the **same object model** as the source but with **no
row data and no security principals**. The action scripts:

- Schemas
- Tables (columns, PK / UK / CHECK constraints, defaults, computed columns)
- Foreign keys (scripted inline with tables via `DriForeignKeys`)
- Indexes — non-clustered, clustered, filtered, columnstore, XML (inline)
- Views, functions (scalar / inline-TVF / multi-statement-TVF / CLR),
  stored procedures (T-SQL + CLR)
- DML triggers (inline with tables) and DDL triggers (database scope)
- Sequences, synonyms
- User-defined types — alias, CLR, and table-valued (TVP) types
- XML schema collections
- Partition functions and partition schemes
- Full-text catalogs and full-text indexes
- Legacy default / rule objects, CLR assemblies, Service Broker queue
  definitions

Security objects are **always excluded**: users, database/application roles,
permissions, role memberships, audits, credentials, certificates, keys, and
security policies. Data is **always excluded**: no `INSERT`s, no
`Copy-DbaDbTableData`, no `bcp`. These are non-negotiable per the user's
explicit "ignore security, ignore data" requirement.

Artifacts: per-phase `.sql` files are written under
`<output>/<db>/NN_Phase.sql`, plus a combined `<output>/<db>.sql` that begins
with a `CREATE DATABASE IF NOT EXISTS` guard so it can be replayed against
an empty target. In **DryRun** the artifacts are produced but not applied.

Config knobs in `config/default.psd1`:

```powershell
SchemaOnlyDatabaseList              = @()          # which databases to copy
SchemaOnlyIncludeObjectTypes        = $null        # $null = use the full defaults
SchemaOnlyExcludeSecurity           = $true        # always true by design
SchemaOnlyTableScriptMode           = 'PerTable'   # 'PerTable' | 'Collection'
SchemaOnlyExcludeTables             = @()          # tables to skip in the Tables phase
SchemaOnlyTableScriptTimeoutSeconds = 300          # per-table wall-clock timeout
```

### Per-table scripting (Tables phase)

The Tables phase iterates tables one at a time by default
(`SchemaOnlyTableScriptMode = 'PerTable'`) and logs the schema-qualified
name and `object_id` before and after each table with elapsed time:

```
[table] scripting [integra].[Execution] object_id=295672101 (timeout=300s)
[table] done      [integra].[Execution] in 3.21s (128 lines)
```

Why this is the default: SMO's `.Script($opts)` path on a single table can
hang when the server-side metadata query against `sys.indexes` for that
table never returns. On one observed source the tables
`[integra].[Execution]` and `[integra].[Application]` hang indefinitely
with no `blocking_session_id`. Per-table mode ensures every other table
still gets scripted, and the wall-clock timeout (300s default) skips the
offender so the run completes. Skipped tables are recorded in
`<output>/<db>/_skipped_tables.txt`.

**Running into this?** Add the offenders to `config/local.psd1`:

```powershell
SchemaOnlyExcludeTables = @('[integra].[Execution]', '[integra].[Application]')
```

Entries may be written as `[schema].[table]`, `schema.table`, bare `table`
(matches any schema), or a numeric `object_id`. Matching is
case-insensitive.

**Timeout caveat.** The per-table timeout runs `.Script()` in a child
PowerShell runspace and stops that runspace when the deadline elapses.
This is *best-effort*: managed code is stopped cleanly, but if SMO is
blocked inside a native SqlClient socket read the underlying TCP call may
linger in the background until the OS tears the process down. The main
runspace is freed either way, so the schema-only copy finishes.

### Caveats

- **Encrypted modules.** `WITH ENCRYPTION` makes the body unreadable to
  SMO. The scaffold logs a WARN per affected object and continues; rebuild
  those modules from source control on the target.
- **Filegroups and partitioning.** The combined script does `CREATE
  DATABASE <name>` with server defaults. If the source uses custom
  filegroups or partition schemes, create those filegroups on the target
  before applying the script, or edit the `08_PartitionFunctions.sql` /
  `09_PartitionSchemes.sql` phase files.
- **Full-Text Search.** Full-text catalogs / indexes require the Full-Text
  Search feature to be installed on the target. The apply step fails
  cleanly if the feature is missing.
- **Service Broker.** Queue definitions are scripted; contracts, services,
  routes, and remote service bindings are not.
- **Cross-database references.** Three-part-name and linked-server
  references are scripted verbatim — the referenced database or linked
  server must exist on the target for the objects to be valid at runtime.
- **Security / permissions.** Lost by design. Run option 3 (Copy logins)
  first if you need logins; re-apply ownership and explicit GRANTs
  manually.
- **SQL version differences.** The scripting-option builder only sets
  properties that exist on the installed SMO variant. Missing properties
  are tolerated; missing SMO collections log as "skip" for that phase.
- **Schema phase fallback.** On some sources (observed on SQL 2022 /
  dbatools 2.1.24, e.g. `dwcontrol`) SMO's generic `Schema.Script($opts)`
  throws `Script failed for Schema '<name>'.` for every schema — even
  schemas whose `sys.schemas` owner is plain `dbo`. The Schemas phase
  therefore tries `$schema.Script($opts)`, then `$schema.Script()` with
  no args, and finally emits a manual, guarded
  `IF SCHEMA_ID(N'<name>') IS NULL EXEC(N'CREATE SCHEMA [<name>]
  AUTHORIZATION [dbo]');` statement. The `AUTHORIZATION [dbo]` choice is
  intentional and aligned with the "ignore security" requirement: the
  copy does not script the source's schema owner because the owning
  principal is, by design, not being copied. When the manual fallback
  fires, the original SMO error is logged as a `WARN` line so the
  underlying SMO problem is still visible.

## Safety defaults

The configuration file includes a `DryRun` flag (default `$true`). Destructive operations
on the target should honour this flag and log what they would do without changing state.
This is enforced by convention in the public functions; see each function's help block.

## Testing

There is no requirement for a live SQL Server to run the repo-level checks. The tests in
`tests/Syntax.Tests.ps1` validate that every script parses and the module imports cleanly.
Live-SQL behaviour must be validated manually in a real environment.

## License

No license has been declared yet. Treat this as "all rights reserved" until a license is added.
