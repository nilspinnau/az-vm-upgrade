Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
InModuleScope AzVmUpgrade {
    BeforeAll { . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1') }
    Describe 'Generation stages and retained OS image planning' {
        It 'keeps Gen1 NVMe blocked and identifies TL-only or rebuild without mutation' {
            $e=New-FixtureEvidence;$e.disks[0].hyperVGeneration='V1';$e.guest.bootMode='BIOS'
            $e.fingerprint=Get-ConfigurationFingerprint $e
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'requires-rebuild'
            $p.imageGeneration.generationPath | Should -Be 'separate-trusted-launch-or-rebuild'
            ($p.imageGeneration.alternatives -join ' ') | Should -Match 'Trusted Launch only'
            ($p.imageGeneration.alternatives -join ' ') | Should -Match 'MBR2GPT validate'
            ($p.imageGeneration.alternatives -join ' ') | Should -Match 'Enhanced Backup'
            ($p.imageGeneration.actions -join ' ') | Should -Match 'still blocks Trusted Launch'
            $out=Join-Path $TestDrive 'gen1-guide';Export-VmUpgradeReport $p $out | Out-Null
            Test-Path (Join-Path $out 'upgrade.ps1') | Should -BeFalse
            Get-Content (Join-Path $out 'guide.md') -Raw | Should -Match 'No rollback to Gen1 except full recovery'
        }
        It 'does not mistake Gen1 SCSI resize for a generation conversion' {
            $e=New-FixtureEvidence;$e.disks[0].hyperVGeneration='V1';$e.guest.bootMode='BIOS'
            $e.fingerprint=Get-ConfigurationFingerprint $e
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $p.imageGeneration.generation | Should -Be 'V1'
            $p.targetController | Should -Be 'SCSI'
            $p.classification | Should -Be 'ready'
        }
        It 'retains existing specialized OS without inventing image metadata' {
            $p=New-FixturePlan
            $p.imageGeneration.imageHandling | Should -Be 'retain-existing-os-disk'
            $p.imageGeneration.provenanceStatus | Should -Be 'not-collected'
            ($p.imageGeneration.actions -join ' ') | Should -Match 'does not update its installed OS'
        }
        It 'does not accept image Gen2 tags instead of authoritative disk generation' {
            $e=New-FixtureEvidence;$e.disks[0].Remove('hyperVGeneration')
            $e.imageProvenance=@{status='collected';kind='marketplace';metadata=@{hyperVGeneration='V2'};observedAt=$e.observedAt;reference=$null;resolvedVersion='1.2.3';definition=$null;error=$null}
            $e.fingerprint=Get-ConfigurationFingerprint $e
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'incomplete-evidence'
        }
        It 'refuses contradictory image metadata: <Case>' -ForEach @(@{Case='generation'},@{Case='architecture'}) {
            $e=New-FixtureEvidence
            $e.imageProvenance=@{status='collected';kind='gallery-version';definition=@{hyperVGeneration='V2';architecture='x64'};observedAt=$e.observedAt;reference=$null;resolvedVersion='1.2.3';metadata=$null;error=$null}
            if($Case -eq 'generation'){$e.imageProvenance.definition.hyperVGeneration='V1'}else{$e.imageProvenance.definition.architecture='Arm64'}
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'blocked'
            $p.checks.name | Should -Contain 'image-provenance-conflict'
        }
        It 'requires actual boot evidence even with a declared Gen2 image' {
            $e=New-FixtureEvidence;$e.guest.bootMode='BIOS'
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'incomplete-evidence'
            $p.checks.name | Should -Contain 'guest-uefi'
        }
        It 'keeps Trusted Launch assessment-only after a generation stage' {
            $e=New-FixtureEvidence;$e.vm.securityProfile=@{securityType='TrustedLaunch'}
            $e.fingerprint=Get-ConfigurationFingerprint $e
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'does not treat the Windows GPT candidate label as Linux UEFI proof' {
            $e=New-FixtureEvidence;$e.guest.bootMode='UEFI-candidate'
            (Get-ImageGenerationAssessment $e 'NVMe').checks.name | Should -Contain 'guest-uefi'
        }
        It 'retains the documented Windows boot candidate distinction' {
            $e=New-FixtureEvidence;$e.vm.storageProfile.osDisk.osType='Windows';$e.guest.bootMode='UEFI-candidate'
            (Get-ImageGenerationAssessment $e 'NVMe').checks.name | Should -Not -Contain 'guest-uefi'
        }
    }
    Describe 'Scoped read-only image provenance' {
        BeforeEach {
            $script:e=New-FixtureEvidence
            Mock Invoke-UpgradeAz {throw 'Unexpected image CLI call'}
            Mock Invoke-ArmRead {throw 'Unexpected image resource read'}
        }
        It 'does not fetch an imagined image for specialized disk VMs' {
            $r=Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId
            $r.status | Should -Be 'not-exposed'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly
        }
        It 'resolves Marketplace exactVersion without following latest' {
            $script:e.vm.storageProfile.imageReference=@{publisher='Canonical';offer='ubuntu-24_04-lts';sku='server';version='latest';exactVersion='24.04.202609040'}
            Mock Invoke-UpgradeAz {@{name='24.04.202609040';hyperVGeneration='V2';architecture='x64';osDiskImage=@{operatingSystem='Linux'};features=@(@{name='DiskControllerTypes';value='SCSI,NVMe'})}}
            $r=Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId -ObservationPath (Join-Path $TestDrive 'marketplace')
            $r.status | Should -Be 'collected'
            $r.resolvedVersion | Should -Be '24.04.202609040'
            Should -Invoke Invoke-UpgradeAz -Times 1 -Exactly -ParameterFilter {'Canonical:ubuntu-24_04-lts:server:24.04.202609040' -in $Arguments -and $script:e.subscriptionId -in $Arguments}
        }
        It 'refuses unresolved Marketplace latest without a speculative read' {
            $script:e.vm.storageProfile.imageReference=@{publisher='Canonical';offer='ubuntu';sku='server';version='latest'}
            (Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId).status | Should -Be 'failed'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'collects exact gallery version and definition, not mutable latest' {
            $id="/subscriptions/$($script:e.subscriptionId)/resourceGroups/images/providers/Microsoft.Compute/galleries/g/images/i/versions/1.2.3"
            $script:e.vm.storageProfile.imageReference=@{id=$id}
            Mock Invoke-ArmRead {
                param($Id)
                @{id=$Id;etag='synthetic';properties=@{provisioningState='Succeeded';hyperVGeneration='V2';architecture='x64';osType='Linux';osState='Generalized';features=@(@{name='SecurityType';value='TrustedLaunchSupported'},@{name='DiskControllerTypes';value='SCSI,NVMe'})}}
            }
            $r=Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId
            $r.status | Should -Be 'collected'
            $r.kind | Should -Be 'gallery-version'
            $r.resolvedVersion | Should -Be '1.2.3'
            $r.definition.features.Count | Should -Be 2
            Should -Invoke Invoke-ArmRead -Times 2 -Exactly
            Should -Invoke Invoke-ArmRead -Times 2 -Exactly -ParameterFilter {$ApiVersion -eq '2023-07-03'}
        }
        It 'uses the documented managed-image API separately from gallery APIs' {
            $script:e.vm.storageProfile.imageReference=@{id="/subscriptions/$($script:e.subscriptionId)/resourceGroups/images/providers/Microsoft.Compute/images/i"}
            Mock Invoke-ArmRead {param($Id) @{id=$Id;properties=@{hyperVGeneration='V2';provisioningState='Succeeded'}}}
            (Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId).status | Should -Be 'collected'
            Should -Invoke Invoke-ArmRead -Times 1 -Exactly -ParameterFilter {$ApiVersion -eq '2024-03-01'}
        }
        It 'refuses unresolved or external image identities: <Case>' -ForEach @(
            @{Case='gallery-latest'},@{Case='cross-subscription'},@{Case='shared'}
        ) {
            $id="/subscriptions/$($script:e.subscriptionId)/resourceGroups/images/providers/Microsoft.Compute/galleries/g/images/i/versions/1.2.3"
            switch($Case){
                gallery-latest {$id=$id -replace '1.2.3$','latest'}
                cross-subscription {$id=$id -replace $script:e.subscriptionId,('1' * 36)}
                shared {$id='/SharedGalleries/g/Images/i/Versions/1.2.3'}
            }
            $script:e.vm.storageProfile.imageReference=@{id=$id}
            (Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId).status | Should -Be 'failed'
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly
        }
        It 'retains image response before rejecting a version contradiction' {
            $script:e.vm.storageProfile.imageReference=@{publisher='Canonical';offer='ubuntu';sku='server';version='1.2.3'}
            Mock Invoke-UpgradeAz {@{name='1.2.4';hyperVGeneration='V2'}}
            $path=Join-Path $TestDrive 'contradictory'
            (Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId -ObservationPath $path).status | Should -Be 'failed'
            (Read-UpgradeJson "$path.image-source.json").name | Should -Be '1.2.4'
        }
        It 'retains image access denial as unknown provenance, not readiness' {
            $script:e.vm.storageProfile.imageReference=@{id="/subscriptions/$($script:e.subscriptionId)/resourceGroups/images/providers/Microsoft.Compute/images/i"}
            Mock Invoke-ArmRead {throw 'AuthorizationFailed 403'}
            (Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId).status | Should -Be 'denied'
        }
        It 'propagates durable image-evidence publication failure' {
            $script:e.vm.storageProfile.imageReference=@{publisher='Canonical';offer='ubuntu';sku='server';version='1.2.3'}
            Mock Invoke-UpgradeAz {@{name='1.2.3'}}
            Mock Write-UpgradeJson {throw [IO.IOException]::new('Image evidence publication failed')}
            {Get-ImageProvenanceEvidence $script:e.vm $script:e.subscriptionId -ObservationPath (Join-Path $TestDrive 'fail')} | Should -Throw '*publication failed*'
        }
    }
}
