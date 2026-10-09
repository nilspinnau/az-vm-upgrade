#Requires -Version 7.5
param([string]$OutputDirectory = '.\out\synthetic-example')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
. (Join-Path $PSScriptRoot '..\tests\Fixtures.ps1')
$evidence = New-FixtureEvidence
$evidence.guest = $null
$evidence.vm.hardwareProfile.vmSize = 'Standard_D2s_v3'
$evidence.skus[0].name = 'Standard_D2s_v3'
$evidence.skus[0].family = 'standardDSv3Family'
($evidence.usage | Where-Object { $_.name.value -eq 'standardDSv5Family' }).name.value = 'standardDSv3Family'
$evidence.fingerprint = & (Get-Module AzVmUpgrade) { param($e) Get-ConfigurationFingerprint $e } $evidence
$plan = New-VmUpgradePlan $evidence -TargetSize Standard_D2s_v6 -Controller NVMe
Export-VmUpgradeReport $plan $OutputDirectory
