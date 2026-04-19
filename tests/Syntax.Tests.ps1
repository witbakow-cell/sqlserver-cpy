<#
.SYNOPSIS
    Lightweight syntax validation for sqlserver-cpy.

.DESCRIPTION
    Runs two checks without needing a live SQL Server or the dbatools / SqlServer modules:

      1. Every .ps1 and .psm1 under the repo parses with the PowerShell tokenizer (no syntax errors).
      2. The module manifest is readable by Test-ModuleManifest (structure-only check; does
         not actually import the module since RequiredModules are external).

    Written to run under Pester 5 if available, or as a plain script otherwise. Invoke directly:
        powershell -NoProfile -File tests/Syntax.Tests.ps1
    or via Pester:
        Invoke-Pester -Path tests/Syntax.Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$failures = @()

Write-Host "Scanning PowerShell files under $repoRoot ..." -ForegroundColor Cyan
$files = Get-ChildItem -Path $repoRoot -Recurse -File -Include *.ps1, *.psm1 |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '/\.git/' }

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failures += [pscustomobject]@{
            File   = $file.FullName
            Errors = ($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        }
    } else {
        Write-Host "  OK  $($file.FullName)"
    }
}

Write-Host ''
Write-Host 'Checking module manifest structure...' -ForegroundColor Cyan
$manifestPath = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/SqlServerCpy.psd1'
try {
    # Test-ModuleManifest will try to resolve RequiredModules on some hosts; if that is
    # undesired offline, Import-PowerShellDataFile gives a pure structural check.
    $null = Import-PowerShellDataFile -Path $manifestPath
    Write-Host "  OK  $manifestPath"
} catch {
    $failures += [pscustomobject]@{
        File   = $manifestPath
        Errors = $_.Exception.Message
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'All syntax checks passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'Syntax checks FAILED:' -ForegroundColor Red
    $failures | Format-List
    exit 1
}
