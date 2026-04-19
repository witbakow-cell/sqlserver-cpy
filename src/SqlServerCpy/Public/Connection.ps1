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
    Historical helper retained for any caller that still wants to pass a raw
    server name plus trust/encrypt flags directly to a dbatools cmdlet that
    exposes those parameters. In practice, the preferred path for commands
    such as Get-DbaSpConfigure / Get-DbaLogin / Get-DbaAgentJob is to pass a
    pre-built Connect-DbaInstance connection object as -SqlInstance; see
    Get-SqlCpyDbaConnection and Get-SqlCpyInstanceSplat. Connection-object
    reuse is the only pattern that reliably applies TrustServerCertificate to
    cmdlets that do not expose the parameter directly, which is what broke
    "Compare server configuration" against chbbbid2.

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
    The dbatools cmdlet the splat will be applied to, e.g. 'Connect-DbaInstance'.
    When supplied, only parameters that command actually accepts are emitted.

.PARAMETER SimulatedParameters
    Test-only. When supplied, parameter filtering uses this list instead of
    calling Get-Command. Enables unit tests without dbatools installed.

.OUTPUTS
    Hashtable for @splatting.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Server,
        [AllowNull()] [System.Management.Automation.PSCredential]$Credential,
        [string]$CommandName,
        [string[]]$SimulatedParameters
    )

    $paramSet = $null
    if ($PSBoundParameters.ContainsKey('SimulatedParameters')) {
        $paramSet = Get-SqlCpyCommandParameter -Name 'simulated' -Simulated $SimulatedParameters
    } elseif ($CommandName) {
        $paramSet = Get-SqlCpyCommandParameter -Name $CommandName
    }

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

    NOTE: Copy-Dba* cmdlets accept already-open dbatools connection objects
    for -Source / -Destination, and that is now the preferred path because
    TrustServerCertificate is applied via Connect-DbaInstance once and then
    reused. Pass pre-built connection objects via -SourceConnection /
    -DestinationConnection; when supplied, trust/encrypt flags are omitted
    from the returned splat (they are already baked into the connection) and
    raw name strings are replaced with the connection objects themselves.

    As with the SqlInstance helper, pass -CommandName so unsupported parameter
    names (most notably -ConnectionTimeout) are filtered out.

.PARAMETER Config
    Config hashtable.

.PARAMETER Source
    Source SQL Server instance name. Ignored when -SourceConnection is given.

.PARAMETER Destination
    Target SQL Server instance name. Ignored when -DestinationConnection is given.

.PARAMETER SourceConnection
    Optional pre-built dbatools connection object for the source. Produced by
    Get-SqlCpyDbaConnection / Connect-DbaInstance. When present, takes precedence
    over -Source and carries the TrustServerCertificate / EncryptConnection
    settings.

.PARAMETER DestinationConnection
    Optional pre-built dbatools connection object for the destination.

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
        [string]$Source,
        [string]$Destination,
        $SourceConnection,
        $DestinationConnection,
        [string]$CommandName,
        [string[]]$SimulatedParameters
    )

    $paramSet = $null
    if ($PSBoundParameters.ContainsKey('SimulatedParameters')) {
        $paramSet = Get-SqlCpyCommandParameter -Name 'simulated' -Simulated $SimulatedParameters
    } elseif ($CommandName) {
        $paramSet = Get-SqlCpyCommandParameter -Name $CommandName
    }

    $useSrcConn = $null -ne $SourceConnection
    $useDstConn = $null -ne $DestinationConnection

    $splat = @{
        Source      = if ($useSrcConn) { $SourceConnection } else { $Source }
        Destination = if ($useDstConn) { $DestinationConnection } else { $Destination }
    }

    if (-not $useSrcConn -or -not $useDstConn) {
        # Only emit trust/encrypt flags when at least one side is still a raw
        # name; once both sides are connection objects, their internal flags
        # win and the command-level flags are either redundant or rejected.
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
    }

    if ($Config.ContainsKey('ConnectionTimeoutSeconds') -and $Config.ConnectionTimeoutSeconds) {
        if ($paramSet) {
            $resolved = Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates @('ConnectionTimeout','ConnectTimeout','StatementTimeout')
            if ($resolved) { $splat[$resolved] = [int]$Config.ConnectionTimeoutSeconds }
        }
    }
    if (-not $useSrcConn -and $Config.SourceCredential) {
        if (-not $paramSet -or $paramSet.ContainsKey('SourceSqlCredential')) {
            $splat['SourceSqlCredential'] = $Config.SourceCredential
        }
    }
    if (-not $useDstConn -and $Config.TargetCredential) {
        if (-not $paramSet -or $paramSet.ContainsKey('DestinationSqlCredential')) {
            $splat['DestinationSqlCredential'] = $Config.TargetCredential
        }
    }

    return $splat
}

