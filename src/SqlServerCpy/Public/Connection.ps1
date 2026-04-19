function Get-SqlCpyConnectionSplat {
<#
.SYNOPSIS
    Returns a hashtable suitable for splatting the connection-security parameters
    onto any dbatools cmdlet that accepts `-SqlInstance` / `-SqlCredential`
    (and, where supported, `-EncryptConnection` / `-TrustServerCertificate` /
    `-ConnectionTimeout`).

.DESCRIPTION
    Centralizes construction of SQL Server connection parameters so migration
    functions do not repeatedly reach into the config hashtable and hand-build
    connection arguments. This is what the "centralized dbatools connection
    creation" point in the project task list is about.

    The returned hashtable is callsite-safe: every dbatools cmdlet that accepts
    -SqlInstance also accepts -SqlCredential, -EncryptConnection,
    -TrustServerCertificate, and -ConnectionTimeout in current versions
    (dbatools 2.x). If you are on an older build that does not, use
    Get-SqlCpyDbaInstance below to produce a connected SMO instance and pass
    that as -SqlInstance instead.

.PARAMETER Config
    A config hashtable as produced by Get-SqlCpyConfig. Must contain at least
    EncryptConnection, TrustServerCertificate, ConnectionTimeoutSeconds. The
    server name is passed explicitly via -Server, not taken from the config,
    because callers often operate on exactly one of source/target.

.PARAMETER Server
    The SQL Server instance name to target (e.g. 'chbbbid2', 'localhost', or
    a SQL Server Browser name like 'chbbbid2\SQLPROD').

.PARAMETER Credential
    Optional PSCredential. If omitted and the config does not carry one, the
    current Windows identity is used (trusted connection).

.OUTPUTS
    Hashtable, intended for @splatting into Get-DbaSpConfigure, Copy-DbaLogin,
    Copy-DbaAgentJob, Connect-DbaInstance, Invoke-DbaQuery, etc.

.EXAMPLE
    $cfg = Get-SqlCpyConfig
    $splat = Get-SqlCpyConnectionSplat -Config $cfg -Server $cfg.SourceServer
    Get-DbaSpConfigure @splat
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Server,
        [System.Management.Automation.PSCredential]$Credential
    )

    $splat = @{
        SqlInstance = $Server
    }

    if ($Config.ContainsKey('EncryptConnection')) {
        $splat['EncryptConnection'] = [bool]$Config.EncryptConnection
    }
    if ($Config.ContainsKey('TrustServerCertificate')) {
        $splat['TrustServerCertificate'] = [bool]$Config.TrustServerCertificate
    }
    if ($Config.ContainsKey('ConnectionTimeoutSeconds') -and $Config.ConnectionTimeoutSeconds) {
        $splat['ConnectionTimeout'] = [int]$Config.ConnectionTimeoutSeconds
    }
    if ($Credential) {
        $splat['SqlCredential'] = $Credential
    }

    return $splat
}

function Get-SqlCpyCopySplat {
<#
.SYNOPSIS
    Returns a splat hashtable for Copy-Dba* cmdlets, which take -Source /
    -Destination (plus matching credential/TLS parameter names).

.DESCRIPTION
    Twin of Get-SqlCpyConnectionSplat for the subset of dbatools cmdlets whose
    parameter names are -Source and -Destination rather than -SqlInstance.
    Examples: Copy-DbaLogin, Copy-DbaAgentJob, Copy-DbaSsisCatalog,
    Copy-DbaSpConfigure.

.PARAMETER Config
    Config hashtable as produced by Get-SqlCpyConfig.

.PARAMETER Source
    Source SQL Server instance name.

.PARAMETER Destination
    Target SQL Server instance name.

.OUTPUTS
    Hashtable for splatting.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )

    $splat = @{
        Source      = $Source
        Destination = $Destination
    }

    if ($Config.ContainsKey('EncryptConnection')) {
        $splat['EncryptConnection'] = [bool]$Config.EncryptConnection
    }
    if ($Config.ContainsKey('TrustServerCertificate')) {
        # Copy-Dba* cmdlets generally accept the same -TrustServerCertificate switch on
        # both ends. If a version in use does not, fall back to two explicit
        # Connect-DbaInstance handles via Get-SqlCpyDbaInstance and pass those instead.
        $splat['TrustServerCertificate'] = [bool]$Config.TrustServerCertificate
    }
    if ($Config.ContainsKey('ConnectionTimeoutSeconds') -and $Config.ConnectionTimeoutSeconds) {
        $splat['ConnectionTimeout'] = [int]$Config.ConnectionTimeoutSeconds
    }
    if ($Config.SourceCredential) { $splat['SourceSqlCredential']      = $Config.SourceCredential }
    if ($Config.TargetCredential) { $splat['DestinationSqlCredential'] = $Config.TargetCredential }

    return $splat
}

function Get-SqlCpyDbaInstance {
<#
.SYNOPSIS
    Opens a dbatools SMO connection (a [Sqlcollaborative.Dbatools.Parameter.DbaInstanceParameter]
    or connected SMO Server) honouring the project's connection-security config.

.DESCRIPTION
    Uses Connect-DbaInstance under the hood. This is the escape hatch for dbatools
    cmdlets that do not yet accept -TrustServerCertificate / -EncryptConnection
    directly: connect once here, then pass the returned object to -SqlInstance
    on the downstream cmdlet.

    Throws if dbatools is not installed - callers should run
    Test-SqlCpyPreflight first to surface that as an actionable error.

.PARAMETER Config
    Config hashtable as produced by Get-SqlCpyConfig.

.PARAMETER Server
    SQL Server instance name.

.PARAMETER Credential
    Optional PSCredential for SQL auth.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Server,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not (Get-Command -Name Connect-DbaInstance -ErrorAction SilentlyContinue)) {
        throw "dbatools is not available in this session. Install-Module dbatools (see DEPENDENCIES.md) and retry."
    }

    $splat = Get-SqlCpyConnectionSplat -Config $Config -Server $Server -Credential $Credential
    return Connect-DbaInstance @splat -ErrorAction Stop
}

