function Get-SkuCapability {
    param($Sku, [Parameter(Mandatory)][string]$Name)
    $capabilityMatches = @($Sku.capabilities | Where-Object name -IEQ $Name)
    if ($capabilityMatches.Count -ne 1) { return $null }
    return $capabilityMatches[0].value
}

function Get-LifecycleFinding {
    param([string]$Size, $Catalog)
    foreach ($entry in $Catalog.entries) {
        if ($Size -cmatch $entry.pattern) {
            @{
                series = $entry.series; retirementDate = $entry.retirementDate
                growthRestrictedFrom = $entry.growthRestrictedFrom
                source = $entry.source; reviewedAt = $Catalog.reviewedAt
                catalogStale = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($Catalog.reviewedAt)).TotalDays -gt 90
            }
        }
    }
}

function Get-SkuCacheCapability {
    param($Sku, [string]$Name)
    $direct = Get-SkuCapability $Sku $Name
    if ($null -ne $direct) { return $direct }
    if ($Name -in @('CachedDiskReadBytesPerSecond','CachedDiskWriteBytesPerSecond')) {
        $legacy = Get-SkuCapability $Sku 'CachedDiskBytesPerSecond'
        if ($null -ne $legacy) { return $legacy }
    }
    $temp = Get-SkuCapability $Sku 'MaxResourceVolumeMB'
    $nvmeTemp = Get-SkuCapability $Sku 'NvmeDiskSizeInMiB'
    # Combined limits represent cache alone only on a proved no-temp-disk SKU.
    if ($null -eq $temp -or [double]$temp -ne 0 -or ($nvmeTemp -and [double]$nvmeTemp -gt 0)) { return $null }
    $combined = @{
        CachedDiskIOPS = 'CombinedTempDiskAndCachedIOPS'
        CachedDiskReadBytesPerSecond = 'CombinedTempDiskAndCachedReadBytesPerSecond'
        CachedDiskWriteBytesPerSecond = 'CombinedTempDiskAndCachedWriteBytesPerSecond'
    }
    Get-SkuCapability $Sku $combined[$Name]
}

function Get-QuotaProjection {
    param([Parameter(Mandatory)]$SourceSku, [Parameter(Mandatory)]$TargetSku, [Parameter(Mandatory)][AllowEmptyCollection()][array]$Usage)
    $sourceCores = Get-SkuCapability $SourceSku 'vCPUs'
    $targetCores = Get-SkuCapability $TargetSku 'vCPUs'
    if (-not $sourceCores -or -not $targetCores -or -not $SourceSku.family -or -not $TargetSku.family) {
        return @{ status = 'unknown'; checks = @(); detail = 'Missing vCPUs or SKU family metadata.' }
    }
    # vCPUsAvailable is the active constrained-core count, not quota consumption.
    $sourceCount = [int]$sourceCores
    $targetCount = [int]$targetCores
    $sameFamily = $SourceSku.family -ieq $TargetSku.family
    $deltas = @(
        @{ name = 'cores'; delta = $targetCount - $sourceCount; minimum = $sourceCount },
        @{ name = $TargetSku.family; delta = $targetCount - $(if ($sameFamily) { $sourceCount } else { 0 }); minimum = $(if ($sameFamily) { $sourceCount } else { 0 }) },
        @{ name = 'virtualMachines'; delta = 0; minimum = 1 }
    )
    $checks = @()
    foreach ($delta in $deltas) {
        $items = @($Usage | Where-Object { $_.name.value -ieq $delta.name })
        if ($items.Count -ne 1 -or $null -eq $items[0].currentValue -or $null -eq $items[0].limit) {
            $checks += @{ name = $delta.name; status = 'unknown'; detail = 'Quota record missing or ambiguous.' }
            continue
        }
        $current = [int]$items[0].currentValue
        $limit = [int]$items[0].limit
        $projected = $current + $delta.delta
        $status = if ($current -lt $delta.minimum -or $projected -lt 0) { 'unknown' }
        elseif ($projected -le $limit) { 'pass' } else { 'failed' }
        $checks += @{ name = $delta.name; status = $status; current = $current; delta = $delta.delta; projected = $projected; limit = $limit }
    }
    if (-not $sameFamily) {
        $sourceUsage = @($Usage | Where-Object { $_.name.value -ieq $SourceSku.family })
        if ($sourceUsage.Count -ne 1 -or $sourceUsage[0].currentValue -lt $sourceCount) {
            $checks += @{ name = $SourceSku.family; status = 'unknown'; detail = 'Source-family usage does not include the existing VM; refresh usage.' }
        } else {
            $checks += @{ name = $SourceSku.family; status = 'pass'; current = $sourceUsage[0].currentValue
                delta = -$sourceCount; projected = $sourceUsage[0].currentValue - $sourceCount; limit = $sourceUsage[0].limit }
        }
    }
    $status = if (@($checks | Where-Object status -eq 'unknown').Count) { 'unknown' }
    elseif (@($checks | Where-Object status -eq 'failed').Count) { 'failed' } else { 'pass' }
    @{ status = $status; checks = $checks; detail = 'Steady-state resize projection; includes allocated and deallocated VMs. Not an allocation guarantee.' }
}

