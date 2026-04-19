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
