Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    BeforeAll {
        . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
        function Read-TerminalSample {
            param([int]$Attempt=1)
            $prefix = [IO.Path]::GetFileName($script:terminalPath)
            $file = Get-ChildItem $TestDrive -Filter "$prefix.*.sample-$('{0:D2}' -f $Attempt).json" | Select-Object -First 1
            Read-UpgradeJson $file.FullName
        }
    }
    Describe 'Bounded read-only post-guest reconciliation' {
        BeforeEach {
            $script:terminalPlan = New-FixturePlan
            $script:terminalLive = New-FixtureEvidence
            $script:terminalLive.vm.hardwareProfile.vmSize = $script:terminalPlan.targetSize
            $script:terminalLive.vm.storageProfile.diskControllerType = $script:terminalPlan.targetController
            $script:terminalLive.fingerprint = Get-ConfigurationFingerprint $script:terminalLive
            $script:terminalPath = Join-Path $TestDrive "terminal-$([guid]::NewGuid().ToString('N'))"
            $script:oldReserve = $env:AZVM_LAB_WORK_DEADLINE
            $env:AZVM_LAB_WORK_DEADLINE = $null
            Mock Invoke-ArmRead {
                param($Id,$Deadline)
                if ($Id -like '*/instanceView') { return $script:terminalLive.instanceView }
                New-FixtureArmModel $script:terminalLive.vm
            }
            Mock Start-Sleep {}
            Mock Invoke-VmGuestProbe { throw 'Guest replay forbidden' }
            Mock Invoke-MinimalArmPatch { throw 'Mutation forbidden' }
            Mock Invoke-ArmPowerAction { throw 'Power action forbidden' }
        }
        AfterEach { $env:AZVM_LAB_WORK_DEADLINE=$script:oldReserve }
        It 'preserves original evidence and guest observation, replacing statuses only with fresh real samples' {
            $script:terminalLive.instanceView.statuses[0].code='ProvisioningState/updating'
            $script:instanceCalls=0
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -like '*/instanceView') {
                    $script:instanceCalls++
                    return @{statuses=@(@{code=$(if($script:instanceCalls -eq 1){'ProvisioningState/updating'}else{'ProvisioningState/succeeded'})},@{code='PowerState/running'})}
                }
                New-FixtureArmModel $script:terminalLive.vm
            }
            $result=Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath
            $script:terminalLive.instanceView.statuses[0].code | Should -Be 'ProvisioningState/updating'
            $result.instanceView.statuses[0].code | Should -Be 'ProvisioningState/succeeded'
            $result.guest | Should -Be $script:terminalLive.guest
            (Read-TerminalSample 1).instanceView.statuses[0].code | Should -Be 'ProvisioningState/updating'
            (Read-TerminalSample 2).instanceView.statuses[0].code | Should -Be 'ProvisioningState/succeeded'
            Should -Invoke Invoke-VmGuestProbe -Times 0 -Exactly
            Should -Invoke Invoke-MinimalArmPatch -Times 0 -Exactly
            Should -Invoke Invoke-ArmPowerAction -Times 0 -Exactly
        }
        It 'rejects initial unknown or failed provisioning without even fresh reads: <Code>' -ForEach @(
            @{Code='ProvisioningState/unknown'},@{Code='ProvisioningState/failed'}
        ) {
            $script:terminalLive.instanceView.statuses[0].code=$Code
            {Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath} | Should -Throw '*initial reconciliation status*'
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly
        }
        It 'rejects a failed or unknown model immediately even with succeeded instance: <State>' -ForEach @(
            @{State='Failed'},@{State='Unknown'},@{State='Creating'},@{State='succeeded'}
        ) {
            $script:modelState=$State
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -like '*/instanceView') { return $script:terminalLive.instanceView }
                New-FixtureArmModel $script:terminalLive.vm $script:modelState
            }
            {Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath} | Should -Throw '*unknown reconciliation provisioning*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
            (Read-TerminalSample).model.properties.provisioningState | Should -Be $State
        }
        It 'refuses ambiguous model provisioning rather than treating an array as a successful scalar' {
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -like '*/instanceView') { return $script:terminalLive.instanceView }
                $raw=New-FixtureArmModel $script:terminalLive.vm
                $raw.properties.provisioningState=@('Succeeded','Succeeded')
                return $raw
            }
            {Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath} | Should -Throw '*ambiguous model provisioning*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
        It 'requires model terminal success as well as instance success and only polls explicit model Updating' {
            $script:modelReads=0
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -like '*/instanceView') { return $script:terminalLive.instanceView }
                $script:modelReads++
                New-FixtureArmModel $script:terminalLive.vm $(if($script:modelReads -eq 1){'Updating'}else{'Succeeded'})
            }
            $result=Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath
            $result.reconciliationStatusObservation.model.properties.provisioningState | Should -Be 'Succeeded'
            $script:modelReads | Should -Be 2
        }
        It 'does not overwrite earlier raw collections when invoked again with the same observation prefix' {
            Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath | Out-Null
            $first=@(Get-ChildItem $TestDrive -Filter "*.sample-*.json")
            $bytes=[IO.File]::ReadAllBytes($first[0].FullName)
            Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath | Out-Null
            @(Get-ChildItem $TestDrive -Filter "*.sample-*.json").Count | Should -Be ($first.Count+1)
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($first[0].FullName)) | Should -Be ([Convert]::ToBase64String($bytes))
        }
        It 'caps both requests at the same absolute reserve cutoff rather than 900 seconds per read' {
            $script:cutoff=[DateTimeOffset]::UtcNow.AddSeconds(10)
            $env:AZVM_LAB_WORK_DEADLINE=$script:cutoff.ToString('o')
            Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath | Out-Null
            Should -Invoke Invoke-ArmRead -Times 2 -Exactly -ParameterFilter {$Deadline -eq $script:cutoff}
        }
        It 'refuses before reads when reserve has expired' {
            $env:AZVM_LAB_WORK_DEADLINE=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
            {Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath} | Should -Throw '*deadline*'
            Should -Invoke Invoke-ArmRead -Times 0 -Exactly
        }
        It 'retains a late model response but refuses a second read or promotion after the finite wallclock expires' {
            Mock Invoke-ArmRead {
                [Threading.Thread]::Sleep(1100)
                New-FixtureArmModel $script:terminalLive.vm
            }
            {Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath -TimeoutSeconds 1} | Should -Throw '*beyond its deadline*'
            Should -Invoke Invoke-ArmRead -Times 1 -Exactly
            (Read-TerminalSample).model.id | Should -Be $script:terminalPlan.vmId
        }
        It 'retains successful first read on denied second read and refuses without polling' {
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -like '*/instanceView') { throw 'ARM denied' }
                New-FixtureArmModel $script:terminalLive.vm
            }
            {Get-ReconciliationTerminalEvidence $script:terminalPlan $script:terminalLive $script:terminalLive.fingerprint -ObservationPath $script:terminalPath} | Should -Throw '*ARM denied*'
            (Read-TerminalSample).model.id | Should -Be $script:terminalPlan.vmId
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }
    Describe 'Read deadline transport' {
        It 'forwards the explicit absolute deadline from ARM GET through CLI to bounded child process' {
            $script:requestDeadline=[DateTimeOffset]::UtcNow.AddSeconds(2)
            Mock Get-Command { @{Source='synthetic-az.exe'} } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-UpgradeProcess { @{exitCode=0;stdout='{"properties":{"provisioningState":"Succeeded"}}';stderr=''} }
            Invoke-ArmRead '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/lab/providers/Microsoft.Compute/virtualMachines/vm' '2024-07-01' -Deadline $script:requestDeadline | Out-Null
            Should -Invoke Invoke-UpgradeProcess -Times 1 -Exactly -ParameterFilter { $Deadline -eq $script:requestDeadline -and $Operation -eq 'rest GET' }
        }
    }
}