function Test-TargetCompatibility {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)]$SourceSku,
        [Parameter(Mandatory)]$TargetSku, [ValidateSet('SCSI','NVMe')][string]$Controller = 'SCSI')
    $checks = [Collections.Generic.List[object]]::new()
    $vm = $Evidence.vm
    $osDisk = @($Evidence.disks | Where-Object { $_.id -ieq $vm.storageProfile.osDisk.managedDisk.id })
    if ($osDisk.Count -ne 1) {
        $checks.Add((New-Check 'boot-generation' unknown 'OS disk ARM evidence missing.'))
    } else {
        $generation = $osDisk[0].hyperVGeneration
        $supportedGenerations = Get-SkuCapability $TargetSku 'HyperVGenerations'
        if (-not $generation -or -not $supportedGenerations) {
            $checks.Add((New-Check 'boot-generation' unknown 'Generation capability is missing.'))
        } elseif ($generation -notin ($supportedGenerations -split ',' | ForEach-Object Trim)) {
            $checks.Add((New-Check 'boot-generation' unsupported 'Target does not support current boot generation.'))
        } elseif ($Controller -eq 'NVMe' -and $generation -ne 'V2') {
            $checks.Add((New-Check 'boot-generation' unsupported 'NVMe needs Generation 2; use a separate rebuild/conversion plan.'))
        } else { $checks.Add((New-Check 'boot-generation' pass "Retain $generation.")) }
    }
    foreach ($name in @('CpuArchitectureType','MemoryGB','vCPUs','MaxDataDiskCount','MaxNetworkInterfaces','MaxResourceVolumeMB')) {
        if ($null -eq (Get-SkuCapability $TargetSku $name) -or $null -eq (Get-SkuCapability $SourceSku $name)) {
            $checks.Add((New-Check "capability:$name" unknown 'Missing source or target SKU metadata.'))
        }
    }
    $sourceArch = Get-SkuCapability $SourceSku 'CpuArchitectureType'
    $targetArch = Get-SkuCapability $TargetSku 'CpuArchitectureType'
    if ($sourceArch -and $targetArch -and $sourceArch -ne $targetArch) {
        $checks.Add((New-Check 'architecture' unsupported 'Architecture changes require rebuild.'))
    }
    foreach ($name in @('vCPUs','MemoryGB')) {
        $sourceValue = Get-SkuCapability $SourceSku $name
        $targetValue = Get-SkuCapability $TargetSku $name
        if ($sourceValue -and $targetValue -and [double]$targetValue -lt [double]$sourceValue) {
            $checks.Add((New-Check "minimum:$name" unsupported 'Downsizing is outside this upgrade workflow.'))
        }
    }
    foreach ($pair in @(@('MaxDataDiskCount',@($vm.storageProfile.dataDisks).Count),@('MaxNetworkInterfaces',@($Evidence.nics).Count))) {
        $value = Get-SkuCapability $TargetSku $pair[0]
        if ($null -ne $value -and [int]$value -lt $pair[1]) { $checks.Add((New-Check $pair[0] unsupported 'Target device limit is below the attached device count.')) }
    }
    $controllers = Get-SkuCapability $TargetSku 'DiskControllerTypes'
    if (-not $controllers) {
        $checks.Add((New-Check 'controller' unknown 'Target controller capability is missing; no controller is inferred.'))
    } elseif ($Controller -notin ($controllers -split ',' | ForEach-Object Trim)) {
        $checks.Add((New-Check 'controller' unsupported "Target does not advertise $Controller."))
    }
    $current = Get-Field $vm 'storageProfile.diskControllerType'
    if ($current -notin @('SCSI','NVMe')) {
        $checks.Add((New-Check 'source-controller' unknown 'Explicit current ARM controller is required; legacy SKU metadata may omit DiskControllerTypes.'))
    } elseif ($Evidence.guest -and $Evidence.guest.actualController -ne $current) {
        $checks.Add((New-Check 'source-controller' unknown 'ARM and guest current controller evidence does not agree.'))
    }
    $sourceTemp = Get-SkuCapability $SourceSku 'MaxResourceVolumeMB'
    $targetTemp = Get-SkuCapability $TargetSku 'MaxResourceVolumeMB'
    $sourceNvmeTemp = Get-SkuCapability $SourceSku 'NvmeDiskSizeInMiB'
    $targetNvmeTemp = Get-SkuCapability $TargetSku 'NvmeDiskSizeInMiB'
    if (($null -ne $sourceTemp -and [double]$sourceTemp -gt 0) -or ($sourceNvmeTemp -and [double]$sourceNvmeTemp -gt 0) -or
        ($null -ne $targetTemp -and [double]$targetTemp -gt 0) -or ($targetNvmeTemp -and [double]$targetNvmeTemp -gt 0)) {
        $checks.Add((New-Check 'temporary-storage' unsupported 'This release executes only no-temp-disk to no-temp-disk paths; no preview registration or formatting.'))
    }
    foreach ($metric in @('UncachedDiskIOPS','UncachedDiskBytesPerSecond','CachedDiskIOPS','CachedDiskReadBytesPerSecond','CachedDiskWriteBytesPerSecond')) {
        $before = Get-SkuCapability $SourceSku $metric
        $after = Get-SkuCapability $TargetSku $metric
        if ($metric -like 'Cached*') {
            $before = Get-SkuCacheCapability $SourceSku $metric
            $after = Get-SkuCacheCapability $TargetSku $metric
        }
        if ($null -eq $before -or $null -eq $after) {
            $checks.Add((New-Check "performance:$metric" unknown 'Performance capability requires reviewed evidence.'))
        } elseif ([double]$after -lt [double]$before) {
            $checks.Add((New-Check "performance:$metric" unsupported 'Target advertised disk performance is lower than source.'))
        }

    }
    if ($vm.securityProfile -and (Get-Field $vm 'securityProfile.securityType') -notin @($null,'Standard')) {
        $checks.Add((New-Check 'security-type' unsupported 'Trusted Launch/confidential VMs need a separately validated path; security is never changed implicitly.'))
    }
    $hostEncrypted = (Get-Field $vm 'securityProfile.encryptionAtHost') -eq $true
    if ($hostEncrypted) {
        foreach ($item in @(@('source',$SourceSku),@('target',$TargetSku))) {
            $support = Get-SkuCapability $item[1] 'EncryptionAtHostSupported'
            $status = if ($null -eq $support) { 'unknown' } elseif ($support -ieq 'True') { 'pass' } else { 'unsupported' }
            $checks.Add((New-Check "encryption-at-host:$($item[0])" $status 'Encryption at host must remain enabled on a supported size.' 'Compute SKU API'))
        }
        $state = Get-Field $Evidence 'hostEncryption.state'
        $status = if (-not $state) { 'unknown' } elseif ($state -eq 'Registered') { 'pass' } else { 'unsupported' }
        $checks.Add((New-Check 'encryption-at-host-feature' $status 'Subscription feature must be Registered; the toolkit never registers or disables encryption.' 'ARM feature'))
    }
    if (@(Get-Field $vm 'encryptionExtensions' | Where-Object { $null -ne $_ }).Count) {
        $checks.Add((New-Check 'azure-disk-encryption' unsupported 'ADE extension detected. ADE migration/decryption is outside this workflow.'))
    }
    $zones = @($vm.zones)
    if ($vm.location -notin $TargetSku.locations) { $checks.Add((New-Check 'region' unsupported 'Target not advertised in current region.')) }
    if ($zones.Count -gt 1) { $checks.Add((New-Check 'zone' unsupported 'Unexpected multiple VM zones.')) }
    elseif ($zones.Count -eq 1) {
        $infos = @($TargetSku.locationInfo | Where-Object location -IEQ $vm.location)
        if ($infos.Count -ne 1 -or $zones[0] -notin $infos[0].zones) {
            $checks.Add((New-Check 'zone' unsupported 'Target not advertised in the exact current zone.'))
        }
    }
    foreach ($restriction in $TargetSku.restrictions) {
        $restrictedLocations = @(Get-Field $restriction 'restrictionInfo.locations')
        $restrictedZones = @(Get-Field $restriction 'restrictionInfo.zones')
        $applies = if ($restriction.type -eq 'Location') { $vm.location -in $restriction.values -or $vm.location -in $restrictedLocations }
        elseif ($restriction.type -eq 'Zone') { $vm.location -in $restrictedLocations -and ($zones.Count -eq 0 -or $zones[0] -in $restrictedZones) }
        else { $true }
        if ($applies) { $checks.Add((New-Check 'subscription-restriction' unsupported ($restriction | ConvertTo-Json -Compress -Depth 10) 'Compute SKU API')) }
    }
    if ($null -eq $TargetSku.restrictions) { $checks.Add((New-Check 'subscription-restriction' unknown 'Target restriction metadata is missing.')) }
    if (@($Evidence.nics | Where-Object acceleratedNetworking -EQ $true).Count -and
        (Get-SkuCapability $TargetSku 'AcceleratedNetworkingEnabled') -ne 'True') {
        $checks.Add((New-Check 'accelerated-networking' unsupported 'Target support is missing; existing configuration is retained.'))
    }
    foreach ($disk in $Evidence.disks) {
        if ($disk.sku.name -match 'Premium' -and (Get-SkuCapability $TargetSku 'PremiumIO') -ne 'True') {
            $checks.Add((New-Check 'premium-storage' unsupported 'Target does not advertise premium disk support.'))
        }
        if ($disk.sku.name -in @('UltraSSD_LRS','PremiumV2_LRS') -or $disk.maxShares -gt 1) {
            $checks.Add((New-Check 'disk-layout' unsupported 'Ultra/Premium SSD v2/shared disks require a separately tested path.'))
        }
        if ($disk.adeEnabled -eq $true -or ($hostEncrypted -and (Get-Field $disk 'adeSettingsPresent') -eq $true)) {
            $checks.Add((New-Check 'azure-disk-encryption' unsupported 'Current or retained ADE settings detected; no decryption or ADE migration is performed.'))
        }
        if (Get-Field $disk 'securityProfile') {
            $checks.Add((New-Check 'disk-security-profile' unsupported 'Confidential disk/security settings require a separate recovery path.'))
        }
        if ($disk.encryption.type -and $disk.encryption.type -ne 'EncryptionAtRestWithPlatformKey') {
            $checks.Add((New-Check 'customer-managed-encryption' unsupported 'Customer-managed or confidential encryption requires separately tested recovery.'))
        }
    }
    return @($checks)
}

