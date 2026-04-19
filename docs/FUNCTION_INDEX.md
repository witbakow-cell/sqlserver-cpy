# Function index

This is a quick-browse index of every public function exported by the `SqlServerCpy`
module. Each function also carries a comment-based help block in its source file for
`Get-Help <Name>` use. Source file is shown in parentheses; click through on GitHub to
read the help block.

## Configuration

- **`Get-SqlCpyConfig`** (`src/SqlServerCpy/Public/Config.ps1`)
  — Loads `config/default.psd1` and merges any `config/local.psd1` on top. Returns a
  hashtable containing at least `SourceServer`, `TargetServer`, `DryRun`, `Areas`,
  `EncryptConnection`, `TrustServerCertificate`, `ConnectionTimeoutSeconds`.
- **`Get-SqlCpyRepoRoot`** (`src/SqlServerCpy/Public/Config.ps1`)
  — Returns the repository root, inferred from the module's location.

## Connection / preflight

- **`Get-SqlCpyDbaConnection`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Opens a `Connect-DbaInstance` handle with `TrustServerCertificate = $true`
  applied at the connection level. This is the preferred entry point because
  downstream dbatools cmdlets (Get-DbaSpConfigure, Get-DbaLogin, Copy-Dba*)
  inherit the trust decision automatically when the handle is reused as
  `-SqlInstance` / `-Source` / `-Destination`, even though those cmdlets
  themselves do not expose `-TrustServerCertificate`.
- **`Get-SqlCpyDbaInstance`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Back-compat wrapper around `Get-SqlCpyDbaConnection`.
- **`Get-SqlCpyCachedConnection`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Returns the source/target connection object cached on `$Config` by a
  successful `Test-SqlCpyPreflight`, or opens a fresh one on cache miss. Used
  by every migration / compare function so Step 1 and later steps reuse
  exactly the same authenticated handle.
- **`Get-SqlCpyInstanceSplat`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Builds a splat of the form `@{ SqlInstance = <connection object>; ... }`
  for dbatools cmdlets that accept `-SqlInstance`. Trust/encrypt flags are
  intentionally omitted (they are already on the connection object).
- **`Get-SqlCpyConnectionSplat`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Legacy raw-name splat builder: takes a server string and emits
  `SqlInstance`/`EncryptConnection`/`TrustServerCertificate`/`SqlCredential`
  and a timeout, filtered to the parameter set of the target cmdlet via
  `-CommandName`. Used by `Get-SqlCpyDbaConnection` itself to call
  `Connect-DbaInstance`. Prefer `Get-SqlCpyInstanceSplat` for everything else.
- **`Get-SqlCpyCopySplat`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Splat builder for `Copy-Dba*` cmdlets that take `-Source` / `-Destination`.
  Accepts pre-built connection objects via `-SourceConnection` /
  `-DestinationConnection`; when supplied, those replace the raw name strings
  and command-level trust/encrypt flags are omitted. Also filters against
  `-CommandName`.
- **`Get-SqlCpyCommandParameter`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Returns the parameter names (and alias map) a given command exposes, via
  `Get-Command`. Supports a `-Simulated` list for tests that must not depend on
  dbatools being installed.
- **`Resolve-SqlCpyParameterName`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Given a parameter-set hashtable and a priority-ordered list of candidate
  names, returns the first name the command actually accepts (parameter or
  alias). Used to route a configured timeout into whatever name the installed
  dbatools version uses.
- **`Test-SqlCpyPreflight`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Validates source and target connectivity under the configured TLS settings and
  prints actionable diagnostics for untrusted certificate chains, auth failures,
  network failures, and missing `dbatools`. On success, caches the opened
  connection objects on `$Config._SourceConnection` / `$Config._TargetConnection`
  so later steps reuse them. Returns `$true`/`$false`.
- **`Get-SqlCpyConnectionErrorHint`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Maps a SQL connection error message to a one-line remediation hint.

## Logging / UI

- **`Write-SqlCpyStep`** (`src/SqlServerCpy/Public/Logging.ps1`)
  — Writes a timestamped step header to the screen.
- **`Write-SqlCpyInfo`** (`src/SqlServerCpy/Public/Logging.ps1`)
  — Writes an informational line.
