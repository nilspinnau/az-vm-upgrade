Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    BeforeAll {
        . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
    }
    Describe 'Encryption at host compatibility and preservation' {
        BeforeEach {
            $script:encrypted = New-FixtureEvidence
            $script:encrypted.vm.securityProfile = @{ encryptionAtHost = $true; securityType = 'Standard' }
            $script:encrypted.hostEncryption = @{ state = 'Registered' }
            $script:encrypted.fingerprint = Get-ConfigurationFingerprint $script:encrypted
        }
        It 'permits retaining enabled host encryption on compatible bounded lab sizes' {
            $p = New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'ready'
            @($p.checks | Where-Object { $_.name -like 'encryption-at-host*' -and $_.status -eq 'pass' }).Count | Should -Be 3
        }
        It 'does not accept absent source or target encryption capability' -ForEach @(@{ Index = 0 },@{ Index = 1 }) {
            $script:encrypted.skus[$Index].capabilities = @($script:encrypted.skus[$Index].capabilities | Where-Object name -NE EncryptionAtHostSupported)
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'incomplete-evidence'
        }
        It 'blocks a target without host-encryption support' {
            ($script:encrypted.skus[1].capabilities | Where-Object name -EQ EncryptionAtHostSupported).value = 'False'
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'requires read-only feature evidence without automatic registration' -ForEach @(
            @{ State = $null; Expected = 'incomplete-evidence' },
            @{ State = 'NotRegistered'; Expected = 'blocked' },
            @{ State = 'Registering'; Expected = 'blocked' }
        ) {
            $script:encrypted.hostEncryption.state = $State
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be $Expected
        }
        It 'retains an ADE extension safety block even without active disk settings' {
            $script:encrypted.vm.encryptionExtensions = @(@{ publisher = 'Microsoft.Azure.Security'; type = 'AzureDiskEncryptionForLinux' })
            $script:encrypted.fingerprint = Get-ConfigurationFingerprint $script:encrypted
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'blocks retained ADE disk metadata and does not decrypt it' {
            $script:encrypted.disks[0].adeEnabled = $false
            $script:encrypted.disks[0].adeSettingsPresent = $true
            $script:encrypted.fingerprint = Get-ConfigurationFingerprint $script:encrypted
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'keeps CMK and confidential disk security separate from host encryption' -ForEach @(
            @{ Field = 'encryption'; Value = @{ type = 'EncryptionAtRestWithCustomerKey' } },
            @{ Field = 'securityProfile'; Value = @{ securityType = 'ConfidentialVM_DiskEncryptedWithCustomerKey' } }
        ) {
            $script:encrypted.disks[0][$Field] = $Value
            $script:encrypted.fingerprint = Get-ConfigurationFingerprint $script:encrypted
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'rejects encryption drift before recording a new expected fingerprint' {
            $live = New-FixtureEvidence
            $live.vm.securityProfile = @{ encryptionAtHost = $false; securityType = 'Standard' }
            $journal = @{ phase = 'deallocated'; originalEvidence = $script:encrypted; expectedFingerprint = 'original' }
            { Save-UpgradePhase $journal (Join-Path $TestDrive 'journal.json') updated $live } | Should -Throw '*security profile*'
            $journal.phase | Should -Be 'deallocated'
            $journal.expectedFingerprint | Should -Be 'original'
            Test-Path (Join-Path $TestDrive 'journal.json') | Should -BeFalse
        }
        It 'permits intended size/controller changes while preserving security' {
            $live = New-FixtureEvidence
            $live.vm.securityProfile = @{ encryptionAtHost = $true; securityType = 'Standard' }
            $live.vm.hardwareProfile.vmSize = 'Standard_D2s_v6'
            $live.vm.storageProfile.diskControllerType = 'NVMe'
            { Assert-UpgradeSecurityPreserved $script:encrypted $live } | Should -Not -Throw
        }
        It 'never silently changes Trusted Launch, Secure Boot or vTPM' -ForEach @(
            @{ Field = 'securityType'; Value = 'Standard' },
            @{ Field = 'secureBootEnabled'; Value = $false },
            @{ Field = 'vTpmEnabled'; Value = $false }
        ) {
            $script:encrypted.vm.securityProfile = @{ encryptionAtHost = $true; securityType = 'TrustedLaunch'
                uefiSettings = @{ secureBootEnabled = $true; vTpmEnabled = $true } }
            $live = $script:encrypted | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
            if ($Field -eq 'securityType') { $live.vm.securityProfile[$Field] = $Value }
            else { $live.vm.securityProfile.uefiSettings[$Field] = $Value }
            { Assert-UpgradeSecurityPreserved $script:encrypted $live } | Should -Throw '*security profile*'
        }
        It 'rejects changed disk encryption or missing security evidence' {
            $live = New-FixtureEvidence
            $live.vm.securityProfile = $script:encrypted.vm.securityProfile
            $live.disks[0].encryption = @{ type = 'EncryptionAtRestWithCustomerKey' }
            { Assert-UpgradeSecurityPreserved $script:encrypted $live } | Should -Throw '*encryption changed*'
            $live.disks = @()
            { Assert-UpgradeSecurityPreserved $script:encrypted $live } | Should -Throw '*missing*'
        }
        It 'preserves filesystem identity at the same Microsoft-mapped LUN across controllers' {
            $script:encrypted.guest.managedDataMappings = @(@{ lun = 0; uuids = @('synthetic-filesystem-uuid'); controller = 'SCSI' })
            $p = New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $live = $script:encrypted | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
            $live.vm.hardwareProfile.vmSize = $p.targetSize
            $live.guest.runtimeSizeEvidence.vmSize = $p.targetSize
            $live.vm.storageProfile.diskControllerType = 'NVMe'
            $live.guest.actualController = 'NVMe'
            $live.guest.managedDataMappings[0].controller = 'NVMe'
            { Test-PostUpgradeGuest $p $live } | Should -Not -Throw
            $live.guest.managedDataMappings[0].uuids = @('other-filesystem')
            { Test-PostUpgradeGuest $p $live } | Should -Throw '*LUN mapping*'
        }
        It 'requires the consent-bound connectivity baseline before downtime' {
            $review = New-FixtureReview
            $review.guestNetworkProbeConsent = $true
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview $review).classification | Should -Be 'needs-preparation'
            $script:encrypted.guest.azureHttpsConnectivity = 'failed'
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview $review).classification | Should -Be 'blocked'
            $script:encrypted.guest.azureHttpsConnectivity = 'pass'
            (New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview $review).classification | Should -Be 'ready'
        }
        It 'binds Terraform no-op to host encryption rather than accepting a false setting' {
            $id = $script:encrypted.vm.id
            $tf = @{ format_version = '1.2'; resource_changes = @(@{
                address = 'azurerm_linux_virtual_machine.test[0]'; type = 'azurerm_linux_virtual_machine'
                change = @{ actions = @('no-op'); before = @{ id = $id }
                    after = @{ id = $id; size = 'Standard_D2s_v6'; disk_controller_type = 'NVMe'; encryption_at_host_enabled = $false } }
            }) }
            $map = @{ vmAddress = 'azurerm_linux_virtual_machine.test[0]' }
            (Test-TerraformUpgradePlan $tf $map $id Standard_D2s_v6 NVMe -Reconciliation -ExpectedEncryptionAtHost $true).status | Should -Be 'failed'
            $tf.resource_changes[0].change.after.encryption_at_host_enabled = $true
            (Test-TerraformUpgradePlan $tf $map $id Standard_D2s_v6 NVMe -Reconciliation -ExpectedEncryptionAtHost $true).status | Should -Be 'pass'
            $tf.resource_changes[0].change.after_unknown = @{ encryption_at_host_enabled = $true }
            (Test-TerraformUpgradePlan $tf $map $id Standard_D2s_v6 NVMe -Reconciliation -ExpectedEncryptionAtHost $true).status | Should -Be 'failed'
        }
        It 'bounds ADE extension evidence without retaining protected settings' {
            $raw = @{ id = $script:encrypted.vm.id; location = 'westeurope'; properties = @{
                storageProfile = @{ osDisk = @{ osType = 'Linux' } }
            }; resources = @(@{ properties = @{ publisher = 'Microsoft.Azure.Security'
                type = 'AzureDiskEncryptionForLinux'; protectedSettings = @{ privateValue = 'never-export' } } }) }
            $model = Get-BoundedVmModel $raw
            $model.encryptionExtensions.Count | Should -Be 1
            ($model | ConvertTo-Json -Depth 20) | Should -Not -Match 'never-export|protectedSettings'
        }
        It 'uses combined cache limits only for a proved no-temp SKU and checks write throughput too' {
            foreach ($sku in $script:encrypted.skus) {
                $sku.capabilities = @($sku.capabilities | Where-Object name -NotLike 'Cached*')
                $sku.capabilities += @(
                    @{ name = 'CombinedTempDiskAndCachedIOPS'; value = '9000' },
                    @{ name = 'CombinedTempDiskAndCachedReadBytesPerSecond'; value = '125000000' },
                    @{ name = 'CombinedTempDiskAndCachedWriteBytesPerSecond'; value = '125000000' }
                )
            }
            $script:encrypted.skus[0].capabilities = @($script:encrypted.skus[0].capabilities | Where-Object name -NE DiskControllerTypes)
            @(Test-TargetCompatibility $script:encrypted $script:encrypted.skus[0] $script:encrypted.skus[1] NVMe | Where-Object status -NE pass).Count | Should -Be 0
            ($script:encrypted.skus[1].capabilities | Where-Object name -EQ CombinedTempDiskAndCachedWriteBytesPerSecond).value = '1'
            @(Test-TargetCompatibility $script:encrypted $script:encrypted.skus[0] $script:encrypted.skus[1] NVMe | Where-Object { $_.name -eq 'performance:CachedDiskWriteBytesPerSecond' -and $_.status -eq 'unsupported' }).Count | Should -Be 1
            ($script:encrypted.skus[0].capabilities | Where-Object name -EQ MaxResourceVolumeMB).value = '1024'
            Get-SkuCacheCapability $script:encrypted.skus[0] CachedDiskIOPS | Should -BeNullOrEmpty
        }
        It 'rejects a changed data checksum and application health after preparation' {
            $p = New-VmUpgradePlan $script:encrypted -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $prep = New-GuestPreparationPlan $p -Component nvme-boot -GuestChangeConsent
            $manifest = @{ status = 'ok'; action = 'apply'; planHash = $p.hash
                observedAt = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o'); bootId = 'previous' }
            $script:encrypted.guest.bootId = 'restarted'
            $script:encrypted.guest.sentinelHash = '3' * 64
            $script:encrypted.guest.applicationHealth = 'failed'
            $outcome = Test-PreparationOutcome $prep $manifest $script:encrypted
            $outcome.status | Should -Be 'rejected'
            @($outcome.checks | Where-Object { $_.name -in @('data-sentinel-unchanged','application-health') -and $_.status -eq 'failed' }).Count | Should -Be 2
            $script:encrypted.guest.observedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
            @(Test-PreparationOutcome $prep $manifest $script:encrypted | ForEach-Object checks | Where-Object { $_.name -eq 'guest-freshness' -and $_.status -eq 'failed' }).Count | Should -Be 1
        }
    }
}
