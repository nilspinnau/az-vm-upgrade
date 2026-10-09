@{
    RootModule = 'AzVmUpgrade.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'fbf105f1-402b-4f6b-a5c1-4a107374ab7d'
    Author = 'az-vm-upgrade contributors'
    Description = 'Evidence-led Azure VM discovery, planning and gated disposable-lab upgrades.'
    PowerShellVersion = '7.5'
    FunctionsToExport = @(
        'Get-VmInventory', 'Get-VmEvidence', 'New-VmUpgradePlan',
        'Export-VmUpgradeReport', 'Invoke-VmUpgrade', 'Get-VmRecoveryGuide',
        'Test-TerraformUpgradePlan', 'Get-UpgradeHash', 'Read-UpgradeJson',
        'Write-UpgradeJson', 'Test-UpgradeDocument', 'Get-SkuCapability',
        'Get-QuotaProjection', 'Get-LifecycleFinding', 'Test-TargetCompatibility',
        'Get-BackendCatalog', 'Test-BackendFile', 'New-ExternalBackendPlan', 'Test-ExternalBackendResult',
        'New-GuestPreparationPlan', 'Invoke-GuestPreparation', 'Restart-VmForPreparation', 'Test-PreparationOutcome', 'Get-PreparationRecoveryGuide'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('Azure','VirtualMachine','Upgrade') } }
}
