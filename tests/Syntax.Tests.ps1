<#
.SYNOPSIS
    Lightweight syntax and configuration validation for sqlserver-cpy.

.DESCRIPTION
    Runs the following checks without needing a live SQL Server or the dbatools /
    SqlServer modules:

      1. Every .ps1 and .psm1 under the repo parses with the PowerShell tokenizer
         (no syntax errors).
      2. The module manifest is readable by Import-PowerShellDataFile
         (structure-only check; does not actually import the module since
         RequiredModules are external).
      3. config/default.psd1 declares the connection-security keys that the
         centralized connection helpers rely on.
      4. The module manifest exports the new connection/preflight functions.

    Written to run as a plain script. Invoke directly:
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
$manifest = $null
try {
    $manifest = Import-PowerShellDataFile -Path $manifestPath
    Write-Host "  OK  $manifestPath"
} catch {
    $failures += [pscustomobject]@{
        File   = $manifestPath
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Checking config/default.psd1 contains connection-security keys...' -ForegroundColor Cyan
$cfgPath = Join-Path -Path $repoRoot -ChildPath 'config/default.psd1'
try {
    $cfg = Import-PowerShellDataFile -Path $cfgPath
    $requiredKeys = @('EncryptConnection', 'TrustServerCertificate', 'ConnectionTimeoutSeconds',
                      'SourceServer', 'TargetServer', 'DryRun', 'Areas')
    foreach ($k in $requiredKeys) {
        if (-not $cfg.ContainsKey($k)) {
            $failures += [pscustomobject]@{
                File   = $cfgPath
                Errors = "Missing required key: $k"
            }
        } else {
            Write-Host "  OK  key '$k' = $($cfg[$k])"
        }
    }
} catch {
    $failures += [pscustomobject]@{
        File   = $cfgPath
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Checking manifest exports the new connection/preflight functions...' -ForegroundColor Cyan
if ($manifest) {
    $mustExport = @(
        'Get-SqlCpyConnectionSplat'
        'Get-SqlCpyCopySplat'
        'Get-SqlCpyDbaInstance'
        'Test-SqlCpyPreflight'
        'Get-SqlCpyConnectionErrorHint'
        'Get-SqlCpyCommandParameter'
        'Resolve-SqlCpyParameterName'
    )
    foreach ($fn in $mustExport) {
        if ($manifest.FunctionsToExport -notcontains $fn) {
            $failures += [pscustomobject]@{
                File   = $manifestPath
                Errors = "FunctionsToExport missing: $fn"
            }
        } else {
            Write-Host "  OK  exports $fn"
        }
    }
}

Write-Host ''
Write-Host 'Dot-sourcing Connection.ps1 in isolation and probing splat helper...' -ForegroundColor Cyan
$connFile = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/Public/Connection.ps1'
try {
    # Provide minimal stubs so the file can be dot-sourced without the logging module.
    function Write-SqlCpyStep    { param($Message) Write-Host "[stub STEP] $Message" }
    function Write-SqlCpyInfo    { param($Message) Write-Host "[stub INFO] $Message" }
    function Write-SqlCpyWarning { param($Message) Write-Host "[stub WARN] $Message" }
    function Write-SqlCpyError   { param($Message) Write-Host "[stub ERR ] $Message" }

    . $connFile

    $probeCfg = @{
        EncryptConnection        = $true
        TrustServerCertificate   = $true
        ConnectionTimeoutSeconds = 15
    }

    # ---- Case 1: no command name + dbatools absent -> conservative splat.
    # The bug this guards against: scaffold v0.1 always emitted
    # -ConnectionTimeout, which fails on cmdlets that do not expose it.
    $splat = Get-SqlCpyConnectionSplat -Config $probeCfg -Server 'chbbbid2'
    foreach ($k in 'SqlInstance', 'EncryptConnection', 'TrustServerCertificate') {
        if (-not $splat.ContainsKey($k)) {
            $failures += [pscustomobject]@{
                File   = $connFile
                Errors = "Get-SqlCpyConnectionSplat (no -CommandName) missing universal key: $k"
            }
        } else {
            Write-Host "  OK  splat (no cmd) has $k = $($splat[$k])"
        }
    }
    if ($splat.ContainsKey('ConnectionTimeout')) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Get-SqlCpyConnectionSplat (no -CommandName) should NOT include ConnectionTimeout by default; got $($splat.ConnectionTimeout)"
        }
    } else {
        Write-Host "  OK  splat (no cmd) correctly omitted ConnectionTimeout"
    }

    # ---- Case 2: simulated command that SUPPORTS ConnectionTimeout.
    $supported = @('SqlInstance','SqlCredential','EncryptConnection','TrustServerCertificate','ConnectionTimeout')
    $splat2 = Get-SqlCpyConnectionSplat -Config $probeCfg -Server 'chbbbid2' -SimulatedParameters $supported
    if (-not $splat2.ContainsKey('ConnectionTimeout') -or $splat2.ConnectionTimeout -ne 15) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Simulated command supporting ConnectionTimeout should include it; got $($splat2.ConnectionTimeout)"
        }
    } else {
        Write-Host "  OK  simulated-supported splat has ConnectionTimeout = $($splat2.ConnectionTimeout)"
    }

    # ---- Case 3: simulated command that does NOT expose ConnectionTimeout
    # (the dbatools 2.x Get-DbaSpConfigure / Copy-Dba* case -> root cause of
    #  "A parameter cannot be found that matches parameter name 'ConnectionTimeout'").
    $noTimeout = @('SqlInstance','SqlCredential','EncryptConnection','TrustServerCertificate')
    $splat3 = Get-SqlCpyConnectionSplat -Config $probeCfg -Server 'chbbbid2' -SimulatedParameters $noTimeout
    if ($splat3.ContainsKey('ConnectionTimeout')) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Simulated command WITHOUT ConnectionTimeout must not receive it; got $($splat3.ConnectionTimeout)"
        }
    } else {
        Write-Host "  OK  simulated-unsupported splat correctly omitted ConnectionTimeout"
    }
    foreach ($k in 'SqlInstance','EncryptConnection','TrustServerCertificate') {
        if (-not $splat3.ContainsKey($k)) {
            $failures += [pscustomobject]@{
                File   = $connFile
                Errors = "Simulated-unsupported splat missing universal key $k"
            }
        }
    }

    # ---- Case 4: simulated command that only speaks -ConnectTimeout alias.
    $altName = @('SqlInstance','SqlCredential','EncryptConnection','TrustServerCertificate','ConnectTimeout')
    $splat4 = Get-SqlCpyConnectionSplat -Config $probeCfg -Server 'chbbbid2' -SimulatedParameters $altName
    if (-not $splat4.ContainsKey('ConnectTimeout') -or $splat4.ContainsKey('ConnectionTimeout')) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Alternate-named timeout parameter not routed correctly: keys=$(@($splat4.Keys) -join ',')"
        }
    } else {
        Write-Host "  OK  routed timeout to alternate parameter -ConnectTimeout = $($splat4.ConnectTimeout)"
    }

    # ---- Case 5: Get-SqlCpyCopySplat filters the same way.
    $copyNoTimeout = @('Source','Destination','EncryptConnection','TrustServerCertificate','SourceSqlCredential','DestinationSqlCredential')
    $copySplat = Get-SqlCpyCopySplat -Config $probeCfg -Source 'a' -Destination 'b' -SimulatedParameters $copyNoTimeout
    if ($copySplat.ContainsKey('ConnectionTimeout')) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Get-SqlCpyCopySplat: ConnectionTimeout leaked into splat when command does not accept it"
        }
    } else {
        Write-Host "  OK  Get-SqlCpyCopySplat filtered ConnectionTimeout correctly"
    }

    # ---- Case 6: error-hint maps the parameter-binding message to a helpful string.
    $hint = Get-SqlCpyConnectionErrorHint -Message 'The certificate chain was issued by an authority that is not trusted' -Config $probeCfg
    if (-not $hint) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = 'Get-SqlCpyConnectionErrorHint returned empty for certificate chain message'
        }
    } else {
        Write-Host "  OK  cert-chain hint: $hint"
    }

    $paramHint = Get-SqlCpyConnectionErrorHint -Message "A parameter cannot be found that matches parameter name 'ConnectionTimeout'." -Config $probeCfg
    if ($paramHint -notmatch 'parameter') {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Get-SqlCpyConnectionErrorHint did not map parameter-binding error: $paramHint"
        }
    } else {
        Write-Host "  OK  param-binding hint: $paramHint"
    }
} catch {
    $failures += [pscustomobject]@{
        File   = $connFile
        Errors = $_.Exception.Message
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'All syntax and config checks passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'Checks FAILED:' -ForegroundColor Red
    $failures | Format-List
    exit 1
}
