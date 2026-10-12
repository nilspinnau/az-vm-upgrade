Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
InModuleScope AzVmUpgrade {
    Describe 'Bounded read-only cost query throttling' {
        BeforeEach {
            $script:previousDeadline=$env:AZVM_LAB_WORK_DEADLINE
            $env:AZVM_LAB_WORK_DEADLINE=$null
            $script:costCalls=0
            Mock Get-Random {0}
            Mock Wait-LabCostRetry {}
            Mock Invoke-UpgradeAz {
                $script:costCalls++
                @{properties=@{rows=@(@(1,'USD'));columns=@(@{name='PreTaxCost'},@{name='Currency'})}}
            }
        }
        AfterEach {$env:AZVM_LAB_WORK_DEADLINE=$script:previousDeadline}
        It 'issues only the fixed subscription-scoped ActualCost query' {
            Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000' | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-UpgradeAz -Exactly 1 -ParameterFilter {
                $TimeoutSeconds -le 90 -and $Arguments[0] -eq 'rest' -and
                $Arguments[4] -eq 'post' -and $Arguments[6] -match '/Microsoft.CostManagement/query\?api-version=2025-03-01$' -and
                ($Arguments[8] | ConvertFrom-Json).type -eq 'ActualCost'
            }
            Should -Invoke Wait-LabCostRetry -Exactly 0
        }
        It 'retries recognized 429 reads with bounded exponential waits, never a mutation' {
            Mock Invoke-UpgradeAz {
                $script:costCalls++
                if($script:costCalls -lt 3){throw 'Azure CLI failed (1): ERROR: (429) Too many requests'}
                @{properties=@{rows=@(@(1,'USD'))}}
            }
            Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000' -WarningAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Should -Invoke Wait-LabCostRetry -Exactly 1 -ParameterFilter {$Seconds -eq 60}
            Should -Invoke Wait-LabCostRetry -Exactly 1 -ParameterFilter {$Seconds -eq 120}
            Should -Invoke Invoke-UpgradeAz -Exactly 3
        }
        It 'honors an exposed longer retry-after value' {
            Mock Invoke-UpgradeAz {
                $script:costCalls++
                if($script:costCalls -eq 1){throw "Azure CLI failed (1): ERROR: (TooManyRequests) Throttled`nRetry-After: 150"}
                @{properties=@{rows=@(@(1,'USD'))}}
            }
            Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000' -WarningAction SilentlyContinue | Out-Null
            Should -Invoke Wait-LabCostRetry -Exactly 1 -ParameterFilter {$Seconds -eq 150}
        }
        It 'recognizes the retained sanitized CLI JSON throttle response' {
            Mock Invoke-UpgradeAz {
                $script:costCalls++
                if($script:costCalls -eq 1){throw 'Azure CLI failed (1): ERROR: Too Many Requests({"error":{"code":"429","message":"Too many requests. Please retry."}})'}
                @{properties=@{rows=@(@(1,'USD'))}}
            }
            Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000' -WarningAction SilentlyContinue | Out-Null
            Should -Invoke Invoke-UpgradeAz -Exactly 2
            Should -Invoke Wait-LabCostRetry -Exactly 1
        }
        It 'refuses retry-after beyond the finite budget' {
            Mock Invoke-UpgradeAz {throw "Azure CLI failed (1): ERROR: (429) Throttled`nRetry-After: 3600"}
            {Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000'} | Should -Throw '*bounded deadline*'
            Should -Invoke Invoke-UpgradeAz -Exactly 1
            Should -Invoke Wait-LabCostRetry -Exactly 0
        }
        It 'does not retry other errors or ambiguous messages: <ErrorText>' -ForEach @(
            @{ErrorText='Azure CLI failed (1): ERROR: (403) Forbidden'},
            @{ErrorText='Transport timeout'},
            @{ErrorText='Malformed body mentions 429'},
            @{ErrorText='Atomic evidence publication failed'},
            @{ErrorText='Azure CLI failed (1): ERROR: Too Many Requests({"error":{"code":"403"}})'},
            @{ErrorText='Azure CLI failed (1): ERROR: Too Many Requests({broken})'}
        ) {
            Mock Invoke-UpgradeAz {throw $ErrorText}
            {Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000'} | Should -Throw
            Should -Invoke Invoke-UpgradeAz -Exactly 1
            Should -Invoke Wait-LabCostRetry -Exactly 0
        }
        It 'propagates exhaustion after three attempts without a stale result' {
            Mock Invoke-UpgradeAz {throw 'Azure CLI failed (1): ERROR: (429) Throttled'}
            {Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000' -WarningAction SilentlyContinue} | Should -Throw '*429*'
            Should -Invoke Invoke-UpgradeAz -Exactly 3
            Should -Invoke Wait-LabCostRetry -Exactly 2
        }
        It 'refuses a wait that crosses the cleanup reserve' {
            $env:AZVM_LAB_WORK_DEADLINE=[DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o')
            Mock Invoke-UpgradeAz {throw 'Azure CLI failed (1): ERROR: (429) Throttled'}
            {Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000'} | Should -Throw '*bounded deadline*'
            Should -Invoke Invoke-UpgradeAz -Exactly 1
            Should -Invoke Wait-LabCostRetry -Exactly 0
        }
        It 'checks reserve before starting any query' {
            $env:AZVM_LAB_WORK_DEADLINE=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
            {Get-LabMonthToDateCost '00000000-0000-0000-0000-000000000000'} | Should -Throw
            Should -Invoke Invoke-UpgradeAz -Exactly 0
        }
    }
    Describe 'Cost retry real wait deadline checks' {
        It 'rechecks deadline during the real wait' {
            $previousDeadline=$env:AZVM_LAB_WORK_DEADLINE
            $env:AZVM_LAB_WORK_DEADLINE=$null
            Mock Start-Sleep {$env:AZVM_LAB_WORK_DEADLINE=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')}
            try {
                {Wait-LabCostRetry -Seconds 60} | Should -Throw
                Should -Invoke Start-Sleep -Exactly 1
            } finally {$env:AZVM_LAB_WORK_DEADLINE=$previousDeadline}
        }
    }
}
