<#
.SYNOPSIS
    Root launcher for sqlserver-cpy. Imports the module and starts the interactive TUI.

.DESCRIPTION
    Run this from the repository root in a PowerShell 5.1+ or 7+ session on Windows.
    Requires the dbatools and SqlServer modules (see DEPENDENCIES.md).

.PARAMETER ConfigPath
    Optional explicit path to a default config file. Defaults to ./config/default.psd1.

.EXAMPLE
    ./Start-SqlServerCopy.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

$modulePath = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/SqlServerCpy.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Module manifest not found at $modulePath"
}

Import-Module -Name $modulePath -Force

if ($ConfigPath) {
    Start-SqlCpyInteractive -ConfigPath $ConfigPath
} else {
    Start-SqlCpyInteractive
}
