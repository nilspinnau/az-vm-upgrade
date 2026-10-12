Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
InModuleScope AzVmUpgrade {
    BeforeAll {
        . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
        function New-ReservationFixture {
            $e = New-FixtureEvidence
            $id = "/subscriptions/$($e.subscriptionId)/resourceGroups/reservation-fixture/providers/Microsoft.Compute/capacityReservationGroups/group"
            $member = @{id="$id/capacityReservations/target";location='westeurope';zones=@('1')
                sku=@{name='Standard_D2s_v6';capacity=2};properties=@{provisioningState='Succeeded'
                    instanceView=@{statuses=@(@{code='ProvisioningState/succeeded'})
                        utilizationInfo=@{currentCapacity=2;virtualMachinesAllocated=@()}}}}
            $e.vm.capacityReservation=@{capacityReservationGroup=@{id=$id}}
            $e.capacityReservationEvidence=@{status='collected';observedAt=[DateTimeOffset]::UtcNow.ToString('o');groupId=$id
                group=@{id=$id;location='westeurope';zones=@('1');properties=@{capacityReservations=@(@{id=$member.id})}}
                reservations=@($member)}
            $e.fingerprint=Get-ConfigurationFingerprint $e
            return $e
        }
    }
    Describe 'Non-NVMe migration and reservation read-only planning' {
        It 'plans a SCSI-only target without requiring NVMe guest readiness' {
            $e=New-FixtureEvidence
            ($e.skus[1].capabilities | Where-Object name -EQ 'DiskControllerTypes').value='SCSI'
            $e.guest.nvmeDriver='unknown';$e.guest.nvmeBoot='unknown'
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'ready'
            $p.targetController | Should -Be 'SCSI'
            $p.capacityReservation.status | Should -Be 'not-associated'
            $p.checks.name | Should -Not -Contain 'nvme-boot'
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'observes compatible reserved capacity but keeps associated execution blocked' {
            $e=New-ReservationFixture
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $p.capacityReservation.status | Should -Be 'compatible-observed'
            $p.capacityReservation.availableUnits | Should -Be 2
            $p.classification | Should -Be 'blocked'
            $p.quota.status | Should -Be 'pass'
            $p.capacity.status | Should -Be 'unknown'
            $p.capacityReservation.action | Should -Match 'Retain existing association'
        }
        It 'reports missing target reservation with explicit owner choices, not silent detachment' {
            $e=New-ReservationFixture
            $e.capacityReservationEvidence.reservations[0].sku.name='Standard_D2s_v5'
            $r=Get-CapacityReservationAssessment $e Standard_D2s_v6
            $r.status | Should -Be 'incompatible'
            $r.action | Should -Match 'separately'
            $r.action | Should -Match 'Terraform'
            $e.vm.capacityReservation.capacityReservationGroup.id | Should -Not -BeNullOrEmpty
        }
        It 'refuses incompatible or unknown reservation evidence: <Case>' -ForEach @(
            @{Case='region'},@{Case='zone'},@{Case='state'},@{Case='exhausted'},@{Case='overallocated'},
            @{Case='missing-utilization'},@{Case='stale'},@{Case='denied'},@{Case='duplicate'},@{Case='quantity'},
            @{Case='runtime-state'},@{Case='missing-association-id'},@{Case='malformed-current'},@{Case='wrong-member'},@{Case='regional-zone'}
        ) {
            $e=New-ReservationFixture;$r=$e.capacityReservationEvidence.reservations[0]
            switch($Case) {
                region {$e.capacityReservationEvidence.group.location='eastus'}
                zone {$r.zones=@('2')}
                state {$r.properties.provisioningState='Failed'}
                exhausted {$r.properties.instanceView.utilizationInfo.virtualMachinesAllocated=@(@{id='/vm/a'},@{id='/vm/b'})}
                overallocated {$r.properties.instanceView.utilizationInfo.virtualMachinesAllocated=@(@{id='/vm/a'},@{id='/vm/b'},@{id='/vm/c'})}
                missing-utilization {$r.properties.Remove('instanceView')}
                stale {$e.capacityReservationEvidence.observedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')}
                denied {$e.capacityReservationEvidence.status='denied'}
                duplicate {$e.capacityReservationEvidence.reservations+=@{}+$r}
                quantity {$r.sku.capacity=0}
                runtime-state {$r.properties.instanceView.statuses=@(@{code='ProvisioningState/failed'})}
                missing-association-id {$e.vm.capacityReservation=@{capacityReservationGroup=@{}}}
                malformed-current {$r.properties.instanceView.utilizationInfo.currentCapacity='2'}
                wrong-member {$r.id='/outside/reservation'}
                regional-zone {$e.vm.zones=@()}
            }
            (Get-CapacityReservationAssessment $e Standard_D2s_v6).status | Should -Not -Be 'compatible-observed'
        }
        It 'does not count the current VM twice when already allocated to the target reservation' {
            $e=New-ReservationFixture
            $e.capacityReservationEvidence.reservations[0].properties.instanceView.utilizationInfo.virtualMachinesAllocated=@(@{id=$e.vm.id},@{id='/vm/other'})
            (Get-CapacityReservationAssessment $e Standard_D2s_v6).availableUnits | Should -Be 1
        }
        It 'recognizes an explicitly non-zonal VM/group/member combination without inventing a zone' {
            $e=New-ReservationFixture
            $e.vm.zones=@()
            $e.capacityReservationEvidence.group.zones=@()
            $e.capacityReservationEvidence.reservations[0].zones=@()
            (Get-CapacityReservationAssessment $e Standard_D2s_v6).status | Should -Be 'compatible-observed'
        }
        It 'binds association drift to the configuration fingerprint and rejects forced ready execution' {
            $p=New-FixturePlan;$before=$p.fingerprint
            $p.evidence.vm.capacityReservation=(New-ReservationFixture).vm.capacityReservation
            (Get-ConfigurationFingerprint $p.evidence) | Should -Not -Be $before
            $unsigned=@{}+$p;$unsigned.Remove('hash');$p.hash=Get-UpgradeHash $unsigned
            { Assert-UpgradeApproval $p (New-FixtureApproval $p) } | Should -Throw '*assessment-only*'
        }
        It 'publishes actionable reservation findings without a ready launcher' {
            $e=New-ReservationFixture
            $p=New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $out=Join-Path $TestDrive 'reservation-report'
            Export-VmUpgradeReport $p $out | Out-Null
            Get-Content (Join-Path $out 'guide.md') -Raw | Should -Match 'compatible-observed'
            Get-Content (Join-Path $out 'guide.md') -Raw | Should -Match 'paid even unused'
            Test-Path (Join-Path $out 'upgrade.ps1') | Should -BeFalse
            (Read-UpgradeJson (Join-Path $out 'plan.json')).capacityReservation.groupId | Should -Be $p.capacityReservation.groupId
        }
        It 'refuses Terraform association removal even when size/controller changes are otherwise valid' {
            $e=New-ReservationFixture
            $before=@{id=$e.vm.id;size='Standard_D2s_v5';disk_controller_type='SCSI';capacity_reservation_group_id=$e.vm.capacityReservation.capacityReservationGroup.id}
            $after=@{}+$before;$after.size='Standard_D2s_v6';$after.capacity_reservation_group_id=$null
            $tf=@{format_version='1.2';resource_changes=@(@{address='azurerm_linux_virtual_machine.test';type='azurerm_linux_virtual_machine';change=@{actions=@('update');before=$before;after=$after}})}
            (Test-TerraformUpgradePlan $tf @{vmAddress='azurerm_linux_virtual_machine.test'} $e.vm.id Standard_D2s_v6 SCSI).status | Should -Be 'failed'
        }
    }
    Describe 'Associated reservation discovery preserves raw responses before refusal' {
        BeforeEach {
            $script:e=New-ReservationFixture
            $script:groupId=$script:e.vm.capacityReservation.capacityReservationGroup.id
            $script:deny=$false;$script:badMember=$false
            Mock Invoke-UpgradeAz {
                param($Arguments)
                switch ($Arguments[0]+':'+$Arguments[1]) {
                    'account:show' {@{id=$script:e.subscriptionId;tenantId=$script:e.tenantId;environmentName='AzureCloud'}}
                    'vm:list-skus' {$script:e.skus}
                    'vm:list-usage' {$script:e.usage}
                    default {throw 'Unexpected non-read operation'}
                }
            }
            Mock Invoke-ArmRead {
                param($Id,$ApiVersion)
                if ($Id -eq $script:e.vm.id) {
                    return @{id=$Id;location='westeurope';zones=@('1');properties=@{
                        hardwareProfile=$script:e.vm.hardwareProfile;storageProfile=$script:e.vm.storageProfile
                        networkProfile=$script:e.vm.networkProfile;capacityReservation=$script:e.vm.capacityReservation}}
                }
                if ($Id -eq $script:groupId) {
                    if($script:deny){throw 'AuthorizationFailed 403'}
                    return $script:e.capacityReservationEvidence.group
                }
                if ($Id -like "$script:groupId/capacityReservations/*") {
                    $member=@{}+$script:e.capacityReservationEvidence.reservations[0]
                    if($script:badMember){$member.id='/contradictory/member'}
                    return $member
                }
                if($Id -like '*/extensions'){return @{value=@()}}
                if($Id -like '*/instanceView'){return $script:e.instanceView}
                if($Id -like '*/vmSizes'){return @{value=@(@{name='Standard_D2s_v6'})}}
                if($Id -like '*/disks/*'){return @{id=$Id;properties=@{diskSizeGB=64}}}
                if($Id -like '*/networkInterfaces/*'){return @{id=$Id;properties=@{enableAcceleratedNetworking=$true}}}
                throw 'Unexpected read outside fixture'
            }
        }
        It 'collects exact group/member expanded runtime evidence without any mutation' {
            $out=Join-Path $TestDrive 'observed'
            $e=Get-VmEvidence $script:e.vm.id -ObservationPath $out
            $e.capacityReservationEvidence.status | Should -Be 'collected'
            (Read-UpgradeJson "$out.capacity-reservation.json").reservations.Count | Should -Be 1
            Should -Invoke Invoke-ArmRead -Times 2 -Exactly -ParameterFilter {$ApiVersion -eq '2024-07-01&$expand=instanceView'}
            (Read-UpgradeJson "$out.resize-options.json").value[0].name | Should -Be 'Standard_D2s_v6'
            $e.resizeOptions.status | Should -Be 'collected'
        }
        It 'retains malformed resize-list evidence before rejecting it' {
            Mock Invoke-ArmRead { @{value=@(@{name='Standard_D2s_v6'},@{name='Standard_D2s_v6'})} } -ParameterFilter {$Id -like '*/vmSizes'}
            $out=Join-Path $TestDrive 'bad-resize-options'
            $e=Get-VmEvidence $script:e.vm.id -ObservationPath $out
            (Read-UpgradeJson "$out.resize-options.json").value.Count | Should -Be 2
            $e.resizeOptions.status | Should -Be 'failed'
            $e.checks.name | Should -Contain 'resize-options'
        }
        It 'refuses resize-list access denial without claiming current-cluster availability' {
            Mock Invoke-ArmRead { throw 'AuthorizationFailed 403' } -ParameterFilter {$Id -like '*/vmSizes'}
            $e=Get-VmEvidence $script:e.vm.id
            $e.resizeOptions.status | Should -Be 'denied'
            $e.resizeOptions.sizes.Count | Should -Be 0
        }
        It 'does not continue discovery when resize observation publication fails' {
            Mock Write-UpgradeJson { throw [IO.IOException]::new('Resize observation publication failed') } -ParameterFilter {$Path -like '*.resize-options.json'}
            {Get-VmEvidence $script:e.vm.id -ObservationPath (Join-Path $TestDrive 'unwritable')} | Should -Throw '*publication failed*'
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly -ParameterFilter {$Id -like '*capacityReservationGroups*'}
        }
        It 'retains denied access explicitly rather than assuming unassociated capacity' {
            $script:deny=$true
            $e=Get-VmEvidence $script:e.vm.id
            $e.capacityReservationEvidence.status | Should -Be 'denied'
            $e.checks.name | Should -Contain 'capacity-reservation-evidence'
        }
        It 'retains contradictory raw member before rejecting its identity' {
            $script:badMember=$true;$out=Join-Path $TestDrive 'refused'
            $e=Get-VmEvidence $script:e.vm.id -ObservationPath $out
            $e.capacityReservationEvidence.status | Should -Be 'failed'
            (Read-UpgradeJson "$out.capacity-reservation.json").reservations[0].id | Should -Be '/contradictory/member'
        }
        It 'does not discover or require reservation resources for an unassociated VM' {
            $script:e.vm.Remove('capacityReservation')
            $e=Get-VmEvidence $script:e.vm.id
            $e.capacityReservationEvidence | Should -BeNullOrEmpty
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly -ParameterFilter {$Id -like '*capacityReservationGroups*'}
        }
        It 'refuses out-of-group membership without following its resource ID' {
            $script:e.capacityReservationEvidence.group.properties.capacityReservations=@(@{id='/unapproved/member'})
            $e=Get-VmEvidence $script:e.vm.id
            $e.capacityReservationEvidence.status | Should -Be 'failed'
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly -ParameterFilter {$Id -eq '/unapproved/member'}
        }
    }
}
