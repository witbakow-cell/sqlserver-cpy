function Get-SqlCpyCommandParameter {
<#
.SYNOPSIS
    Returns the set of parameter names a given command accepts, or $null if the
    command cannot be resolved.

.DESCRIPTION
    Wraps Get-Command so we can cheaply probe dbatools (or any) cmdlet/function
    for which parameter names it actually exposes in the installed version. The
    returned value is a hashtable keyed by the parameter's canonical name with
    a value of $true, which makes `$params.ContainsKey('ConnectionTimeout')`
    both fast and alias-resolution-free.

    Also records parameter aliases so callers can ask "does this command expose
    -ConnectionTimeout OR a known alias for it?".

.PARAMETER Name
    Command name to probe (e.g. 'Get-DbaSpConfigure', 'Copy-DbaLogin').

.PARAMETER Simulated
    Test-only: supply a pre-built parameter set (array of names) to simulate a
    command without calling Get-Command. Used by tests/Syntax.Tests.ps1 to
    exercise the filtering logic without requiring dbatools to be installed.

.OUTPUTS
    [hashtable] of parameter-name -> $true, plus special key '_Aliases' mapping
    alias -> canonical name. $null when the command cannot be found.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string[]]$Simulated
    )

    if ($PSBoundParameters.ContainsKey('Simulated')) {
        $set = @{ _Aliases = @{} }
        foreach ($p in $Simulated) { $set[$p] = $true }
        return $set
    }

    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }

    $set = @{ _Aliases = @{} }
    foreach ($p in $cmd.Parameters.Values) {
        $set[$p.Name] = $true
        foreach ($a in $p.Aliases) {
            $set._Aliases[$a] = $p.Name
        }
    }
    return $set
}

function Resolve-SqlCpyParameterName {
<#
.SYNOPSIS
    Returns the first name in -Candidates that the command exposes (as a
    parameter or alias), or $null if none match.

.DESCRIPTION
    dbatools renamed several parameters across major versions. For example,
    -ConnectionTimeout was removed from most Copy-Dba* cmdlets and on some
    commands a parameter named -StatementTimeout or -Timeout appears instead.
    This helper lets a caller express that preference list in priority order.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [hashtable]$ParameterSet,
        [Parameter(Mandatory)] [string[]]$Candidates
    )
    if (-not $ParameterSet) { return $null }
    foreach ($c in $Candidates) {
        if ($ParameterSet.ContainsKey($c)) { return $c }
        if ($ParameterSet._Aliases -and $ParameterSet._Aliases.ContainsKey($c)) {
            return $ParameterSet._Aliases[$c]
        }
    }
    return $null
}