- **`Write-SqlCpyWarning`** (`src/SqlServerCpy/Public/Logging.ps1`)
  — Writes a yellow warning line; does not throw.
- **`Write-SqlCpyError`** (`src/SqlServerCpy/Public/Logging.ps1`)
  — Writes a red error line; does not throw. For fatal errors, let exceptions bubble up.
- **`Show-SqlCpyErrorScreen`** (`src/SqlServerCpy/Public/Logging.ps1`)
  — End-of-run error screen. Offers best-effort clipboard copy via `Set-Clipboard` or
  falls back to writing a timestamped file.

## Orchestration

- **`Start-SqlCpyInteractive`** (`src/SqlServerCpy/Public/Interactive.ps1`)
  — Main TUI entry point. Called by `Start-SqlServerCopy.ps1`. Catches runtime errors
  per action and renders `Show-SqlCpyErrorScreen` when one escapes.

## Server-level configuration

- **`Invoke-SqlCpyServerConfigCompare`** (`src/SqlServerCpy/Public/ServerConfig.ps1`)
  — Read-only compare between source and target via `Get-DbaSpConfigure`. Returns
  objects with `Name`, `SourceValue`, `TargetValue`, `Status`.
- **`Invoke-SqlCpyServerConfigApply`** (`src/SqlServerCpy/Public/ServerConfig.ps1`)
  — Equalises server configuration. Honours DryRun. Uses `Copy-DbaSpConfigure`.

## Logins

- **`Invoke-SqlCpyLoginCopy`** (`src/SqlServerCpy/Public/Logins.ps1`)
  — Copies logins and database-user mappings via `Copy-DbaLogin`. Honours DryRun.
  Filters out logins that match any prefix in `Config.LoginSkipPrefixes`
  (defaults: `NT AUTHORITY`, `NT SERVICE`, `BUILTIN`, `ADIS`) and logs every
  skipped entry.
- **`Test-SqlCpyLoginSkipped`** (`src/SqlServerCpy/Public/Logins.ps1`)
  — Pure predicate used by the copy path; case-insensitive prefix check that
  strips an outer domain qualifier so `MYDOMAIN\BUILTIN\Administrators` still
  matches `BUILTIN`.

## SQL Agent

- **`Invoke-SqlCpyAgentJobCopy`** (`src/SqlServerCpy/Public/AgentJobs.ps1`)
  — Copies Agent jobs via `Copy-DbaAgentJob`. Honours DryRun.

## SSIS catalog

- **`Invoke-SqlCpySsisCatalogCopy`** (`src/SqlServerCpy/Public/SsisCatalog.ps1`)
  — Copies SSISDB folders, projects, environments, references via `Copy-DbaSsisCatalog`.
  Honours DryRun. See the function's help block for caveats on sensitive environment
  variables.

## SSRS (Reporting Services)

SSRS copy talks to the **ReportService2010 SOAP** endpoint on both sides (plus
REST v2.0 where available for KPIs) rather than copying the ReportServer
catalog database. The orchestrator attempts every class of asset; individual
phase failures are logged and do not abort the rest.

- **`Invoke-SqlCpySsrsCopy`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Top-level orchestrator. Copies roles, schedules, folders, data sources,
  datasets, resources, reports, item-level policies, subscriptions and KPIs.
  Honours DryRun; reads the `CopySsrs*` toggles from config.
- **`Get-SqlCpySsrsProxy`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Opens a `New-WebServiceProxy` handle to `<uri>/ReportService2010.asmx?wsdl`
  under Windows default credentials (or an explicit `PSCredential`).
- **`Get-SqlCpySsrsRestBase`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Derives the `/Reports/api/v2.0` REST base URL from a ReportServer URL.
- **`Get-SqlCpySsrsCatalogItems`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Recursively lists every catalog item under a path via `ListChildren`.
- **`New-SqlCpySsrsFolderTree`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Creates folders parent-first on the target; no-op for existing folders.
- **`Copy-SqlCpySsrsCatalogItem`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Copies a single Report / DataSet / DataSource / Resource via
  `GetItemDefinition` + `CreateCatalogItem`; for reports also replays
  `SetItemDataSources` / `SetItemReferences` so shared references rebind.
- **`Copy-SqlCpySsrsItemPolicies`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Copies item-level security (role assignments) via
  `GetPolicies`/`SetPolicies`, honouring inheritance.
