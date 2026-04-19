# Function index

This is a quick-browse index of every public function exported by the `SqlServerCpy`
module. Each function also carries a comment-based help block in its source file for
`Get-Help <Name>` use. Source file is shown in parentheses; click through on GitHub to
read the help block.

## Configuration

- **`Get-SqlCpyConfig`** (`src/SqlServerCpy/Public/Config.ps1`)
  — Loads `config/default.psd1` and merges any `config/local.psd1` on top. Returns a
  hashtable containing at least `SourceServer`, `TargetServer`, `DryRun`, `Areas`.
- **`Get-SqlCpyRepoRoot`** (`src/SqlServerCpy/Public/Config.ps1`)
  — Returns the repository root, inferred from the module's location.

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
