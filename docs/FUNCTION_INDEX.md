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

- **`Get-SqlCpyConnectionSplat`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Builds a hashtable of connection-security parameters (`SqlInstance`,
  `EncryptConnection`, `TrustServerCertificate`, `SqlCredential`, and a timeout if
  supported) filtered to match the parameter set of the target cmdlet. Pass
  `-CommandName` with the dbatools cmdlet you are about to invoke (e.g.
  `Get-DbaSpConfigure`, `Get-DbaLogin`, `Invoke-DbaQuery`). Without
  `-CommandName`, the splat omits any command-version-sensitive parameter to stay
  safe.
- **`Get-SqlCpyCopySplat`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Same idea for `Copy-Dba*` cmdlets that take `-Source` / `-Destination`. Also
  respects `-CommandName` filtering.
- **`Get-SqlCpyCommandParameter`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Returns the parameter names (and alias map) a given command exposes, via
  `Get-Command`. Supports a `-Simulated` list for tests that must not depend on
  dbatools being installed.
- **`Resolve-SqlCpyParameterName`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Given a parameter-set hashtable and a priority-ordered list of candidate
  names, returns the first name the command actually accepts (parameter or
  alias). Used to route a configured timeout into whatever name the installed
  dbatools version uses.
- **`Get-SqlCpyDbaInstance`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Opens a `Connect-DbaInstance` SMO handle honouring the connection-security config.
  Use this when a downstream cmdlet does not expose `-EncryptConnection` /
  `-TrustServerCertificate`.
- **`Test-SqlCpyPreflight`** (`src/SqlServerCpy/Public/Connection.ps1`)
  — Validates source and target connectivity under the configured TLS settings and
  prints actionable diagnostics for untrusted certificate chains, auth failures,
  network failures, and missing `dbatools`. Returns `$true`/`$false`.
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

## SQL Agent

- **`Invoke-SqlCpyAgentJobCopy`** (`src/SqlServerCpy/Public/AgentJobs.ps1`)
  — Copies Agent jobs via `Copy-DbaAgentJob`. Honours DryRun.

## SSIS catalog

- **`Invoke-SqlCpySsisCatalogCopy`** (`src/SqlServerCpy/Public/SsisCatalog.ps1`)
  — Copies SSISDB folders, projects, environments, references via `Copy-DbaSsisCatalog`.
  Honours DryRun. See the function's help block for caveats on sensitive environment
  variables.

## Schema-only database copy

- **`Invoke-SqlCpySchemaOnlyDatabaseCopy`** (`src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1`)
  — Scripts objects from source databases and applies them to the target without data.
  Honours DryRun.

## Planned (not in this scaffold)

- SSAS migration — see [`docs/SSAS_PLANNED.md`](SSAS_PLANNED.md).
