@{
    RootModule        = 'SqlServerCpy.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a1f4a0b6-2d3a-4a6e-9f0c-2a8a2b7c9e10'
    Author            = 'sqlserver-cpy contributors'
    CompanyName       = 'N/A'
    Copyright         = ''
    Description       = 'PowerShell scaffold for moving Microsoft SQL Server assets between machines. Initial scaffold - see README.md.'
    PowerShellVersion = '5.1'

    # dbatools is the primary engine; SqlServer is the fallback module.
    # Listed as required so Import-Module surfaces missing deps early.
    RequiredModules   = @(
        @{ ModuleName = 'dbatools';  ModuleVersion = '2.1.0'  }
        @{ ModuleName = 'SqlServer'; ModuleVersion = '22.0.0' }
    )

    FunctionsToExport = @(
        'Get-SqlCpyConfig'
        'Get-SqlCpyRepoRoot'
        'Get-SqlCpyConnectionSplat'
        'Get-SqlCpyCopySplat'
        'Get-SqlCpyInstanceSplat'
        'Get-SqlCpyDbaConnection'
        'Get-SqlCpyDbaInstance'
        'Get-SqlCpyCachedConnection'
        'Get-SqlCpyConnectionErrorHint'
        'Get-SqlCpyCommandParameter'
        'Resolve-SqlCpyParameterName'
        'Test-SqlCpyPreflight'
        'Write-SqlCpyStep'
        'Write-SqlCpyInfo'
        'Write-SqlCpyWarning'
        'Write-SqlCpyError'
        'Show-SqlCpyErrorScreen'
        'Start-SqlCpyInteractive'
        'Invoke-SqlCpyServerConfigCompare'
        'Invoke-SqlCpyServerConfigApply'
        'Invoke-SqlCpyLoginCopy'
        'Test-SqlCpyLoginSkipped'
        'Invoke-SqlCpyAgentJobCopy'
        'Invoke-SqlCpySsisCatalogCopy'
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
        'Invoke-SqlCpySchemaOnlyDatabaseCopy'
        'Export-SqlCpySchemaOnlyDatabase'
        'New-SqlCpySchemaOnlyScriptingOption'
        'Get-SqlCpySchemaOnlyObjectTypeDefaults'
        'Get-SqlCpySchemaOnlySecurityExcludedTypes'
        'Get-SqlCpySchemaOnlyScriptPhases'
        'Get-SqlCpySchemaOnlyInlineOnlyTypes'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SQLServer', 'Migration', 'dbatools', 'SSIS', 'Scaffold')
            ProjectUri = 'https://github.com/witbakow-cell/sqlserver-cpy'
        }
    }
}
