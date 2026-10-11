Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    Describe 'Exact same-interface recovery sequence (offline only)' {
        BeforeAll {
            . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
            $source = Get-Content (Join-Path $script:RepositoryRoot 'tests\integration\Invoke-LabRestoreAcceptance.ps1') -Raw
            $body = $source.Substring($source.IndexOf('    param($plan, $context, $outputPath, $journalDirectory)'))
            $body = $body.Substring(0, $body.LastIndexOf('} $plan $context $OutputPath $JournalDirectory'))
            $script:restoreBody = [scriptblock]::Create($body)
        }
        BeforeEach {
            $script:restoreEvidence = New-FixtureEvidence
            $script:restoreEvidence.vm.zones = @()
            $script:restoreEvidence.vm.securityProfile = @{ encryptionAtHost = $true }
            $script:restoreEvidence.guest.azureHttpsConnectivity = 'pass'
            $script:restoreEvidence.vm.hardwareProfile.vmSize = 'Standard_D4as_v5'
            $script:restoreEvidence.skus = @(
                (New-FixtureSku 'Standard_D2as_v5' 'standardDASv5Family' 2),
                (New-FixtureSku 'Standard_D4as_v5' 'standardDASv5Family' 4))
            $script:restoreEvidence.usage = @(
                @{ name = @{ value = 'cores' }; currentValue = 4; limit = 100 },
                @{ name = @{ value = 'standardDASv5Family' }; currentValue = 4; limit = 100 })
            $script:restorePlan = @{ vmId = $script:restoreEvidence.vm.id; hash = 'f' * 64
                sourceSize = 'Standard_D2as_v5'; targetSize = 'Standard_D4as_v5'; targetController = 'SCSI'
                evidence = $script:restoreEvidence }
            $prefix = $script:restorePlan.vmId -replace '/providers/.*$', '/providers'
            $script:restoreContext = @{ testResourceGroup = 'azvm-upgrade-lab-offline'
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
                vmName = 'recovery-vm'; nicName = 'recovery-nic'; osDiskName = 'restored-os'; dataDiskName = 'restored-data'
                osSnapshotId = "$prefix/Microsoft.Compute/snapshots/os"
                dataSnapshotId = "$prefix/Microsoft.Compute/snapshots/data" }
            $script:recoveryTargets = @(
                "$prefix/Microsoft.Compute/virtualMachines/recovery-vm",
                "$prefix/Microsoft.Network/networkInterfaces/recovery-nic",
                "$prefix/Microsoft.Compute/disks/restored-os",
                "$prefix/Microsoft.Compute/disks/restored-data")
            $script:resources = @{}
            $script:gate = ''
            $script:reads = 0
            $script:originalStarts = 0
            $script:trace = [Collections.Generic.List[string]]::new()
            $script:output = Join-Path $TestDrive 'restore.json'
            $script:journalDir = Join-Path $TestDrive 'journals'
            [IO.Directory]::CreateDirectory($script:journalDir) | Out-Null
            $key = Get-UpgradeHash $script:restorePlan.vmId.ToLowerInvariant()
            Write-UpgradeJson @{ planHash = $script:restorePlan.hash; phase = 'verified'; pendingOperation = $null } (Join-Path $script:journalDir "$key.journal.json")
            Mock Start-Sleep {}
            Mock Test-PostUpgradeGuest {
                param($Plan, $Live)
                if ($Live.guest.applicationHealth -ne 'pass') { throw 'observed unhealthy original' }
            }
            Mock Get-VmEvidence {
                param($VmId)
                $script:reads++
                $e = $script:restoreEvidence | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
                if ($VmId -eq $script:recoveryTargets[0]) {
                    if ($script:gate -eq 'restored-guest') { $e.guest.sentinelHash = 'changed' }
                } elseif ($script:gate -eq 'original-health' -and $script:reads -eq 1) {
                    $e.guest.applicationHealth = 'failed'
                } elseif ($script:gate -eq 'original-restart' -and $script:reads -gt 1) {
                    $e.guest.applicationHealth = 'failed'
                }
                return $e
            }
            Mock Wait-VmState { param($VmId, $PowerState) $script:trace.Add("wait:$PowerState") }
            Mock Invoke-ArmRead {
                param($Id)
                if ($Id -match '/snapshots/') {
                    $disk = if ($Id -eq $script:restoreContext.osSnapshotId) {
                        $script:restoreEvidence.vm.storageProfile.osDisk.managedDisk.id
                    } else { $script:restoreEvidence.vm.storageProfile.dataDisks[0].managedDisk.id }
                    if ($script:gate -eq 'snapshot') { $disk = 'wrong-source' }
                    return @{ properties = @{ provisioningState = 'Succeeded'; creationData = @{ sourceResourceId = $disk }
                        encryption = @{ type = 'EncryptionAtRestWithPlatformKey' } } }
                }
                return @{ properties = @{ ipConfigurations = @(@{ properties = @{
                    subnet = @{ id = 'synthetic-subnet' }; publicIPAddress = if ($script:gate -eq 'nic') { @{ id = 'unapproved' } } else { $null }
                } }); networkSecurityGroup = @{ id = 'synthetic-nsg' } } }
            }
            Mock Invoke-UpgradeAz {
                param($Arguments)
                $verb = ($Arguments[0..1] -join ':')
                $script:trace.Add($verb)
                if ($verb -eq 'resource:list') { return @($script:resources.Values) }
                if ($verb -eq 'provider:show') {
                    return @{ resourceTypes = @(@{ resourceType = 'virtualMachines'; apiVersions = if ($script:gate -eq 'provider') { @('old') } else { @('2025-11-01') } }) }
                }
                $marker = (Get-UpgradeHash $script:restoreContext).Substring(0,16)
                if ($verb -eq 'disk:create') {
                    $name = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
                    $id = @($script:recoveryTargets | Where-Object { $_ -match "/disks/$name$" })[0]
                    $script:resources[$id] = @{ id = $id; tags = @{ 'az-vm-upgrade-restore-run' = $marker } }
                    return @{ id = $id; status = 'observed-created' }
                }
                if ($verb -eq 'network:nic' -and $Arguments[2] -eq 'create') {
                    $id = $script:recoveryTargets[1]
                    $script:resources[$id] = @{ id = $id; tags = @{ 'az-vm-upgrade-restore-run' = $marker } }
                    return @{ id = $id }
                }
                if ($verb -eq 'rest:--method') {
                    $id = $script:recoveryTargets[0]
                    $script:resources[$id] = @{ id = $id; tags = @{ 'az-vm-upgrade-restore-run' = if ($script:gate -eq 'cleanup-ownership') { 'wrong-owner' } else { $marker } } }
                    return @{ id = $id; properties = @{ provisioningState = 'Succeeded' } }
                }
                if ($verb -eq 'vm:start') { $script:originalStarts++; return }
                if ($verb -in @('vm:delete','disk:delete') -or ($verb -eq 'network:nic' -and $Arguments[2] -eq 'delete')) {
                    $id = $Arguments[[array]::IndexOf($Arguments, '--ids') + 1]
                    $script:resources.Remove($id)
                }
            }
        }
        It 'runs the actual same-interface recovery body through sequential cleanup and original restart' {
            & $script:restoreBody $script:restorePlan $script:restoreContext $script:output $script:journalDir
            $r = Read-UpgradeJson $script:output
            $r.status | Should -Be 'restoration-verified'
            $r.steps.name | Should -Contain 'recovery-cleanup-and-original-reverified'
            $script:resources.Count | Should -Be 0
            $script:originalStarts | Should -Be 1
            $script:trace.IndexOf('vm:deallocate') | Should -BeLessThan $script:trace.IndexOf('disk:create')
            $script:trace.IndexOf('vm:delete') | Should -BeLessThan $script:trace.IndexOf('vm:start')
            @(Get-ChildItem $TestDrive -Filter 'restore.json.*.json').Count | Should -BeGreaterThan 10
        }
        It 'retains the failed observation and preserves sequential cleanup at <Gate>' -ForEach @(
            @{ Gate = 'original-health'; Observation = 'original' },
            @{ Gate = 'provider'; Observation = 'compute-provider' },
            @{ Gate = 'snapshot'; Observation = 'snapshot' },
            @{ Gate = 'nic'; Observation = 'source-nic' },
            @{ Gate = 'restored-guest'; Observation = 'evidence' },
            @{ Gate = 'original-restart'; Observation = 'original-restart' }
        ) {
            $script:gate = $Gate
            { & $script:restoreBody $script:restorePlan $script:restoreContext $script:output $script:journalDir } | Should -Throw
            (Read-UpgradeJson $script:output).status | Should -Be 'failed'
            @(Get-ChildItem $TestDrive -Filter "restore.json.*$Observation*.json").Count | Should -BeGreaterThan 0
            $script:resources.Count | Should -Be 0
            if ($Gate -in @('restored-guest','original-restart')) { $script:originalStarts | Should -Be 1 }
            else { $script:originalStarts | Should -Be 0 }
        }
        It 'retains cleanup ownership rejection without deleting a mismarked target or starting the original' {
            $script:gate = 'cleanup-ownership'
            { & $script:restoreBody $script:restorePlan $script:restoreContext $script:output $script:journalDir } |
                Should -Throw '*ownership marker mismatch*'
            (Read-UpgradeJson $script:output).cleanupError | Should -Match 'ownership marker mismatch'
            $script:originalStarts | Should -Be 0
            $script:resources.Count | Should -Be 4
            $files = @(Get-ChildItem $TestDrive -Filter 'restore.json.*.cleanup-ownership.json')
            $files.Count | Should -BeGreaterThan 0
            (Read-UpgradeJson $files[0].FullName).response[0].tags.'az-vm-upgrade-restore-run' | Should -Be 'wrong-owner'
        }
    }
}
