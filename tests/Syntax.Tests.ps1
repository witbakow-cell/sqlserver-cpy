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
                      'SourceServer', 'TargetServer', 'DryRun', 'Areas',
                      'LoginSkipPrefixes', 'SourceSsrsUri', 'TargetSsrsUri',
                      'CopySsrsFolders','CopySsrsReports','CopySsrsDatasets',
                      'CopySsrsDataSources','CopySsrsResources','CopySsrsSecurity',
                      'CopySsrsRoles','CopySsrsSubscriptions','CopySsrsSchedules',
                      'CopySsrsKpis')
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

    # LoginSkipPrefixes must include the four user-mandated prefixes.
    $mustHavePrefixes = @('NT AUTHORITY','NT SERVICE','BUILTIN','ADIS')
    $have = @()
    if ($cfg.ContainsKey('LoginSkipPrefixes') -and $cfg.LoginSkipPrefixes) {
        $have = @($cfg.LoginSkipPrefixes)
    }
    foreach ($p in $mustHavePrefixes) {
        if ($have -notcontains $p) {
            $failures += [pscustomobject]@{
                File   = $cfgPath
                Errors = "LoginSkipPrefixes missing required prefix: $p"
            }
        } else {
            Write-Host "  OK  LoginSkipPrefixes contains '$p'"
        }
    }

    # Areas should have the new SsrsCatalog flag.
    if (-not $cfg.Areas.ContainsKey('SsrsCatalog')) {
        $failures += [pscustomobject]@{
            File   = $cfgPath
            Errors = "Areas missing SsrsCatalog flag"
        }
    } else {
        Write-Host "  OK  Areas.SsrsCatalog = $($cfg.Areas.SsrsCatalog)"
    }
} catch {
    $failures += [pscustomobject]@{
        File   = $cfgPath
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Checking manifest exports SSRS + login-skip functions...' -ForegroundColor Cyan
if ($manifest) {
    $ssrsExports = @(
        'Invoke-SqlCpySsrsCopy'
        'Get-SqlCpySsrsProxy'
        'Get-SqlCpySsrsRestBase'
        'Get-SqlCpySsrsCatalogItems'
        'New-SqlCpySsrsFolderTree'
        'Copy-SqlCpySsrsCatalogItem'
        'Copy-SqlCpySsrsItemPolicies'
        'Copy-SqlCpySsrsRoles'
        'Copy-SqlCpySsrsSchedules'
        'Copy-SqlCpySsrsSubscriptions'
        'Test-SqlCpyLoginSkipped'
    )
    foreach ($fn in $ssrsExports) {
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
Write-Host 'Dot-sourcing Logins.ps1 and probing Test-SqlCpyLoginSkipped...' -ForegroundColor Cyan
$loginsFile = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/Public/Logins.ps1'
try {
    . $loginsFile

    $prefixes = @('NT AUTHORITY','NT SERVICE','BUILTIN','ADIS')

    $cases = @(
        @{ Name = 'NT AUTHORITY\SYSTEM';               Expected = $true  }
        @{ Name = 'NT SERVICE\MSSQL$INST';             Expected = $true  }
        @{ Name = 'BUILTIN\Administrators';            Expected = $true  }
        @{ Name = 'ADIS\sqlagent';                     Expected = $true  }
        @{ Name = 'ADIS_TeamA_ReadOnly';               Expected = $true  }
        @{ Name = 'MYDOMAIN\BUILTIN\Administrators';   Expected = $true  }
        @{ Name = 'nt authority\network service';      Expected = $true  }
        @{ Name = 'MYDOMAIN\alice';                    Expected = $false }
        @{ Name = 'sa';                                Expected = $false }
        @{ Name = '';                                  Expected = $false }
        @{ Name = 'ntauthority';                       Expected = $false }
        @{ Name = 'ADISON\bob';                        Expected = $false }
    )

    foreach ($c in $cases) {
        $got = Test-SqlCpyLoginSkipped -LoginName $c.Name -SkipPrefixes $prefixes
        if ($got -ne $c.Expected) {
            $failures += [pscustomobject]@{
                File   = $loginsFile
                Errors = "Test-SqlCpyLoginSkipped('{0}') = {1}, expected {2}" -f $c.Name, $got, $c.Expected
            }
        } else {
            Write-Host ("  OK  Test-SqlCpyLoginSkipped('{0}') = {1}" -f $c.Name, $got)
        }
    }

    # Empty / null prefix list must never skip anything.
    if (Test-SqlCpyLoginSkipped -LoginName 'BUILTIN\Administrators' -SkipPrefixes @()) {
        $failures += [pscustomobject]@{
            File   = $loginsFile
            Errors = "Test-SqlCpyLoginSkipped must return false when SkipPrefixes is empty."
        }
    } else {
        Write-Host "  OK  Empty SkipPrefixes -> no skip"
    }
} catch {
    $failures += [pscustomobject]@{
        File   = $loginsFile
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Checking Ssrs.ps1 parses and Get-SqlCpySsrsRestBase behaves...' -ForegroundColor Cyan
$ssrsFile = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/Public/Ssrs.ps1'
try {
    . $ssrsFile
    $rest1 = Get-SqlCpySsrsRestBase -Uri 'http://chbbbid2/ReportServer'
    if ($rest1 -ne 'http://chbbbid2/Reports/api/v2.0') {
        $failures += [pscustomobject]@{
            File   = $ssrsFile
            Errors = "Get-SqlCpySsrsRestBase derived '$rest1' from ReportServer URL."
        }
    } else {
        Write-Host "  OK  REST base = $rest1"
    }
    $rest2 = Get-SqlCpySsrsRestBase -Uri 'https://reports.example.com:8080/ReportServer/'
    if ($rest2 -notmatch '^https://reports\.example\.com:8080/Reports/api/v2\.0$') {
        $failures += [pscustomobject]@{
            File   = $ssrsFile
            Errors = "Get-SqlCpySsrsRestBase derived '$rest2' for HTTPS URL."
        }
    } else {
        Write-Host "  OK  REST base (https) = $rest2"
    }
} catch {
    $failures += [pscustomobject]@{
        File   = $ssrsFile
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Checking manifest exports the new connection/preflight functions...' -ForegroundColor Cyan
if ($manifest) {
    $mustExport = @(
        'Get-SqlCpyConnectionSplat'
        'Get-SqlCpyCopySplat'
        'Get-SqlCpyInstanceSplat'
        'Get-SqlCpyDbaConnection'
        'Get-SqlCpyDbaInstance'
        'Get-SqlCpyCachedConnection'
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

    # ---- Case 7: Get-SqlCpyInstanceSplat passes the connection object as
    # -SqlInstance and DOES NOT attach TrustServerCertificate / EncryptConnection
    # (those are baked into the connection, and Get-DbaSpConfigure / Get-DbaLogin
    # do not expose them anyway). This is the core of the
    # "certificate chain not trusted" fix.
    $fakeConn = [pscustomobject]@{ Name = 'chbbbid2'; VersionString = '15.0.0.0' }
    $instSplat = Get-SqlCpyInstanceSplat -Config $probeCfg -Connection $fakeConn -SimulatedParameters @('SqlInstance')
    if (-not $instSplat.ContainsKey('SqlInstance')) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = 'Get-SqlCpyInstanceSplat did not set -SqlInstance to the connection object.'
        }
    } elseif (-not [object]::ReferenceEquals($instSplat.SqlInstance, $fakeConn)) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = 'Get-SqlCpyInstanceSplat set -SqlInstance but not to the supplied connection object.'
        }
    } else {
        Write-Host "  OK  instance splat carries the connection object as -SqlInstance"
    }
    foreach ($forbidden in 'TrustServerCertificate','EncryptConnection') {
        if ($instSplat.ContainsKey($forbidden)) {
            $failures += [pscustomobject]@{
                File   = $connFile
                Errors = "Get-SqlCpyInstanceSplat must not emit -$forbidden when using a connection object (it is baked in)."
            }
        } else {
            Write-Host "  OK  instance splat correctly omits -$forbidden"
        }
    }

    # ---- Case 8: instance splat routes a timeout when the target command exposes one.
    $instTimed = Get-SqlCpyInstanceSplat -Config $probeCfg -Connection $fakeConn -SimulatedParameters @('SqlInstance','ConnectionTimeout')
    if ($instTimed.ConnectionTimeout -ne 15) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Get-SqlCpyInstanceSplat should route ConnectionTimeout when the command supports it; got $($instTimed.ConnectionTimeout)"
        }
    } else {
        Write-Host "  OK  instance splat routed ConnectionTimeout when supported"
    }

    # ---- Case 9: Get-SqlCpyCopySplat with connection objects substitutes them
    # into -Source / -Destination and drops command-level trust flags.
    $srcC = [pscustomobject]@{ Role = 'src' }
    $dstC = [pscustomobject]@{ Role = 'dst' }
    $copyConnSplat = Get-SqlCpyCopySplat -Config $probeCfg -SourceConnection $srcC -DestinationConnection $dstC -SimulatedParameters @('Source','Destination','EncryptConnection','TrustServerCertificate','SourceSqlCredential','DestinationSqlCredential')
    if (-not [object]::ReferenceEquals($copyConnSplat.Source, $srcC) -or -not [object]::ReferenceEquals($copyConnSplat.Destination, $dstC)) {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = "Get-SqlCpyCopySplat did not route connection objects into Source/Destination."
        }
    } else {
        Write-Host "  OK  copy splat put connection objects into -Source/-Destination"
    }
    foreach ($forbidden in 'TrustServerCertificate','EncryptConnection') {
        if ($copyConnSplat.ContainsKey($forbidden)) {
            $failures += [pscustomobject]@{
                File   = $connFile
                Errors = "Get-SqlCpyCopySplat with connection objects must not emit -$forbidden."
            }
        } else {
            Write-Host "  OK  copy-with-connections splat correctly omits -$forbidden"
        }
    }

    # ---- Case 10: raw-name call still emits trust/encrypt flags for backward
    # compatibility with callers that have not yet switched to connection objects.
    $copyRawSplat = Get-SqlCpyCopySplat -Config $probeCfg -Source 'a' -Destination 'b' -SimulatedParameters @('Source','Destination','EncryptConnection','TrustServerCertificate')
    foreach ($expected in 'TrustServerCertificate','EncryptConnection') {
        if (-not $copyRawSplat.ContainsKey($expected)) {
            $failures += [pscustomobject]@{
                File   = $connFile
                Errors = "Get-SqlCpyCopySplat raw-name path dropped $expected; cfg has it set."
            }
        }
    }
    Write-Host "  OK  copy splat raw-name path still carries trust/encrypt"

    # ---- Case 11: ServerConfig.ps1 uses the cached connection helper, i.e.
    # the Compare step asks for a connection object rather than building a
    # raw -SqlInstance string splat. If this regresses we would lose trust
    # on Get-DbaSpConfigure again.
    $srvCfgPath = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/Public/ServerConfig.ps1'
    $srvCfgText = Get-Content -LiteralPath $srvCfgPath -Raw
    if ($srvCfgText -notmatch 'Get-SqlCpyCachedConnection' -or $srvCfgText -notmatch 'Get-SqlCpyInstanceSplat') {
        $failures += [pscustomobject]@{
            File   = $srvCfgPath
            Errors = 'ServerConfig.ps1 must obtain Get-DbaSpConfigure input via Get-SqlCpyCachedConnection + Get-SqlCpyInstanceSplat (connection-object path) so TrustServerCertificate applies.'
        }
    } else {
        Write-Host "  OK  ServerConfig uses connection-object helpers"
    }

    # ---- Case 12: Test-SqlCpyPreflight caches connection objects on Config so
    # Compare/Apply reuse exactly the same trust decision.
    $preflightText = (Get-Content -LiteralPath $connFile -Raw)
    if ($preflightText -notmatch '_SourceConnection' -or $preflightText -notmatch '_TargetConnection') {
        $failures += [pscustomobject]@{
            File   = $connFile
            Errors = 'Test-SqlCpyPreflight must cache connection objects as $Config._SourceConnection / $Config._TargetConnection for downstream reuse.'
        }
    } else {
        Write-Host "  OK  Preflight caches connection objects on Config"
    }
} catch {
    $failures += [pscustomobject]@{
        File   = $connFile
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Dot-sourcing SchemaOnlyDatabase.ps1 and probing scripting defaults...' -ForegroundColor Cyan
$schemaFile = Join-Path -Path $repoRoot -ChildPath 'src/SqlServerCpy/Public/SchemaOnlyDatabase.ps1'
try {
    . $schemaFile

    $defaults = Get-SqlCpySchemaOnlyObjectTypeDefaults
    $mustInclude = @(
        'Schemas','Tables','ForeignKeys','Indexes','Views','StoredProcedures',
        'UserDefinedFunctions','Triggers','Sequences','Synonyms',
        'UserDefinedDataTypes','UserDefinedTableTypes','XmlSchemaCollections',
        'PartitionFunctions','PartitionSchemes','FullTextCatalogs','FullTextIndexes',
        'DatabaseTriggers','Defaults'
    )
    foreach ($t in $mustInclude) {
        if ($defaults -notcontains $t) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "SchemaOnly default object types missing: $t"
            }
        } else {
            Write-Host "  OK  schema-only default includes $t"
        }
    }

    $excluded = Get-SqlCpySchemaOnlySecurityExcludedTypes
    $mustExclude = @('Users','Roles','Permissions','RoleMembership','DatabaseRoles')
    foreach ($t in $mustExclude) {
        if ($excluded -notcontains $t) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "SchemaOnly security-excluded list missing: $t"
            }
        } else {
            Write-Host "  OK  schema-only excludes security type $t"
        }
    }

    # Defaults list must NOT leak any security category.
    foreach ($sec in $excluded) {
        if ($defaults -contains $sec) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "Security category '$sec' leaked into SchemaOnly default includes."
            }
        }
    }

    $phases = Get-SqlCpySchemaOnlyScriptPhases
    if ($phases.Count -lt 10) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Expected >= 10 schema-only phases, got $($phases.Count)"
        }
    } else {
        Write-Host "  OK  schema-only phase count = $($phases.Count)"
    }

    # Phases ordering: Schemas must come before Tables, Tables before Views,
    # Views before StoredProcedures. Foreign keys scripted via DriForeignKeys
    # inline with tables, so we only assert the critical relative order.
    $phaseIndex = @{}
    for ($i = 0; $i -lt $phases.Count; $i++) { $phaseIndex[$phases[$i].Property] = $i }
    $ordering = @(
        @('Schemas','Tables'),
        @('Tables','Views'),
        @('Views','StoredProcedures'),
        @('UserDefinedDataTypes','Tables'),
        @('PartitionFunctions','PartitionSchemes'),
        @('FullTextCatalogs','Views')
    )
    foreach ($pair in $ordering) {
        if ($phaseIndex.ContainsKey($pair[0]) -and $phaseIndex.ContainsKey($pair[1])) {
            if ($phaseIndex[$pair[0]] -ge $phaseIndex[$pair[1]]) {
                $failures += [pscustomobject]@{
                    File = $schemaFile
                    Errors = "SchemaOnly phase order wrong: $($pair[0]) should come before $($pair[1])"
                }
            } else {
                Write-Host "  OK  phase order: $($pair[0]) -> $($pair[1])"
            }
        }
    }

    $inline = Get-SqlCpySchemaOnlyInlineOnlyTypes
    foreach ($t in 'ForeignKeys','Indexes','Triggers','FullTextIndexes') {
        if ($inline -notcontains $t) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "Inline-only list missing: $t"
            }
        } else {
            Write-Host "  OK  inline-only contains $t"
        }
    }

    # New-SqlCpySchemaOnlyScriptingOption must return an object whose flags
    # exclude data + security and include indexes/triggers/DRI when those
    # property names exist on the returned object. We set them on a bare
    # pscustomobject fallback so the check works without SMO installed.
    $probeOpts = New-SqlCpySchemaOnlyScriptingOption
    if (-not $probeOpts) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "New-SqlCpySchemaOnlyScriptingOption returned `$null"
        }
    } else {
        Write-Host "  OK  scripting option object is non-null (type=$($probeOpts.GetType().Name))"
    }

    # Verify the scripting-option builder explicitly sets the critical flags.
    $schemaText = Get-Content -LiteralPath $schemaFile -Raw
    $mustContain = @(
        'ScriptData\s*=\s*\$false'
        'ScriptSchema\s*=\s*\$true'
        'Indexes\s*=\s*\$true'
        'Triggers\s*=\s*\$true'
        'DriForeignKeys\s*=\s*\$true'
        'DriPrimaryKey\s*=\s*\$true'
        'DriChecks\s*=\s*\$true'
        'DriDefaults\s*=\s*\$true'
        'FullTextIndexes\s*=\s*\$true'
        'Permissions\s*=\s*\$false'
        'IncludeDatabaseRoleMemberships\s*=\s*\$false'
        'LoginSid\s*=\s*\$false'
    )
    foreach ($pat in $mustContain) {
        if ($schemaText -notmatch $pat) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "SchemaOnly scripting options missing flag matching: $pat"
            }
        } else {
            Write-Host "  OK  scripting options set: $pat"
        }
    }

    # Body must not issue BCP or INSERT data operations.
    if ($schemaText -match 'Copy-DbaDbTableData|Write-DbaDataTable|bcp\.exe|INSERT\s+INTO') {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "SchemaOnly copy must not invoke any data-movement path."
        }
    } else {
        Write-Host "  OK  no data-movement commands present"
    }
} catch {
    $failures += [pscustomobject]@{
        File = $schemaFile
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Checking config/default.psd1 SchemaOnly keys and manifest exports...' -ForegroundColor Cyan
try {
    $cfg2 = Import-PowerShellDataFile -Path $cfgPath
    foreach ($k in 'SchemaOnlyIncludeObjectTypes','SchemaOnlyExcludeSecurity','SchemaOnlyDatabaseList') {
        if (-not $cfg2.ContainsKey($k)) {
            $failures += [pscustomobject]@{
                File = $cfgPath
                Errors = "Missing SchemaOnly config key: $k"
            }
        } else {
            Write-Host "  OK  config has $k"
        }
    }
    if ($cfg2.SchemaOnlyExcludeSecurity -ne $true) {
        $failures += [pscustomobject]@{
            File = $cfgPath
            Errors = "SchemaOnlyExcludeSecurity must default to `$true"
        }
    }
} catch {
    $failures += [pscustomobject]@{
        File = $cfgPath
        Errors = $_.Exception.Message
    }
}

if ($manifest) {
    foreach ($fn in 'Export-SqlCpySchemaOnlyDatabase','New-SqlCpySchemaOnlyScriptingOption','Get-SqlCpySchemaOnlyObjectTypeDefaults','Get-SqlCpySchemaOnlySecurityExcludedTypes','Get-SqlCpySchemaOnlyScriptPhases','Get-SqlCpySchemaOnlyInlineOnlyTypes','Test-SqlCpySchemaOnlyTableExcluded','Invoke-SqlCpyScriptObjectWithTimeout') {
        if ($manifest.FunctionsToExport -notcontains $fn) {
            $failures += [pscustomobject]@{
                File = $manifestPath
                Errors = "FunctionsToExport missing SchemaOnly helper: $fn"
            }
        } else {
            Write-Host "  OK  manifest exports $fn"
        }
    }
}

Write-Host ''
Write-Host 'Checking per-table scripting config keys...' -ForegroundColor Cyan
try {
    $cfg3 = Import-PowerShellDataFile -Path $cfgPath
    foreach ($k in 'SchemaOnlyTableScriptMode','SchemaOnlyExcludeTables','SchemaOnlyTableScriptTimeoutSeconds') {
        if (-not $cfg3.ContainsKey($k)) {
            $failures += [pscustomobject]@{
                File = $cfgPath
                Errors = "Missing per-table config key: $k"
            }
        } else {
            Write-Host "  OK  config has $k = $($cfg3[$k])"
        }
    }
    if ($cfg3.SchemaOnlyTableScriptMode -ne 'PerTable') {
        $failures += [pscustomobject]@{
            File = $cfgPath
            Errors = "SchemaOnlyTableScriptMode must default to 'PerTable'; got '$($cfg3.SchemaOnlyTableScriptMode)'"
        }
    }
    if ($cfg3.SchemaOnlyTableScriptTimeoutSeconds -ne 300) {
        $failures += [pscustomobject]@{
            File = $cfgPath
            Errors = "SchemaOnlyTableScriptTimeoutSeconds must default to 300; got $($cfg3.SchemaOnlyTableScriptTimeoutSeconds)"
        }
    }
    # The default must not hard-code the known-problem tables; they live as
    # documentation only.
    if (@($cfg3.SchemaOnlyExcludeTables).Count -ne 0) {
        $failures += [pscustomobject]@{
            File = $cfgPath
            Errors = "SchemaOnlyExcludeTables must default to an empty array (user decides per install). Got: $($cfg3.SchemaOnlyExcludeTables -join ', ')"
        }
    }
} catch {
    $failures += [pscustomobject]@{
        File = $cfgPath
        Errors = $_.Exception.Message
    }
}

Write-Host ''
Write-Host 'Probing Test-SqlCpySchemaOnlyTableExcluded...' -ForegroundColor Cyan
try {
    # Helper already dot-sourced via $schemaFile above.
    $list = @('[integra].[Execution]', 'integra.Application', 'OtherTable', '295672101')

    $tblCases = @(
        @{ Schema='integra'; Table='Execution';   Oid=295672101; Expected=$true  }  # bracketed full match + oid
        @{ Schema='integra'; Table='Application'; Oid=208719796; Expected=$true  }  # plain schema.table + oid match on diff entry
        @{ Schema='dbo';     Table='OtherTable';  Oid=1;         Expected=$true  }  # bare-name match, any schema
        @{ Schema='integra'; Table='OtherTable';  Oid=2;         Expected=$true  }  # bare-name match, any schema
        @{ Schema='INTEGRA'; Table='EXECUTION';   Oid=0;         Expected=$true  }  # case-insensitive
        @{ Schema='dbo';     Table='Execution';   Oid=0;         Expected=$false }  # schema mismatch
        @{ Schema='integra'; Table='Other';       Oid=0;         Expected=$false }  # no match
        @{ Schema='dbo';     Table='Misc';        Oid=295672101; Expected=$true  }  # matches by object_id alone
        @{ Schema='dbo';     Table='Misc';        Oid=999999;    Expected=$false } # different object_id
    )
    foreach ($c in $tblCases) {
        $got = Test-SqlCpySchemaOnlyTableExcluded -SchemaName $c.Schema -TableName $c.Table -ObjectId $c.Oid -ExcludeList $list
        if ($got -ne $c.Expected) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = ("Test-SqlCpySchemaOnlyTableExcluded schema={0} table={1} oid={2} returned {3}, expected {4}" -f $c.Schema,$c.Table,$c.Oid,$got,$c.Expected)
            }
        } else {
            Write-Host ("  OK  exclude[{0}.{1} oid={2}] = {3}" -f $c.Schema,$c.Table,$c.Oid,$got)
        }
    }

    # Empty list never excludes.
    if (Test-SqlCpySchemaOnlyTableExcluded -SchemaName 'x' -TableName 'y' -ObjectId 1 -ExcludeList @()) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = 'Empty ExcludeList must never exclude.'
        }
    } else {
        Write-Host '  OK  empty exclude list -> never excluded'
    }

    # Null list never excludes.
    if (Test-SqlCpySchemaOnlyTableExcluded -SchemaName 'x' -TableName 'y' -ObjectId 1 -ExcludeList $null) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = 'Null ExcludeList must never exclude.'
        }
    } else {
        Write-Host '  OK  null exclude list -> never excluded'
    }

    # Whitespace-only entries must be ignored, not match everything.
    if (Test-SqlCpySchemaOnlyTableExcluded -SchemaName 'x' -TableName 'y' -ObjectId 1 -ExcludeList @('', '   ')) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = 'Whitespace-only entries in ExcludeList must be ignored.'
        }
    } else {
        Write-Host '  OK  whitespace-only entries ignored'
    }

    # Numeric entry that does not match object_id must not coincidentally match a name.
    if (Test-SqlCpySchemaOnlyTableExcluded -SchemaName 'dbo' -TableName '295672101' -ObjectId 0 -ExcludeList @('295672101')) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Numeric entry must match object_id, not a name that happens to be all-digits (without oid)."
        }
    } else {
        Write-Host '  OK  numeric entry does not match all-digit table name without object_id'
    }
} catch {
    $failures += [pscustomobject]@{
        File = $schemaFile
        Errors = "Table-exclusion probe failed: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Probing Invoke-SqlCpyScriptObjectWithTimeout...' -ForegroundColor Cyan
try {
    # Fast path: a mock item whose Script($opts) returns quickly.
    $fast = [pscustomobject]@{ Name = 'fast' }
    $fast | Add-Member -MemberType ScriptMethod -Name Script -Force -Value {
        param($opts)
        return @('SELECT 1;','SELECT 2;')
    }
    $fastOut = Invoke-SqlCpyScriptObjectWithTimeout -Item $fast -Options ([pscustomobject]@{}) -TimeoutSeconds 5
    if (($fastOut -join '|') -notmatch 'SELECT 1') {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Invoke-SqlCpyScriptObjectWithTimeout fast path did not return expected lines; got: $($fastOut -join '|')"
        }
    } else {
        Write-Host "  OK  timeout helper returns lines on the fast path"
    }

    # Timeout path: Start-Sleep longer than the timeout must raise.
    $slow = [pscustomobject]@{ Name = 'slow' }
    $slow | Add-Member -MemberType ScriptMethod -Name Script -Force -Value {
        param($opts)
        Start-Sleep -Seconds 5
        return @('SHOULD NOT APPEAR')
    }
    $timedOut = $false
    try {
        Invoke-SqlCpyScriptObjectWithTimeout -Item $slow -Options ([pscustomobject]@{}) -TimeoutSeconds 1 | Out-Null
    } catch {
        if ($_.Exception.Message -match 'timed out after') { $timedOut = $true }
    }
    if (-not $timedOut) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Invoke-SqlCpyScriptObjectWithTimeout did not raise 'timed out after' on slow mock."
        }
    } else {
        Write-Host "  OK  timeout helper aborts on slow mock"
    }

    # Invalid timeout must throw.
    $badThrew = $false
    try {
        Invoke-SqlCpyScriptObjectWithTimeout -Item $fast -Options $null -TimeoutSeconds 0 | Out-Null
    } catch { $badThrew = $true }
    if (-not $badThrew) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Invoke-SqlCpyScriptObjectWithTimeout must reject TimeoutSeconds <= 0."
        }
    } else {
        Write-Host "  OK  timeout helper rejects non-positive TimeoutSeconds"
    }
} catch {
    $failures += [pscustomobject]@{
        File = $schemaFile
        Errors = "Timeout helper probe failed: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Probing schema-phase fallback helpers...' -ForegroundColor Cyan
try {
    # Format-SqlCpySchemaCreateStatement: escaping + always-dbo authorization.
    $cases = @(
        @{ In = 'A00';          Contains = "SCHEMA_ID(N'A00')";         Bracket = '[A00]'         }
        @{ In = '_';            Contains = "SCHEMA_ID(N'_')";            Bracket = '[_]'           }
        @{ In = 'ad';           Contains = "SCHEMA_ID(N'ad')";           Bracket = '[ad]'          }
        @{ In = "O'Brien";      Contains = "SCHEMA_ID(N'O''Brien')";     Bracket = "[O''Brien]"    }
        @{ In = 'weird]name';   Contains = "SCHEMA_ID(N'weird]name')";   Bracket = '[weird]]name]' }
        @{ In = '$money';       Contains = "SCHEMA_ID(N'`$money')";     Bracket = '[$money]'      }
        @{ In = 'a.b';          Contains = "SCHEMA_ID(N'a.b')";          Bracket = '[a.b]'         }
    )
    foreach ($c in $cases) {
        $got = Format-SqlCpySchemaCreateStatement -Name $c.In
        if ($got -notmatch 'AUTHORIZATION \[dbo\]') {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "Format-SqlCpySchemaCreateStatement('$($c.In)') did not emit AUTHORIZATION [dbo]: $got"
            }
        } elseif (-not $got.Contains($c.Contains)) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "Format-SqlCpySchemaCreateStatement('$($c.In)') did not contain expected literal fragment '$($c.Contains)': $got"
            }
        } elseif (-not $got.Contains($c.Bracket)) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "Format-SqlCpySchemaCreateStatement('$($c.In)') did not contain expected bracket fragment '$($c.Bracket)': $got"
            }
        } else {
            Write-Host ("  OK  Format-SqlCpySchemaCreateStatement('{0}') -> {1}" -f $c.In, $got)
        }
    }

    # Empty / whitespace-only schema names must be rejected.
    $threw = $false
    try { Format-SqlCpySchemaCreateStatement -Name '   ' | Out-Null } catch { $threw = $true }
    if (-not $threw) {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = 'Format-SqlCpySchemaCreateStatement must reject whitespace-only names.'
        }
    } else {
        Write-Host '  OK  whitespace-only schema name rejected'
    }

    # Get-SqlCpySchemaScriptLines: .Script($opts) wins when it returns lines.
    $mockA = [pscustomobject]@{ Name = 'Good' }
    $mockA | Add-Member -MemberType ScriptMethod -Name Script -Force -Value {
        param($opts)
        if ($opts) { return @('CREATE SCHEMA [Good];') }
        return @('fallback-should-not-be-used')
    }
    $out = Get-SqlCpySchemaScriptLines -Schema $mockA -ScriptingOptions ([pscustomobject]@{X=1})
    if (($out -join "`n") -notmatch 'CREATE SCHEMA \[Good\]') {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Get-SqlCpySchemaScriptLines should prefer .Script(`$opts) when it returns lines; got: $($out -join '|')"
        }
    } else {
        Write-Host '  OK  helper prefers .Script($options)'
    }

    # When .Script($opts) throws, .Script() (no args) is tried.
    $mockB = [pscustomobject]@{ Name = 'FallbackOK' }
    $mockB | Add-Member -MemberType ScriptMethod -Name Script -Force -Value {
        param($opts)
        if ($opts) { throw 'simulated options failure' }
        return @('CREATE SCHEMA [FallbackOK];')
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    $sink = { param($m) $warnings.Add($m) }
    $out2 = Get-SqlCpySchemaScriptLines -Schema $mockB -ScriptingOptions ([pscustomobject]@{}) -WarningSink $sink
    if (($out2 -join "`n") -notmatch 'CREATE SCHEMA \[FallbackOK\]') {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Get-SqlCpySchemaScriptLines should fall back to .Script() no-arg when .Script(`$opts) throws; got: $($out2 -join '|')"
        }
    } else {
        Write-Host '  OK  helper falls back to .Script() when .Script($opts) throws'
    }

    # When both overloads throw, emit the manual fallback and warn.
    $mockC = [pscustomobject]@{ Name = 'A00' }
    $mockC | Add-Member -MemberType ScriptMethod -Name Script -Force -Value {
        param($opts)
        throw ('Script failed for Schema ''{0}''.' -f $this.Name)
    }
    $warnings.Clear()
    $out3 = Get-SqlCpySchemaScriptLines -Schema $mockC -ScriptingOptions ([pscustomobject]@{}) -WarningSink $sink
    if (($out3 -join "`n") -notmatch 'CREATE SCHEMA \[A00\] AUTHORIZATION \[dbo\]') {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Get-SqlCpySchemaScriptLines manual fallback must emit CREATE SCHEMA [A00] AUTHORIZATION [dbo]; got: $($out3 -join '|')"
        }
    } else {
        Write-Host '  OK  helper falls back to manual CREATE SCHEMA with AUTHORIZATION [dbo]'
    }
    if ($warnings.Count -lt 1 -or ($warnings -join "`n") -notmatch 'manual CREATE SCHEMA fallback') {
        $failures += [pscustomobject]@{
            File = $schemaFile
            Errors = "Get-SqlCpySchemaScriptLines must route a warning through WarningSink when using manual fallback."
        }
    } else {
        Write-Host '  OK  helper routes warning through WarningSink on manual fallback'
    }

    # System schemas helper covers the four the user called out plus db_* roles.
    $sys = Get-SqlCpySchemaOnlySystemSchemaNames
    foreach ($s in 'dbo','guest','INFORMATION_SCHEMA','sys','db_owner') {
        if ($sys -notcontains $s) {
            $failures += [pscustomobject]@{
                File = $schemaFile
                Errors = "Get-SqlCpySchemaOnlySystemSchemaNames missing required system schema: $s"
            }
        } else {
            Write-Host "  OK  system-schema list contains $s"
        }
    }
} catch {
    $failures += [pscustomobject]@{
        File = $schemaFile
        Errors = "Schema-phase fallback probe failed: $($_.Exception.Message)"
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
