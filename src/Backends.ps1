function Get-BackendCatalog {
    [CmdletBinding()]
    param()
    Read-UpgradeJson (Join-Path $script:RepositoryRoot 'catalog\backends.json')
}

function Test-BackendFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackendId, [Parameter(Mandatory)][string]$Path)
    $backend = @((Get-BackendCatalog).backends | Where-Object id -CEQ $BackendId)
    if ($backend.Count -ne 1 -or -not $backend[0].sha256) { throw "Backend $BackendId is unknown or has no file pin." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Backend file does not exist; this toolkit never downloads it.' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $backend[0].sha256) { throw "Backend file hash $actual does not match the pinned $($backend[0].sha256)." }
    @{ id = $BackendId; commit = $backend[0].commit; sha256 = $actual; license = $backend[0].license; verified = $true }
}

function New-ExternalBackendPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$ScriptPath,
        [switch]$AcceptNoToolkitControls, [switch]$AcceptDowntime, [switch]$AcceptNoAutomaticRollback)
    $backendId = 'sap-azure-nvme-conversion'
    $backend = @((Get-BackendCatalog).backends | Where-Object id -CEQ $backendId)[0]
    if (-not ($AcceptNoToolkitControls -and $AcceptDowntime -and $AcceptNoAutomaticRollback)) {
        throw 'All boundary acknowledgements are required: no toolkit controls, downtime, no automatic rollback.'
    }
    if ((Get-Date).ToUniversalTime() -gt [DateTimeOffset]::Parse($Plan.expiresAt).UtcDateTime) { throw 'Plan expired; reassess after any guest preparation or reboot.' }
    $guest = $Plan.evidence.guest
    if (-not $guest) { throw 'Fresh guest evidence is required before the external backend.' }
    Assert-FreshEvidence $guest.observedAt 30
    if ($Plan.targetController -cne 'NVMe' -or -not $Plan.targetSize) { throw 'The pinned backend plan is limited to an explicit conversion to NVMe with a target size.' }
    if ($Plan.sourceController -cne 'SCSI') { throw 'Source controller must be proved as SCSI.' }
    $blockers = @($Plan.checks | Where-Object { $_.name -cne 'os-support' -and $_.status -cne 'pass' -and $_.status -cne 'disabled' })
    if ($blockers.Count) { throw "Plan has unresolved checks: $((($blockers | ForEach-Object { $_.name }) | Sort-Object -Unique) -join ', ')." }
    if ($guest.nvmeBoot -ne 'pass' -or $guest.actualController -ne 'SCSI') { throw 'Guest must prove NVMe boot readiness while still on SCSI.' }
    $verified = Test-BackendFile $backendId $ScriptPath
    $identity = Get-VmIdentity $Plan.vmId
    foreach ($value in @($identity.resourceGroup, $identity.name, $Plan.targetSize)) {
        if ($value -notmatch '^[A-Za-z0-9_.()-]{1,90}$') { throw 'Value contains characters not permitted in the emitted command.' }
    }
    $command = ".\Azure-NVMe-Conversion.ps1 -ResourceGroupName '$($identity.resourceGroup)' -VMName '$($identity.name)' -VMSize '$($Plan.targetSize)' -NewControllerType NVMe"
    @{
        schemaVersion = 'backend-plan/1.0'; backend = $backendId; verified = $verified
        vmId = $Plan.vmId; planHash = $Plan.hash; command = $command
        forbiddenParameters = @($backend.forbiddenParameters)
        excludedFromToolkitControls = @($backend.bypassesToolkitControls)
        boundaries = @(
            'Invoked manually by the operator; Invoke-VmUpgrade never calls it and it is not nested in toolkit mutations.',
            'Approval, plan hash, drift, ETag, journal and recovery guards do not cover this run.',
            'Guest preparation is separate: no -FixOperatingSystemSettings, no automatic fstab rewrite, no package or driver install.',
            'Rollback to SCSI is not promised; the original SKU may lack capacity or compatibility.',
            'Mellanox and synthetic networking must remain; no NIC changes are made by this plan.')
        before = @('Confirm locks, backups/restore points and a maintenance window outside this toolkit.', 'Do not reboot after preparation if Windows StartOverride could be recreated; reassess guest evidence first.')
        after = @('Collect fresh ARM and guest evidence, then call Test-ExternalBackendResult.')
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Test-ExternalBackendResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$BackendPlan, [Parameter(Mandatory)]$PostEvidence, [Parameter(Mandatory)][int]$ExitCode)
    $checks = [Collections.Generic.List[object]]::new()
    $add = { param($n, $ok, $d) $checks.Add(@{ name = $n; status = $(if ($ok) { 'pass' } else { 'failed' }); detail = $d }) }
    $vm = $PostEvidence.vm
    $guest = $PostEvidence.guest
    $target = ($BackendPlan.command -split "-VMSize '")[1].Split("'")[0]
    & $add 'exit-code' ($ExitCode -eq 0) "Backend exit code $ExitCode."
    & $add 'same-vm' ($vm -and $vm.id -ieq $BackendPlan.vmId) 'Evidence is for the planned VM.'
    & $add 'target-size' ($vm.hardwareProfile.vmSize -ceq $target) 'VM size equals the planned target.'
    & $add 'target-controller' ((Get-Field $vm 'storageProfile.diskControllerType') -ceq 'NVMe') 'ARM controller is NVMe.'
    & $add 'running' (@($PostEvidence.instanceView.statuses | Where-Object code -EQ 'PowerState/running').Count -eq 1) 'VM is running.'
    $fresh = $false
    if ($guest) { try { $fresh = [DateTimeOffset]::Parse($guest.observedAt) -gt [DateTimeOffset]::Parse($BackendPlan.startedAt) } catch { $fresh = $false } }
    & $add 'guest-after-run' $fresh 'Guest evidence was observed after the backend run began.'
    if ($guest) {
        & $add 'guest-nvme' ($guest.actualController -ceq 'NVMe' -and $guest.nvmeBoot -ceq 'pass') 'Guest reports NVMe root and boot readiness.'
        & $add 'stable-mounts' ($guest.persistentMounts -eq $true -and $guest.layoutSupported -eq $true) 'Persistent mounts remain stable.'
        & $add 'networking' ($guest.mellanoxDriver -ceq 'pass' -and $guest.manaDriver -ceq 'pass') 'MANA and Mellanox drivers remain present.'
    } else { & $add 'guest-evidence' $false 'Guest evidence is missing.' }
    $failed = @($checks | Where-Object status -NE 'pass')
    @{ schemaVersion = 'backend-result/1.0'; status = $(if ($failed.Count) { 'rejected' } else { 'accepted' }); checks = @($checks)
        note = 'Acceptance covers software checks only; application health, restart and deallocate/start resilience remain owner responsibilities.' }
}
