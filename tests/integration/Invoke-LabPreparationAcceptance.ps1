#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PreparationPath,
    [Parameter(Mandatory)][string]$TestContextPath,
    [Parameter(Mandatory)][switch]$LiveTestConsent,
    [string]$OutputPath = '.\out\live-preparation-acceptance.json',
    [string]$JournalDirectory = '.\out\journals',
    [string]$TerraformNoOpEvidencePath
)
$ErrorActionPreference = 'Stop'
if (-not $LiveTestConsent) { throw 'Live preparation tests require explicit approval; offline CI never invokes this script.' }
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
$preparation = Read-UpgradeJson $PreparationPath
$context = Read-UpgradeJson $TestContextPath
Test-UpgradeDocument $preparation preparation | Out-Null
if ($context.preparationHash -cne $preparation.hash -or $context.vmId -ine $preparation.vmId) { throw 'Test context must bind to the exact preparation request.' }
foreach ($flag in @('labOnly', 'guestConsent', 'restartApproved', 'exclusiveWindow')) {
    if ($context[$flag] -ne $true) { throw "Explicit $flag approval required for live tests." }
}
if ([DateTimeOffset]::Parse($context.expiresAt) -le [DateTimeOffset]::UtcNow) { throw 'Live test context expired.' }
if (-not $context.testResourceGroup -or -not $context.dataSentinelNote) { throw 'Exact test group and a data-sentinel procedure are required.' }
if (Test-Path -LiteralPath $OutputPath) { throw 'Preserve the existing result; select a new output path.' }
$identity = Get-VmIdentity $preparation.vmId
if ($identity.resourceGroup -ine $context.testResourceGroup) { throw 'VM is outside the approved test resource group.' }

$result = [ordered]@{ schemaVersion = 'live-preparation-acceptance/1.0'; preparationHash = $preparation.hash; steps = @(); status = 'in-progress' }
Write-UpgradeJson $result $OutputPath
$step = { param($name, $status, $detail) $result.steps += @{ at = [DateTimeOffset]::UtcNow.ToString('o'); name = $name; status = $status; detail = $detail }; Write-UpgradeJson $result $OutputPath }
try {
    $manifest = Invoke-GuestPreparation -Preparation $preparation -Action apply -GuestConsent -JournalDirectory $JournalDirectory -Confirm:$false
    & $step 'apply' 'pass' "changes=$(@($manifest.changes).Count)"
    Restart-VmForPreparation -Preparation $preparation -RebootConsent -JournalDirectory $JournalDirectory -Confirm:$false | Out-Null
    & $step 'restart' 'pass' 'restart only'
    $post = Get-VmEvidence -VmId $preparation.vmId -GuestConsent
    $outcome = Test-PreparationOutcome -Preparation $preparation -Manifest $manifest -PostEvidence $post
    & $step 'reassessment' $outcome.status (($outcome.checks | Where-Object status -EQ 'failed' | ForEach-Object name) -join ',')
    if ($outcome.status -ne 'accepted') { throw 'Post-preparation reassessment rejected.' }
    if ($TerraformNoOpEvidencePath) {
        if (-not (Test-Path -LiteralPath $TerraformNoOpEvidencePath)) { throw 'Terraform no-op evidence file is missing.' }
        $tf = Read-UpgradeJson $TerraformNoOpEvidencePath
        if ($tf.status -ne 'no-op' -or $tf.vmId -ine $preparation.vmId) { throw 'Terraform evidence is not an exact no-op for this VM.' }
        & $step 'terraform-no-op' 'pass' 'operator-supplied plan evidence'
    } else { & $step 'terraform-no-op' 'skipped' 'no evidence supplied' }
    if ($context.rollbackApproved -eq $true) {
        $rb = Invoke-GuestPreparation -Preparation $preparation -Action rollback -GuestConsent -RollbackAcknowledged -JournalDirectory $JournalDirectory -Confirm:$false
        & $step 'rollback' 'pass' "changes=$(@($rb.changes).Count); restoration still needs reboot and fresh evidence"
    } else { & $step 'rollback' 'skipped' 'rollbackApproved not set' }
    $result.status = 'completed'
} catch {
    $result.status = 'failed'; $result.error = $_.Exception.Message
    throw
} finally { Write-UpgradeJson $result $OutputPath }