- **`Copy-SqlCpySsrsRoles`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Copies system + catalog role **definitions** (`ListRoles`,
  `GetRoleProperties`, `CreateRole`).
- **`Copy-SqlCpySsrsSchedules`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Copies shared schedules (`ListSchedules`, `CreateSchedule`).
- **`Copy-SqlCpySsrsSubscriptions`** (`src/SqlServerCpy/Public/Ssrs.ps1`)
  — Best-effort subscription copy (`ListSubscriptions`,
  `GetSubscriptionProperties`, `CreateSubscription`). Encrypted delivery
  credentials are not portable over SOAP - the function logs this.

## Schema-only database copy

The schema-only action produces a target database with the **same object
model** as the source but **no data and no security**. It scripts schemas,
tables (columns, PK/UK/CK, defaults, computed columns), foreign keys, indexes
(incl. filtered, columnstore, XML), views, functions, stored procedures, DML
and DDL triggers, sequences, synonyms, alias/CLR/table-valued user-defined
types, XML schema collections, partition functions/schemes, full-text
catalogs and indexes, legacy defaults/rules, CLR assemblies, and Service
Broker queue definitions. Users, roles, permissions, role memberships, keys,
certificates, and audit specifications are **never** scripted. Data-movement
commands (`Copy-DbaDbTableData`, BCP, `INSERT`s) are not invoked.

- **`Invoke-SqlCpySchemaOnlyDatabaseCopy`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Top-level entry point. Walks each source database via SMO (reached through
  the cached `Connect-DbaInstance` handle, so TLS/trust settings apply), writes
  per-phase `.sql` files plus a combined script to an artifacts folder, and
  (unless `DryRun`) applies the combined script to the target. Creates the
  target database with `CREATE DATABASE IF NOT EXISTS` at the top of the
  combined script. Honours `DryRun` (default `$true`). Accepts
  `-IncludeObjectTypes` for narrow runs; defaults come from
  `Get-SqlCpySchemaOnlyObjectTypeDefaults`. The Tables phase is fast
  in-process by default (`SchemaOnlyTableScriptMode = 'InProcess'`) with
  before/after per-table logging, a pre-computed `object_id` map (so log
  lines show real IDs, not 0), parent-side phase-start/phase-done/combine
  timing lines, and an exclusion list (`SchemaOnlyExcludeTables`). Switch
  to `SchemaOnlyTableScriptMode = 'Isolated'` to get
  `SchemaOnlyTableScriptTimeoutSeconds` (default 300s) enforced via a
  child PowerShell runspace — significantly slower, best-effort cancel.
- **`Export-SqlCpySchemaOnlyDatabase`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Pure scripting pass. Given an open connection and a database name, emits
  a per-phase `.sql` file for every enabled object category plus a combined
  `<db>.sql`. Separated from the orchestrator so tests and callers can stub
  the database object. Also writes `<output>/<db>/_skipped_tables.txt`
  recording any table excluded, timed out, or errored in the Tables phase.
  The standalone `14_FullTextCatalogs` phase is muted by default — the
  orchestrator removes `FullTextCatalogs` from the include list unless
  `SchemaOnlyIncludeFullTextCatalogs = $true`, and when muted the phase is
  skipped silently (no `[skip]` log line). Full-text **indexes** are still
  scripted inline with their parent tables via the `FullTextIndexes`
  scripting option.
- **`New-SqlCpySchemaOnlyScriptingOption`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Builds an SMO `ScriptingOptions` (or dbatools `New-DbaScriptingOption`
  wrapper) configured for schema + DRI + indexes + DML/FullText triggers, with
  **`ScriptData = $false`**, **`Permissions = $false`**,
  **`IncludeDatabaseRoleMemberships = $false`**, and **`LoginSid = $false`**.
  Only sets properties that exist on the current SMO variant, so it tolerates
  minor SQL version differences.
- **`Get-SqlCpySchemaOnlyObjectTypeDefaults`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Returns the canonical list of SMO object categories that the schema-only
  copy includes by default.
- **`Get-SqlCpySchemaOnlySecurityExcludedTypes`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Returns the categories that the schema-only copy must **never** script
  (users/roles/permissions/certificates/etc.). Used by the Defaults list and
  by tests to prove no security category leaks into the include list.
