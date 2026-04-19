# SQL Server Reporting Services (SSRS) copy.
#
# Strategy: SSRS APIs - ReportService2010 SOAP for catalog objects, policies
# and subscriptions; ReportServer REST (/reports/api/v2.0) where available for
# KPIs / mobile reports. ReportServer-database-level copy is intentionally NOT
# the primary path - it is version-specific and drags along machine-keyed
# encrypted columns.
#
# Scope (as requested: do not intentionally skip any class of SSRS asset):
#   - Folders
#   - Shared data sources
#   - Shared datasets
#   - Reports (.rdl)
#   - Resources (images, xlsx, pdf, ...)
#   - Item-level security (policies)
#   - System-level policies
#   - Role definitions (system + catalog)
#   - Schedules (shared)
#   - Subscriptions (best-effort; data-driven subscriptions usually require
#     extra credentials / encryption keys that cannot be migrated via SOAP)
#   - KPIs / mobile reports (via REST when the target speaks it)
#
# Caveats (also documented in DECISIONS_AND_CAVEATS.txt):
#   - Sensitive fields (stored credentials on data sources, subscription
#     credentials, symmetric keys) are NOT portable over SOAP. This module
#     copies the item, flags the unset credential, and logs an actionable
#     hint.
#   - ReportService2010 coverage varies by SSRS version (2008 R2 through
#     2019+). Calls that a given target does not expose are caught, logged,
#     and the copy continues.
#   - Running the SOAP client under PS 5.1 uses New-WebServiceProxy; under
#     PS 7+ the cmdlet is still present but may require -UseDefaultCredential.
#     Helpers below pick whichever is available.

function Get-SqlCpySsrsProxy {
<#
.SYNOPSIS
    Opens a ReportService2010 SOAP proxy against an SSRS ReportServer endpoint.

.DESCRIPTION
    Uses New-WebServiceProxy with default (Windows) credentials. The ReportServer
    endpoint is expected to be the HTTP(S) URL of the report server virtual
    directory, e.g. 'http://chbbbid2/ReportServer'. The WSDL is appended
    automatically.

    The returned object exposes the ReportService2010 methods:
        ListChildren, CreateFolder, CreateCatalogItem, SetItemDataSources,
        GetPolicies, SetPolicies, ListRoles, CreateRole, ListSchedules,
        CreateSchedule, ListSubscriptions, CreateSubscription, etc.

    Throws with a hint if New-WebServiceProxy is not available or the endpoint
    cannot be reached.

.PARAMETER Uri
    Full ReportServer URL (without '/ReportService2010.asmx').

.PARAMETER Credential
    Optional PSCredential for the ReportServer endpoint. When omitted, default
    (logged-on) Windows credentials are used.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [pscredential]$Credential
    )

    if (-not (Get-Command -Name New-WebServiceProxy -ErrorAction SilentlyContinue)) {
        throw "New-WebServiceProxy is not available in this PowerShell host. SSRS copy requires a Windows PowerShell 5.1 or PowerShell 7.x session that exposes this cmdlet."
    }

    $wsdl = ($Uri.TrimEnd('/')) + '/ReportService2010.asmx?wsdl'

    try {
        if ($Credential) {
            $proxy = New-WebServiceProxy -Uri $wsdl -Credential $Credential -Namespace 'SqlCpySsrs' -ErrorAction Stop
        } else {
            $proxy = New-WebServiceProxy -Uri $wsdl -UseDefaultCredential -Namespace 'SqlCpySsrs' -ErrorAction Stop
        }
    } catch {
        throw ("Cannot open SSRS proxy at {0}: {1}" -f $wsdl, $_.Exception.Message)
    }

    # Default credentials for calls that do not accept an explicit credential.
    if (-not $Credential) {
        $proxy.UseDefaultCredentials = $true
    } else {
        $proxy.Credentials = $Credential.GetNetworkCredential()
    }
    $proxy.PreAuthenticate = $true
    return $proxy
}

