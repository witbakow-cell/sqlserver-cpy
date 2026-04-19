# SqlServerCpy module loader.
# Dot-sources every .ps1 under Public/ and exports the functions declared in the manifest.

$ErrorActionPreference = 'Stop'

$publicRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Public'

if (Test-Path -LiteralPath $publicRoot) {
    Get-ChildItem -Path $publicRoot -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}
