function Invoke-SqlCpySsisCatalogCopy {
<#
.SYNOPSIS
    Copies SSISDB folders, projects, environments, references, and permissions.

.DESCRIPTION
    Primary engine: dbatools Copy-DbaSsisCatalog for the catalog-level copy. For
    gaps (environment variable sensitivity handling, certain reference edge cases)
    fall back to the SqlServer PowerShell module's Integration Services provider
    or directly to Microsoft.SqlServer.Management.IntegrationServices.

    The catalog itself (SSISDB database + master key) is assumed to exist on the
    target. If it does not, the function will refuse to copy projects and prompt
    the user via the TUI to create the catalog first (out of scope for this
    initial scaffold).

    Honours the DryRun flag. Connection security parameters flow via
    Get-SqlCpyCopySplat.

.PARAMETER SourceServer
    Source SQL Server instance name.

.PARAMETER TargetServer
    Target SQL Server instance name.

.PARAMETER FolderFilter
    Optional array of catalog folder names to restrict the copy. $null = all.

.PARAMETER DryRun
    When $true, only log intended copies.

.PARAMETER Config
    Config hashtable for connection security. When omitted, Get-SqlCpyConfig is called.

.NOTES
    Requires SSISDB to exist on both source and target. Environments are copied
    with references; sensitive values may require a project password on the
    target side - this is flagged as TODO for live validation.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceServer,
        [Parameter(Mandatory)] [string]$TargetServer,
        [string[]]$FolderFilter,
        [bool]$DryRun = $true,
        [hashtable]$Config
    )

    if (-not $Config) { $Config = Get-SqlCpyConfig }

    Write-SqlCpyStep "Copying SSIS catalog: $SourceServer -> $TargetServer (DryRun=$DryRun)"

    # TODO: Validate on a live environment. Confirm the target SSISDB exists.
    # TODO: Decide how sensitive environment variables should be remapped on target.
    if ($DryRun) {
        $scope = if ($FolderFilter) { $FolderFilter -join ', ' } else { '<all folders>' }
        Write-SqlCpyInfo "DRYRUN would copy SSIS catalog folders: $scope"
        return
    }

    $params = Get-SqlCpyCopySplat -Config $Config -Source $SourceServer -Destination $TargetServer
    $params['EnableException'] = $true
    if ($FolderFilter) { $params['Folder'] = $FolderFilter }

    # TODO: Copy-DbaSsisCatalog behavior varies by dbatools version. Confirm parameter
    # set and fallback to SqlServer module's IntegrationServices provider if needed.
    Copy-DbaSsisCatalog @params
}