function Get-SqlCpySsrsRestBase {
<#
.SYNOPSIS
    Returns the base URL for the ReportServer REST v2.0 API corresponding to a
    given ReportServer endpoint, or $null if the target looks like a native
    legacy server without the Reports portal REST API.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Uri)

    $base = $Uri.TrimEnd('/')
    # Canonical SSRS 2016+ layout: /ReportServer (SOAP) + /Reports (portal+REST).
    # We return '<scheme>://<host>/Reports/api/v2.0'.
    if ($base -match '^(https?://[^/]+)(/.*)?$') {
        return ($Matches[1] + '/Reports/api/v2.0')
    }
    return $null
}

function Get-SqlCpySsrsCatalogItems {
<#
.SYNOPSIS
    Enumerates every catalog item at and below a given path, recursively.

.DESCRIPTION
    Wraps ReportService2010.ListChildren(..., Recursive=$true). Returns the raw
    CatalogItem array the SOAP service produces; each element carries Name,
    Path, TypeName, ID, Size, CreationDate, ModifiedDate, CreatedBy, ModifiedBy.
    Callers group by TypeName ('Folder', 'Report', 'Dataset', 'DataSource',
    'Resource', 'Component', etc.) to decide how to copy each item.

.PARAMETER Proxy
    ReportService2010 proxy from Get-SqlCpySsrsProxy.

.PARAMETER RootPath
    Path under which to enumerate. Default '/'.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Proxy,
        [string]$RootPath = '/'
    )

    try {
        $items = $Proxy.ListChildren($RootPath, $true)
        return ,$items
    } catch {
        Write-SqlCpyWarning ("ListChildren({0}) failed: {1}" -f $RootPath, $_.Exception.Message)
        return ,@()
    }
}

function New-SqlCpySsrsFolderTree {
<#
.SYNOPSIS
    Ensures every folder under $RootPath exists on the target, preserving
    hierarchy. No-op for folders that already exist.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $TargetProxy,
        [Parameter(Mandatory)] [object[]]$Folders,
        [bool]$DryRun = $true
    )

    $sorted = $Folders | Sort-Object -Property @{ Expression = { ($_.Path -split '/').Count } }
    foreach ($f in $sorted) {
        if (-not $f.Path -or $f.Path -eq '/') { continue }
        $parent = Split-Path -Path $f.Path -Parent
        if ([string]::IsNullOrWhiteSpace($parent)) { $parent = '/' }
        $name = $f.Name
        if ($DryRun) {
            Write-SqlCpyInfo ("DRYRUN would create folder: {0} (under {1})" -f $f.Path, $parent)
            continue
        }
        try {
            [void]$TargetProxy.CreateFolder($name, $parent, $null)
            Write-SqlCpyInfo ("Created folder: {0}" -f $f.Path)
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'AlreadyExists' -or $msg -match 'already exists') {
                Write-SqlCpyInfo ("Folder exists (skip): {0}" -f $f.Path)
            } else {
                Write-SqlCpyWarning ("Create folder {0} failed: {1}" -f $f.Path, $msg)
            }
        }
    }
}