- **`Get-SqlCpySchemaOnlyScriptPhases`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Returns the ordered `Phase / SmoProperty / Description` tuples that
  control the per-phase scripting walk. Order is dependency-safe: schemas ->
  types/sequences/partitions -> synonyms -> tables (inline PK/UK/CK/FK/indexes/
  DML triggers) -> full-text catalogs -> views -> functions -> procedures ->
  broker queues -> DDL triggers.
- **`Get-SqlCpySchemaOnlyInlineOnlyTypes`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Returns the object types (`ForeignKeys`, `Indexes`, `Triggers` on tables,
  `FullTextIndexes`) that are scripted inline with their parent and therefore
  have no dedicated phase.
- **`Get-SqlCpySchemaOnlySystemSchemaNames`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Returns the schema names the Schemas phase must never emit (`dbo`,
  `guest`, `INFORMATION_SCHEMA`, `sys`, and the `db_*` fixed-role schemas).
  The Schemas phase filter uses this list.
- **`Get-SqlCpySchemaScriptLines`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Per-schema scripting helper. Tries `$schema.Script($options)`, then
  `$schema.Script()` with no args, then falls back to a manual
  `CREATE SCHEMA [name] AUTHORIZATION [dbo]` statement built from the
  schema name. Exists because SMO's generic `.Script($options)` path was
  observed to fail on SQL 2022 / dbatools 2.1.24 (e.g. `dwcontrol`) with
  `Script failed for Schema 'A00'.` even when the schema has a plain `dbo`
  owner and interactive `.Script()` works. Takes a `-WarningSink`
  scriptblock so the caller can route the fallback notice through
  `Write-SqlCpyWarning` with the original SMO error detail.
- **`Format-SqlCpySchemaCreateStatement`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Emits a guarded, re-runnable
  `IF SCHEMA_ID(N'…') IS NULL EXEC(N'CREATE SCHEMA […] AUTHORIZATION [dbo]')`
  batch. Escapes single quotes (for the T-SQL literal and the nested EXEC
  literal) and right brackets (for the quoted identifier). Always uses
  `AUTHORIZATION [dbo]` because the schema-only copy intentionally ignores
  security; replaying the source owner would require principals that by
  design are not being copied.
- **`Test-SqlCpySchemaOnlyTableExcluded`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Pure predicate used by the Tables phase to decide whether a table matches
  `SchemaOnlyExcludeTables`. Accepts `[schema].[table]`, `schema.table`, bare
  `table` (any schema), or a numeric `object_id`; matching is case-insensitive
  and tolerates bracket characters.
- **`Invoke-SqlCpyScriptObjectWithTimeout`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Runs `$item.Script($options)` in an isolated PowerShell runspace with a
  wall-clock timeout. Returns the script lines on success, throws
  `Script call timed out after Ns` on deadline. Used by the Tables phase
  only when `SchemaOnlyTableScriptMode = 'Isolated'` (opt-in) so a hung
  single-table SMO call does not block the whole copy. Best-effort:
  managed code is stopped cleanly but native SqlClient socket reads may
  linger until process teardown. Not used in the default `'InProcess'`
  mode.
- **`Resolve-SqlCpySchemaOnlyTableMode`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Normalizes `SchemaOnlyTableScriptMode` strings. Accepts (case-
  insensitive) `InProcess`, `FastPerTable`, legacy `PerTable`,
  `Isolated`, `Collection`. `InProcess`/`FastPerTable`/`PerTable` all
  normalize to `InProcess`; unknown values fall back to `InProcess`.
  Kept as a pure helper so tests can assert the alias mapping without
  SQL Server.
- **`Get-SqlCpyDatabaseObjectIdMap`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Issues one `sys.tables`/`sys.schemas` query via `Invoke-DbaQuery` and
  returns a hashtable mapping lower-cased `[schema].[table]` to
  `object_id`. The Tables phase uses it as a fallback when `$table.ID` /
  `$table.ObjectId` return 0 so log lines show real object_ids. Returns
  an empty hashtable if `Invoke-DbaQuery` is unavailable or the query
  fails; callers log `object_id=-` in that case.

## Planned (not in this scaffold)

- SSAS migration — see [`docs/SSAS_PLANNED.md`](SSAS_PLANNED.md).
