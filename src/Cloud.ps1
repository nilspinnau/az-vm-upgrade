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
        provisionVmAgent = if ($properties.storageProfile.osDisk.osType -eq 'Windows') {
            Get-Field $properties 'osProfile.windowsConfiguration.provisionVMAgent'
        } else { Get-Field $properties 'osProfile.linuxConfiguration.provisionVMAgent' }
        allowExtensionOperations = Get-Field $properties 'osProfile.allowExtensionOperations'
    }
}

function Get-VmEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VmId, [switch]$GuestConsent)
    $identity = Get-VmIdentity $VmId
    $account = Invoke-UpgradeAz @('account','show','--subscription',$identity.subscriptionId)
    if ($account.id -ne $identity.subscriptionId) { throw 'Subscription identity mismatch.' }
    if ($account.environmentName -ne 'AzureCloud') { throw 'This release supports Azure public cloud only.' }
    $raw = Invoke-ArmRead $VmId '2024-07-01'
    $instance = Invoke-ArmRead "$VmId/instanceView" '2024-07-01'
    $vm = Get-BoundedVmModel $raw
    $checks = [Collections.Generic.List[object]]::new()
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
                supportedCapabilities = $disk.properties.supportedCapabilities
                maxShares = $disk.properties.maxShares; managedBy = $disk.managedBy
                networkAccessPolicy = $disk.properties.networkAccessPolicy
                diskIOPSReadWrite = $disk.properties.diskIOPSReadWrite
                diskMBpsReadWrite = $disk.properties.diskMBpsReadWrite
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
    $guest = $null
    if ($GuestConsent) {
        try { $guest = Invoke-VmGuestProbe -VmId $VmId -OsType $vm.storageProfile.osDisk.osType }
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
        capacity = @{ status = 'unknown'; detail = 'Quota and advertised SKU availability do not guarantee allocation.' }
        fingerprint = $null
    }
    $evidence.fingerprint = Get-ConfigurationFingerprint $evidence
    Test-UpgradeDocument $evidence evidence | Out-Null
    return $evidence
}

function Invoke-VmGuestProbe {
    param([string]$VmId, [ValidateSet('Linux','Windows')][string]$OsType)
    $identity = Get-VmIdentity $VmId
    $file = if ($OsType -eq 'Linux') { 'linux-probe.sh' } else { 'windows-probe.ps1' }
    $commandId = if ($OsType -eq 'Linux') { 'RunShellScript' } else { 'RunPowerShellScript' }
    $result = Invoke-UpgradeAz @('vm','run-command','invoke','--ids',$VmId,'--subscription',$identity.subscriptionId,
        '--command-id',$commandId,'--scripts',("@"+(Join-Path $script:RepositoryRoot "guest\$file"))) -TimeoutSeconds 600
    $messages = @($result.value | Where-Object { $_.code -match 'StdOut' })
    if ($messages.Count -ne 1) { throw 'Run Command returned no unique stdout result.' }
    # Run Command output is bounded by Azure; markers distinguish truncation from valid evidence.
    $match = [regex]::Match($messages[0].message, '(?s)AZVM_EVIDENCE_BEGIN\s*(\{.*?\})\s*AZVM_EVIDENCE_END')
    if (-not $match.Success) { throw 'Guest evidence is missing, truncated, or invalid.' }
    $guest = $match.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String
    Test-UpgradeDocument $guest guest | Out-Null
    if (-not $guest.complete) { throw 'Guest probe reported incomplete evidence.' }
    return $guest
}