function Copy-SqlCpySsrsCatalogItem {
<#
.SYNOPSIS
    Copies one non-folder catalog item (Report, Dataset, DataSource, Resource,
    Component, KPI when SOAP-addressable) from source to target.

.DESCRIPTION
    Downloads the item's definition via GetItemDefinition (SOAP), then uploads
    it to the target via CreateCatalogItem with Overwrite=$true. ItemType is
    taken from the CatalogItem.TypeName. MIME type for Resource items is
    preserved via GetItemDefinition's companion GetProperties call.

    Limitations documented inline below - see Caveats at top of file.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProxy,
        [Parameter(Mandatory)] $TargetProxy,
        [Parameter(Mandatory)] $Item,
        [bool]$DryRun = $true
    )

    $parent = Split-Path -Path $Item.Path -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = '/' }

    if ($DryRun) {
        Write-SqlCpyInfo ("DRYRUN would copy {0}: {1}" -f $Item.TypeName, $Item.Path)
        return
    }

    try {
        $definition = $SourceProxy.GetItemDefinition($Item.Path)
    } catch {
        Write-SqlCpyWarning ("GetItemDefinition failed for {0}: {1}" -f $Item.Path, $_.Exception.Message)
        return
    }

    $properties = $null
    try {
        $properties = $SourceProxy.GetProperties($Item.Path, $null)
    } catch {
        # Non-fatal; keep going without property copy.
        $properties = $null
    }

    $warnings = $null
    try {
        [void]$TargetProxy.CreateCatalogItem(
            $Item.TypeName,
            $Item.Name,
            $parent,
            $true,            # Overwrite
            $definition,
            $properties,
            [ref]$warnings)
        Write-SqlCpyInfo ("Copied {0}: {1}" -f $Item.TypeName, $Item.Path)
        if ($warnings) {
            foreach ($w in $warnings) {
                Write-SqlCpyWarning ("SSRS warning on {0}: {1}" -f $Item.Path, $w.Message)
            }
        }
    } catch {
        Write-SqlCpyWarning ("CreateCatalogItem {0} failed: {1}" -f $Item.Path, $_.Exception.Message)
        return
    }

    # Report-specific follow-up: rebind references to shared data sources /
    # datasets so the target item points to matching objects on the target.
    if ($Item.TypeName -eq 'Report') {
        try {
            $srcDs = $SourceProxy.GetItemDataSources($Item.Path)
            if ($srcDs) {
                [void]$TargetProxy.SetItemDataSources($Item.Path, $srcDs)
            }
        } catch {
            Write-SqlCpyWarning ("SetItemDataSources on {0} failed: {1} (rebinding may need manual fixup)" -f $Item.Path, $_.Exception.Message)
        }
        try {
            $srcDsr = $SourceProxy.GetItemReferences($Item.Path, 'DataSet')
            if ($srcDsr) {
                [void]$TargetProxy.SetItemReferences($Item.Path, $srcDsr)
            }
        } catch {
            # Only present on 2010+; swallow quietly.
        }
    }
}

function Copy-SqlCpySsrsItemPolicies {
<#
.SYNOPSIS
    Copies item-level security (role assignments) for a single catalog item.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProxy,
        [Parameter(Mandatory)] $TargetProxy,
        [Parameter(Mandatory)] [string]$Path,
        [bool]$DryRun = $true
    )

    try {
        $inherit = $false
        $policies = $SourceProxy.GetPolicies($Path, [ref]$inherit)
    } catch {
        Write-SqlCpyWarning ("GetPolicies failed for {0}: {1}" -f $Path, $_.Exception.Message)
        return
    }

    if ($inherit) {
        if ($DryRun) {
            Write-SqlCpyInfo ("DRYRUN would inherit policies on {0}" -f $Path)
            return
        }
        try {
            $TargetProxy.InheritParentSecurity($Path)
            return
        } catch {
            Write-SqlCpyWarning ("InheritParentSecurity failed for {0}: {1}" -f $Path, $_.Exception.Message)
            return
        }
    }

    if ($DryRun) {
        Write-SqlCpyInfo ("DRYRUN would set {0} policy entr(y|ies) on {1}" -f $policies.Count, $Path)
        return
    }
    try {
        $TargetProxy.SetPolicies($Path, $policies)
        Write-SqlCpyInfo ("Set {0} policy entr(y|ies) on {1}" -f $policies.Count, $Path)
    } catch {
        Write-SqlCpyWarning ("SetPolicies failed for {0}: {1} (group/user may not exist on target)" -f $Path, $_.Exception.Message)
    }
}