function Get-SqlCpyConnectionSplat {
<#
.SYNOPSIS
    Returns a hashtable suitable for splatting onto a dbatools cmdlet that
    accepts `-SqlInstance` / `-SqlCredential`, filtered so only parameters the
    target command actually supports are included.

.DESCRIPTION
    Centralizes construction of SQL Server connection parameters so migration
    functions do not repeatedly reach into the config hashtable and hand-build
    connection arguments.

    IMPORTANT: the set of parameters dbatools cmdlets expose is *not* uniform.
    -ConnectionTimeout exists on Connect-DbaInstance but not on Get-DbaLogin,
    Copy-DbaSpConfigure, etc. Blindly splatting it onto every cmdlet fails with
    "A parameter cannot be found that matches parameter name 'ConnectionTimeout'".

    This function therefore takes an optional -CommandName and filters the
    result against that command's real parameter set via Get-Command. Callers
    should pass -CommandName whenever possible. When the command can't be
    resolved (e.g. dbatools not imported yet), the splat falls back to the
    conservative universal subset (-SqlInstance/-SqlCredential only).

.PARAMETER Config
    Config hashtable as produced by Get-SqlCpyConfig.

.PARAMETER Server
    SQL Server instance name to target.

.PARAMETER Credential
    Optional PSCredential. If omitted the current Windows identity is used.

.PARAMETER CommandName
    The dbatools cmdlet the splat will be applied to, e.g. 'Get-DbaSpConfigure'.
    When supplied, only parameters that command actually accepts are emitted.

.PARAMETER SimulatedParameters
    Test-only. When supplied, parameter filtering uses this list instead of
    calling Get-Command. Enables unit tests without dbatools installed.

.OUTPUTS
    Hashtable for @splatting.

.EXAMPLE
    $cfg = Get-SqlCpyConfig
    $splat = Get-SqlCpyConnectionSplat -Config $cfg -Server $cfg.SourceServer -CommandName 'Get-DbaSpConfigure'
    Get-DbaSpConfigure @splat
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Server,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$CommandName,
        [string[]]$SimulatedParameters
    )

    $paramSet = $null
    if ($PSBoundParameters.ContainsKey('SimulatedParameters')) {
        $paramSet = Get-SqlCpyCommandParameter -Name 'simulated' -Simulated $SimulatedParameters
    } elseif ($CommandName) {
        $paramSet = Get-SqlCpyCommandParameter -Name $CommandName
    }

    # Canonical parameter-name we'd like to emit -> list of names accepted as
    # equivalents in various dbatools versions (priority order).
    $wanted = @(
        @{ Key = 'SqlInstance';            Candidates = @('SqlInstance') }
        @{ Key = 'SqlCredential';          Candidates = @('SqlCredential') }
        @{ Key = 'EncryptConnection';      Candidates = @('EncryptConnection') }
        @{ Key = 'TrustServerCertificate'; Candidates = @('TrustServerCertificate') }
        @{ Key = 'ConnectionTimeout';      Candidates = @('ConnectionTimeout','ConnectTimeout','StatementTimeout') }
    )

    $splat = @{}

    foreach ($w in $wanted) {
        switch ($w.Key) {
            'SqlInstance' {
                $splat['SqlInstance'] = $Server
            }
            'SqlCredential' {
                if ($Credential -and (-not $paramSet -or (Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates $w.Candidates))) {
                    $splat['SqlCredential'] = $Credential
                }
            }
            'EncryptConnection' {
                if ($Config.ContainsKey('EncryptConnection')) {
                    $resolved = if ($paramSet) { Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates $w.Candidates } else { 'EncryptConnection' }
                    if ($resolved) { $splat[$resolved] = [bool]$Config.EncryptConnection }
                }
            }
            'TrustServerCertificate' {
                if ($Config.ContainsKey('TrustServerCertificate')) {
                    $resolved = if ($paramSet) { Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates $w.Candidates } else { 'TrustServerCertificate' }
                    if ($resolved) { $splat[$resolved] = [bool]$Config.TrustServerCertificate }
                }
            }
            'ConnectionTimeout' {
                if ($Config.ContainsKey('ConnectionTimeoutSeconds') -and $Config.ConnectionTimeoutSeconds) {
                    if ($paramSet) {
                        $resolved = Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates $w.Candidates
                        if ($resolved) { $splat[$resolved] = [int]$Config.ConnectionTimeoutSeconds }
                        # If the command doesn't accept a timeout parameter, we silently skip it.
                    } else {
                        # Unknown command: skip timeout entirely to avoid the
                        # "A parameter cannot be found that matches parameter name 'ConnectionTimeout'"
                        # failure. Callers that need it must pass -CommandName.
                    }
                }
            }
        }
    }

    return $splat
}

