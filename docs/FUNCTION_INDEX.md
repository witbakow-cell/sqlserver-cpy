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

- **`Invoke-SqlCpySchemaOnlyDatabaseCopy`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Scripts objects from source databases and applies them to the target without data.
  Honours DryRun.

## Planned (not in this scaffold)

- SSAS migration — see [`docs/SSAS_PLANNED.md`](SSAS_PLANNED.md).
