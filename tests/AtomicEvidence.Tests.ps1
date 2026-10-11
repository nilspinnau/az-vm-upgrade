Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    Describe 'Atomic evidence publication' {
        It 'creates and replaces complete UTF-8 JSON without leftover files' {
            $path = Join-Path $TestDrive 'evidence.json'
            Write-UpgradeJson @{ phase = 'old' } $path
            Write-UpgradeJson @{ phase = 'new'; values = @(1, 2) } $path
            (Read-UpgradeJson $path).phase | Should -Be 'new'
            @(Get-ChildItem $TestDrive -Filter 'evidence.json.*.tmp').Count | Should -Be 0
        }
        It 'allows atomic replacement while a delete-sharing reader holds the old snapshot' {
            $path = Join-Path $TestDrive 'shared.json'
            Write-UpgradeJson @{ phase = 'old' } $path
            $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                Write-UpgradeJson @{ phase = 'new' } $path
                (Read-UpgradeJson $path).phase | Should -Be 'new'
            } finally { $reader.Dispose() }
        }
        It 'retries a transient Windows reader lock without replaying a write or losing old evidence' -Skip:(-not $IsWindows) {
            $path = Join-Path $TestDrive 'transient.json'
            Write-UpgradeJson @{ phase = 'old' } $path
            $script:lockedEvidenceReader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            Mock Start-Sleep {
                (Read-UpgradeJson $path).phase | Should -Be 'old'
                $script:lockedEvidenceReader.Dispose()
            }
            try {
                Write-UpgradeJson @{ phase = 'new' } $path -WarningVariable warnings -WarningAction SilentlyContinue
                (Read-UpgradeJson $path).phase | Should -Be 'new'
                @($warnings).Count | Should -Be 1
                Should -Invoke Start-Sleep -Exactly 1
                @(Get-ChildItem $TestDrive -Filter 'transient.json.*.tmp').Count | Should -Be 0
            } finally { $script:lockedEvidenceReader.Dispose() }
        }
        It 'bounds persistent lock retries, preserves old and unpublished evidence, and throws' -Skip:(-not $IsWindows) {
            $path = Join-Path $TestDrive 'locked.json'
            Write-UpgradeJson @{ phase = 'verified' } $path
            $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            Mock Start-Sleep {}
            try {
                { Write-UpgradeJson @{ phase = 'reconciled' } $path -WarningAction SilentlyContinue } |
                    Should -Throw '*unpublished evidence remains*'
                Should -Invoke Start-Sleep -Exactly 4
                (Read-UpgradeJson $path).phase | Should -Be 'verified'
                $pending = @(Get-ChildItem $TestDrive -Filter 'locked.json.*.tmp')
                $pending.Count | Should -Be 1
                (Read-UpgradeJson $pending[0].FullName).phase | Should -Be 'reconciled'
            } finally { $reader.Dispose() }
        }
        It 'does not retry a read-only destination or silently replace it' -Skip:(-not $IsWindows) {
            $path = Join-Path $TestDrive 'readonly.json'
            Write-UpgradeJson @{ phase = 'old' } $path
            [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly)
            Mock Start-Sleep {}
            try {
                { Write-UpgradeJson @{ phase = 'new' } $path } | Should -Throw '*Atomic evidence publication failed*'
                (Read-UpgradeJson $path).phase | Should -Be 'old'
                Should -Invoke Start-Sleep -Exactly 0
            } finally { [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal) }
        }
        It 'does not promote a journal in memory or on disk when publication fails' {
            $path = Join-Path $TestDrive 'journal.json'
            $journal = @{ phase = 'started'; pendingOperation = @{ name = 'start' }; lastError = 'retained'; events = @() }
            Write-UpgradeJson $journal $path
            Mock Write-UpgradeJson { throw [IO.IOException]::new('injected atomic publication failure') }
            { Save-UpgradePhase $journal $path 'verified' } | Should -Throw '*publication failure*'
            $journal.phase | Should -Be 'started'
            $journal.pendingOperation.name | Should -Be 'start'
            $journal.lastError | Should -Be 'retained'
            $journal.events.Count | Should -Be 0
            (Read-UpgradeJson $path).phase | Should -Be 'started'
        }
        It 'does not admit a new operation intent when its journal publication fails' {
            $journal = @{ phase = 'assessed'; pendingOperation = $null; events = @() }
            Mock Write-UpgradeJson { throw [IO.IOException]::new('injected atomic publication failure') }
            { Start-UpgradeOperation $journal (Join-Path $TestDrive 'intent.json') 'deallocate' } |
                Should -Throw '*publication failure*'
            $journal.pendingOperation | Should -BeNullOrEmpty
            $journal.events.Count | Should -Be 0
            $journal.phase | Should -Be 'assessed'
        }
    }
}
