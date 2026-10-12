#Requires -Version 7.5
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory,ParameterSetName='Live')][string]$VmId,
    [Parameter(Mandatory,ParameterSetName='Offline')][string]$EvidencePath,
    [Parameter(ParameterSetName='Live')][switch]$GuestConsent,
    [Parameter(ParameterSetName='Live')][switch]$GuestNetworkProbeConsent,
    [string]$TargetSize, [ValidateSet('SCSI','NVMe')][string]$Controller,
    [ValidateSet('PreferRunning','Deallocate')][string]$ResizeMode = 'PreferRunning',
    [string]$WorkloadReviewPath, [string]$TerraformMappingPath, [string]$TerraformPlanPath,
    [string]$OutputDirectory = '.\out\vm-plan'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
$evidence = if ($PSCmdlet.ParameterSetName -eq 'Offline') { Read-UpgradeJson $EvidencePath } else { Get-VmEvidence -VmId $VmId -GuestConsent:$GuestConsent -GuestNetworkProbeConsent:$GuestNetworkProbeConsent }
$parameters = @{ Evidence = $evidence; TargetSize = $TargetSize; ResizeMode = $ResizeMode }
if ($Controller) { $parameters.Controller = $Controller }
if ($WorkloadReviewPath) { $parameters.WorkloadReview = Read-UpgradeJson $WorkloadReviewPath }
if ($TerraformMappingPath) { $parameters.TerraformMapping = Read-UpgradeJson $TerraformMappingPath }
if ($TerraformPlanPath) { $parameters.TerraformPlan = Read-UpgradeJson $TerraformPlanPath }
$plan = New-VmUpgradePlan @parameters
Export-VmUpgradeReport $plan $OutputDirectory