function Get-SqlCpyDbaConnection {
<#
.SYNOPSIS
    Opens a dbatools SMO connection (Connect-DbaInstance) with the project's
    connection-security configuration baked in, and returns the connection
    object for reuse across downstream dbatools cmdlets.

.DESCRIPTION
    This is the single entry point the rest of the module should use to
    obtain an authenticated dbatools handle for a given server. The returned
    object captures TrustServerCertificate / EncryptConnection /
    ConnectionTimeout at the connection level, so when it is passed as
    -SqlInstance (or -Source / -Destination) to commands such as
    Get-DbaSpConfigure, Get-DbaLogin, Get-DbaAgentJob, or Copy-Dba* - which
    do NOT expose -TrustServerCertificate themselves in dbatools 2.x - the
    trust decision still applies because they reuse this connection.

    That is the fix for the observed failure:

        WARNING: [Get-DbaSpConfigure] Failure | The certificate chain was
        issued by an authority that is not trusted

    against chbbbid2 on "Compare server configuration". The previous fix
    filtered splat parameters against the target cmdlet, which correctly
    avoided a parameter-binding error but also dropped TrustServerCertificate
    because Get-DbaSpConfigure does not expose it. Passing a pre-built
    connection object instead routes trust through Connect-DbaInstance, which
    does expose it.

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
        [AllowNull()] [System.Management.Automation.PSCredential]$Credential
    )

    if (-not (Get-Command -Name Connect-DbaInstance -ErrorAction SilentlyContinue)) {
        throw "dbatools is not available in this session. Install-Module dbatools (see DEPENDENCIES.md) and retry."
    }

    $splat = Get-SqlCpyConnectionSplat -Config $Config -Server $Server -Credential $Credential -CommandName 'Connect-DbaInstance'
    return Connect-DbaInstance @splat -ErrorAction Stop
}

function Get-SqlCpyDbaInstance {
<#
.SYNOPSIS
    Back-compat wrapper. Use Get-SqlCpyDbaConnection for new code.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$Server,
        [AllowNull()] [System.Management.Automation.PSCredential]$Credential
    )
    $pass = @{ Config = $Config; Server = $Server }
    if ($Credential) { $pass['Credential'] = $Credential }
    return Get-SqlCpyDbaConnection @pass
}

function Get-SqlCpyInstanceSplat {
<#
.SYNOPSIS
    Returns a splat for a dbatools cmdlet that takes -SqlInstance, using a
    pre-built Connect-DbaInstance connection object as the instance.

.DESCRIPTION
    This is the preferred helper for commands like Get-DbaSpConfigure,
    Get-DbaLogin, Get-DbaAgentJob, Invoke-DbaQuery. The connection object
    already carries TrustServerCertificate / EncryptConnection /
    ConnectionTimeout, so those flags are NOT added to the returned splat
    (the commands usually do not expose them anyway).

    -SqlCredential is only emitted when the target command actually accepts
    it - with a connection object the credential has already been consumed,
    but some cmdlets still expose the parameter and won't object.

    A timeout parameter is routed in if the target command exposes one under
    any of the known names (ConnectionTimeout / ConnectTimeout /
    StatementTimeout); this lets Invoke-DbaQuery receive a statement timeout
    even when the server name is already a connection object.

.PARAMETER Config
    Config hashtable.

.PARAMETER Connection
    Pre-built dbatools connection (from Get-SqlCpyDbaConnection).

.PARAMETER CommandName
    The dbatools cmdlet the splat targets.

.PARAMETER SimulatedParameters
    Test-only override.

.OUTPUTS
    Hashtable.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] $Connection,
        [string]$CommandName,
        [string[]]$SimulatedParameters
    )

    $paramSet = $null
    if ($PSBoundParameters.ContainsKey('SimulatedParameters')) {
        $paramSet = Get-SqlCpyCommandParameter -Name 'simulated' -Simulated $SimulatedParameters
    } elseif ($CommandName) {
        $paramSet = Get-SqlCpyCommandParameter -Name $CommandName
    }

    $splat = @{ SqlInstance = $Connection }

    if ($Config.ContainsKey('ConnectionTimeoutSeconds') -and $Config.ConnectionTimeoutSeconds -and $paramSet) {
        $resolved = Resolve-SqlCpyParameterName -ParameterSet $paramSet -Candidates @('ConnectionTimeout','ConnectTimeout','StatementTimeout')
        if ($resolved) { $splat[$resolved] = [int]$Config.ConnectionTimeoutSeconds }
    }

    return $splat
}

