function Get-VmInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$SubscriptionId,
        [string]$ResourceGroup, [string]$Location, [string]$Size,
        [string]$TagName, [AllowEmptyString()][string]$TagValue,
        [switch]$AdvisorCrossCheck,
        [ValidateSet('active','completed','postponed','dismissed','unknown')][string[]]$AdvisorState = @('active','completed','postponed','dismissed','unknown'),
        [string]$AdvisorStatePropertyPath
    )
    $query = Get-Content (Join-Path $script:RepositoryRoot 'queries\inventory.kql') -Raw
    foreach ($filter in @(@('resourceGroup',$ResourceGroup),@('location',$Location),@('size',$Size))) {
        if ($filter[1]) { $query += "`n| where $($filter[0]) =~ $($filter[1] | ConvertTo-Json -Compress)" }
    }
    if ($TagName) {
        if (-not $PSBoundParameters.ContainsKey('TagValue')) { throw 'TagValue is required with TagName.' }
        $query += "`n| where tostring(tags[$($TagName | ConvertTo-Json -Compress)]) == $($TagValue | ConvertTo-Json -Compress)"
    }
    $data = Get-ScopedGraphRecords -SubscriptionId $SubscriptionId -Query $query
    $catalog = Read-UpgradeJson (Join-Path $script:RepositoryRoot 'catalog\lifecycle.json')
    foreach ($row in $data.rows) { $row.lifecycle = @(Get-LifecycleFinding -Size $row.size -Catalog $catalog) }
    $inventory = @{
        schemaVersion = 'inventory/1.0'; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        source = 'Azure Resource Graph (eventually consistent)'; scopes = $data.scopes
        complete = @($data.scopes | Where-Object status -ne 'complete').Count -eq 0
        vms = @($data.rows | Sort-Object id)
    }
    if ($AdvisorCrossCheck) {
        $inventory.advisor = Get-AdvisorRetirementCrossCheck -SubscriptionId $SubscriptionId -Inventory $inventory `
            -VmQuery $query -State $AdvisorState -StatePropertyPath $AdvisorStatePropertyPath
    }
    Test-UpgradeDocument $inventory inventory | Out-Null
    return $inventory
}

function Get-ScopedGraphRecords {
    param([string[]]$SubscriptionId, [string]$Query)
    $rows = @{}
    $coverage = [Collections.Generic.List[object]]::new()
    foreach ($subscription in @($SubscriptionId | Sort-Object -Unique)) {
        if ($subscription -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid subscription ID.' }
        $token = $null
        $seenTokens = @{}
        $scopeRows = @{}
        try {
            do {
                $options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
                if ($token) { $options['$skipToken'] = $token }
                $body = @{ subscriptions = @($subscription); query = $query; options = $options } | ConvertTo-Json -Depth 20 -Compress
                $page = Invoke-UpgradeAz @('rest','--method','post','--subscription',$subscription,
                    '--url','/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01','--body',$body)
                if ($null -eq $page -or $null -eq $page.data) { throw 'Resource Graph returned no data envelope.' }
                foreach ($row in $page.data) {
                    if (-not $row.id -or $row.subscriptionId -ne $subscription) { throw 'Unexpected Resource Graph row scope.' }
                    $key = $row.id.ToLowerInvariant()
                    if ($scopeRows.ContainsKey($key) -and (Get-UpgradeHash $scopeRows[$key]) -ne (Get-UpgradeHash $row)) {
                        throw "Conflicting duplicate resource: $key"
                    }
                    $scopeRows[$key] = $row
                }
                $token = Get-Field $page '$skipToken'
                if ($token) {
                    if ($seenTokens.ContainsKey($token)) { throw 'Repeated Resource Graph pagination token.' }
                    $seenTokens[$token] = $true
                } elseif ([string](Get-Field $page 'resultTruncated') -ieq 'true') {
                    throw 'Resource Graph truncated results without a continuation token.'
                }
            } while ($token)
            foreach ($key in $scopeRows.Keys) { $rows[$key] = $scopeRows[$key] }
            $coverage.Add(@{ subscriptionId = $subscription; status = 'complete'; count = $scopeRows.Count; error = $null })
        } catch {
            $status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
            $coverage.Add(@{ subscriptionId = $subscription; status = $status; count = $scopeRows.Count; error = $_.Exception.Message })
            foreach ($key in $scopeRows.Keys) { $rows[$key] = $scopeRows[$key] }
        }
    }
    @{ scopes = @($coverage); rows = @($rows.Values | Sort-Object id) }
}

function Get-BoundedVmModel {
    param($Model)
    $properties = $Model.properties
    $storageProfile = @{} + $properties.storageProfile
    $storageProfile.dataDisks = @($properties.storageProfile.dataDisks | Where-Object { $null -ne $_ })
    @{
        id = $Model.id.ToLowerInvariant(); location = $Model.location; zones = @($Model.zones | Where-Object { $null -ne $_ })
        etag = Get-Field $Model 'etag'; tags = $Model.tags
        hardwareProfile = $properties.hardwareProfile; storageProfile = $storageProfile
        networkProfile = $properties.networkProfile; securityProfile = $properties.securityProfile
        availabilitySet = $properties.availabilitySet; virtualMachineScaleSet = $properties.virtualMachineScaleSet
        proximityPlacementGroup = $properties.proximityPlacementGroup; host = $properties.host
        hostGroup = $properties.hostGroup; capacityReservation = $properties.capacityReservation
        priority = $properties.priority; additionalCapabilities = $properties.additionalCapabilities
        plan = $Model.plan; licenseType = $properties.licenseType
        extendedLocation = $Model.extendedLocation
        encryptionExtensions = @($Model.resources | Where-Object {
            (Get-Field $_ 'properties.publisher') -eq 'Microsoft.Azure.Security' -and
            (Get-Field $_ 'properties.type') -in @('AzureDiskEncryption','AzureDiskEncryptionForLinux')
        } | ForEach-Object { @{ publisher = $_.properties.publisher; type = $_.properties.type } })
        provisionVmAgent = if ($properties.storageProfile.osDisk.osType -eq 'Windows') {
            Get-Field $properties 'osProfile.windowsConfiguration.provisionVMAgent'
        } else { Get-Field $properties 'osProfile.linuxConfiguration.provisionVMAgent' }
        allowExtensionOperations = Get-Field $properties 'osProfile.allowExtensionOperations'
    }
}

function Get-VmEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VmId, [switch]$GuestConsent, [switch]$GuestNetworkProbeConsent,
        [string]$ObservationPath)
    if ($GuestNetworkProbeConsent -and -not $GuestConsent) { throw 'Guest network testing also requires guest-command consent.' }
    $identity = Get-VmIdentity $VmId
    $account = Invoke-UpgradeAz @('account','show','--subscription',$identity.subscriptionId)
    if ($ObservationPath) { Write-UpgradeJson $account "$ObservationPath.account.json" }
    if ($account.id -ne $identity.subscriptionId) { throw 'Subscription identity mismatch.' }
    if ($account.environmentName -ne 'AzureCloud') { throw 'This release supports Azure public cloud only.' }
    $raw = Invoke-ArmRead $VmId '2024-07-01'
    if ($ObservationPath) { Write-UpgradeJson $raw "$ObservationPath.vm.json" }
    $instance = Invoke-ArmRead "$VmId/instanceView" '2024-07-01'
    if ($ObservationPath) { Write-UpgradeJson $instance "$ObservationPath.instance-view.json" }
    $vm = Get-BoundedVmModel $raw
    $checks = [Collections.Generic.List[object]]::new()
    $resizeOptions = @{ status='unknown'; observedAt=[DateTimeOffset]::UtcNow.ToString('o'); sizes=@(); error=$null }
    try {
        $options = Invoke-ArmRead "$VmId/vmSizes" '2024-07-01'
        if ($ObservationPath) { Write-UpgradeJson $options "$ObservationPath.resize-options.json" }
        if ($null -eq $options.value -or $options.nextLink -or
            @($options.value | Where-Object { -not $_.name }).Count -or
            @($options.value | Group-Object name | Where-Object Count -GT 1).Count) {
            throw 'Incomplete or ambiguous VM resize-options response.'
        }
        $resizeOptions.sizes = @($options.value.name)
        $resizeOptions.status = 'collected'
    } catch [IO.IOException], [UnauthorizedAccessException] { throw }
    catch {
        $resizeOptions.status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
        $resizeOptions.error = $_.Exception.Message
        $checks.Add((New-Check 'resize-options' $resizeOptions.status $_.Exception.Message 'Compute VM sizes API'))
    }
    $reservationEvidence = $null
    $reservationId = Get-Field $vm 'capacityReservation.capacityReservationGroup.id'
    if ($reservationId) {
        $reservationEvidence = @{ status='unknown'; observedAt=[DateTimeOffset]::UtcNow.ToString('o')
            groupId=$reservationId; group=$null; reservations=@(); error=$null }
        try {
            if ($reservationId -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/Microsoft\.Compute/capacityReservationGroups/[^/]+$' -or
                $Matches[1] -ine $identity.subscriptionId) {
                throw 'Capacity reservation group must have an exact same-subscription ARM identity; shared/cross-subscription groups require separate review.'
            }
            $group = Invoke-ArmRead $reservationId '2024-07-01&$expand=instanceView'
            $reservationEvidence.group = $group
            if ($ObservationPath) { Write-UpgradeJson $reservationEvidence "$ObservationPath.capacity-reservation.json" }
            if ($group.id -ine $reservationId -or $null -eq $group.properties.capacityReservations) {
                throw 'Missing or contradictory capacity reservation group identity/member evidence.'
            }
            $seenReservations = @{}
            foreach ($reference in $group.properties.capacityReservations) {
                if (-not $reference.id -or -not $reference.id.StartsWith("$reservationId/capacityReservations/",[StringComparison]::OrdinalIgnoreCase) -or
                    $reference.id.Substring($reservationId.Length + '/capacityReservations/'.Length) -match '^$|/' -or $seenReservations.ContainsKey($reference.id)) {
                    throw 'Capacity reservation member identity is missing, outside the exact group or duplicated.'
                }
                $seenReservations[$reference.id] = $true
                $member = Invoke-ArmRead $reference.id '2024-07-01&$expand=instanceView'
                $reservationEvidence.reservations += $member
                if ($ObservationPath) { Write-UpgradeJson $reservationEvidence "$ObservationPath.capacity-reservation.json" }
                if ($member.id -ine $reference.id) { throw 'Capacity reservation member response identity mismatch.' }
            }
            $reservationEvidence.status = 'collected'
        } catch [IO.IOException], [UnauthorizedAccessException] { throw }
        catch {
            $reservationEvidence.status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
            $reservationEvidence.error = $_.Exception.Message
            $checks.Add((New-Check 'capacity-reservation-evidence' $reservationEvidence.status $_.Exception.Message 'ARM capacity reservation'))
        }
        if ($ObservationPath) { Write-UpgradeJson $reservationEvidence "$ObservationPath.capacity-reservation.json" }
    }
    try {
        $extensions = Invoke-ArmRead "$VmId/extensions" '2024-07-01'
        if ($null -eq $extensions.value -or $extensions.nextLink) { throw 'Incomplete VM extension list; ADE coverage cannot be assumed.' }
        $vm.encryptionExtensions = @($extensions.value | Where-Object {
            $_.properties.publisher -eq 'Microsoft.Azure.Security' -and
            $_.properties.type -in @('AzureDiskEncryption','AzureDiskEncryptionForLinux')
        } | ForEach-Object { @{ publisher = $_.properties.publisher; type = $_.properties.type } })
    } catch {
        $status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
        $checks.Add((New-Check 'ade-extension-coverage' $status $_.Exception.Message 'ARM extensions'))
    }
    $disks = [Collections.Generic.List[object]]::new()
    $nics = [Collections.Generic.List[object]]::new()
    $diskRefs = @($vm.storageProfile.osDisk) + @($vm.storageProfile.dataDisks)
    foreach ($reference in $diskRefs) {
        $id = Get-Field $reference 'managedDisk.id'
        if (-not $id) { $checks.Add((New-Check 'managed-disk' unsupported 'Unmanaged or missing disk reference.')); continue }
        try {
            $disk = Invoke-ArmRead $id '2024-03-02'
            $disks.Add(@{
                id = $disk.id.ToLowerInvariant(); etag = $disk.etag; sku = $disk.sku
                osType = $disk.properties.osType; hyperVGeneration = $disk.properties.hyperVGeneration
                sizeGB = $disk.properties.diskSizeGB; encryption = $disk.properties.encryption
                adeEnabled = Get-Field $disk 'properties.encryptionSettingsCollection.enabled'
                adeSettingsPresent = $null -ne (Get-Field $disk 'properties.encryptionSettingsCollection')
                securityProfile = $disk.properties.securityProfile
                supportedCapabilities = $disk.properties.supportedCapabilities
                maxShares = $disk.properties.maxShares; managedBy = $disk.managedBy
                networkAccessPolicy = $disk.properties.networkAccessPolicy
                diskIOPSReadWrite = $disk.properties.diskIOPSReadWrite
                diskMBpsReadWrite = $disk.properties.diskMBpsReadWrite
                creationData = @{ createOption = Get-Field $disk 'properties.creationData.createOption'
                    sourceResourceId = Get-Field $disk 'properties.creationData.sourceResourceId'
                    imageReference = Get-Field $disk 'properties.creationData.imageReference' }
            })
        } catch {
            $status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
            $checks.Add((New-Check "disk:$id" $status $_.Exception.Message 'ARM'))
        }
    }
    foreach ($reference in $vm.networkProfile.networkInterfaces) {
        try {
            $nic = Invoke-ArmRead $reference.id '2024-05-01'
            $nics.Add(@{
                id = $nic.id.ToLowerInvariant(); etag = $nic.etag
                acceleratedNetworking = $nic.properties.enableAcceleratedNetworking
                ipForwarding = $nic.properties.enableIPForwarding
                ipConfigurations = @($nic.properties.ipConfigurations)
                networkSecurityGroup = $nic.properties.networkSecurityGroup
            })
        } catch {
            $status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
            $checks.Add((New-Check "nic:$($reference.id)" $status $_.Exception.Message 'ARM'))
        }
    }
    $skus = Invoke-UpgradeAz @('vm','list-skus','--subscription',$identity.subscriptionId,
        '--location',$vm.location,'--resource-type','virtualMachines','--all')
    $usage = Invoke-UpgradeAz @('vm','list-usage','--subscription',$identity.subscriptionId,'--location',$vm.location)
    $imageProvenance = Get-ImageProvenanceEvidence $vm $identity.subscriptionId -ObservationPath $ObservationPath
    $hostEncryption = $null
    if ((Get-Field $vm 'securityProfile.encryptionAtHost') -eq $true) {
        try {
            $feature = Invoke-UpgradeAz @('feature','show','--subscription',$identity.subscriptionId,
                '--namespace','Microsoft.Compute','--name','EncryptionAtHost')
            $hostEncryption = @{ state = Get-Field $feature 'properties.state' }
        } catch {
            $status = if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
            $checks.Add((New-Check 'encryption-at-host-feature' $status $_.Exception.Message 'ARM feature'))
        }
    }
    $guest = $null
    if ($GuestConsent) {
        try { $guest = Invoke-VmGuestProbe -VmId $VmId -OsType $vm.storageProfile.osDisk.osType -NetworkProbeConsent:$GuestNetworkProbeConsent -ObservationPath:$ObservationPath }
        catch [IO.IOException], [UnauthorizedAccessException] { throw }
        catch { $checks.Add((New-Check 'guest' failed $_.Exception.Message 'Run Command')) }
    } else { $checks.Add((New-Check 'guest' unknown 'Not collected: guest invocation requires explicit consent.' 'Run Command')) }
    $evidence = @{
        schemaVersion = 'evidence/1.0'; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        tenantId = $account.tenantId; subscriptionId = $identity.subscriptionId
        vm = $vm; disks = @($disks); nics = @($nics)
        instanceView = @{
            statuses = @($instance.statuses); vmAgent = $instance.vmAgent
            diskStatuses = @($instance.disks | ForEach-Object { @{ name = $_.name; statuses = $_.statuses } })
        }
        skus = @($skus); usage = @($usage); guest = $guest; checks = @($checks)
        hostEncryption = $hostEncryption
        capacityReservationEvidence = $reservationEvidence
        resizeOptions = $resizeOptions
        imageProvenance = $imageProvenance
        capacity = @{ status = 'unknown'; detail = 'Quota and advertised SKU availability do not guarantee allocation.' }
        fingerprint = $null
    }
    if ($ObservationPath) { Write-UpgradeJson $evidence "$ObservationPath.evidence.json" }
    $evidence.fingerprint = Get-ConfigurationFingerprint $evidence
    Test-UpgradeDocument $evidence evidence | Out-Null
    return $evidence
}

function Get-ImageProvenanceEvidence {
    param($Vm, [string]$SubscriptionId, [string]$ObservationPath)
    $reference = Get-Field $Vm 'storageProfile.imageReference'
    $result = @{ status='not-exposed'; kind='specialized-or-unknown'; observedAt=[DateTimeOffset]::UtcNow.ToString('o')
        reference=$reference; resolvedVersion=$null; metadata=$null; definition=$null; error=$null }
    if (-not $reference) { return $result }
    try {
        if ($reference.id) {
            $id = [string]$reference.id
            if ($id -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/Microsoft\.Compute/(images/[^/]+|galleries/[^/]+/images/[^/]+/versions/[0-9]+\.[0-9]+\.[0-9]+)$' -or
                $Matches[1] -ine $SubscriptionId) { throw 'Image resource must be an exact same-subscription managed image or immutable gallery version; shared/community/cross-subscription references require separate review.' }
            $result.kind = if ($id -match '/galleries/') { 'gallery-version' } else { 'managed-image' }
            $apiVersion = if ($result.kind -eq 'gallery-version') { '2023-07-03' } else { '2024-03-01' }
            $raw = Invoke-ArmRead $id $apiVersion
            if ($ObservationPath) { Write-UpgradeJson $raw "$ObservationPath.image-source.json" }
            if ($raw.id -ine $id) { throw 'Image metadata response identity contradicts the referenced resource.' }
            if ($result.kind -eq 'gallery-version') {
                $result.resolvedVersion = ($id -split '/')[-1]
                $definitionId = $id -replace '/versions/[^/]+$',''
                $definition = Invoke-ArmRead $definitionId '2023-07-03'
                if ($ObservationPath) { Write-UpgradeJson $definition "$ObservationPath.image-definition.json" }
                if ($definition.id -ine $definitionId) { throw 'Gallery definition response identity mismatch.' }
                $result.definition = @{ id=$definition.id; etag=$definition.etag
                    hyperVGeneration=$definition.properties.hyperVGeneration; architecture=$definition.properties.architecture
                    osType=$definition.properties.osType; osState=$definition.properties.osState
                    features=@($definition.properties.features) }
                $result.metadata = @{ id=$raw.id; etag=$raw.etag; provisioningState=$raw.properties.provisioningState
                    excludeFromLatest=Get-Field $raw 'properties.publishingProfile.excludeFromLatest' }
            } else {
                $result.metadata = @{ id=$raw.id; etag=$raw.etag; hyperVGeneration=$raw.properties.hyperVGeneration
                    architecture=Get-Field $raw 'properties.architecture'; provisioningState=$raw.properties.provisioningState
                    osType=Get-Field $raw 'properties.storageProfile.osDisk.osType'
                    osState=Get-Field $raw 'properties.storageProfile.osDisk.osState' }
            }
        } elseif ($reference.publisher -and $reference.offer -and $reference.sku) {
            $result.kind='marketplace'
            $version = if ($reference.exactVersion) { $reference.exactVersion } else { $reference.version }
            if (-not $version -or $version -ieq 'latest') { throw 'Marketplace provenance needs a resolved exact version, not latest.' }
            foreach ($segment in @($reference.publisher,$reference.offer,$reference.sku,$version)) {
                if ($segment -notmatch '^[A-Za-z0-9._-]+$') { throw 'Malformed Marketplace image reference.' }
            }
            $urn = "$($reference.publisher):$($reference.offer):$($reference.sku):$version"
            $raw = Invoke-UpgradeAz @('vm','image','show','--subscription',$SubscriptionId,'--location',$Vm.location,'--urn',$urn)
            if ($ObservationPath) { Write-UpgradeJson $raw "$ObservationPath.image-source.json" }
            if ($raw.name -cne $version) { throw 'Marketplace response version does not match exact provenance.' }
            $result.resolvedVersion = $version
            $result.metadata = @{ version=$raw.name; hyperVGeneration=$raw.hyperVGeneration; architecture=$raw.architecture
                osType=$raw.osDiskImage.operatingSystem; features=@($raw.features) }
        } else { throw 'Incomplete or shared/community image reference requires separate provenance review.' }
        $result.status='collected'
    } catch [IO.IOException], [UnauthorizedAccessException] { throw }
    catch {
        $result.status=if ($_.Exception.Message -match 'AuthorizationFailed|Forbidden|403') { 'denied' } else { 'failed' }
        $result.error=$_.Exception.Message
    }
    if ($ObservationPath) { Write-UpgradeJson $result "$ObservationPath.image-provenance.json" }
    return $result
}

function Invoke-VmGuestProbe {
    param([string]$VmId, [ValidateSet('Linux','Windows')][string]$OsType, [switch]$NetworkProbeConsent,
        [string]$ObservationPath)
    $identity = Get-VmIdentity $VmId
    $file = if ($OsType -eq 'Linux') { 'linux-probe.sh' } else { 'windows-probe.ps1' }
    $commandId = if ($OsType -eq 'Linux') { 'RunShellScript' } else { 'RunPowerShellScript' }
    $scriptPath = Join-Path $script:RepositoryRoot "guest\$file"
    $temporary = $null
    try {
        if ($NetworkProbeConsent) {
            if ($OsType -ne 'Linux') { throw 'Bounded Azure HTTPS traffic probe is implemented for Linux only.' }
            $temporary = Join-Path ([IO.Path]::GetTempPath()) "azvm-probe-$([guid]::NewGuid().ToString('N')).sh"
            $body = Get-Content $scriptPath -Raw
            [IO.File]::WriteAllText($temporary, "#!/usr/bin/env bash`nexport AZVM_NETWORK_PROBE_CONSENT='approved-azure-https-probe'`n" + ($body -replace '^#!.*\r?\n', ''))
            $scriptPath = $temporary
        }
        $result = Invoke-UpgradeAz @('vm','run-command','invoke','--ids',$VmId,'--subscription',$identity.subscriptionId,
            '--command-id',$commandId,'--scripts',("@"+$scriptPath)) -TimeoutSeconds 600
    } finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary }
    }
    if ($ObservationPath) { Write-UpgradeJson $result "$ObservationPath.run-command.json" }
    $stdout = Get-RunCommandStdout $result
    # Run Command output is bounded by Azure; markers distinguish truncation from valid evidence.
    $match = [regex]::Match($stdout, '(?s)AZVM_EVIDENCE_BEGIN\s*(\{.*?\})\s*AZVM_EVIDENCE_END')
    if (-not $match.Success) { throw 'Guest evidence is missing, truncated, or invalid.' }
    $guest = $match.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String
    Test-UpgradeDocument $guest guest | Out-Null
    if (-not $guest.complete) { throw 'Guest probe reported incomplete evidence.' }
    return $guest
}
