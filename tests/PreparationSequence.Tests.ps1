Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    Describe 'Preparation harness observation ordering (offline only)' {
        BeforeAll {
            . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
            $text = Get-Content (Join-Path $script:RepositoryRoot 'tests\integration\Invoke-LabPreparationAcceptance.ps1') -Raw
            $script:prepBody = [scriptblock]::Create($text.Substring($text.IndexOf('$result = [ordered]')))
        }
        BeforeEach {
            $script:prepGate = ''
            $script:probeCalls = 0
            $script:probe = New-FixtureEvidence
            $script:probe.guest.bootId = 'new-boot'
            $preparation = @{ vmId = $script:probe.vm.id; hash = 'a' * 64
                preState = @{ sentinelHash = $script:probe.guest.sentinelHash }
                expectedModelHash = Get-PreparationModelHash $script:probe; expectedStorageIdentityHash = $script:probe.guest.storageIdentityHash }
            $context = @{ terraformVmAddress = 'synthetic-vm'; rollbackApproved = $true }
            $OutputPath = Join-Path $TestDrive 'preparation.json'
            $JournalDirectory = Join-Path $TestDrive 'journals'
            $TerraformNoOpEvidencePath = Join-Path $TestDrive 'terraform.json'
            Write-UpgradeJson @{ resource_changes = @(); synthetic = $true } $TerraformNoOpEvidencePath
            Mock Invoke-GuestPreparation { @{ status = 'ok'; changes = @() } }
            Mock Restart-VmForPreparation {}
            Mock Test-PreparationOutcome {
                @{ status = if ($script:prepGate -eq 'outcome') { 'rejected' } else { 'accepted' }
                    checks = @(@{ name = 'synthetic-readiness'; status = 'failed'; detail = 'actual mocked observation' }) }
            }
            Mock Test-TerraformUpgradePlan {
                @{ status = if ($script:prepGate -eq 'terraform') { 'failed' } else { 'pass' }; detail = 'mocked Terraform refusal' }
            }
            Mock Get-VmEvidence {
                $script:probeCalls++
                $e = $script:probe | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
                if ($script:probeCalls -gt 1) { $e.guest.bootId = 'rollback-boot' }
                if ($script:prepGate -eq 'health') { $e.guest.applicationHealth = 'failed' }
                if ($script:prepGate -eq 'rollback' -and $script:probeCalls -gt 1) { $e.guest.sentinelHash = 'changed' }
                return $e
            }
        }
        It 'runs apply/reassessment/no-op/rollback through completed with durable observations' {
            . $script:prepBody
            (Read-UpgradeJson $OutputPath).status | Should -Be 'completed'
            (Read-UpgradeJson "$OutputPath.rollback-reboot.json").guest.bootId | Should -Be 'rollback-boot'
            (Read-UpgradeJson "$OutputPath.outcome.json").status | Should -Be 'accepted'
            Should -Invoke Restart-VmForPreparation -Times 2 -Exactly
        }
        It 'retains actual observations before refusing <Gate>' -ForEach @(
            @{ Gate = 'outcome'; File = 'outcome' },
            @{ Gate = 'health'; File = 'reassessment' },
            @{ Gate = 'terraform'; File = 'reassessment' },
            @{ Gate = 'rollback'; File = 'rollback-reboot' }
        ) {
            $script:prepGate = $Gate
            { . $script:prepBody } | Should -Throw
            (Read-UpgradeJson $OutputPath).status | Should -Be 'failed'
            Test-Path "$OutputPath.$File.json" | Should -BeTrue
            if ($Gate -eq 'rollback') {
                (Read-UpgradeJson "$OutputPath.$File.json").guest.sentinelHash | Should -Be 'changed'
            }
        }
    }
}
