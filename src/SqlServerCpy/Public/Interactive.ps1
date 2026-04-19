function Start-SqlCpyInteractive {
<#
.SYNOPSIS
    Starts the interactive menu-driven console flow (TUI) for sqlserver-cpy.

.DESCRIPTION
    Loads configuration, shows the current source/target/DryRun and connection-security
    state, and presents a menu of actions. Each action logs its progress to the screen
    via Write-SqlCpyStep / Write-SqlCpyInfo.

    Any uncaught exception from an action is caught at this level and rendered
    via Show-SqlCpyErrorScreen, which ends the run gracefully and offers to copy
    or save the full error. Individual actions do not crash the whole app.

.PARAMETER ConfigPath
    Optional explicit path to a default config file.

.EXAMPLE
    Start-SqlCpyInteractive

.NOTES
    This function is the main entry point used by the root launcher
    Start-SqlServerCopy.ps1.
#>
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    $cfg = if ($ConfigPath) { Get-SqlCpyConfig -DefaultPath $ConfigPath } else { Get-SqlCpyConfig }

    while ($true) {
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor DarkCyan
        Write-Host '  sqlserver-cpy  -  interactive console' -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor DarkCyan
        Write-Host ("  Source : {0}" -f $cfg.SourceServer)
        Write-Host ("  Target : {0}" -f $cfg.TargetServer)
        Write-Host ("  DryRun : {0}" -f $cfg.DryRun)
        $trustColor = if ($cfg.TrustServerCertificate) { 'Yellow' } else { 'Gray' }
        Write-Host ("  Encrypt: {0}   TrustServerCertificate: {1}   Timeout: {2}s" -f `
            $cfg.EncryptConnection, $cfg.TrustServerCertificate, $cfg.ConnectionTimeoutSeconds) -ForegroundColor $trustColor
        if ($cfg.TrustServerCertificate) {
            Write-Host '  (TrustServerCertificate=True: scaffold/admin default; MITM risk over untrusted networks.)' -ForegroundColor DarkYellow
        }
        Write-Host ''
        Write-Host '  1) Compare server configuration'
        Write-Host '  2) Apply (equalize) server configuration'
        Write-Host '  3) Copy logins'
        Write-Host '  4) Copy SQL Agent jobs'
        Write-Host '  5) Copy SSIS catalog (folders, projects, environments)'
        Write-Host '  6) Copy SSRS assets (reports, datasets, folders, roles, security, subscriptions)'
        Write-Host '  7) Copy selected databases (schema-only, no data)'
        Write-Host '  8) Change source / target / DryRun'
        Write-Host '  9) Change connection security (Encrypt / TrustServerCertificate / Timeout)'
        Write-Host '  P) Preflight: test connectivity to source and target'
        Write-Host '  0) Exit'
        Write-Host ''

        $choice = Read-Host 'Choose an action'

        try {
            switch ($choice) {
                '1' {
                    if (-not (Test-SqlCpyPreflight -Config $cfg)) { continue }
                    $diff = Invoke-SqlCpyServerConfigCompare `
                        -SourceServer   $cfg.SourceServer `
                        -TargetServer   $cfg.TargetServer `
                        -ExtendedChecks $cfg.ExtendedServerChecks `
                        -Config         $cfg
                    if ($diff) { $diff | Format-Table -AutoSize } else { Write-SqlCpyInfo 'No differences.' }
                }
                '2' {
                    if (-not (Test-SqlCpyPreflight -Config $cfg)) { continue }
                    Invoke-SqlCpyServerConfigApply `
                        -SourceServer $cfg.SourceServer `
                        -TargetServer $cfg.TargetServer `
                        -DryRun       $cfg.DryRun `
                        -Config       $cfg
                }
                '3' {
                    if (-not (Test-SqlCpyPreflight -Config $cfg)) { continue }
                    Invoke-SqlCpyLoginCopy `
                        -SourceServer $cfg.SourceServer `
                        -TargetServer $cfg.TargetServer `
                        -DryRun       $cfg.DryRun `
                        -Config       $cfg
                }
                '4' {
                    if (-not (Test-SqlCpyPreflight -Config $cfg)) { continue }
                    Invoke-SqlCpyAgentJobCopy `
                        -SourceServer $cfg.SourceServer `
                        -TargetServer $cfg.TargetServer `
                        -DryRun       $cfg.DryRun `
                        -Config       $cfg
                }
                '5' {
                    if (-not (Test-SqlCpyPreflight -Config $cfg)) { continue }
                    Invoke-SqlCpySsisCatalogCopy `
                        -SourceServer $cfg.SourceServer `
                        -TargetServer $cfg.TargetServer `
                        -FolderFilter $cfg.SsisFolders `
                        -DryRun       $cfg.DryRun `
                        -Config       $cfg
                }
                '6' {
                    # SSRS copy uses the ReportServer web service on each side; the SQL-side
                    # preflight is not required, but run it so connection/trust settings are
                    # validated if the user has a local SSRS that shares the SQL host.
                    $srcUri = $cfg.SourceSsrsUri
                    $tgtUri = $cfg.TargetSsrsUri
                    if (-not $srcUri) { $srcUri = 'http://{0}/ReportServer' -f $cfg.SourceServer }
                    if (-not $tgtUri) { $tgtUri = 'http://{0}/ReportServer' -f $cfg.TargetServer }
                    $root = '/'
                    if ($cfg.ContainsKey('SsrsRootPath') -and $cfg.SsrsRootPath) { $root = $cfg.SsrsRootPath }

                    Invoke-SqlCpySsrsCopy `
                        -SourceUri $srcUri `
                        -TargetUri $tgtUri `
                        -RootPath  $root `
                        -DryRun    $cfg.DryRun `
                        -Config    $cfg
                }
                '7' {
                    if (-not (Test-SqlCpyPreflight -Config $cfg)) { continue }
                    $dbs = $cfg.SchemaOnlyDatabaseList
                    if (-not $dbs -or $dbs.Count -eq 0) {
                        $entered = Read-Host 'Databases (comma-separated)'
                        $dbs = $entered -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                    }
                    if (-not $dbs) { Write-SqlCpyWarning 'No databases specified.'; continue }

                    Invoke-SqlCpySchemaOnlyDatabaseCopy `
                        -SourceServer $cfg.SourceServer `
                        -TargetServer $cfg.TargetServer `
                        -Databases    $dbs `
                        -DryRun       $cfg.DryRun `
                        -Config       $cfg
                }
                '8' {
                    $s = Read-Host ("Source [{0}]" -f $cfg.SourceServer)
                    if ($s) { $cfg.SourceServer = $s }
                    $t = Read-Host ("Target [{0}]" -f $cfg.TargetServer)
                    if ($t) { $cfg.TargetServer = $t }
                    $d = Read-Host ("DryRun [{0}] (y/n)" -f $cfg.DryRun)
                    if ($d -match '^(?i)y') { $cfg.DryRun = $true }
                    elseif ($d -match '^(?i)n') { $cfg.DryRun = $false }
                }
                '9' {
                    $e = Read-Host ("EncryptConnection [{0}] (y/n)" -f $cfg.EncryptConnection)
                    if ($e -match '^(?i)y') { $cfg.EncryptConnection = $true }
                    elseif ($e -match '^(?i)n') { $cfg.EncryptConnection = $false }

                    $tr = Read-Host ("TrustServerCertificate [{0}] (y/n)" -f $cfg.TrustServerCertificate)
                    if ($tr -match '^(?i)y') { $cfg.TrustServerCertificate = $true }
                    elseif ($tr -match '^(?i)n') { $cfg.TrustServerCertificate = $false }

                    $to = Read-Host ("ConnectionTimeoutSeconds [{0}]" -f $cfg.ConnectionTimeoutSeconds)
                    if ($to -match '^\d+$') { $cfg.ConnectionTimeoutSeconds = [int]$to }
                }
                { $_ -match '^(?i)p$' } {
                    [void](Test-SqlCpyPreflight -Config $cfg)
                }
                '0' { return }
                default { Write-SqlCpyWarning "Unknown choice: $choice" }
            }
        } catch {
            Show-SqlCpyErrorScreen -ErrorRecord $_
            return
        }
    }
}
