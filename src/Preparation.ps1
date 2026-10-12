function Get-PreparationCatalog {
    [CmdletBinding()]
    param()
    Read-UpgradeJson (Join-Path $script:RepositoryRoot 'catalog\preparation.json')
}

function Get-PreparationModelHash {
    param([Parameter(Mandatory)]$Evidence)
    # Power operations can change ETags; every other bounded property must stay identical.
    $model = @{ vm = $Evidence.vm; disks = @($Evidence.disks | Sort-Object id); nics = @($Evidence.nics | Sort-Object id) } |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    foreach ($resource in @($model.vm) + @($model.disks) + @($model.nics)) { if ($resource) { $resource.Remove('etag') } }
    Get-UpgradeHash $model
}

function New-GuestPreparationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('nvme-boot', 'azure-vm-utils', 'mana-linux-check', 'mana-windows-driver')][string[]]$Component,
        [string]$DriverPackagePath, [string]$DriverPackageSha256,
        [Parameter(Mandatory)][switch]$GuestChangeConsent,
        [ValidateRange(5, 240)][int]$ValidMinutes = 60
    )
    if (-not $GuestChangeConsent) { throw 'Explicit guest-change consent is required.' }
    $catalog = Get-PreparationCatalog
    $unsigned = @{} + $Plan; $unsigned.Remove('hash')
    if ((Get-UpgradeHash $unsigned) -cne $Plan.hash) { throw 'Plan hash does not match its content.' }
    if ([DateTimeOffset]::UtcNow -gt [DateTimeOffset]::Parse($Plan.expiresAt)) { throw 'Plan expired; create a fresh plan.' }
    $guest = $Plan.evidence.guest
    if (-not $guest) { throw 'Fresh guest evidence is required before planning preparation.' }
    Assert-FreshEvidence $guest.observedAt $catalog.limits.maxGuestEvidenceAgeMinutes
    $family = @($catalog.profiles.GetEnumerator() | Where-Object { $_.Value.osProfiles -contains $guest.osProfile })
    if ($family.Count -ne 1) { throw "Guest profile $($guest.osProfile) has no supported preparation procedure; use the manual guidance." }
    $osFamily = [string]$family[0].Key
    $unsupported = @($Component | Where-Object { $_ -notin $family[0].Value.components })
    if ($unsupported.Count) { throw "Component(s) not supported for ${osFamily}: $($unsupported -join ', ')." }
    if ($guest.agentReady -ne $true) { throw 'The guest agent must be ready for Run Command.' }
    $body = [ordered]@{
        schemaVersion = 'preparation/1.0'; planHash = $Plan.hash; vmId = $Plan.vmId; osFamily = $osFamily
        components = @($Component | Select-Object -Unique)
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        expiresAt = [DateTimeOffset]::UtcNow.AddMinutes($ValidMinutes).ToString('o')
        guestChangeConsent = $true
        expectedFingerprint = $Plan.evidence.fingerprint
        expectedModelHash = Get-PreparationModelHash $Plan.evidence
        expectedStorageIdentityHash = $guest.storageIdentityHash
        preState = @{ bootId = $guest.bootId; nvmeBoot = $guest.nvmeBoot; azureVmUtils = $guest.azureVmUtils; manaDriver = $guest.manaDriver; actualController = $guest.actualController
            sentinelHash = $guest.sentinelHash; applicationHealth = $guest.applicationHealth }
    }
    if ($Component -contains 'azure-vm-utils') {
        $key = ($guest.osProfile -split ':')[0..1] -join ':'
        $version = $catalog.azureVmUtils.approvedVersions.$key
        if (-not $version) { throw 'No verified azure-vm-utils package channel for this distribution; install manually after review.' }
        $body.azureVmUtilsVersion = $version
    }
    if ($Component -contains 'mana-windows-driver') {
        if (-not $DriverPackagePath -or -not $DriverPackageSha256) {
            throw 'No approved Windows MANA artifact exists to download; supply the in-guest signed zip path and its reviewed SHA256.'
        }
        if ($DriverPackageSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $DriverPackagePath -notmatch '^[A-Za-z]:\\[\w .\\-]+\.zip$') { throw 'Invalid driver artifact path or SHA256.' }
        $body.driverPackagePath = $DriverPackagePath; $body.driverPackageSha256 = $DriverPackageSha256.ToLowerInvariant()
    }
    $body.hash = Get-UpgradeHash $body
    $document = @{} + $body
    Test-UpgradeDocument $document preparation | Out-Null
    $document
}