function Get-GuestAdvisory {
    param([Parameter(Mandatory)]$Evidence, [string]$TargetController)
    $guest = $Evidence.guest
    if (-not $guest) { return @() }
    $items = [Collections.Generic.List[string]]::new()
    if (@($Evidence.disks | Where-Object { $_.id -ieq $Evidence.vm.storageProfile.osDisk.managedDisk.id -and $_.hyperVGeneration -eq 'V2' }).Count -eq 1 -and
        (Get-Field $Evidence.vm 'securityProfile.securityType') -ne 'TrustedLaunch') {
        $items.Add('Optional separate security assessment: existing Gen2 VMs can be evaluated for Trusted Launch. Verify supported size/OS, Linux SBInfo Secure Boot compatibility, Enhanced Backup policy and applicable ASR constraints. SKU/NVMe migration does not require or authorize this security change; preserve security type, Secure Boot and vTPM. Follow https://learn.microsoft.com/azure/virtual-machines/trusted-launch-existing-vm with separate consent and recovery testing; do not assume reversible enablement.')
    }
    $windows = "$($guest.osProfile)" -like 'windows:*'
    if ($TargetController -eq 'NVMe' -and -not $windows -and (Get-Field $guest 'azureVmUtils') -and $guest.azureVmUtils -ne 'pass') {
        $items.Add('azure-vm-utils (azure-nvme-id and /dev/disk/azure links) was not fully detected. Install it from the distribution package channel if your release provides one and use /dev/disk/azure/* paths in application configuration. It supplies stable device identification only; it does not replace NVMe boot-driver staging or stable-mount verification.')
    }
    if ($guest.manaDriver -ne 'pass') {
        $items.Add($(if ($windows) { 'MANA driver not found. Obtain the driver through the Microsoft entry point listed in the MANA documentation, verify its Authenticode signature, install it, reboot and reassess. The toolkit does not download or install it.' }
            else { 'MANA module not found. Check your distribution kernel/package documentation for MANA support; do not infer support from the kernel version alone because vendors backport. Mellanox drivers must remain.' }))
    }
    $nicAccelerated = @($Evidence.nics | Where-Object acceleratedNetworking -EQ $true).Count -gt 0
    if ($nicAccelerated -and (Get-Field $guest 'manaDevicePresent') -eq $false) {
        $items.Add('Accelerated Networking is enabled but no MANA PCI device is visible on the current host hardware. This is expected on Mellanox-backed hosts; the target size may land on MANA hardware, so keep both drivers.')
    }
    if ($guest.manaInUse -eq 'unknown') {
        $items.Add('MANA/VF use is unknown (an idle VM shows no traffic). Generate representative traffic and compare VF counters; unknown is not a pass.')
    }
    return @($items)
}

