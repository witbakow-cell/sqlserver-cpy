# Dependencies

This document lists external runtime dependencies for `sqlserver-cpy`.

## PowerShell host

- **PowerShell 5.1** (Windows PowerShell) or **PowerShell 7.2+** on Windows.
- Linux/macOS PowerShell hosts are **not supported** — SMO/AMO/TOM and SSIS catalog access
  rely on Windows-only assemblies.

## PowerShell modules

| Module       | Minimum version | Purpose                                                                              | Install |
|--------------|-----------------|--------------------------------------------------------------------------------------|---------|
| `dbatools`   | 2.1.0           | Primary engine: Agent jobs, logins, schema scripting, server config comparison, etc. | `Install-Module dbatools -Scope CurrentUser` |
| `SqlServer`  | 22.0.0          | Fallback for areas where `dbatools` is incomplete; SSISDB via `Integration Services` provider. | `Install-Module SqlServer -Scope CurrentUser` |
| `Pester`     | 5.5.0           | Optional, only needed to run the repo tests.                                         | `Install-Module Pester -Scope CurrentUser -Force` |

`dbatools` is the **primary** dependency by project decision. Prefer its cmdlets unless you
have a clear reason not to (usually: missing feature, subtle behavior mismatch, or bug).

## Managed assemblies (DLLs)

When falling back from modules to direct SDK use, the following assemblies are expected.
They are not checked into this repository. Obtain them from an official Microsoft source
(SQL Server Feature Pack, NuGet, or a local SQL Server install) and drop them into `lib/`
(gitignored) or rely on GAC registration.

| Area           | Assembly                                           | Typical source |
|----------------|----------------------------------------------------|----------------|
| SMO            | `Microsoft.SqlServer.Smo.dll`                      | SQL Server Shared Management Objects redistributable |
| SMO extended   | `Microsoft.SqlServer.ConnectionInfo.dll`, `Microsoft.SqlServer.Management.Sdk.Sfc.dll`, `Microsoft.SqlServer.SqlEnum.dll` | Same redistributable as SMO |
| SSIS catalog   | `Microsoft.SqlServer.Management.IntegrationServices.dll` | SSIS Feature Pack / `SqlServer` module |
| AMO (SSAS)     | `Microsoft.AnalysisServices.dll`, `Microsoft.AnalysisServices.Core.dll` | AMO redistributable |
| TOM (SSAS tabular) | `Microsoft.AnalysisServices.Tabular.dll`        | AMO redistributable |
| ADOMD.NET      | `Microsoft.AnalysisServices.AdomdClient.dll`       | ADOMD.NET redistributable |

SSAS-related assemblies (AMO, TOM, ADOMD) are listed here because the project scope
includes a planned SSAS extension. They are **not used** by the current scaffold code.

## Optional tools

- **`git`** for version control.
- **`gh`** CLI if you want to run `gh pr create`; not required at runtime.

## Network and permissions

- Network reachability from the machine running the script to both source and target SQL
  Server instances on TCP 1433 (or configured port).
- A Windows or SQL login on each side with permissions appropriate to the task
  (e.g. `sysadmin` for server-level config compare/apply; `ssis_admin` or equivalent
  for SSISDB operations). The scaffold does not attempt to elevate or diagnose
  permission gaps; operations will fail with the provider's native error.

## TLS / certificate trust

Current `dbatools` releases wrap `Microsoft.Data.SqlClient` 4+, which defaults to
`Encrypt=Mandatory` and validates the SQL Server's TLS certificate against the local
trust store. Self-signed or internally issued certs raise:

> "The certificate chain was issued by an authority that is not trusted"

`sqlserver-cpy` exposes three config keys in `config/default.psd1` to control this:

- `EncryptConnection` (default `$true`)
- `TrustServerCertificate` (default `$true`; scaffold/admin convenience - see README for
  the MITM tradeoff and production guidance)
- `ConnectionTimeoutSeconds` (default `15`)

These are applied through a `Connect-DbaInstance` connection object
(`Get-SqlCpyDbaConnection`) that is reused across subsequent `dbatools` calls.
Use the TUI `Preflight` option or call `Test-SqlCpyPreflight` directly to open
(and validate) both endpoints before running migration steps; the resulting
connection objects are cached on the `$Config` hashtable as `_SourceConnection`
/ `_TargetConnection` and retrieved via `Get-SqlCpyCachedConnection`.

### dbatools parameter compatibility

Not every `dbatools` cmdlet accepts the same set of connection parameters. In
the 2.x line:

- `Connect-DbaInstance`, `Invoke-DbaQuery` accept `-TrustServerCertificate`,
  `-EncryptConnection`, `-ConnectionTimeout`.
- `Get-DbaSpConfigure`, `Copy-DbaSpConfigure`, `Get-DbaLogin`, `Copy-DbaLogin`,
  `Get-DbaAgentJob`, `Copy-DbaAgentJob`, `Copy-DbaSsisCatalog` do **not** expose
  `-TrustServerCertificate` or `-ConnectionTimeout`. They **do** accept an
  already-open `Connect-DbaInstance` connection object as `-SqlInstance` /
  `-Source` / `-Destination`, which carries those settings.

Because of this asymmetry, a version of the scaffold that dynamically filtered
its splat against `Get-Command` correctly avoided
`A parameter cannot be found that matches parameter name 'ConnectionTimeout'.`
but also silently dropped `TrustServerCertificate` on Get-DbaSpConfigure, which
resurfaced _"The certificate chain was issued by an authority that is not
trusted"_ on `chbbbid2`.

`sqlserver-cpy` therefore applies `TrustServerCertificate = $true` (and
`EncryptConnection`, `ConnectionTimeoutSeconds`) through `Connect-DbaInstance`
**once** via `Get-SqlCpyDbaConnection`. Downstream cmdlets receive that
connection object via `Get-SqlCpyInstanceSplat` (for `-SqlInstance`) or
`Get-SqlCpyCopySplat -SourceConnection / -DestinationConnection` (for `-Source`
/ `-Destination`). When a connection object is in play, trust/encrypt flags are
omitted from the command-level splat - they are already baked in.

The legacy raw-name helpers (`Get-SqlCpyConnectionSplat`, `Get-SqlCpyCopySplat`
without connection objects) still work and still take an optional
`-CommandName` to filter against `Get-Command`:

1. If the command accepts `-ConnectionTimeout`, the configured
   `ConnectionTimeoutSeconds` is forwarded under that name.
2. If the command accepts an alternate name (currently `-ConnectTimeout` or
   `-StatementTimeout`), it is routed there instead.
3. If the command accepts none, the timeout is **silently skipped** for that call.
   Keep `ConnectionTimeoutSeconds` in config — it is still honoured by
   `Connect-DbaInstance` / `Invoke-DbaQuery` and by the preflight check.

If you find a `dbatools` cmdlet that exposes a timeout under yet another name, add it
to the `Candidates` list inside `Get-SqlCpyConnectionSplat` (`src/SqlServerCpy/Public/Connection.ps1`)
and it will be routed automatically.