function Test-SqlCpyPreflight {
<#
.SYNOPSIS
    Validates that both source and target SQL Server instances are reachable
    under the configured connection security settings, with actionable
    diagnostics for common failure modes.

.DESCRIPTION
    On success, caches the opened source/target connection objects on the
    -Config hashtable under the keys `_SourceConnection` and `_TargetConnection`
    so migration/compare functions can reuse them and inherit the same
    TrustServerCertificate / EncryptConnection decision that preflight made.
    This is what guarantees a successful preflight means Step 1 (Compare
    server configuration) uses the same trust behavior.

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
        @{ Role = 'Source'; Server = $Config.SourceServer; Credential = $Config.SourceCredential; CacheKey = '_SourceConnection' }
        @{ Role = 'Target'; Server = $Config.TargetServer; Credential = $Config.TargetCredential; CacheKey = '_TargetConnection' }
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
            $connPass = @{ Config = $Config; Server = $t.Server }
            if ($t.Credential) { $connPass['Credential'] = $t.Credential }
            $conn = Get-SqlCpyDbaConnection @connPass
            $Config[$t.CacheKey] = $conn
            Write-SqlCpyInfo ("  OK  {0} version {1}" -f $conn.Name, $conn.VersionString)
        } catch {
            $allOk = $false
            $Config.Remove($t.CacheKey) | Out-Null
            $msg = $_.Exception.Message
            Write-SqlCpyError ("{0} connection failed: {1}" -f $t.Role, $msg)
            Write-SqlCpyInfo  (Get-SqlCpyConnectionErrorHint -Message $msg -Config $Config)
        }
    }

    if ($allOk) {
        Write-SqlCpyInfo 'Preflight OK. Reusing authenticated connection objects for subsequent steps.'
    } else {
        Write-SqlCpyWarning 'Preflight failed. Fix the issues above before running migration steps.'
    }
    return $allOk
}

function Get-SqlCpyCachedConnection {
<#
.SYNOPSIS
    Returns a cached source/target dbatools connection (from a successful
    preflight) or opens a fresh one when no cache entry exists.

.DESCRIPTION
    Migration and compare functions call this instead of rebuilding a
    connection from scratch. Reusing the preflight connection is what makes
    TrustServerCertificate apply consistently to downstream cmdlets that do
    not expose the parameter directly - most importantly Get-DbaSpConfigure,
    which drove the original "certificate chain was issued by an authority
    that is not trusted" failure on the Compare step.

.PARAMETER Config
    Config hashtable.

.PARAMETER Role
    'Source' or 'Target'.

.PARAMETER Server
    Server name; used only when no cached connection is present and a fresh
    connection must be opened.

.PARAMETER Credential
    Credential; used only on a cache miss.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [ValidateSet('Source','Target')] [string]$Role,
        [Parameter(Mandatory)] [string]$Server,
        [AllowNull()] [System.Management.Automation.PSCredential]$Credential
    )

    $cacheKey = if ($Role -eq 'Source') { '_SourceConnection' } else { '_TargetConnection' }
    if ($Config.ContainsKey($cacheKey) -and $Config[$cacheKey]) {
        return $Config[$cacheKey]
    }
    $connPass = @{ Config = $Config; Server = $Server }
    if ($Credential) { $connPass['Credential'] = $Credential }
    $conn = Get-SqlCpyDbaConnection @connPass
    $Config[$cacheKey] = $conn
    return $conn
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
                return "Hint: TrustServerCertificate is already `$true in config. If Preflight passed and this error came from a later step, the migration function is not reusing the preflight connection object. Confirm the caller is using Get-SqlCpyCachedConnection / Get-SqlCpyInstanceSplat rather than building a raw splat with a server name. If Preflight itself failed here, verify the server really speaks TLS on the configured port."
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