function Test-SqlCpyPreflight {
<#
.SYNOPSIS
    Validates that both source and target SQL Server instances are reachable under
    the configured connection security settings, and prints actionable diagnostics
    for common failure modes.

.DESCRIPTION
    Intended to run before any migration step. Returns $true when both ends are
    reachable; $false otherwise. Does not throw - the caller can decide whether
    to proceed.

    Failure categories that get targeted messages:
      - Missing dependency         (dbatools not installed)
      - Untrusted certificate      (matches 'certificate chain' / 'not trusted')
      - Authentication failure     ('login failed', 'not associated')
      - Network / host unreachable ('network-related', 'no such host', timeout)

    Any other error is reported verbatim with a suggestion to re-run with
    verbose output.

.PARAMETER Config
    Config hashtable as produced by Get-SqlCpyConfig.

.OUTPUTS
    [bool]. Writes progress and diagnostic lines via Write-SqlCpy* helpers.

.EXAMPLE
    $cfg = Get-SqlCpyConfig
    if (-not (Test-SqlCpyPreflight -Config $cfg)) { return }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config
    )

    Write-SqlCpyStep "Preflight: checking connectivity to source and target"

    if (-not (Get-Command -Name Connect-DbaInstance -ErrorAction SilentlyContinue)) {
        Write-SqlCpyError 'dbatools module not found. Install it with:  Install-Module dbatools -Scope CurrentUser'
        Write-SqlCpyInfo  'See DEPENDENCIES.md for version requirements.'
        return $false
    }

    $sec = @(
        ("EncryptConnection      = {0}" -f $Config.EncryptConnection)
        ("TrustServerCertificate = {0}" -f $Config.TrustServerCertificate)
        ("ConnectionTimeout (s)  = {0}" -f $Config.ConnectionTimeoutSeconds)
    ) -join ' | '
    Write-SqlCpyInfo "Connection security: $sec"

    $targets = @(
        @{ Role = 'Source'; Server = $Config.SourceServer; Credential = $Config.SourceCredential }
        @{ Role = 'Target'; Server = $Config.TargetServer; Credential = $Config.TargetCredential }
    )

    $allOk = $true
    foreach ($t in $targets) {
        if (-not $t.Server) {
            Write-SqlCpyError "$($t.Role) server is not configured."
            $allOk = $false
            continue
        }

        Write-SqlCpyInfo ("Connecting to {0}: {1}" -f $t.Role, $t.Server)
        try {
            $splat = Get-SqlCpyConnectionSplat -Config $Config -Server $t.Server -Credential $t.Credential
            $conn = Connect-DbaInstance @splat -ErrorAction Stop
            Write-SqlCpyInfo ("  OK  {0} version {1}" -f $conn.Name, $conn.VersionString)
        } catch {
            $allOk = $false
            $msg = $_.Exception.Message
            Write-SqlCpyError ("{0} connection failed: {1}" -f $t.Role, $msg)
            Write-SqlCpyInfo  (Get-SqlCpyConnectionErrorHint -Message $msg -Config $Config)
        }
    }

    if ($allOk) {
        Write-SqlCpyInfo 'Preflight OK.'
    } else {
        Write-SqlCpyWarning 'Preflight failed. Fix the issues above before running migration steps.'
    }
    return $allOk
}

function Get-SqlCpyConnectionErrorHint {
<#
.SYNOPSIS
    Maps a SQL connection error message to an actionable remediation hint.

.DESCRIPTION
    Kept deliberately simple: matches a handful of well-known substrings that
    appear in SqlClient / SMO exception messages. Used by Test-SqlCpyPreflight
    and by the wrappers in ServerConfig.ps1 so the user gets a clear next step
    instead of a raw dbatools warning.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Message,
        [hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Message)) { return 'No error text available.' }

    $trust = if ($Config -and $Config.ContainsKey('TrustServerCertificate')) { [bool]$Config.TrustServerCertificate } else { $false }

    switch -Regex ($Message) {
        'certificate chain|not trusted|SSL Provider|certificate.*(validation|verify)' {
            if ($trust) {
                return "Hint: TrustServerCertificate is already `$true but the driver still refused the cert. Check that the server actually speaks TLS (port, firewall) and that the error is not masking a different failure."
            }
            return "Hint: The SQL Server presented a certificate your client could not validate. For local/admin migrations set TrustServerCertificate = `$true in config/local.psd1 (understand the MITM risk). For production, install a properly chained server certificate."
        }
        'Login failed|not associated with a trusted|Cannot open database' {
            return "Hint: Authentication failed. Verify the Windows identity running this script has SQL access, or set a SourceCredential/TargetCredential in config."
        }
        'network-related|no such host|could not find|timeout|timed out|transport-level' {
            return "Hint: Network or host unreachable. Check DNS, TCP 1433 (or configured port), SQL Browser for named instances, and firewall rules. Consider raising ConnectionTimeoutSeconds."
        }
        'is not recognized as the name of a cmdlet|CommandNotFoundException' {
            return "Hint: A required cmdlet is missing. Ensure dbatools is imported (Import-Module dbatools)."
        }
        default {
            return 'Hint: Re-run with -Verbose for the full dbatools / SqlClient stack, and confirm the server name, instance, and credentials.'
        }
    }
}
