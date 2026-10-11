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
$identity = & (Get-Module AzVmUpgrade) { param($id) Get-VmIdentity $id } $preparation.vmId
if ($identity.resourceGroup -ine $context.testResourceGroup) { throw 'VM is outside the approved test resource group.' }

$result = [ordered]@{ schemaVersion = 'live-preparation-acceptance/1.0'; preparationHash = $preparation.hash; steps = @(); status = 'in-progress' }
Write-UpgradeJson $result $OutputPath
$step = { param($name, $status, $detail) $result.steps += @{ at = [DateTimeOffset]::UtcNow.ToString('o'); name = $name; status = $status; detail = $detail }; Write-UpgradeJson $result $OutputPath }
try {
    $manifest = Invoke-GuestPreparation -Preparation $preparation -Action apply -GuestConsent -JournalDirectory $JournalDirectory -Confirm:$false
    Write-UpgradeJson $manifest "$OutputPath.apply.json"
    & $step 'apply' 'pass' "changes=$(@($manifest.changes).Count)"
    Restart-VmForPreparation -Preparation $preparation -RebootConsent -JournalDirectory $JournalDirectory -Confirm:$false | Out-Null
    & $step 'restart' 'pass' 'restart only'
    $post = Get-VmEvidence -VmId $preparation.vmId -GuestConsent -ObservationPath "$OutputPath.reassessment"
    Write-UpgradeJson $post "$OutputPath.reassessment.json"
    $outcome = Test-PreparationOutcome -Preparation $preparation -Manifest $manifest -PostEvidence $post
    Write-UpgradeJson $outcome "$OutputPath.outcome.json"
    & $step 'reassessment' $outcome.status (($outcome.checks | Where-Object status -EQ 'failed' | ForEach-Object name) -join ',')
    if ($outcome.status -ne 'accepted') { throw 'Post-preparation reassessment rejected.' }
    if (-not $preparation.preState.sentinelHash -or $post.guest.sentinelHash -cne $preparation.preState.sentinelHash -or
        $post.guest.applicationHealth -ne 'pass') { throw 'Live lab requires a preserved baseline data checksum and healthy application sentinel.' }
    & $step 'managed-data-and-health' 'pass' 'fresh guest probe matches the plan-bound checksum and health sentinel'
    if ($TerraformNoOpEvidencePath) {
        if (-not (Test-Path -LiteralPath $TerraformNoOpEvidencePath)) { throw 'Terraform no-op evidence file is missing.' }
        $tf = Read-UpgradeJson $TerraformNoOpEvidencePath
        if (-not $context.terraformVmAddress) { throw 'Supply the exact Terraform VM address; a status-only attestation is not plan evidence.' }
        $check = Test-TerraformUpgradePlan -Plan $tf -Mapping @{ vmAddress = $context.terraformVmAddress } -VmId $preparation.vmId `
            -TargetSize $post.vm.hardwareProfile.vmSize -Controller $post.vm.storageProfile.diskControllerType -Reconciliation `
            -ExpectedEncryptionAtHost $post.vm.securityProfile.encryptionAtHost
        if ($check.status -ne 'pass') { throw $check.detail }
        & $step 'terraform-no-op' 'pass' "normal Terraform plan JSON verified; SHA256=$(Get-UpgradeHash $tf)"
    } else { & $step 'terraform-no-op' 'skipped' 'no evidence supplied' }
    if ($context.rollbackApproved -eq $true) {
        $rb = Invoke-GuestPreparation -Preparation $preparation -Action rollback -GuestConsent -RollbackAcknowledged -JournalDirectory $JournalDirectory -Confirm:$false
        Write-UpgradeJson $rb "$OutputPath.rollback.json"
        & $step 'rollback-command' 'pass' "changes=$(@($rb.changes).Count); this alone does not prove restoration"
        Restart-VmForPreparation -Preparation $preparation -RebootConsent -JournalDirectory $JournalDirectory -Confirm:$false | Out-Null
        $restored = Get-VmEvidence -VmId $preparation.vmId -GuestConsent -ObservationPath "$OutputPath.rollback-reboot"
        Write-UpgradeJson $restored "$OutputPath.rollback-reboot.json"
        $modelHash = & (Get-Module AzVmUpgrade) { param($evidence) Get-PreparationModelHash $evidence } $restored
        if ($modelHash -cne $preparation.expectedModelHash) { throw 'Azure configuration or encryption changed during rollback reboot.' }
        if (-not $restored.guest.bootId -or $restored.guest.bootId -ceq $post.guest.bootId -or
            $restored.guest.pendingReboot -ne $false -or $restored.guest.agentReady -ne $true -or
            $restored.guest.persistentMounts -ne $true -or $restored.guest.storageIdentityHash -cne $preparation.expectedStorageIdentityHash -or
            $restored.guest.sentinelHash -cne $preparation.preState.sentinelHash -or $restored.guest.applicationHealth -ne 'pass') {
            throw 'Rollback reboot/data/mount/health evidence did not pass; preservation is not proven.'
        }
        & $step 'rollback-reboot-and-preservation' 'pass' 'fresh boot ID, agent, mounts, data checksum and application sentinel; not VM-level restoration or exact driver-store restoration'
    } else { & $step 'rollback' 'skipped' 'rollbackApproved not set' }
    $result.status = 'completed'
} catch {
    $result.status = 'failed'; $result.error = $_.Exception.Message
    throw
} finally { Write-UpgradeJson $result $OutputPath }