function Get-ResizePlacementAssessment {
    param($Evidence, [string]$TargetSize)
    $result = @{ status='unknown'; detail='Fresh per-VM resize options are unavailable. Regional SKU advertising and portal selection do not prove current-cluster availability or allocation capacity.'
        execution='deallocate-size-update-start' }
    $options = Get-Field $Evidence 'resizeOptions'
    if (-not $TargetSize -or -not $options -or $options.status -ne 'collected') { return $result }
    try { Assert-FreshEvidence $options.observedAt } catch { $result.detail=$_.Exception.Message; return $result }
    $running = @($Evidence.instanceView.statuses | Where-Object code -IEQ 'PowerState/running').Count -eq 1
    $deallocated = @($Evidence.instanceView.statuses | Where-Object code -IEQ 'PowerState/deallocated').Count -eq 1
    if (@($Evidence.instanceView.statuses | Where-Object code -ILike 'PowerState/*').Count -ne 1 -or
        (-not $running -and -not $deallocated)) {
        $result.detail='Resize placement requires an unambiguous running or deallocated power observation; stopped/transitional/unknown is not deallocated.'
        return $result
    }
    if ($TargetSize -cin @($options.sizes)) {
        $result.status = if ($running) { 'listed-on-current-cluster' } else { 'listed-while-deallocated' }
        $result.detail='Exact target is in the observed per-VM resize list, not a capacity guarantee. A native running resize still restarts. This executor deliberately uses approved deallocation/start; it does not silently switch to an in-place restart path.'
    } elseif ($running) {
        $result.status='requires-deallocation'
        $result.detail='Exact target is absent from the current-cluster resize list. Deallocation may expose additional sizes but releases the current allocation. Recheck the exact target after deallocation; no alternate size/zone/region is selected.'
    } elseif ($deallocated) {
        $result.status='not-listed-while-deallocated'
        $result.detail='Exact target is absent from the deallocated VM resize list. Stop before size update; preserve evidence and reassess without an alternate target or blind retry.'
    }
    return $result
}