function Get-SqlCpyCopySplat {
<#
.SYNOPSIS
    Returns a splat hashtable for Copy-Dba* cmdlets, filtered against the
    target command's real parameter set.

.DESCRIPTION
    Twin of Get-SqlCpyConnectionSplat for dbatools cmdlets that use
    -Source / -Destination rather than -SqlInstance. Copy-DbaLogin,
    Copy-DbaAgentJob, Copy-DbaSsisCatalog, Copy-DbaSpConfigure are the common
    callers.

    As with the SqlInstance helper, pass -CommandName so unsupported parameter
    names (most notably -ConnectionTimeout) are filtered out.

.PARAMETER Config
    Config hashtable.

.PARAMETER Source
    Source SQL Server instance name.

.PARAMETER Destination
    Target SQL Server instance name.

.PARAMETER CommandName
    dbatools cmdlet the splat will be applied to.

.PARAMETER SimulatedParameters
    Test-only override - see Get-SqlCpyConnectionSplat.

.OUTPUTS
    Hashtable.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [string]$CommandName,
        [string[]]$SimulatedParameters
    )

    $paramSet = $null
    if ($PSBoundParameters.ContainsKey('SimulatedParameters')) {
        $paramSet = Get-SqlCpyCommandParameter -Name 'simulated' -Simulated $SimulatedParameters
    } elseif ($CommandName) {
        $paramSet = Get-SqlCpyCommandParameter -Name $CommandName
    }

    $splat = @{
        Source      = $Source
        Destination = $Destination
    }

    if ($Config.ContainsKey('EncryptConnection')) {
        if (-not $paramSet -or $paramSet.ContainsKey('EncryptConnection')) {
            $splat['EncryptConnection'] = [bool]$Config.EncryptConnection
        }
    }
    if ($Config.ContainsKey('TrustServerCertificate')) {
        if (-not $paramSet -or $paramSet.ContainsKey('TrustServerCertificate')) {
            $splat['TrustServerCertificate'] = [bool]$Config.TrustServerCertificate
        }
    }
    if ($Config.ContainsKey('ConnectionTimeoutSeconds') -and $Config.ConnectionTimeoutSeconds) {
        if ($paramSet) {
            $resolved = Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates @('ConnectionTimeout','ConnectTimeout','StatementTimeout')
            if ($resolved) { $splat[$resolved] = [int]$Config.ConnectionTimeoutSeconds }
            # If the Copy-Dba* cmdlet doesn't expose any timeout parameter (the
            # common case in dbatools 2.x), we silently skip it rather than
            # crash the migration with a parameter-binding error.
        }
        # Unknown command: skip the timeout to stay safe.
    }
    if ($Config.SourceCredential) {
        if (-not $paramSet -or $paramSet.ContainsKey('SourceSqlCredential')) {
            $splat['SourceSqlCredential'] = $Config.SourceCredential
        }
    }
    if ($Config.TargetCredential) {
        if (-not $paramSet -or $paramSet.ContainsKey('DestinationSqlCredential')) {
            $splat['DestinationSqlCredential'] = $Config.TargetCredential
        }
    }

    return $splat
}

function Get-SqlCpyDbaInstance {
<#
.SYNOPSIS
    Opens a dbatools SMO connection honouring the project's connection-security
    configuration.

.DESCRIPTION
    Uses Connect-DbaInstance under the hood. Connect-DbaInstance accepts
    -ConnectionTimeout on all supported dbatools versions so we splat through
    that command name explicitly.

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

    $splat = Get-SqlCpyConnectionSplat -Config $Config -Server $Server -Credential $Credential -CommandName 'Connect-DbaInstance'
    return Connect-DbaInstance @splat -ErrorAction Stop
}

function Test-SqlCpyPreflight {
<#
.SYNOPSIS
    Validates that both source and target SQL Server instances are reachable
    under the configured connection security settings, with actionable
    diagnostics for common failure modes.

.OUTPUTS
    [bool].
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
            $splat = Get-SqlCpyConnectionSplat -Config $Config -Server $t.Server -Credential $t.Credential -CommandName 'Connect-DbaInstance'
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
        'A parameter cannot be found that matches parameter name' {
            return "Hint: An installed dbatools version does not expose the parameter the wrapper tried to pass. Ensure you are on the version pinned in DEPENDENCIES.md, or update sqlserver-cpy to a build whose Get-SqlCpyConnectionSplat / Get-SqlCpyCopySplat filter against command metadata."
        }
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
