BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
}
Describe 'Run Command action output contracts' {
    InModuleScope AzVmUpgrade {
        BeforeAll { . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1') }
        It 'reads the live combined provisioning response' {
            $r = @{ value = @(@{ code = 'ProvisioningState/succeeded'; message = "Enable succeeded: `n[stdout]`nstructured-output`n`n[stderr]`n" }) }
            (Get-RunCommandStdout $r).Trim() | Should -Be 'structured-output'
        }
        It 'retains the separate stdout response' {
            Get-RunCommandStdout @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; message = 'output' }) } | Should -Be 'output'
        }
        It 'rejects failed provisioning even with output markers' {
            { Get-RunCommandStdout @{ value = @(@{ code = 'ProvisioningState/failed'; message = "[stdout]`noutput`n[stderr]`n" }) } } | Should -Throw
        }
        It 'rejects combined output without a complete stream boundary' {
            { Get-RunCommandStdout @{ value = @(@{ code = 'ProvisioningState/succeeded'; message = "[stdout]`noutput" }) } } | Should -Throw '*truncated*'
        }
        It 'rejects ambiguous combined responses' {
            $r = @{ value = @(@{ code = 'ProvisioningState/succeeded' }, @{ code = 'ProvisioningState/succeeded' }) }
            { Get-RunCommandStdout $r } | Should -Throw '*unique*'
        }
        It 'only injects Azure HTTPS traffic consent when explicitly requested' -ForEach @(@{ Consent = $false }, @{ Consent = $true }) {
            $fixture = New-FixtureEvidence
            $script:guestOutput = "AZVM_EVIDENCE_BEGIN`n$($fixture.guest | ConvertTo-Json -Depth 10 -Compress)`nAZVM_EVIDENCE_END"
            Mock Invoke-UpgradeAz {
                param($Arguments)
                $script:probePath = $Arguments[-1].Substring(1)
                $script:probeBody = Get-Content $script:probePath -Raw
                @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; message = $script:guestOutput }) }
            }
            Invoke-VmGuestProbe -VmId $fixture.vm.id -OsType Linux -NetworkProbeConsent:$Consent | Out-Null
            ($script:probeBody -match "export AZVM_NETWORK_PROBE_CONSENT='approved-azure-https-probe'") | Should -Be $Consent
            if ($Consent) { Test-Path $script:probePath | Should -BeFalse }
        }
        It 'rejects network testing without guest-command consent' {
            $fixture = New-FixtureEvidence
            { Get-VmEvidence -VmId $fixture.vm.id -GuestNetworkProbeConsent } | Should -Throw '*guest-command consent*'
        }
    }
}
