Describe 'Disposable restoration harness authorization' {
    It 'refuses live execution without separate consent before reading any files' {
        $scriptPath = Join-Path $PSScriptRoot 'integration\Invoke-LabRestoreAcceptance.ps1'
        { & $scriptPath -PlanPath missing -TestContextPath missing -LiveTestConsent:$false } | Should -Throw '*exact disposable-resource approval*'
    }

    Describe 'Restored guest evidence rather than serialized security defaults' {
        BeforeAll {
            $path = Join-Path $PSScriptRoot 'integration\Invoke-LabRestoreAcceptance.ps1'
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LabRestoredEvidence'
            }, $true)
            . ([scriptblock]::Create($function.Extent.Text))
        }
        BeforeEach {
            $plan = @{ evidence = @{ guest = @{ storageIdentityHash = 'mounts'; sentinelHash = 'checksum' } } }
            $restored = @{ vm = @{ securityProfile = @{ encryptionAtHost = $true } }
                guest = @{ complete = $true; actualController = 'SCSI'; agentReady = $true
                    storageIdentityHash = 'mounts'; sentinelHash = 'checksum'; applicationHealth = 'pass'; azureHttpsConnectivity = 'pass' } }
        }
        It 'accepts the observed implicit Standard profile without inventing Trusted Launch' {
            { Assert-LabRestoredEvidence $plan $restored } | Should -Not -Throw
            $restored.vm.securityProfile.securityType = 'Standard'
            { Assert-LabRestoredEvidence $plan $restored } | Should -Not -Throw
        }
        It 'rejects changed security or lost encryption' -ForEach @(
            @{ Field = 'encryptionAtHost'; Value = $false },
            @{ Field = 'securityType'; Value = 'TrustedLaunch' },
            @{ Field = 'uefiSettings'; Value = @{ secureBootEnabled = $true; vTpmEnabled = $true } }
        ) {
            $restored.vm.securityProfile[$Field] = $Value
            { Assert-LabRestoredEvidence $plan $restored } | Should -Throw '*verification failed*'
        }
        It 'rejects missing or changed restored guest proof' -ForEach @(
            @{ Field = 'complete'; Value = $false },
            @{ Field = 'agentReady'; Value = $false },
            @{ Field = 'actualController'; Value = 'NVMe' },
            @{ Field = 'storageIdentityHash'; Value = 'changed' },
            @{ Field = 'sentinelHash'; Value = 'changed' },
            @{ Field = 'applicationHealth'; Value = 'failed' },
            @{ Field = 'azureHttpsConnectivity'; Value = 'failed' }
        ) {
            $restored.guest[$Field] = $Value
            { Assert-LabRestoredEvidence $plan $restored } | Should -Throw '*verification failed*'
        }
    }
    It 'requires the exact creation, deallocation, cleanup and restart flags' {
        $scriptPath = Join-Path $PSScriptRoot 'integration\Invoke-LabRestoreAcceptance.ps1'
        $source = Get-Content $scriptPath -Raw
        foreach ($flag in @('deallocateApproved', 'recoveryCreateApproved', 'cleanupApproved', 'restartApproved')) {
            $source | Should -Match $flag
        }
        $source | Should -Match 'Restore context must bind'
        $source | Should -Match 'never overwrite'
        $source | Should -Match 'Cleanup ownership marker mismatch'
        $source | Should -Not -Match 'force-deletion|-Ignore[A-Za-z]+'
    }
    It 'preserves Standard security through the documented API without feature registration' {
        $source = Get-Content (Join-Path $PSScriptRoot 'integration\Invoke-LabRestoreAcceptance.ps1') -Raw
        $source | Should -Match "api-version=2025-11-01"
        $source | Should -Match "securityType = 'Standard'; encryptionAtHost = \`$true"
        $source | Should -Match 'documented explicit Standard-security recovery API is unavailable'
        $source | Should -Not -Match "'feature', 'register'|'vm', 'create'"
        $source | Should -Match "'vm', 'delete'"
        $source | Should -Match "'disk', 'delete'"
    }
}
