# SSAS migration - planned extension

SQL Server Analysis Services (SSAS) migration is **out of scope for the initial
scaffold** but is planned as an extension once the core SQL Server migration
surface is validated.

This document records the intended shape so the work is easy to pick up later.

## Targets

- **Tabular mode** databases (model.bim + deployed database).
- **Multidimensional mode** databases.
- Server-level role memberships and connection settings where portable.

## Dependencies

The SSAS work will use direct SDK access because `dbatools` and the `SqlServer`
module coverage is partial for SSAS admin tasks.

- `Microsoft.AnalysisServices.dll` + `Microsoft.AnalysisServices.Core.dll` (AMO)
- `Microsoft.AnalysisServices.Tabular.dll` (TOM - for tabular models)
- `Microsoft.AnalysisServices.AdomdClient.dll` (ADOMD.NET - for query-time checks)

These are listed in `DEPENDENCIES.md` so operators can stage the DLLs ahead of time.

## Planned function shape

A future file `src/SqlServerCpy/Public/Ssas.ps1` would expose:

- `Invoke-SqlCpySsasDatabaseCopy` — copy a database from source SSAS to target
  SSAS. For tabular, serialize the model via TOM (`TOM.JsonSerializer`) and
  deploy on the target with `TOM.Server.Databases.Add` + `Update`. For
  multidimensional, use AMO's `Server.Backup` / `Server.Restore`.
- `Invoke-SqlCpySsasServerConfigCompare` — compare SSAS server properties
  (memory limits, threading, caching) using AMO `Server.ServerProperties`.
- `Invoke-SqlCpySsasRoleCopy` — copy role definitions and member lists.

## Open questions for live validation

- Connection string handling for data sources when server names differ between
  source and target environments. A remap table in config seems appropriate.
- Impersonation credentials on data sources: cannot be round-tripped via TOM
  and must be re-entered on the target or driven from a secret store.
- Partition strategy for large tabular models — avoid process-full on first
  deployment when data volume is large; prefer deploy-metadata-only then
  trigger a controlled process.

## Why not now

The initial scaffold targets the operator's immediate need: moving relational
assets between SQL Server instances. SSAS has a distinct deployment model and
its own validation surface. Shipping a half-implemented SSAS path inside this
scaffold would invite misuse; a separate, validated extension is safer.
