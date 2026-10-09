#Requires -Version 7.5
<#
Plan-bound guest preparation entry point. Never resizes, deallocates or changes the controller.
  New    : create a preparation request from an approved, fresh plan (needs -GuestChangeConsent)
  Apply  : run the bounded guest procedure (Run Command), journaled, locked
  Restart: separate-consent restart only
  Verify : evaluate fresh post-reboot guest evidence
  Status / Rollback / Guide as named.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('New', 'Apply', 'Restart', 'Verify', 'Status', 'Rollback', 'Guide')][string]$Mode,
    [string]$PlanPath, [string]$PreparationPath = '.\out\preparation.json',
    [string[]]$Component, [string]$DriverPackagePath, [string]$DriverPackageSha256,
    [switch]$GuestChangeConsent, [switch]$RebootConsent, [switch]$RollbackAcknowledged,
    [string]$JournalDirectory = '.\out\journals'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
switch ($Mode) {
    'New' {
        $plan = Read-UpgradeJson $PlanPath
        $arguments = @{ Plan = $plan; Component = $Component; GuestChangeConsent = $GuestChangeConsent }
        if ($DriverPackagePath) { $arguments.DriverPackagePath = $DriverPackagePath; $arguments.DriverPackageSha256 = $DriverPackageSha256 }
        $document = New-GuestPreparationPlan @arguments
        [IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($PreparationPath)))) | Out-Null
        Write-UpgradeJson $document $PreparationPath
        "Preparation request written to $PreparationPath"
    }
    'Apply' { Invoke-GuestPreparation -Preparation (Read-UpgradeJson $PreparationPath) -Action apply -GuestConsent:$GuestChangeConsent -JournalDirectory $JournalDirectory }
    'Status' { Invoke-GuestPreparation -Preparation (Read-UpgradeJson $PreparationPath) -Action status -GuestConsent:$GuestChangeConsent -JournalDirectory $JournalDirectory }
    'Rollback' { Invoke-GuestPreparation -Preparation (Read-UpgradeJson $PreparationPath) -Action rollback -GuestConsent:$GuestChangeConsent -RollbackAcknowledged:$RollbackAcknowledged -JournalDirectory $JournalDirectory }
    'Restart' { Restart-VmForPreparation -Preparation (Read-UpgradeJson $PreparationPath) -RebootConsent:$RebootConsent -JournalDirectory $JournalDirectory }
    'Verify' {
        $preparation = Read-UpgradeJson $PreparationPath
        $journal = Read-UpgradeJson (Join-Path $JournalDirectory "prep-$($preparation.hash.Substring(0,16)).journal.json")
        $post = Get-VmEvidence -VmId $preparation.vmId -GuestConsent:$GuestChangeConsent
        Test-PreparationOutcome -Preparation $preparation -Manifest $journal.manifest -PostEvidence $post | ConvertTo-Json -Depth 10
    }
    'Guide' { Get-PreparationRecoveryGuide (Join-Path $JournalDirectory "prep-$((Read-UpgradeJson $PreparationPath).hash.Substring(0,16)).journal.json") }
}