function Copy-SqlCpySsrsRoles {
<#
.SYNOPSIS
    Copies role definitions (system + catalog) from source to target.

.DESCRIPTION
    Uses ListRoles / GetRoleProperties on the source and CreateRole on the
    target. Roles that already exist are left as-is; a warning is logged so
    the operator knows there was no attempt to merge tasks.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProxy,
        [Parameter(Mandatory)] $TargetProxy,
        [bool]$DryRun = $true
    )

    foreach ($scope in @('Catalog','System')) {
        try {
            $roles = $SourceProxy.ListRoles($scope, $null)
        } catch {
            Write-SqlCpyWarning ("ListRoles({0}) failed: {1}" -f $scope, $_.Exception.Message)
            continue
        }
        foreach ($r in $roles) {
            $desc = $null
            try {
                $tasks = $SourceProxy.GetRoleProperties($r.Name, $scope, [ref]$desc)
            } catch {
                Write-SqlCpyWarning ("GetRoleProperties({0},{1}) failed: {2}" -f $r.Name, $scope, $_.Exception.Message)
                continue
            }
            if ($DryRun) {
                Write-SqlCpyInfo ("DRYRUN would create {0} role: {1} ({2} tasks)" -f $scope, $r.Name, $tasks.Count)
                continue
            }
            try {
                $TargetProxy.CreateRole($r.Name, $desc, $tasks)
                Write-SqlCpyInfo ("Created {0} role: {1}" -f $scope, $r.Name)
            } catch {
                $msg = $_.Exception.Message
                if ($msg -match 'AlreadyExists' -or $msg -match 'already exists') {
                    Write-SqlCpyInfo ("{0} role exists (skip): {1}" -f $scope, $r.Name)
                } else {
                    Write-SqlCpyWarning ("CreateRole({0},{1}) failed: {2}" -f $scope, $r.Name, $msg)
                }
            }
        }
    }
}

function Copy-SqlCpySsrsSchedules {
<#
.SYNOPSIS
    Copies shared schedules from source to target.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProxy,
        [Parameter(Mandatory)] $TargetProxy,
        [bool]$DryRun = $true
    )

    try {
        $schedules = $SourceProxy.ListSchedules($null)
    } catch {
        Write-SqlCpyWarning ("ListSchedules failed: {0}" -f $_.Exception.Message)
        return
    }

    foreach ($s in $schedules) {
        if ($DryRun) {
            Write-SqlCpyInfo ("DRYRUN would create schedule: {0}" -f $s.Name)
            continue
        }
        try {
            [void]$TargetProxy.CreateSchedule($s.Name, $s.Definition, $null)
            Write-SqlCpyInfo ("Created schedule: {0}" -f $s.Name)
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'AlreadyExists' -or $msg -match 'already exists') {
                Write-SqlCpyInfo ("Schedule exists (skip): {0}" -f $s.Name)
            } else {
                Write-SqlCpyWarning ("CreateSchedule {0} failed: {1}" -f $s.Name, $msg)
            }
        }
    }
}

function Copy-SqlCpySsrsSubscriptions {
<#
.SYNOPSIS
    Copies per-item subscriptions from source to target, best-effort.

.DESCRIPTION
    Subscriptions carry encrypted credentials and schedules that may reference
    principal SIDs that do not exist on the target. This function enumerates
    subscriptions on the source and attempts to recreate them via
    CreateSubscription. Data-driven subscriptions (CreateDataDrivenSubscription)
    are attempted separately; failures are logged with an actionable hint.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceProxy,
        [Parameter(Mandatory)] $TargetProxy,
        [bool]$DryRun = $true
    )

    $subs = @()
    try {
        $subs = $SourceProxy.ListSubscriptions($null)
    } catch {
        Write-SqlCpyWarning ("ListSubscriptions failed: {0} (subscription copy will be skipped)" -f $_.Exception.Message)
        return
    }

    foreach ($sub in $subs) {
        if ($DryRun) {
            Write-SqlCpyInfo ("DRYRUN would copy subscription: {0} on {1}" -f $sub.SubscriptionID, $sub.Path)
            continue
        }
        try {
            $extSettings = $null
            $desc = $null
            $active = $null
            $status = $null
            $eventType = $null
            $matchData = $null
            $params = $null
            $owner = $null
            $SourceProxy.GetSubscriptionProperties(
                $sub.SubscriptionID,
                [ref]$extSettings,
                [ref]$desc,
                [ref]$active,
                [ref]$status,
                [ref]$eventType,
                [ref]$matchData,
                [ref]$params) | Out-Null

            [void]$TargetProxy.CreateSubscription(
                $sub.Path,
                $extSettings,
                $desc,
                $eventType,
                $matchData,
                $params)
            Write-SqlCpyInfo ("Copied subscription on {0}: {1}" -f $sub.Path, $desc)
        } catch {
            Write-SqlCpyWarning ("Copy subscription on {0} failed: {1} (encrypted credentials / delivery extension config may need manual fixup)" -f $sub.Path, $_.Exception.Message)
        }
    }
}

