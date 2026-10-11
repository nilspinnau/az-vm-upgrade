Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    Describe 'External observations before assertions' {
        BeforeEach {
            $script:MutationJournal = $null
            $script:MutationJournalPath = $null
        }
        It 'retains an invalid guest Run Command response before marker rejection' {
            $path = Join-Path $TestDrive 'probe'
            Mock Invoke-UpgradeAz { @{ value = @(@{ code = 'ProvisioningState/succeeded'
                message = "Enable succeeded: `n[stdout]`ninvalid guest output`n[stderr]`nactual guest traceback" }) } }
            { Invoke-VmGuestProbe '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/lab/providers/Microsoft.Compute/virtualMachines/vm' Linux -ObservationPath $path } |
                Should -Throw '*missing, truncated, or invalid*'
            (Read-UpgradeJson "$path.run-command.json").value[0].message | Should -Match 'actual guest traceback'
        }
        It 'retains failing ARM model and instance statuses before polling rejects' {
            $path = Join-Path $TestDrive 'poll.json'
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -match 'instanceView') { return @{ statuses = @(@{ code = 'ProvisioningState/failed' }) } }
                @{ properties = @{ provisioningState = 'Failed'; hardwareProfile = @{ vmSize = 'observed-size' } } }
            }
            { Wait-VmState 'synthetic-id' running -ObservationPath $path } | Should -Throw '*failed VM provisioning*'
            (Read-UpgradeJson $path).model.properties.hardwareProfile.vmSize | Should -Be 'observed-size'
            (Read-UpgradeJson $path).instanceView.statuses[0].code | Should -Be 'ProvisioningState/failed'
        }
        It 'does not poll or continue when durable publication fails' {
            Mock Invoke-ArmRead { @{ properties = @{ provisioningState = 'Failed' }; statuses = @() } }
            Mock Write-UpgradeJson { throw [IO.IOException]::new('injected observation write failure') }
            Mock Start-Sleep {}
            { Wait-VmState 'synthetic-id' running -ObservationPath (Join-Path $TestDrive 'fail.json') } |
                Should -Throw '*observation write failure*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
        It 'retains malformed preparation output with an uncertain pending action' {
            . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
            $e = New-FixtureEvidence
            $p = New-FixturePlan
            $prep = New-GuestPreparationPlan -Plan $p -Component nvme-boot -GuestChangeConsent
            $script:prepEvidence = $e
            Mock Get-VmEvidence { $script:prepEvidence }
            Mock Invoke-UpgradeAz { @{ value = @(@{ code = 'ProvisioningState/succeeded'
                message = "Enable succeeded: `n[stdout]`ntruncated manifest`n[stderr]`nactual preparation error" }) } }
            $dir = Join-Path $TestDrive 'prep-journals'
            { Invoke-GuestPreparation $prep apply -GuestConsent -JournalDirectory $dir -Confirm:$false } |
                Should -Throw '*missing or truncated*'
            $j = Get-ChildItem $dir -Filter '*.journal.json'
            (Read-UpgradeJson $j.FullName).pendingAction | Should -Be 'apply'
            (Read-UpgradeJson "$($j.FullName).apply.run-command.json").value[0].message | Should -Match 'actual preparation error'
            (Read-UpgradeJson $j.FullName).status | Should -Be 'in-progress'
        }
    }
}
