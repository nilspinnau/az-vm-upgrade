#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$TestContextPath,
    [Parameter(Mandatory)][switch]$LiveTestConsent,
    [string]$OutputPath = '.\out\live-acceptance.json',
    [string]$JournalDirectory = '.\out\journals'
)
$ErrorActionPreference = 'Stop'
if (-not $LiveTestConsent) { throw 'Live tests require explicit disruptive-operation approval; offline CI never invokes this script.' }
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
$plan = Read-UpgradeJson $PlanPath
$context = Read-UpgradeJson $TestContextPath
Test-UpgradeDocument $plan plan | Out-Null
$unsigned = @{} + $plan; $unsigned.Remove('hash')
if ((Get-UpgradeHash $unsigned) -cne $plan.hash -or $context.planHash -cne $plan.hash -or $context.vmId -ine $plan.vmId) { throw 'Live acceptance context must bind to the exact unaltered VM upgrade plan.' }
foreach ($flag in @('labOnly','guestConsent','restartApproved','deallocateStartApproved','protectionAccepted','exclusiveWindow')) {
    if ($context[$flag] -ne $true) { throw "Explicit $flag approval required for live tests." }
}
if ($context.budgetLimit -le 0 -or -not $context.protectionReference -or -not $context.testResourceGroup) { throw 'Exact test group, approved budget and protection evidence are required.' }
if (Test-Path -LiteralPath $OutputPath) { throw 'Preserve the existing live test journal; select a new output path after reviewing any previous outcome.' }
& (Get-Module AzVmUpgrade) {
    param($plan,$context,$OutputPath,$JournalDirectory)
    function Get-CycleConfigurationHash {
        param($live)
        $model = @{vm=$live.vm;disks=@($live.disks | Sort-Object id);nics=@($live.nics | Sort-Object id)} |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        # Power operations may change ETags; all bounded configuration must remain identical.
        foreach ($resource in @($model.vm) + @($model.disks) + @($model.nics)) { $resource.Remove('etag') }
        Get-UpgradeHash $model
    }
    function Assert-LabCycle {
        param($live)
        if ([DateTimeOffset]::Parse($context.expiresAt) -le [DateTimeOffset]::UtcNow) { throw 'Live test context expired.' }
        $identity = Get-VmIdentity $plan.vmId
        if ($identity.resourceGroup -ine $context.testResourceGroup -or $live.vm.id -ine $plan.vmId -or $live.tenantId -ine $plan.tenantId -or
            $live.subscriptionId -ine $plan.subscriptionId -or $live.vm.tags['az-vm-upgrade-disposable'] -ne 'true') { throw 'Live disposable-lab identity gate failed.' }
        $target = @($live.skus | Where-Object name -CEQ $plan.targetSize)
        if ($target.Count -ne 1 -or $live.vm.hardwareProfile.vmSize -cne $plan.targetSize) { throw 'Lab VM is not at the approved target.' }
        if (@(Test-TargetCompatibility $live $target[0] $target[0] $plan.targetController | Where-Object status -NE 'pass').Count) { throw 'Current target compatibility/restrictions no longer pass.' }
        if ((Get-QuotaProjection $target[0] $target[0] $live.usage).status -ne 'pass') { throw 'Current quota evidence failed.' }
        if (@($live.checks | Where-Object status -in @('failed','denied','unsupported')).Count) { throw 'Current resource or guest reads failed.' }
        if ($journal.initialConfigurationHash -and (Get-CycleConfigurationHash $live) -cne $journal.initialConfigurationHash) { throw 'Lab configuration changed during lifecycle tests; stop.' }
    }
    $journal = @{schemaVersion='live-acceptance/1.0';vmId=$plan.vmId;planHash=$plan.hash;events=@();pendingOperation=$null;status='in-progress';lastError=$null}
    Write-UpgradeJson $journal $OutputPath
    $script:ExecutingVmId = $plan.vmId
    $script:MutationTenantId = $plan.tenantId
    $script:MutationJournal = $journal
    $script:MutationJournalPath = $OutputPath
    $lock = $null
    try {
        [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($JournalDirectory)) | Out-Null
        $lockPath = Join-Path $JournalDirectory "$((Get-UpgradeHash $plan.vmId.ToLowerInvariant())).lock"
        try { $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch [IO.IOException] { throw 'Another local upgrade/test owns the VM lock; do not run from a different host or journal directory.' }
        $initial = Get-VmEvidence -VmId $plan.vmId -GuestConsent
        Assert-LabCycle $initial
        Test-PostUpgradeGuest $plan $initial
        $journal.initialFingerprint = $initial.fingerprint
        $journal.initialConfigurationHash = Get-CycleConfigurationHash $initial
        foreach ($action in @('restart','deallocate','start')) {
            $live = Get-VmEvidence $plan.vmId
            Assert-LabCycle $live
            $requestId = [guid]::NewGuid().ToString()
            $journal.pendingOperation = @{name=$action;requestId=$requestId;at=[DateTimeOffset]::UtcNow.ToString('o')}
            Write-UpgradeJson $journal $OutputPath
            Invoke-ArmPowerAction $plan.vmId $action $requestId
            $state = if ($action -eq 'deallocate') { 'deallocated' } else { 'running' }
            Wait-VmState $plan.vmId $state $plan.targetSize $plan.targetController | Out-Null
            $after = Get-VmEvidence -VmId $plan.vmId -GuestConsent:($state -eq 'running')
            Assert-LabCycle $after
            if ($state -eq 'running') { Test-PostUpgradeGuest $plan $after }
            $journal.events += @{action=$action;status='pass';operation=$journal.pendingOperation;evidence=$after}
            $journal.pendingOperation = $null
            Write-UpgradeJson $journal $OutputPath
        }
        $journal.status = 'cycles-verified'
        $journal.limitations = 'Operator recovery exercise, post-cycle owner acceptance and normal Terraform reconciliation remain separate; cleanup is never automatic.'
        Write-UpgradeJson $journal $OutputPath
        return $journal
    } catch {
        $journal.status = 'failed'
        $journal.lastError = $_.Exception.Message
        Write-UpgradeJson $journal $OutputPath
        throw
    } finally {
        if ($lock) { $lock.Dispose() }
        $script:ExecutingVmId = $null; $script:MutationTenantId = $null
        $script:MutationJournal = $null; $script:MutationJournalPath = $null
    }
} $plan $context $OutputPath $JournalDirectory