function Get-CapacityReservationAssessment {
    param([Parameter(Mandatory)]$Evidence, [string]$TargetSize)
    $association = Get-Field $Evidence.vm 'capacityReservation'
    $id = Get-Field $association 'capacityReservationGroup.id'
    $result = @{ status='not-associated'; groupId=$id; targetSize=$TargetSize; reservationId=$null
        availableUnits=$null; detail='No capacity reservation association. Reservation is optional; quota/SKU checks do not guarantee allocation.'
        action='Do not create or purchase capacity implicitly. Review allocation risk with the owner.' }
    if (-not $association) { return $result }
    $result.status = 'unknown'
    $result.action = 'Preserve the association. Obtain fresh group/member/instance-view evidence; no implicit detach, quantity change, purchase or deletion.'
    $result.detail = 'Capacity reservation association or evidence is incomplete.'
    $e = Get-Field $Evidence 'capacityReservationEvidence'
    if (-not $id -or -not $e -or $e.status -ne 'collected') { return $result }
    if ($id -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/Microsoft\.Compute/capacityReservationGroups/[^/]+$' -or
        $Matches[1] -ine $Evidence.subscriptionId) {
        $result.detail='Invalid or shared/cross-subscription reservation group identity requires separate review.'; return $result
    }
    try { Assert-FreshEvidence $e.observedAt } catch { $result.detail=$_.Exception.Message; return $result }
    $group = $e.group
    if ($e.groupId -ine $id -or $group.id -ine $id -or $group.location -ine $Evidence.vm.location) {
        $result.status='incompatible'; $result.detail='Reservation group identity/region does not match the associated VM.'; return $result
    }
    $zones = @($Evidence.vm.zones)
    $groupZones = @($group.zones | Where-Object { $null -ne $_ })
    if ($zones.Count -gt 1 -or ($zones.Count -eq 1 -and $zones[0] -notin $groupZones) -or
        ($zones.Count -eq 0 -and $groupZones.Count -gt 0)) {
        $result.status='incompatible'; $result.detail='VM and reservation group zonal/regional placement do not match.'; return $result
    }
    $references = @($group.properties.capacityReservations)
    $members = @($e.reservations)
    if ($null -eq $group.properties.capacityReservations -or $references.Count -ne $members.Count -or @($members | Group-Object id | Where-Object Count -GT 1).Count -or
        @($references | Group-Object id | Where-Object Count -GT 1).Count -or
        @($references | Where-Object { -not $_.id -or -not $_.id.StartsWith("$id/capacityReservations/",[StringComparison]::OrdinalIgnoreCase) -or
            $_.id.Substring($id.Length + '/capacityReservations/'.Length) -match '^$|/' }).Count -or
        @($members | Where-Object { $_.id -notin @($references.id) }).Count) {
        $result.detail='Incomplete or duplicate reservation member evidence.'; return $result
    }
    $targetReservations = @($members | Where-Object { $_.sku.name -ceq $TargetSize -and
        (Get-UpgradeHash @($_.zones | Where-Object { $null -ne $_ })) -eq (Get-UpgradeHash $zones) })
    if (-not $TargetSize) { $result.detail='Select an explicit target before reservation compatibility can be assessed.'; return $result }
    if ($targetReservations.Count -eq 0) {
        $result.status='incompatible'; $result.detail='Associated group has no reservation for the exact target size and zone.'
        $result.action='Owner must separately choose/provision a matching paid target reservation, or approve VM deallocation/detachment and unreserved allocation; update Terraform desired association and reassess. Do not zero a shared reservation automatically.'
        return $result
    }
    if ($targetReservations.Count -ne 1) { $result.detail='Target reservation is ambiguous.'; return $result }
    $member = $targetReservations[0]
    $result.reservationId = $member.id
    $current = Get-Field $member 'properties.instanceView.utilizationInfo.currentCapacity'
    $allocated = $member.properties.instanceView.utilizationInfo.virtualMachinesAllocated
    if ($member.location -ine $Evidence.vm.location -or $member.properties.provisioningState -ne 'Succeeded') {
        $result.status='incompatible'; $result.detail='Target reservation region or provisioning state is not usable.'; return $result
    }
    if (($current -isnot [int] -and $current -isnot [long]) -or
        $current -lt 0 -or $current -gt [int]::MaxValue -or
        ($member.sku.capacity -isnot [int] -and $member.sku.capacity -isnot [long]) -or $member.sku.capacity -ne $current -or $null -eq $allocated -or
        @($member.properties.instanceView.statuses | Where-Object code -IEQ 'ProvisioningState/succeeded').Count -ne 1 -or
        @($allocated | Where-Object { -not $_.id }).Count -or @($allocated | Group-Object id | Where-Object Count -GT 1).Count) {
        $result.detail='Current reserved capacity/allocation evidence is missing, inconsistent or incomplete.'; return $result
    }
    $result.availableUnits = [long]$current - @($allocated | Where-Object { $_.id -ine $Evidence.vm.id }).Count
    if ($result.availableUnits -lt 1) {
        $result.status='incompatible'; $result.detail='No observed reserved unit remains for this VM; over-allocation is not reserved capacity.'; return $result
    }
    $result.status='compatible-observed'
    $result.detail='Exact target size/region/zone, succeeded reservation and observed reserved unit match. Availability is a point-in-time observation, not a lock or SLA guarantee from this toolkit.'
    $result.action='Retain existing association and desired Terraform capacity_reservation_group_id. Associated-VM execution/recovery is assessment-only until separately reviewed and tested; no reservation mutation is generated.'
    return $result
}