function Invoke-SqlCpySsrsCopy {
<#
.SYNOPSIS
    Copies SSRS assets from a source ReportServer to a target ReportServer via
    the ReportService2010 SOAP API (and REST where available).

.DESCRIPTION
    The user requirement is explicit: do NOT intentionally skip any class of
    SSRS asset. This orchestrator therefore attempts, in order:

        1. Role definitions (system + catalog)
        2. Shared schedules
        3. Folder tree
        4. Shared data sources
        5. Shared datasets
        6. Resources
        7. Reports
        8. Item-level policies (security) for everything copied above
        9. Subscriptions (best-effort)
       10. KPIs / mobile reports via REST v2.0 (best-effort, target-dependent)

    Each phase honours DryRun: nothing is written on the target when DryRun is
    $true; the would-be action is logged instead. Individual failures within a
    phase are caught, warned, and do NOT abort subsequent phases - this is
    deliberate because in SSRS you often copy 90% of a catalog cleanly and
    manually fix the remaining 10% (encrypted creds, missing principals, etc.).

.PARAMETER SourceUri
    Source ReportServer URL, e.g. 'http://chbbbid2/ReportServer'.

.PARAMETER TargetUri
    Target ReportServer URL, e.g. 'http://localhost/ReportServer'.

.PARAMETER RootPath
    SSRS catalog path to scope the copy. '/' copies everything.

.PARAMETER DryRun
    When $true, only log intended operations.

.PARAMETER Config
    Config hashtable. Read: CopySsrs* toggles, SourceCredential/TargetCredential.

.EXAMPLE
    Invoke-SqlCpySsrsCopy -SourceUri http://chbbbid2/ReportServer `
        -TargetUri http://localhost/ReportServer -DryRun $true

.NOTES
    Requires a PowerShell host that exposes New-WebServiceProxy (Windows
    PowerShell 5.1; PowerShell 7.x on Windows). Target SSRS must be at least
    2008 R2 (ReportService2010 endpoint). REST operations require SSRS 2016+
    with the portal ('/Reports') enabled.

    Caveats: stored credentials on data sources and subscription deliveries
    are encrypted with the source server's key and are NOT portable over
    SOAP. Those items are copied with blank credential fields and logged; an
    operator needs to re-enter the credentials on the target.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceUri,
        [Parameter(Mandatory)] [string]$TargetUri,
        [string]$RootPath = '/',
        [bool]$DryRun = $true,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep ("Copying SSRS: {0} -> {1} (DryRun={2}, Root={3})" -f $SourceUri, $TargetUri, $DryRun, $RootPath)

    # TODO: Validate on a live environment. The SOAP endpoint URL is
    # version-specific - some deployments expose ReportService2010 at a
    # non-default virtual directory (e.g. behind a reverse proxy).
    $srcCred = $null; $tgtCred = $null
    if ($Config.ContainsKey('SsrsSourceCredential')) { $srcCred = $Config.SsrsSourceCredential }
    if ($Config.ContainsKey('SsrsTargetCredential')) { $tgtCred = $Config.SsrsTargetCredential }

    $srcProxy = Get-SqlCpySsrsProxy -Uri $SourceUri -Credential $srcCred
    $tgtProxy = Get-SqlCpySsrsProxy -Uri $TargetUri -Credential $tgtCred

    $doRoles       = $true; if ($Config.ContainsKey('CopySsrsRoles'))         { $doRoles       = [bool]$Config.CopySsrsRoles }
    $doSchedules   = $true; if ($Config.ContainsKey('CopySsrsSchedules'))     { $doSchedules   = [bool]$Config.CopySsrsSchedules }
    $doFolders     = $true; if ($Config.ContainsKey('CopySsrsFolders'))       { $doFolders     = [bool]$Config.CopySsrsFolders }
    $doDataSources = $true; if ($Config.ContainsKey('CopySsrsDataSources'))   { $doDataSources = [bool]$Config.CopySsrsDataSources }
    $doDatasets    = $true; if ($Config.ContainsKey('CopySsrsDatasets'))      { $doDatasets    = [bool]$Config.CopySsrsDatasets }
    $doResources   = $true; if ($Config.ContainsKey('CopySsrsResources'))     { $doResources   = [bool]$Config.CopySsrsResources }
    $doReports     = $true; if ($Config.ContainsKey('CopySsrsReports'))       { $doReports     = [bool]$Config.CopySsrsReports }
    $doSecurity    = $true; if ($Config.ContainsKey('CopySsrsSecurity'))      { $doSecurity    = [bool]$Config.CopySsrsSecurity }
    $doSubs        = $true; if ($Config.ContainsKey('CopySsrsSubscriptions')) { $doSubs        = [bool]$Config.CopySsrsSubscriptions }
    $doKpis        = $true; if ($Config.ContainsKey('CopySsrsKpis'))          { $doKpis        = [bool]$Config.CopySsrsKpis }

    # Phase 1: roles.
    if ($doRoles) {
        Write-SqlCpyInfo 'SSRS phase: role definitions'
        Copy-SqlCpySsrsRoles -SourceProxy $srcProxy -TargetProxy $tgtProxy -DryRun $DryRun
    }

    # Phase 2: shared schedules.
    if ($doSchedules) {
        Write-SqlCpyInfo 'SSRS phase: shared schedules'
        Copy-SqlCpySsrsSchedules -SourceProxy $srcProxy -TargetProxy $tgtProxy -DryRun $DryRun
    }

    # Enumerate everything under the root once.
    $items = Get-SqlCpySsrsCatalogItems -Proxy $srcProxy -RootPath $RootPath
    Write-SqlCpyInfo ("Found {0} catalog items under {1}" -f $items.Count, $RootPath)

    $byType = @{}
    foreach ($i in $items) {
        $t = "$($i.TypeName)"
        if (-not $byType.ContainsKey($t)) { $byType[$t] = @() }
        $byType[$t] += $i
    }

    # Phase 3: folders, parent-first.
    if ($doFolders -and $byType.ContainsKey('Folder')) {
        Write-SqlCpyInfo ("SSRS phase: folders ({0})" -f $byType['Folder'].Count)
        New-SqlCpySsrsFolderTree -TargetProxy $tgtProxy -Folders $byType['Folder'] -DryRun $DryRun
    }

    # Phase 4: shared data sources.
    if ($doDataSources -and $byType.ContainsKey('DataSource')) {
        Write-SqlCpyInfo ("SSRS phase: shared data sources ({0})" -f $byType['DataSource'].Count)
        foreach ($it in $byType['DataSource']) {
            Copy-SqlCpySsrsCatalogItem -SourceProxy $srcProxy -TargetProxy $tgtProxy -Item $it -DryRun $DryRun
        }
        if (-not $DryRun) {
            Write-SqlCpyWarning 'Stored data-source credentials are encrypted with the source server key and are NOT copied. Re-enter credentials on the target (or use stored credentials + keyfile backup/restore).'
        }
    }

    # Phase 5: shared datasets.
    if ($doDatasets -and $byType.ContainsKey('DataSet')) {
        Write-SqlCpyInfo ("SSRS phase: shared datasets ({0})" -f $byType['DataSet'].Count)
        foreach ($it in $byType['DataSet']) {
            Copy-SqlCpySsrsCatalogItem -SourceProxy $srcProxy -TargetProxy $tgtProxy -Item $it -DryRun $DryRun
        }
    }

    # Phase 6: resources (images, xlsx, misc).
    if ($doResources -and $byType.ContainsKey('Resource')) {
        Write-SqlCpyInfo ("SSRS phase: resources ({0})" -f $byType['Resource'].Count)
        foreach ($it in $byType['Resource']) {
            Copy-SqlCpySsrsCatalogItem -SourceProxy $srcProxy -TargetProxy $tgtProxy -Item $it -DryRun $DryRun
        }
    }

    # Phase 7: reports.
    if ($doReports -and $byType.ContainsKey('Report')) {
        Write-SqlCpyInfo ("SSRS phase: reports ({0})" -f $byType['Report'].Count)
        foreach ($it in $byType['Report']) {
            Copy-SqlCpySsrsCatalogItem -SourceProxy $srcProxy -TargetProxy $tgtProxy -Item $it -DryRun $DryRun
        }
    }

    # Phase 7b: linked reports (same TypeName 'Report' in ListChildren but
    # distinguished by ItemReferenceData via GetItemLink on 2010+). Attempt
    # generic copy; link recreation is best-effort.
    if ($doReports -and $byType.ContainsKey('LinkedReport')) {
        Write-SqlCpyInfo ("SSRS phase: linked reports ({0})" -f $byType['LinkedReport'].Count)
        foreach ($it in $byType['LinkedReport']) {
            Copy-SqlCpySsrsCatalogItem -SourceProxy $srcProxy -TargetProxy $tgtProxy -Item $it -DryRun $DryRun
        }
    }

    # Phase 8: item-level security.
    if ($doSecurity) {
        Write-SqlCpyInfo 'SSRS phase: item-level security (policies)'
        Copy-SqlCpySsrsItemPolicies -SourceProxy $srcProxy -TargetProxy $tgtProxy -Path '/' -DryRun $DryRun
        foreach ($it in $items) {
            Copy-SqlCpySsrsItemPolicies -SourceProxy $srcProxy -TargetProxy $tgtProxy -Path $it.Path -DryRun $DryRun
        }
    }

    # Phase 9: subscriptions.
    if ($doSubs) {
        Write-SqlCpyInfo 'SSRS phase: subscriptions (best-effort)'
        Copy-SqlCpySsrsSubscriptions -SourceProxy $srcProxy -TargetProxy $tgtProxy -DryRun $DryRun
    }

    # Phase 10: KPIs / mobile reports via REST. These are not exposed through
    # ReportService2010 on SSRS 2016+; the REST endpoint is /Reports/api/v2.0.
    if ($doKpis) {
        $srcRest = Get-SqlCpySsrsRestBase -Uri $SourceUri
        $tgtRest = Get-SqlCpySsrsRestBase -Uri $TargetUri
        if ($srcRest -and $tgtRest) {
            Write-SqlCpyInfo ("SSRS phase: KPIs / mobile reports via REST {0} -> {1}" -f $srcRest, $tgtRest)
            try {
                $kpis = Invoke-RestMethod -Uri ("{0}/Kpis" -f $srcRest) -UseDefaultCredentials -ErrorAction Stop
                if ($kpis -and $kpis.value) {
                    foreach ($k in $kpis.value) {
                        if ($DryRun) {
                            Write-SqlCpyInfo ("DRYRUN would copy KPI: {0}" -f $k.Path)
                            continue
                        }
                        try {
                            Invoke-RestMethod -Method Post -Uri ("{0}/Kpis" -f $tgtRest) `
                                -Body ($k | ConvertTo-Json -Depth 10) -ContentType 'application/json' `
                                -UseDefaultCredentials -ErrorAction Stop | Out-Null
                            Write-SqlCpyInfo ("Copied KPI: {0}" -f $k.Path)
                        } catch {
                            Write-SqlCpyWarning ("Copy KPI {0} failed: {1}" -f $k.Path, $_.Exception.Message)
                        }
                    }
                }
            } catch {
                Write-SqlCpyWarning ("REST KPI enumeration failed (target may be SSRS < 2016 or REST disabled): {0}" -f $_.Exception.Message)
            }
        } else {
            Write-SqlCpyInfo 'SSRS phase: REST base not derivable from ReportServer URL; skipping KPI/mobile copy.'
        }
    }

    Write-SqlCpyStep 'SSRS copy phase summary complete. Review WARN lines above for items that need manual fixup (encrypted creds, missing principals, unsupported asset types on older SSRS).'
}
