function New-FixtureSku {
    param([string]$Name = 'Standard_D2s_v5', [string]$Family = 'standardDSv5Family', [int]$Cores = 2)
    $capabilities = @{
        vCPUs = "$Cores"; vCPUsAvailable = "$Cores"; MemoryGB = '8'; MaxDataDiskCount = '4'
        MaxNetworkInterfaces = '2'; CpuArchitectureType = 'x64'; HyperVGenerations = 'V1,V2'
        DiskControllerTypes = 'SCSI,NVMe'; MaxResourceVolumeMB = '0'
        UncachedDiskIOPS = '3750'; UncachedDiskBytesPerSecond = '85000000'
        CachedDiskIOPS = '4000'; CachedDiskBytesPerSecond = '100000000'
        PremiumIO = 'True'; AcceleratedNetworkingEnabled = 'True'; EncryptionAtHostSupported = 'True'
    }
    @{
        name = $Name; family = $Family; locations = @('westeurope'); resourceType = 'virtualMachines'
        locationInfo = @(@{ location = 'westeurope'; zones = @('1','2','3') }); restrictions = @()
        capabilities = @($capabilities.Keys | Sort-Object | ForEach-Object { @{ name = $_; value = $capabilities[$_] } })
    }
}

function New-FixtureUsage {
    @(
        @{ name = @{ value = 'cores' }; currentValue = 10; limit = 20 },
        @{ name = @{ value = 'standardDSv5Family' }; currentValue = 4; limit = 20 },
        @{ name = @{ value = 'standardDSv6Family' }; currentValue = 2; limit = 20 },
        @{ name = @{ value = 'virtualMachines' }; currentValue = 5; limit = 100 }
    )
}

function New-FixtureEvidence {
    $vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/azvm-upgrade-lab-offline/providers/microsoft.compute/virtualmachines/testvm'
    $osDiskId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/azvm-upgrade-lab-offline/providers/microsoft.compute/disks/os'
    $dataDiskId = $osDiskId -replace '/os$', '/data'
    $nicId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/azvm-upgrade-lab-offline/providers/microsoft.network/networkinterfaces/test'
    $evidence = @{
        schemaVersion = 'evidence/1.0'; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        tenantId = '00000000-0000-0000-0000-000000000000'; subscriptionId = '00000000-0000-0000-0000-000000000000'
        vm = @{
            id = $vmId; location = 'westeurope'; zones = @('1')
            tags = @{ 'az-vm-upgrade-disposable' = 'true' }; etag = $null
            hardwareProfile = @{ vmSize = 'Standard_D2s_v5' }
            storageProfile = @{
                diskControllerType = 'SCSI'; osDisk = @{ osType = 'Linux'; managedDisk = @{ id = $osDiskId } }
                dataDisks = @(@{ lun = 0; managedDisk = @{ id = $dataDiskId } })
            }
            networkProfile = @{ networkInterfaces = @(@{ id = $nicId }) }; securityProfile = $null
        }
        disks = @(
            @{ id = $osDiskId; hyperVGeneration = 'V2'; sku = @{ name = 'StandardSSD_LRS' }; supportedCapabilities = @{ diskControllerTypes = 'SCSI' } },
            @{ id = $dataDiskId; sku = @{ name = 'StandardSSD_LRS' } }
        )
        nics = @(@{ id = $nicId; acceleratedNetworking = $true })
        instanceView = @{ statuses = @(@{ code = 'ProvisioningState/succeeded' },@{ code = 'PowerState/running' }) }
        skus = @((New-FixtureSku),(New-FixtureSku 'Standard_D2s_v6' 'standardDSv6Family'))
        usage = @(New-FixtureUsage); checks = @()
        guest = @{
            schemaVersion = 'guest/1.0'; observedAt = [DateTimeOffset]::UtcNow.ToString('o'); complete = $true
            osProfile = 'ubuntu:22.04:x86_64'; agentReady = $true; pendingReboot = $false
            nvmeDriver = 'pass'; nvmeBoot = 'pass'; manaDriver = 'pass'; mellanoxDriver = 'pass'
            actualController = 'SCSI'; persistentMounts = $true; layoutSupported = $true
            storageIdentityHash = ('1' * 64); sentinelHash = ('2' * 64); applicationHealth = 'pass'
            accelerationInUse = 'pass'; manaInUse = 'pass'
            runtimeSizeEvidence = @{status='collected';vmSize='Standard_D2s_v5';logicalProcessors=2;error=$null}
        }
        capacity = @{ status = 'unknown'; detail = 'Synthetic fixture, not live evidence.' }; fingerprint = '0' * 64
        resizeOptions = @{status='collected';observedAt=[DateTimeOffset]::UtcNow.ToString('o');sizes=@('Standard_D2s_v5','Standard_D2s_v6');error=$null}
    }
    $evidence.fingerprint = & (Get-Module AzVmUpgrade) { param($e) Get-ConfigurationFingerprint $e } $evidence
    return $evidence
}

function New-FixtureReview {
    @{ reviewed = $true; noThirdPartyBootFilters = $true; noClusterOrAppliance = $true
        noTemporaryStorageDependencies = $true; requireManaInUse = $true; reference = 'synthetic-offline-review' }
}

function New-FixturePlan {
    $evidence = New-FixtureEvidence
    New-VmUpgradePlan $evidence -TargetSize 'Standard_D2s_v6' -Controller NVMe -WorkloadReview (New-FixtureReview)
}

function New-FixtureApproval {
    param($Plan)
    @{
        schemaVersion = 'approval/1.0'; planHash = $Plan.hash; vmId = $Plan.vmId
        tenantId = $Plan.tenantId; subscriptionId = $Plan.subscriptionId
        targetSize = $Plan.targetSize; targetController = $Plan.targetController
        executionMode = $Plan.resize.execution; restartDowntime = $true
        expiresAt = $Plan.expiresAt; testResourceGroup = 'azvm-upgrade-lab-offline'
        labOnly = $true; downtime = $true; temporaryDataLoss = $true; guestCommands = $true
        exclusiveWindow = $true; requireOwnerAcceptance = $true
        protection = @{ type = 'accepted-recovery-method'; accepted = $true
            reference = 'synthetic-offline-protection'; verifiedAt = [DateTimeOffset]::UtcNow.ToString('o') }
    }
}
