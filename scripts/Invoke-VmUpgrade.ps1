#Requires -Version 7.5
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$PlanPath, [Parameter(Mandatory)][string]$ApprovalPath,
    [string]$JournalDirectory = '.\out\journals', [switch]$Resume,
    [string]$TerraformReconciliationPath, [string]$OwnerAcceptancePath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
Invoke-VmUpgrade -PlanPath $PlanPath -ApprovalPath $ApprovalPath -JournalDirectory $JournalDirectory `
    -Resume:$Resume -TerraformReconciliationPath $TerraformReconciliationPath -OwnerAcceptancePath $OwnerAcceptancePath -WhatIf:$WhatIfPreference
