#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$TestContextPath,
    [Parameter(Mandatory)][switch]$LiveTestConsent,
    [string]$OutputPath = '.\out\live-restore-acceptance.json',
    [string]$JournalDirectory = '.\out\journals'
)
$ErrorActionPreference = 'Stop'
if (-not $LiveTestConsent) { throw 'Live restoration requires exact disposable-resource approval.' }
Import-Module (Join-Path $PSScriptRoot '..\..\src\AzVmUpgrade.psd1') -Force
$plan = Read-UpgradeJson $PlanPath
$context = Read-UpgradeJson $TestContextPath
Test-UpgradeDocument $plan plan | Out-Null
$unsigned = @{} + $plan
$unsigned.Remove('hash')
if ((Get-UpgradeHash $unsigned) -cne $plan.hash) { throw 'Restore plan content does not match its approved hash.' }
if ($context.planHash -cne $plan.hash -or $context.vmId -ine $plan.vmId) { throw 'Restore context must bind to the exact original plan.' }
foreach ($flag in @('labOnly', 'guestConsent', 'exclusiveWindow', 'deallocateApproved', 'recoveryCreateApproved', 'cleanupApproved', 'restartApproved')) {
    if ($context[$flag] -ne $true) { throw "Explicit $flag consent is required." }
}
if (Test-Path -LiteralPath $OutputPath) { throw 'Preserve the existing restoration result; do not blindly resume uncertain creates.' }
& (Get-Module AzVmUpgrade) {
    param($plan, $context, $outputPath, $journalDirectory)
    function Assert-Window {
        if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($context.expiresAt)) { throw 'Approved restoration window expired.' }
    }
    function Assert-LabRestoredEvidence($plan, $restored) {
        if ($restored.vm.securityProfile.encryptionAtHost -ne $true -or $restored.guest.actualController -ne 'SCSI' -or
            ($restored.vm.securityProfile.securityType -and $restored.vm.securityProfile.securityType -ne 'Standard') -or
            $restored.vm.securityProfile.uefiSettings.secureBootEnabled -eq $true -or
            $restored.vm.securityProfile.uefiSettings.vTpmEnabled -eq $true -or
            $restored.guest.complete -ne $true -or $restored.guest.agentReady -ne $true -or
            $restored.guest.storageIdentityHash -cne $plan.evidence.guest.storageIdentityHash -or
            $restored.guest.sentinelHash -cne $plan.evidence.guest.sentinelHash -or $restored.guest.applicationHealth -ne 'pass' -or
            $restored.guest.azureHttpsConnectivity -ne 'pass') { throw 'Restored VM boot/encryption/mount/data/health/connectivity verification failed.' }
    }
    Assert-Window
    $identity = Get-VmIdentity $plan.vmId
    if ($context.testResourceGroup -ine $identity.resourceGroup) { throw 'Restore resources must remain in the exact approved lab group.' }
    foreach ($field in @('vmName', 'nicName', 'osDiskName', 'dataDiskName')) {
        if ($context[$field] -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{1,63}$') { throw "Invalid exact restoration resource name: $field." }
    }
    $prefix = "/subscriptions/$($identity.subscriptionId)/resourceGroups/$($identity.resourceGroup)/providers"
    $targets = @(
        "$prefix/Microsoft.Compute/virtualMachines/$($context.vmName)",
        "$prefix/Microsoft.Network/networkInterfaces/$($context.nicName)",
        "$prefix/Microsoft.Compute/disks/$($context.osDiskName)",
        "$prefix/Microsoft.Compute/disks/$($context.dataDiskName)"
    )
    $key = Get-UpgradeHash $plan.vmId.ToLowerInvariant()
    $journal = Read-UpgradeJson (Join-Path $journalDirectory "$key.journal.json")
    if ($journal.planHash -cne $plan.hash -or $journal.phase -notin @('verified', 'reconciled') -or $journal.pendingOperation) {
        throw 'Complete technical verification and resolve pending operations before restoration testing.'
    }
    $lock = [IO.File]::Open((Join-Path $journalDirectory "$key.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $result = @{ schemaVersion = 'live-restore-acceptance/1.0'; planHash = $plan.hash; status = 'in-progress'; steps = @()
        targets = $targets; contextHash = Get-UpgradeHash $context }
    $marker = (Get-UpgradeHash $context).Substring(0, 16)
    $deallocated = $false
    $created = [Collections.Generic.List[string]]::new()
    function Step($name, $detail) {
        $result.steps += @{ name = $name; status = 'pass'; at = [DateTimeOffset]::UtcNow.ToString('o'); detail = $detail }
        Write-UpgradeJson $result $outputPath
    }
    function Az($arguments) { Invoke-UpgradeAz (@($arguments) + @('--subscription', $identity.subscriptionId)) }
    function Observe($name, $value) {
        $result.observationCount = 1 + [int]$result.observationCount
        Write-UpgradeJson @{ observedAt = [DateTimeOffset]::UtcNow.ToString('o'); response = $value } "$outputPath.$($result.observationCount).$name.json"
    }
    try {
        $existing = @(Az @('resource', 'list', '--resource-group', $identity.resourceGroup))
        Observe 'existing-resources' $existing
        if (@($existing | Where-Object { $_.id -in $targets }).Count) { throw 'A restoration target already exists; never overwrite it.' }
        $original = Get-VmEvidence -VmId $plan.vmId -GuestConsent -GuestNetworkProbeConsent -ObservationPath "$outputPath.original"
        Observe 'original' $original
        Test-PostUpgradeGuest $plan $original
        if (Get-Field $original.vm 'capacityReservation') { throw 'Capacity reservation associated recovery requires separate reviewed protection/placement; this harness never detaches or changes reservations.' }
        if ($original.vm.securityProfile.securityType -and $original.vm.securityProfile.securityType -ne 'Standard') { throw 'This lab restore harness supports Standard security only.' }
        if ($original.vm.securityProfile.encryptionAtHost -ne $true -or $original.vm.storageProfile.dataDisks.Count -ne 1 -or $original.nics.Count -ne 1) {
            throw 'Restoration requires the bounded one-data-disk, one-private-NIC host-encrypted lab.'
        }
        $source = @($original.skus | Where-Object name -CEQ $plan.sourceSize)
        if ($source.Count -ne 1 -or (Get-SkuCapability $source[0] 'EncryptionAtHostSupported') -ine 'True') { throw 'Recovery source SKU encryption support is not proved.' }
        if ($original.vm.location -notin $source[0].locations -or $null -eq $source[0].restrictions -or
            @($source[0].restrictions).Count -or @($original.vm.zones).Count) {
            throw 'Recovery requires an unrestricted source SKU in the original region and a non-zonal lab.'
        }
        $provider = Az @('provider', 'show', '--namespace', 'Microsoft.Compute')
        Observe 'compute-provider' $provider
        $vmType = @($provider.resourceTypes | Where-Object resourceType -EQ 'virtualMachines')
        if ($vmType.Count -ne 1 -or '2025-11-01' -notin $vmType[0].apiVersions) {
            throw 'The documented explicit Standard-security recovery API is unavailable; do not register a feature or change security.'
        }
        $cores = [int](Get-SkuCapability $source[0] 'vCPUs')
        foreach ($quotaName in @('cores', $source[0].family)) {
            $quota = @($original.usage | Where-Object { $_.name.value -ieq $quotaName })
            if ($quota.Count -ne 1 -or ([int]$quota[0].currentValue + $cores) -gt [int]$quota[0].limit) { throw "No verified extra recovery quota: $quotaName." }
        }
        foreach ($binding in @(
            @{ snapshot = $context.osSnapshotId; disk = $original.vm.storageProfile.osDisk.managedDisk.id },
            @{ snapshot = $context.dataSnapshotId; disk = $original.vm.storageProfile.dataDisks[0].managedDisk.id }
        )) {
            if (-not $binding.snapshot.StartsWith("$prefix/Microsoft.Compute/snapshots/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot outside approved group.' }
            $snapshot = Invoke-ArmRead $binding.snapshot '2024-03-02'
            Observe 'snapshot' $snapshot
            if ($snapshot.properties.provisioningState -ne 'Succeeded' -or $snapshot.properties.creationData.sourceResourceId -ine $binding.disk -or
                $snapshot.properties.encryption.type -ne 'EncryptionAtRestWithPlatformKey') { throw 'Exact platform-key snapshot provenance not proved.' }
        }
        $nic = Invoke-ArmRead $original.nics[0].id '2024-05-01'
        Observe 'source-nic' $nic
        if ($nic.properties.ipConfigurations.Count -ne 1 -or $nic.properties.ipConfigurations[0].properties.publicIPAddress -or
            -not $nic.properties.networkSecurityGroup.id) { throw 'Original private NIC/NSG topology is not proved.' }
        Write-UpgradeJson $result $outputPath
        Assert-Window
        Az @('vm', 'deallocate', '--ids', $plan.vmId) | Out-Null
        $deallocated = $true
        Wait-VmState $plan.vmId deallocated -ObservationPath "$outputPath.original-deallocate.json" | Out-Null
        Step 'original-deallocated' 'Only one VM is allowed to run during the sequential restore exercise.'
        $tags = @('--tags', 'az-vm-upgrade-disposable=true', "az-vm-upgrade-restore-run=$marker")
        foreach ($disk in @(
            @{ name = $context.osDiskName; snapshot = $context.osSnapshotId; id = $targets[2] },
            @{ name = $context.dataDiskName; snapshot = $context.dataSnapshotId; id = $targets[3] }
        )) {
            Assert-Window
            $created.Add($disk.id)
            $response = Az (@('disk', 'create', '--resource-group', $identity.resourceGroup, '--name', $disk.name, '--location', $original.vm.location,
                '--source', $disk.snapshot, '--sku', 'StandardSSD_LRS') + $tags)
            Observe 'disk-create' $response
        }
        Assert-Window
        $created.Add($targets[1])
        $response = Az (@('network', 'nic', 'create', '--resource-group', $identity.resourceGroup, '--name', $context.nicName,
            '--location', $original.vm.location, '--subnet', $nic.properties.ipConfigurations[0].properties.subnet.id,
            '--network-security-group', $nic.properties.networkSecurityGroup.id, '--accelerated-networking', 'true') + $tags)
        Observe 'nic-create' $response
        Assert-Window
        $created.Add($targets[0])
        # Older CLI create templates require a feature for explicit Standard security.
        # The documented 2025-11-01 API preserves it without changing subscription features.
        $request = @{
            location = $original.vm.location
            tags = @{ 'az-vm-upgrade-disposable' = 'true'; 'az-vm-upgrade-restore-run' = $marker }
            properties = @{
                hardwareProfile = @{ vmSize = $plan.sourceSize }
                securityProfile = @{ securityType = 'Standard'; encryptionAtHost = $true }
                networkProfile = @{ networkInterfaces = @(@{ id = $targets[1]; properties = @{ primary = $true } }) }
                storageProfile = @{
                    diskControllerType = 'SCSI'
                    osDisk = @{ name = $context.osDiskName; osType = 'Linux'; createOption = 'Attach'; deleteOption = 'Detach'; managedDisk = @{ id = $targets[2] } }
                    dataDisks = @(@{ lun = 0; name = $context.dataDiskName; createOption = 'Attach'; deleteOption = 'Detach'; managedDisk = @{ id = $targets[3] } })
                }
            }
        }
        $requestPath = [IO.Path]::GetFullPath("$outputPath.request.json")
        Write-UpgradeJson $request $requestPath
        $response = Az @('rest', '--method', 'put', '--url', "https://management.azure.com$($targets[0])?api-version=2025-11-01",
            '--body', "@$requestPath")
        Observe 'vm-create' $response
        Wait-VmState $targets[0] running $plan.sourceSize SCSI -ObservationPath "$outputPath.recovery-start.json" | Out-Null
        $restored = Get-VmEvidence -VmId $targets[0] -GuestConsent -GuestNetworkProbeConsent -ObservationPath "$outputPath.restored"
        Write-UpgradeJson $restored "$outputPath.evidence.json"
        Assert-LabRestoredEvidence $plan $restored
        Step 'vm-restored-and-verified' 'Actual boot from copied OS snapshot and unchanged managed-data checksum; host encryption explicitly enabled. Not application-consistent backup certification.'
        $result.status = 'restoration-verified'
    } catch {
        $result.status = 'failed'; $result.error = $_.Exception.Message
        throw
    } finally {
        try {
            foreach ($id in $targets | Where-Object { $created.Contains($_) }) {
                $resource = @(Az @('resource', 'list', '--resource-group', $identity.resourceGroup) | Where-Object { $_.id -ieq $id })
                Observe 'cleanup-ownership' $resource
                if ($resource.Count) {
                    if ($resource.Count -ne 1 -or $resource[0].tags.'az-vm-upgrade-restore-run' -cne $marker) { throw 'Cleanup ownership marker mismatch; stop.' }
                    if ($id -ieq $targets[0]) { Az @('vm', 'delete', '--ids', $id, '--yes') | Out-Null }
                    elseif ($id -ieq $targets[1]) { Az @('network', 'nic', 'delete', '--ids', $id) | Out-Null }
                    else { Az @('disk', 'delete', '--ids', $id, '--yes') | Out-Null }
                }
            }
            $cleanupDeadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
            do {
                $remaining = @(Az @('resource', 'list', '--resource-group', $identity.resourceGroup) | Where-Object { $_.id -in $targets })
                Observe 'cleanup-absence' $remaining
                if (-not $remaining.Count) { break }
                Start-Sleep -Seconds 5
            } while ([DateTimeOffset]::UtcNow -lt $cleanupDeadline)
            if ($remaining.Count) { throw 'Recovery resources remain; do not start a second running VM.' }
            if ($deallocated) {
                Az @('vm', 'start', '--ids', $plan.vmId) | Out-Null
                Wait-VmState $plan.vmId running $plan.targetSize $plan.targetController -ObservationPath "$outputPath.original-start.json" | Out-Null
                $post = Get-VmEvidence -VmId $plan.vmId -GuestConsent -GuestNetworkProbeConsent -ObservationPath "$outputPath.original-restart"
                Observe 'original-restart' $post
                Test-PostUpgradeGuest $plan $post
                Step 'recovery-cleanup-and-original-reverified' 'Exact marked recovery resources removed; original upgraded VM restarted and data/security/connectivity reverified.'
            }
        } catch {
            $result.status = 'failed'; $result.cleanupError = $_.Exception.Message
            throw
        } finally {
            try { Write-UpgradeJson $result $outputPath }
            finally { $lock.Dispose() }
        }
    }
} $plan $context $OutputPath $JournalDirectory