function Get-GuestPreparationScript {
    param([Parameter(Mandatory)]$Preparation, [Parameter(Mandatory)][ValidateSet('apply', 'rollback', 'status')][string]$Action, [switch]$RollbackAcknowledged)
    $catalog = Get-PreparationCatalog
    $procedure = $catalog.profiles.($Preparation.osFamily)
    $body = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $procedure.script) -Raw
    $components = @($Preparation.components) -join ','
    if ($components -notmatch '^[a-z-]+(,[a-z-]+)*$' -or $Preparation.planHash -notmatch '^[0-9a-f]{64}$') { throw 'Preparation values failed validation.' }
    $consent = if ($Action -eq 'status') { '' } else { 'approved-guest-preparation' }
    $ack = if ($RollbackAcknowledged) { 'restored-controller-confirmed' } else { '' }
    if ($Preparation.osFamily -eq 'ubuntu') {
        $version = [string]$Preparation.azureVmUtilsVersion
        if ($version -and $version -notmatch '^[0-9][A-Za-z0-9.+~:-]{1,60}$') { throw 'Invalid package version.' }
        $header = "#!/usr/bin/env bash`nexport AZVM_PREP_ACTION='$Action' AZVM_PLAN_HASH='$($Preparation.planHash)' AZVM_COMPONENTS='$components' AZVM_UTILS_VERSION='$version' AZVM_PREPARE_CONSENT='$consent' AZVM_ROLLBACK_ACK='$ack'`n"
        return $header + ($body -replace '^#!.*\r?\n', '')
    }
    $path = [string]$Preparation.driverPackagePath; $sha = [string]$Preparation.driverPackageSha256
    if (($path -and $path -notmatch '^[A-Za-z]:\\[\w .\\-]+\.zip$') -or ($sha -and $sha -notmatch '^[0-9a-fA-F]{64}$')) { throw 'Invalid driver artifact values.' }
    "`$AzvmConfig = @{ Action='$Action'; PlanHash='$($Preparation.planHash)'; Components='$components'; Consent='$consent'; RollbackAck='$ack'; DriverPackagePath='$path'; DriverPackageSha256='$sha' }`n" + $body
}

function Read-PreparationManifest {
    param([Parameter(Mandatory)]$RunResult, [Parameter(Mandatory)]$Preparation, [Parameter(Mandatory)][string]$Action)
    $stdout = Get-RunCommandStdout $RunResult
    $match = [regex]::Match($stdout, '(?s)AZVM_PREP_BEGIN\s*(\{.*?\})\s*AZVM_PREP_END')
    if (-not $match.Success) { throw 'Preparation manifest is missing or truncated; outcome is uncertain, run status before retrying.' }
    $manifest = $match.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    Test-UpgradeDocument $manifest preparation-manifest | Out-Null
    if ($manifest.planHash -cne $Preparation.planHash -or $manifest.action -cne $Action) { throw 'Preparation manifest does not match the requested plan/action.' }
    $manifest
}