function New-VmUpgradePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evidence, [string]$TargetSize,
        [ValidateSet('SCSI','NVMe')][string]$Controller, [hashtable]$WorkloadReview,
        [hashtable]$TerraformMapping, [hashtable]$TerraformPlan)
    Test-UpgradeDocument $Evidence evidence | Out-Null
    if ($Evidence.guest) { Test-UpgradeDocument $Evidence.guest guest | Out-Null }
    if ($WorkloadReview.healthChecks) { Assert-ApplicationHealthChecks @($WorkloadReview.healthChecks) }
    $checks = [Collections.Generic.List[object]]::new()
    foreach ($check in $Evidence.checks) { $checks.Add($check) }
    try { Assert-FreshEvidence $Evidence.observedAt }
    catch { $checks.Add((New-Check 'control-plane-evidence' stale $_.Exception.Message)) }
    if ((Get-ConfigurationFingerprint $Evidence) -ne $Evidence.fingerprint) { throw 'Evidence fingerprint mismatch.' }
    $vm = $Evidence.vm
    $identity = Get-VmIdentity $vm.id
    if ($identity.subscriptionId -ine $Evidence.subscriptionId) { throw 'Evidence subscription does not match the VM ID.' }
    $sourceSize = $vm.hardwareProfile.vmSize
    $source = @($Evidence.skus | Where-Object name -CEQ $sourceSize)
    if ($source.Count -ne 1) { $checks.Add((New-Check 'source-sku' unknown 'Source SKU metadata missing or ambiguous.')) }
    $currentController = Get-Field $vm 'storageProfile.diskControllerType'
    if (-not $currentController) { $checks.Add((New-Check 'current-controller' unknown 'Controller is not exposed; do not assume SCSI.')) }
    if (-not $Controller) { $Controller = $currentController }
    foreach ($placement in @('availabilitySet','virtualMachineScaleSet','proximityPlacementGroup','host','hostGroup','extendedLocation')) {
        if (Get-Field $vm $placement) { $checks.Add((New-Check "placement:$placement" unsupported 'Special placement needs a reviewed migration; no other VMs will be stopped.')) }
    }
    $reservation = Get-CapacityReservationAssessment $Evidence $TargetSize
    if ($reservation.status -ne 'not-associated') {
        $checks.Add((New-Check 'capacity-reservation' unsupported "$($reservation.detail) $($reservation.action)" 'ARM / Microsoft capacity reservation guidance'))
    }
    if ($vm.priority -eq 'Spot') { $checks.Add((New-Check 'spot' unsupported 'Spot allocation is not an unattended supported path.')) }
    if (Get-Field $vm 'storageProfile.osDisk.diffDiskSettings') { $checks.Add((New-Check 'ephemeral-os' unsupported 'Ephemeral OS disk requires a rebuild path.')) }
    if ($vm.plan -or $vm.licenseType -match 'SAP|HPC') {
        $checks.Add((New-Check 'workload-certification' required 'Marketplace appliance/SAP/HPC requires application-specific certification and migration review.'))
    }
    if (@($Evidence.disks).Count -ne (1 + @($vm.storageProfile.dataDisks).Count) -or
        @($Evidence.nics).Count -ne @($vm.networkProfile.networkInterfaces).Count) {
        $checks.Add((New-Check 'resource-coverage' unknown 'Disk/NIC evidence does not cover all attached resources.'))
    }
    foreach ($nic in $Evidence.nics) {
        $status = if ($null -eq $nic.acceleratedNetworking) { 'unknown' } elseif ($nic.acceleratedNetworking) { 'pass' } else { 'disabled' }
        $checks.Add((New-Check "accelerated-networking:$($nic.id)" $status 'Retain current NIC configuration; capability and actual VF use are separate checks.' 'ARM NIC'))
    }
    if (-not $Evidence.guest) { $checks.Add((New-Check 'guest-readiness' unknown 'Collect fresh guest evidence with explicit consent.')) }
    else {
        $guest = $Evidence.guest
        try { Assert-FreshEvidence $guest.observedAt }
        catch { $checks.Add((New-Check 'guest-freshness' stale $_.Exception.Message)) }
        if (-not $guest.complete) { $checks.Add((New-Check 'guest-coverage' unknown 'Incomplete guest probe.')) }
        $runtime = Get-Field $guest 'runtimeSizeEvidence'
        if (-not $runtime -or $runtime.status -ne 'collected') {
            $checks.Add((New-Check 'guest-runtime-size' unknown 'Fresh guest IMDS compute size is required; ARM model size alone does not prove allocation.'))
        } elseif ($runtime.vmSize -cne $sourceSize) {
            $checks.Add((New-Check 'guest-runtime-size' failed 'Guest IMDS size contradicts ARM desired size; investigate a previous failed resize before new work.'))
        }
        if ($null -eq $guest.pendingReboot) { $checks.Add((New-Check 'pending-reboot' unknown 'Pending reboot evidence is unavailable for this OS profile.')) }
        elseif ($guest.pendingReboot) { $checks.Add((New-Check 'pending-reboot' required 'Reboot and reassess before the maintenance window.')) }
        if ($null -eq $guest.persistentMounts -or $null -eq $guest.layoutSupported) {
            $checks.Add((New-Check 'disk-layout' unknown 'Guest layout/mount evidence is unavailable.'))
        } elseif ($guest.persistentMounts -ne $true -or $guest.layoutSupported -ne $true) {
            $checks.Add((New-Check 'disk-layout' unsupported 'Resolve unstable mounts, RAID/LVM/filters, swap/pagefile/temp dependencies before orchestration.'))
        }
        if ($guest.manaDriver -ne 'pass' -or $guest.mellanoxDriver -ne 'pass') {
            $status = if ($guest.manaDriver -eq 'unknown' -or $guest.mellanoxDriver -eq 'unknown') { 'unknown' } else { 'required' }
            $checks.Add((New-Check 'network-drivers' $status 'Both MANA and Mellanox capability must be present, independently of actual host VF use.'))
        }
        if ($Controller -eq 'NVMe' -and ($guest.nvmeDriver -ne 'pass' -or $guest.nvmeBoot -ne 'pass')) {
            $status = if ($guest.nvmeDriver -eq 'unknown' -or $guest.nvmeBoot -eq 'unknown') { 'unknown' } else { 'required' }
            $checks.Add((New-Check 'nvme-boot' $status 'Stage NVMe driver in boot image and configure documented timeout; reassess afterward.'))
        }
        if ($guest.actualController -eq 'unknown' -or -not $guest.storageIdentityHash) { $checks.Add((New-Check 'guest-storage-identity' unknown 'Actual OS controller and persistent storage identities must be proved.')) }
        if ($guest.ContainsKey('managedDataMappings') -and
            (@($guest.managedDataMappings).Count -ne @($vm.storageProfile.dataDisks).Count -or
             @($guest.managedDataMappings | Where-Object controller -NE $currentController).Count)) {
            $checks.Add((New-Check 'guest-data-lun-mapping' unknown 'Microsoft Azure udev LUN mapping must cover every attached managed data disk on the actual controller.'))
        }
        $matrix = Read-UpgradeJson (Join-Path $script:RepositoryRoot 'catalog\support.json')
        $osMatches = @($matrix.labProfiles | Where-Object { $guest.osProfile -cmatch $_.pattern })
        if ($osMatches.Count -ne 1) { $checks.Add((New-Check 'os-support' unsupported "OS profile $($guest.osProfile) is assessment-only in this release.")) }
        if ($guest.agentReady -ne $true) {
            $status = if ($null -eq $guest.agentReady) { 'unknown' } else { 'required' }
            $checks.Add((New-Check 'guest-agent' $status 'VM guest agent readiness has not passed.'))
        }
        if ($WorkloadReview.guestNetworkProbeConsent -eq $true -and $guest.azureHttpsConnectivity -ne 'pass') {
            $status = if ($guest.azureHttpsConnectivity -eq 'failed') { 'failed' } else { 'required' }
            $checks.Add((New-Check 'azure-https-connectivity' $status 'The approved bounded guest network probe must pass before downtime.'))
        }
    }
    if (@($Evidence.instanceView.statuses | Where-Object code -EQ 'ProvisioningState/succeeded').Count -ne 1 -or
        @($Evidence.instanceView.statuses | Where-Object code -EQ 'PowerState/running').Count -ne 1) {
        $checks.Add((New-Check 'instance-health' required 'Assess and validate the original VM while running and successfully provisioned.'))
    }
    if (-not $WorkloadReview -or $WorkloadReview.reviewed -ne $true -or
        $WorkloadReview.noThirdPartyBootFilters -ne $true -or $WorkloadReview.noClusterOrAppliance -ne $true -or
        $WorkloadReview.noTemporaryStorageDependencies -ne $true -or -not $WorkloadReview.reference) {
        $checks.Add((New-Check 'workload-review' required 'Supply a reviewed workload contract for filters, clustering, temporary data and owner health checks.'))
    }
    $candidates = @()
    if ($source.Count -eq 1 -and $Controller) {
        foreach ($sku in $Evidence.skus) {
            if ($sku.name -eq $sourceSize) { continue }
            if ($TargetSize -and $sku.name -cne $TargetSize) { continue }
            $compatibility = @(Test-TargetCompatibility $Evidence $source[0] $sku $Controller)
            $quota = Get-QuotaProjection $source[0] $sku $Evidence.usage
            $candidates += @{
                name = $sku.name; family = $sku.family; controller = $Controller
                vCPUs = Get-SkuCapability $sku 'vCPUs'; memoryGB = Get-SkuCapability $sku 'MemoryGB'
                checks = $compatibility; quota = $quota
                compatible = @($compatibility | Where-Object status -NE 'pass').Count -eq 0
                capacity = 'unknown'
            }
        }
    }
    $candidates = @($candidates | Sort-Object @{ Expression = { -not $_.compatible } },@{ Expression = { [int]$_.vCPUs } },@{ Expression = { [double]$_.memoryGB } },name)
    $target = @($candidates | Where-Object name -CEQ $TargetSize)
    $quotaResult = @{ status = 'unknown'; checks = @(); detail = 'No explicitly selected compatible target.' }
    if (-not $TargetSize) { $checks.Add((New-Check 'target-approval' required 'Select an explicit target; ranked candidates are not execution authorization.')) }
    elseif ($target.Count -ne 1) { $checks.Add((New-Check 'target-sku' unknown 'Exact target not available in current regional SKU metadata, or equals source.')) }
    else {
        foreach ($check in $target[0].checks) { $checks.Add($check) }
        $quotaResult = $target[0].quota
        if ($quotaResult.status -ne 'pass') { $checks.Add((New-Check 'quota' $quotaResult.status 'Refresh usage or obtain sufficient quota manually; never infer capacity from quota.')) }
    }
    $iac = @{ managed = $false; status = 'not-declared'; suggestions = @(); check = $null }
    if ($TerraformMapping) {
        $iac.managed = $true
        if (-not $TerraformPlan) { $checks.Add((New-Check 'terraform' unknown 'A resource-address mapping requires a Terraform plan JSON.')) }
        else {
            $iac.check = Test-TerraformUpgradePlan -Plan $TerraformPlan -Mapping $TerraformMapping -VmId $vm.id -TargetSize $TargetSize -Controller $Controller `
                -ExpectedEncryptionAtHost (Get-Field $vm 'securityProfile.encryptionAtHost')
            $iac.check.mapping = $TerraformMapping
            $iac.status = $iac.check.status
            if ($iac.check.status -ne 'pass') { $checks.Add((New-Check 'terraform' unsupported $iac.check.detail)) }
        }
        $controllerSuggestion = if ($currentController -eq $Controller) {
            "Retain existing $($TerraformMapping.vmAddress).disk_controller_type; no controller change is needed."
        } else { "Set $($TerraformMapping.vmAddress).disk_controller_type = $Controller" }
        $iac.suggestions = @("Set $($TerraformMapping.vmAddress).size = $TargetSize", $controllerSuggestion, 'Preserve NIC properties; no ignore_changes is generated.')
        if ($reservation.groupId) { $iac.suggestions += "Preserve $($TerraformMapping.vmAddress).capacity_reservation_group_id = $($reservation.groupId); association changes need separate owner approval and plan." }
        if ((Get-Field $vm 'securityProfile.encryptionAtHost') -eq $true) {
            $iac.suggestions += "Retain $($TerraformMapping.vmAddress).encryption_at_host_enabled = true"
        }
    }
    $advisories = @(Get-GuestAdvisory $Evidence -TargetController $Controller)
    $resize = Get-ResizePlacementAssessment $Evidence $TargetSize
    if ($currentController -and $Controller -and $currentController -ne $Controller) {
        $resize.status='controller-conversion-required'
        $resize.execution='deallocate-size-controller-update-start'
        $resize.detail='A controller change is not native size-only resize. Use the separately gated conversion procedure and guest boot preparation; native resize-list membership is not conversion authorization.'
    }
    if ($TargetSize -and $currentController -eq $Controller -and $resize.status -in @('unknown','not-listed-while-deallocated')) {
        $checks.Add((New-Check 'resize-placement' unknown $resize.detail 'Compute VM sizes API'))
    }
    $classification = if (@($checks | Where-Object { $_.name -eq 'boot-generation' -and $_.status -eq 'unsupported' }).Count) { 'requires-rebuild' }
    elseif (@($checks | Where-Object { $_.name -eq 'workload-certification' }).Count) { 'requires-application-specific-work' }
    elseif (@($checks | Where-Object status -EQ 'unsupported').Count -or @($checks | Where-Object status -EQ 'failed').Count) { 'blocked' }
    elseif (@($checks | Where-Object { $_.status -in @('unknown','stale','denied') }).Count) { 'incomplete-evidence' }
    elseif (@($checks | Where-Object status -EQ 'required').Count) { 'needs-preparation' }
    else { 'ready' }
    $plan = @{
        schemaVersion = 'plan/1.0'; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
        vmId = $vm.id; tenantId = $Evidence.tenantId; subscriptionId = $identity.subscriptionId
        sourceSize = $sourceSize; sourceController = $currentController
        targetSize = if ($TargetSize) { $TargetSize } else { $null }
        targetController = if ($Controller) { $Controller } else { $null }
        classification = $classification
        executionBoundary = 'disposable-lab-only'; checks = @($checks); advisories = $advisories; candidates = $candidates
        quota = $quotaResult; capacity = $Evidence.capacity; capacityReservation = $reservation; terraform = $iac
        resize = $resize
        workloadReview = $WorkloadReview; fingerprint = $Evidence.fingerprint
        evidence = $Evidence; hash = $null
        disruption = 'Single VM deallocate/update/start; downtime and loss of temporary storage. Original allocation cannot be guaranteed.'
    }
    $unsigned = @{} + $plan
    $unsigned.Remove('hash')
    $plan.hash = Get-UpgradeHash $unsigned
    Test-UpgradeDocument $plan plan | Out-Null
    return $plan
}

function Test-TerraformUpgradePlan {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Mapping,
        [Parameter(Mandatory)][string]$VmId, [string]$TargetSize, [string]$Controller,
        [switch]$Reconciliation, [Nullable[bool]]$ExpectedEncryptionAtHost = $null)
    if ($Plan.errored -eq $true -or $Plan.format_version -notmatch '^1\.' -or -not $Mapping.vmAddress) {
        return @{ status = 'failed'; detail = 'Missing mapping, errored plan, or unsupported Terraform plan format.' }
    }
    $changes = @($Plan.resource_changes)
    $mapped = @($changes | Where-Object address -CEQ $Mapping.vmAddress)
    if ($mapped.Count -ne 1 -or $mapped[0].type -notin @('azurerm_linux_virtual_machine','azurerm_windows_virtual_machine')) {
        return @{ status = 'failed'; detail = 'Mapped AzureRM VM address is missing or not unique.' }
    }
    if ((Get-Field $mapped[0] 'change.before.id') -ine $VmId) {
        return @{ status = 'failed'; detail = 'Mapped VM before.id does not match the approved VM.' }
    }
    foreach ($change in $changes) {
        if (@($change.change.actions).Count -ne 1 -or $change.change.actions[0] -notin @('update','no-op')) {
            return @{ status = 'failed'; detail = "Missing or unsupported maintenance action at $($change.address)." }
        }
        if (@($change.change.replace_paths | Where-Object { $null -ne $_ }).Count) {
            return @{ status = 'failed'; detail = "Replacement/create/delete at $($change.address) is not allowed in a maintenance resize plan." }
        }
        if ($Reconciliation -and @($change.change.actions | Where-Object { $_ -ne 'no-op' }).Count) {
            return @{ status = 'failed'; detail = "Reconciliation is not clean at $($change.address)." }
        }
        if (-not $Reconciliation -and $change.address -ne $Mapping.vmAddress -and @($change.change.actions | Where-Object { $_ -ne 'no-op' }).Count) {
            return @{ status = 'failed'; detail = "Unrelated changes at $($change.address) are not allowed." }
        }
    }
    $after = $mapped[0].change.after
    if ($null -ne $ExpectedEncryptionAtHost -and
        (Get-Field $after 'encryption_at_host_enabled') -cne $ExpectedEncryptionAtHost) {
        return @{ status = 'failed'; detail = 'Desired encryption-at-host setting is missing or differs from the approved VM.' }
    }
    $unknown = Get-Field $mapped[0] 'change.after_unknown'
    if ($unknown -and ($unknown | ConvertTo-Json -Depth 50 -Compress) -match ':true') {
        return @{ status = 'failed'; detail = 'Unknown post-change values require a reviewed provider plan.' }
    }
    if ($after.size -cne $TargetSize -or $after.disk_controller_type -cne $Controller) {
        return @{ status = 'failed'; detail = 'Desired target size/controller do not match the approved plan.' }
    }
    if (-not $Reconciliation) {
        $before = @{} + $mapped[0].change.before
        $desired = @{} + $after
        foreach ($key in @('size','disk_controller_type')) { $before.Remove($key); $desired.Remove($key) }
        if ((Get-UpgradeHash $before) -ne (Get-UpgradeHash $desired)) {
            return @{ status = 'failed'; detail = 'Properties beyond size/controller changed; review rather than ignore them.' }
        }
        $unknown = Get-Field $mapped[0] 'change.after_unknown'
        if ($unknown) {
            $unknownJson = $unknown | ConvertTo-Json -Depth 50 -Compress
            if ($unknownJson -match ':true') {
            return @{ status = 'failed'; detail = 'Unknown post-change values require a reviewed provider plan.' }
            }
        }
    }
    @{ status = 'pass'; detail = 'Explicit mapping and exact desired configuration verified; no replacement or unrelated change.' }
}
