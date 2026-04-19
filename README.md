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
`-ConnectionTimeout` exists on `Connect-DbaInstance` and `Invoke-DbaQuery` but **not** on
`Get-DbaSpConfigure`, `Copy-DbaSpConfigure`, `Copy-DbaLogin`, `Copy-DbaAgentJob`, or
`Copy-DbaSsisCatalog` in the 2.x line. An earlier version of the scaffold added
`-ConnectionTimeout` to every splat, which produced this error on the very first
menu action:

```
ERROR  Source connection failed: A parameter cannot be found that matches parameter
name 'ConnectionTimeout'.
```

The splat helpers now take an optional `-CommandName` and filter the emitted hashtable
against the real parameter set of that cmdlet (via `Get-Command`). If the command does
not expose any timeout parameter, the timeout is silently skipped for that call; your
configured `ConnectionTimeoutSeconds` is still honoured by `Connect-DbaInstance` and
`Invoke-DbaQuery`, including during Preflight. There is nothing you need to change in
config — keep `ConnectionTimeoutSeconds` set to whatever suits your environment.

If you add a new migration function, pass `-CommandName` to `Get-SqlCpyConnectionSplat`
/ `Get-SqlCpyCopySplat` so the same filtering applies. See
[`DEPENDENCIES.md`](DEPENDENCIES.md#dbatools-parameter-compatibility) for details and
the list of parameter-name candidates the helpers try (`ConnectionTimeout`,
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