function Invoke-GuestPreparation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$Preparation,
        [Parameter(Mandatory)][ValidateSet('apply', 'rollback', 'status')][string]$Action,
        [Parameter(Mandatory)][switch]$GuestConsent,
        [switch]$RollbackAcknowledged,
        [string]$JournalDirectory = (Join-Path $script:RepositoryRoot 'out\journals')
    )
    if (-not $GuestConsent) { throw 'Run Command always requires explicit guest consent.' }
    Test-UpgradeDocument $Preparation preparation | Out-Null
    $unsigned = @{} + $Preparation; $unsigned.Remove('hash')
    if ((Get-UpgradeHash $unsigned) -cne $Preparation.hash) { throw 'Preparation request was altered.' }
    if ($Action -eq 'apply' -and [DateTimeOffset]::UtcNow -gt [DateTimeOffset]::Parse($Preparation.expiresAt)) { throw 'Preparation request expired; reassess and create a new one.' }
    if ($Action -eq 'rollback' -and -not $RollbackAcknowledged) { throw 'Rollback requires -RollbackAcknowledged after confirming the restored controller/size is compatible.' }
    $identity = Get-VmIdentity $Preparation.vmId
    $family = if ($Preparation.osFamily -eq 'ubuntu') { 'Linux' } else { 'Windows' }
    $key = Get-UpgradeHash $Preparation.vmId.ToLowerInvariant()
    $journalPath = Join-Path $JournalDirectory "prep-$($Preparation.hash.Substring(0,16)).journal.json"
    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($JournalDirectory)) | Out-Null
    $lock = $null
    try {
        try { $lock = [IO.File]::Open((Join-Path $JournalDirectory "$key.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { throw 'Another local upgrade/preparation owns the VM lock.' }
        $journal = if (Test-Path -LiteralPath $journalPath) { Read-UpgradeJson $journalPath } else {
            @{ schemaVersion = 'preparation-journal/1.0'; vmId = $Preparation.vmId; preparationHash = $Preparation.hash; status = 'new'; events = @(); lastError = $null }
        }
        if ($Action -ne 'status' -and $journal.status -eq 'in-progress') {
            throw 'A previous preparation call was interrupted; its outcome is unknown. Run -Action status and review before any retry.'
        }
        $live = Get-VmEvidence -VmId $Preparation.vmId -ObservationPath "$journalPath.pre-$Action"
        Write-UpgradeJson $live "$journalPath.pre-$Action.json"
        Assert-LabWorkDeadline
        if ($Action -eq 'apply' -and [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($Preparation.expiresAt)) { throw 'Preparation request expired while collecting evidence; no guest mutation submitted.' }
        if ($live.vm.id -ine $Preparation.vmId -or $live.subscriptionId -ine $identity.subscriptionId) { throw 'Live VM identity does not match the preparation request.' }
        if ($Action -eq 'apply' -and $live.fingerprint -cne $Preparation.expectedFingerprint) { throw 'Live resources changed since the plan was approved; reassess.' }
        if (@($live.instanceView.statuses | Where-Object code -EQ 'PowerState/running').Count -ne 1) { throw 'VM must be running for guest preparation.' }
        if (-not $PSCmdlet.ShouldProcess($Preparation.vmId, "Guest preparation: $Action ($($Preparation.components -join ', '))")) { return }
        $script = Get-GuestPreparationScript $Preparation $Action -RollbackAcknowledged:$RollbackAcknowledged
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ("azvm-prep-$([guid]::NewGuid().ToString('N')).$(if ($family -eq 'Linux') { 'sh' } else { 'ps1' })")
        $journal.status = 'in-progress'; $journal.pendingAction = $Action
        $journal.events += @{ at = [DateTimeOffset]::UtcNow.ToString('o'); action = $Action; state = 'started' }
        Write-UpgradeJson $journal $journalPath
        try {
            [IO.File]::WriteAllText($temporary, ($script -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
            $commandId = if ($family -eq 'Linux') { 'RunShellScript' } else { 'RunPowerShellScript' }
            $result = Invoke-UpgradeAz @('vm', 'run-command', 'invoke', '--ids', $Preparation.vmId, '--subscription', $identity.subscriptionId,
                '--command-id', $commandId, '--scripts', "@$temporary") -TimeoutSeconds 1800
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        Write-UpgradeJson $result "$journalPath.$Action.run-command.json"
        $manifest = Read-PreparationManifest $result $Preparation $Action
        $journal.manifest = $manifest
        $journal.pendingAction = $null
        $journal.status = if ($manifest.status -ne 'ok') { 'failed' } elseif ($Action -eq 'apply') { 'applied-awaiting-reboot' } elseif ($Action -eq 'rollback') { 'rolled-back-awaiting-reboot' } else { $journal.status -replace '^in-progress$', 'reconciled' }
        $journal.events += @{ at = [DateTimeOffset]::UtcNow.ToString('o'); action = $Action; state = $journal.status }
        Write-UpgradeJson $journal $journalPath
        if ($manifest.status -ne 'ok') { throw "Guest preparation reported failure; see $journalPath and run rollback only after review." }
        $manifest
    } finally { if ($lock) { $lock.Dispose() } }
}

function Restart-VmForPreparation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$Preparation,
        [Parameter(Mandatory)][switch]$RebootConsent,
        [string]$JournalDirectory = (Join-Path $script:RepositoryRoot 'out\journals')
    )
    if (-not $RebootConsent) { throw 'A guest restart requires separate explicit consent.' }
    Test-UpgradeDocument $Preparation preparation | Out-Null
    $journalPath = Join-Path $JournalDirectory "prep-$($Preparation.hash.Substring(0,16)).journal.json"
    if (-not (Test-Path -LiteralPath $journalPath)) { throw 'No preparation journal exists.' }
    $journal = Read-UpgradeJson $journalPath
    if ($journal.status -notin @('applied-awaiting-reboot', 'rolled-back-awaiting-reboot')) { throw "Journal state $($journal.status) does not permit a preparation restart." }
    $live = Get-VmEvidence -VmId $Preparation.vmId -ObservationPath "$journalPath.pre-restart"
    Write-UpgradeJson $live "$journalPath.pre-restart.json"
    Assert-LabWorkDeadline
    if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($Preparation.expiresAt)) { throw 'Preparation request expired while collecting restart evidence; no restart submitted.' }
    $power = Invoke-ArmRead "$($Preparation.vmId)/instanceView" '2024-07-01'
    Write-UpgradeJson $power "$journalPath.pre-restart.power.json"
    Assert-LabWorkDeadline
    if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($Preparation.expiresAt)) { throw 'Preparation request expired before restart; no restart submitted.' }
    if (@($power.statuses | Where-Object code -EQ 'PowerState/running').Count -ne 1) { throw 'Fresh ARM power state must be running before preparation restart.' }
    if ((Get-PreparationModelHash $live) -cne $Preparation.expectedModelHash) { throw 'Azure configuration changed during preparation; stop and reassess.' }
    if (-not $PSCmdlet.ShouldProcess($Preparation.vmId, 'Restart VM (no deallocate, resize or controller change)')) { return }
    $script:ExecutingVmId = $Preparation.vmId
    $script:MutationTenantId = $live.tenantId
    $script:MutationJournal = $null
    $requestId = [guid]::NewGuid().ToString()
    $journal.pendingOperation = @{ name = 'restart'; requestId = $requestId; at = [DateTimeOffset]::UtcNow.ToString('o') }
    Write-UpgradeJson $journal $journalPath
    Invoke-ArmPowerAction -VmId $Preparation.vmId -Action restart -RequestId $requestId
    Wait-VmState -VmId $Preparation.vmId -PowerState running -ObservationPath "$journalPath.restart-poll.json" | Out-Null
    $journal.pendingOperation = $null
    $journal.status = $journal.status -replace 'awaiting-reboot', 'restarted-awaiting-reassessment'
    $journal.events += @{ at = [DateTimeOffset]::UtcNow.ToString('o'); action = 'restart'; state = $journal.status }
    Write-UpgradeJson $journal $journalPath
    $journal.status
}

function Test-PreparationOutcome {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preparation, [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$PostEvidence)
    $guest = $PostEvidence.guest
    $checks = [System.Collections.Generic.List[object]]::new()
    function Add($name, $ok, $detail) { $checks.Add(@{ name = $name; status = $(if ($ok) { 'pass' } else { 'failed' }); detail = $detail }) }
    Add 'manifest' ($Manifest.status -eq 'ok' -and $Manifest.action -eq 'apply' -and $Manifest.planHash -ceq $Preparation.planHash) 'Guest manifest succeeded for this plan'
    Add 'guest-evidence' ([bool]$guest -and $guest.complete -eq $true -and $guest.agentReady -eq $true -and $guest.pendingReboot -eq $false) 'Fresh complete guest evidence, agent ready, no pending reboot'
    try {
        Assert-FreshEvidence $guest.observedAt (Get-PreparationCatalog).limits.maxGuestEvidenceAgeMinutes
        Add 'guest-freshness' $true 'Guest evidence is within the preparation freshness limit'
    } catch { Add 'guest-freshness' $false $_.Exception.Message }
    $after = $guest -and $guest.observedAt -and [DateTimeOffset]::Parse($guest.observedAt) -gt [DateTimeOffset]::Parse($Manifest.observedAt)
    Add 'observed-after-preparation' $after 'Guest evidence was collected after preparation'
    Add 'rebooted' ($guest -and $guest.bootId -and $guest.bootId -cne $Manifest.bootId) 'Boot ID changed since preparation'
    Add 'azure-configuration-unchanged' ((Get-PreparationModelHash $PostEvidence) -ceq $Preparation.expectedModelHash) 'VM, disks and NICs unchanged apart from ETags (no hidden resize)'
    Add 'storage-unchanged' ($guest.persistentMounts -eq $true -and $guest.storageIdentityHash -ceq $Preparation.expectedStorageIdentityHash) 'Persistent mounts and disk identities unchanged'
    if (Get-Field $Preparation 'preState.sentinelHash') {
        Add 'data-sentinel-unchanged' ($guest.sentinelHash -ceq $Preparation.preState.sentinelHash) 'Prepared guest retains the baseline managed-data checksum'
    }
    if ((Get-Field $Preparation 'preState.applicationHealth') -eq 'pass') {
        Add 'application-health' ($guest.applicationHealth -eq 'pass') 'Baseline lab application sentinel remains healthy'
    }
    Add 'mellanox-retained' ($guest.mellanoxDriver -eq 'pass') 'Mellanox/synthetic path retained'
    foreach ($component in $Preparation.components) {
        switch ($component) {
            'nvme-boot' { Add $component ($guest.nvmeBoot -eq 'pass') 'NVMe boot readiness verified after reboot' }
            'azure-vm-utils' { Add $component ($guest.azureVmUtils -eq 'pass') 'azure-nvme-id and /dev/disk/azure present (not a substitute for boot or mount checks)' }
            'mana-windows-driver' { Add $component ($guest.manaDriver -eq 'pass') 'MANA driver present; host placement and VF traffic remain separate' }
            'mana-linux-check' { $checks.Add(@{ name = $component; status = 'info'; detail = "manaDriver=$($guest.manaDriver) manaDevicePresent=$($guest.manaDevicePresent) manaInUse=$($guest.manaInUse); informational only" }) }
        }
    }
    $failed = @($checks | Where-Object status -EQ 'failed')
    @{
        schemaVersion = 'preparation-outcome/1.0'; status = $(if ($failed.Count) { 'rejected' } else { 'accepted' }); checks = @($checks)
        next = 'Create a NEW upgrade plan from this evidence and obtain a new approval. This outcome is readiness evidence only; it does not authorize an upgrade and does not prove a later boot on NVMe.'
    }
}

function Get-PreparationRecoveryGuide {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalPath)
    $journal = Read-UpgradeJson $JournalPath
    @"
# Preparation recovery for $($journal.vmId)

Journal state: **$($journal.status)**. Pending action: **$($journal.pendingAction)**.

1. Preserve this journal. An interrupted call has an unknown outcome: run ``-Action status`` to read the guest state; never blindly repeat apply.
2. ``-Action rollback -RollbackAcknowledged`` restores only what the guest manifest recorded: Linux initramfs module file / NVMe options, an azure-vm-utils package this toolkit installed, Windows boot-start values and StartOverride entries, and a MANA driver this toolkit added. Run it only on a VM whose controller/size is compatible with the restored settings.
3. Rollback restores recorded guest settings; it is **not** a VM restore and has not been proven live. Backup files and recorded values are not proof of restoration: verify with fresh guest evidence after a reboot.
4. A VM that no longer boots needs the accepted VM-level recovery (protection reference, serial console). Original-SKU capacity is not guaranteed and SCSI rollback is never promised.
5. Reboot is a separate consent step. Reconcile Terraform through a normal plan; never edit state JSON.
"@
}
