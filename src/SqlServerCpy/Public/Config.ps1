function Get-SqlCpyConfig {
<#
.SYNOPSIS
    Loads sqlserver-cpy configuration from a .psd1 file, optionally merged with a local override.

.DESCRIPTION
    Reads config/default.psd1 from the repository (or a caller-supplied path) and, if
    config/local.psd1 exists, merges its top-level keys on top. Returns a hashtable.

    The returned object always contains at least: SourceServer, TargetServer, DryRun, Areas.

.PARAMETER DefaultPath
    Path to the default configuration file. Defaults to '<repo>/config/default.psd1'.

.PARAMETER LocalPath
    Path to an optional local override file. Defaults to '<repo>/config/local.psd1'.

.EXAMPLE
    $cfg = Get-SqlCpyConfig
    $cfg.SourceServer   # -> 'chbbbid2'

.NOTES
    The merge is shallow: top-level keys from local.psd1 replace those from default.psd1.
    Nested hashtables (e.g. Areas) are replaced as a whole rather than deep-merged.
#>
    [CmdletBinding()]
    param(
        [string]$DefaultPath,
        [string]$LocalPath
    )

    if (-not $DefaultPath) {
        $DefaultPath = Join-Path -Path (Get-SqlCpyRepoRoot) -ChildPath 'config/default.psd1'
    }
    if (-not $LocalPath) {
        $LocalPath = Join-Path -Path (Get-SqlCpyRepoRoot) -ChildPath 'config/local.psd1'
    }

    if (-not (Test-Path -LiteralPath $DefaultPath)) {
        throw "Default config file not found: $DefaultPath"
    }

    $config = Import-PowerShellDataFile -Path $DefaultPath

    if (Test-Path -LiteralPath $LocalPath) {
        $local = Import-PowerShellDataFile -Path $LocalPath
        foreach ($key in $local.Keys) {
            $config[$key] = $local[$key]
        }
    }

    return $config
}

function Get-SqlCpyRepoRoot {
<#
.SYNOPSIS
    Returns the repository root directory, inferred from the module's location.

.DESCRIPTION
    The module ships under '<repo>/src/SqlServerCpy'. This helper walks two levels up
    from $PSScriptRoot so config/, docs/, tests/ can be located without hard-coded paths.
#>
    [CmdletBinding()]
    param()

    # $PSScriptRoot here is '<repo>/src/SqlServerCpy/Public' when dot-sourced from the module.
    $public = $PSScriptRoot
    if (-not $public) { return (Get-Location).Path }
    return (Resolve-Path (Join-Path -Path $public -ChildPath '..\..\..')).Path
}
