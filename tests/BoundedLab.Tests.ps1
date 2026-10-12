Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force
InModuleScope AzVmUpgrade {
    Describe 'Wall-clock external command bounds, offline' {
        BeforeEach {
            $script:oldDeadline = $env:AZVM_LAB_WORK_DEADLINE
            $env:AZVM_LAB_WORK_DEADLINE = $null
            $script:start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
            $script:start.UseShellExecute = $false
            $script:start.RedirectStandardOutput = $true; $script:start.RedirectStandardError = $true
            foreach ($arg in @('-NoProfile','-NonInteractive','-Command')) { $script:start.ArgumentList.Add($arg) }
            $script:output = Join-Path $TestDrive "process-$([guid]::NewGuid().ToString('N')).json"
        }
        AfterEach { $env:AZVM_LAB_WORK_DEADLINE = $script:oldDeadline }
        It 'captures actual success and exit code without a shell launcher' {
            $script:start.ArgumentList.Add("[Console]::Out.WriteLine('synthetic'); exit 0")
            $r = Invoke-UpgradeProcess $script:start -TimeoutSeconds 20 -ObservationPath $script:output
            $r.stdout.Trim() | Should -Be 'synthetic'
            $r.exitCode | Should -Be 0
            (Read-UpgradeJson $script:output).status | Should -Be 'exited'
        }
        It 'terminates an actually stalled child and retains wall-clock failure' {
            $script:start.ArgumentList.Add('Start-Sleep -Seconds 60')
            $timer = [Diagnostics.Stopwatch]::StartNew()
            { Invoke-UpgradeProcess $script:start -TimeoutSeconds 1 -ObservationPath $script:output } | Should -Throw '*wall-clock deadline*'
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 10
            $r = Read-UpgradeJson $script:output
            $r.status | Should -Be 'failed'
            Get-Process -Id $r.pid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
        It 'refuses any child start after the lab reserve' {
            $env:AZVM_LAB_WORK_DEADLINE = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
            $script:start.ArgumentList.Add('throw "must not start"')
            { Invoke-UpgradeProcess $script:start -ObservationPath $script:output } | Should -Throw '*Lab work deadline*'
            Test-Path $script:output | Should -BeFalse
        }
        It 'bounds a stalled command by the lab reserve even with a longer command timeout' {
            $env:AZVM_LAB_WORK_DEADLINE = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o')
            $script:start.ArgumentList.Add('Start-Sleep -Seconds 60')
            { Invoke-UpgradeProcess $script:start -TimeoutSeconds 60 -ObservationPath $script:output } | Should -Throw '*wall-clock deadline*'
            (Read-UpgradeJson $script:output).status | Should -Be 'failed'
        }
    }
    Describe 'Independent lab worker supervision and exact cleanup, mocked cloud' {
        BeforeAll {
            $script:processBody = ${function:Invoke-UpgradeProcess}
            $text = Get-Content (Join-Path $script:RepositoryRoot 'tests\integration\Invoke-BoundedLabCycle.ps1') -Raw
            $body = $text.Substring($text.IndexOf('    param($wrapper,'))
            $body = $body.Substring(0, $body.LastIndexOf('} $wrapper $SubscriptionId'))
            $script:supervisor = [scriptblock]::Create($body)
        }
        BeforeEach {
            $script:sub = '00000000-0000-0000-0000-000000000000'
            $script:rg = 'azvm-upgrade-lab-offline'
            $script:output = Join-Path $TestDrive 'supervisor.json'
            $script:exists = $false
            $script:deleted = $false
            $script:failure = ''
            Mock Invoke-UpgradeProcess {
                param($StartInfo,$TimeoutSeconds,$Deadline,$ObservationPath)
                $script:exists = $true
                if ($script:failure -eq 'real-stall') {
                    return (& $script:processBody -StartInfo $StartInfo -TimeoutSeconds $TimeoutSeconds -Deadline $Deadline -ObservationPath $ObservationPath)
                }
                if ($script:failure -eq 'stall') { throw 'External command wall-clock deadline reached' }
                @{exitCode=if($script:failure -eq 'worker'){1}else{0};stdout='synthetic';stderr=''}
            }
            Mock Invoke-UpgradeAz {
                param($Arguments)
                switch ($Arguments[0]+':'+$Arguments[1]) {
                    'account:show' { @{id=$script:sub} }
                    'group:exists' { $script:exists }
                    'group:show' { @{name=$script:rg;location='swedencentral';tags=@{'az-vm-upgrade-disposable'=if($script:failure -eq 'ownership'){'false'}else{'true'}}} }
                    'group:delete' { $script:deleted=$true; if ($script:failure -ne 'cleanup-timeout') { $script:exists=$false } }
                    'resource:list' { @() }
                    default { throw 'Unmocked cloud operation blocked' }
                }
            }
        }
        It 'initiates owned cleanup after <Failure> and never waits for user input' -ForEach @(
            @{Failure='stall'},@{Failure='worker'}
        ) {
            $script:failure = $Failure
            { & $script:supervisor 'synthetic-wrapper.ps1' $script:sub $script:rg 'swedencentral' ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output } | Should -Throw
            $r = Read-UpgradeJson $script:output
            $r.cleanup | Should -Be 'pass'
            $r.cleanupStartedAt | Should -Not -BeNullOrEmpty
            $script:deleted | Should -BeTrue
            Should -Invoke Invoke-UpgradeAz -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'group' -and $Arguments[1] -eq 'delete' -and '--no-wait' -in $Arguments }
        }
        It 'does not delete a group whose ownership is not proved' {
            $script:failure='ownership'
            { & $script:supervisor 'synthetic-wrapper.ps1' $script:sub $script:rg 'swedencentral' ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output } | Should -Throw '*operator intervention*'
            $script:deleted | Should -BeFalse
            (Read-UpgradeJson $script:output).cleanup | Should -Be 'unverified'
        }
        It 'terminates a real hanging wrapper then initiates mocked owned cleanup at reserve' {
            $script:failure = 'real-stall'
            $sleeper = Join-Path $TestDrive 'synthetic-stall.ps1'
            [IO.File]::WriteAllText($sleeper, 'Start-Sleep -Seconds 60')
            { & $script:supervisor $sleeper $script:sub $script:rg 'swedencentral' ([DateTimeOffset]::UtcNow.AddMinutes(45).AddSeconds(1)) $script:output } | Should -Throw '*wall-clock deadline*'
            (Read-UpgradeJson $script:output).cleanup | Should -Be 'pass'
            $pidValue = (Read-UpgradeJson "$script:output.worker.json").pid
            Get-Process -Id $pidValue -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $script:deleted | Should -BeTrue
        }
        It 'attempts exact cleanup immediately when resumed beyond the cleanup deadline' {
            $script:failure='stall'
            { & $script:supervisor 'synthetic-wrapper.ps1' $script:sub $script:rg 'swedencentral' ([DateTimeOffset]::UtcNow.AddMinutes(-1)) $script:output } | Should -Throw '*wall-clock deadline*'
            $r = Read-UpgradeJson $script:output
            $r.deadlineBreached | Should -BeTrue
            $r.cleanup | Should -Be 'pass'
            $script:deleted | Should -BeTrue
        }
        It 'confirms independent absence after a successful worker' {
            & $script:supervisor 'synthetic-wrapper.ps1' $script:sub $script:rg 'swedencentral' ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output
            (Read-UpgradeJson $script:output).cleanup | Should -Be 'pass'
            $script:deleted | Should -BeTrue
        }
        It 'retains cleanup timeout explicitly without claiming absence or polling forever' {
            $script:failure = 'cleanup-timeout'
            Mock Assert-LabWorkDeadline { throw 'Synthetic cleanup deadline reached' }
            { & $script:supervisor 'synthetic-wrapper.ps1' $script:sub $script:rg 'swedencentral' ([DateTimeOffset]::UtcNow.AddHours(1)) $script:output } | Should -Throw '*operator intervention*'
            $r = Read-UpgradeJson $script:output
            $r.cleanup | Should -Be 'unverified'
            $r.cleanupError | Should -Match 'cleanup deadline'
            $script:deleted | Should -BeTrue
            $script:exists | Should -BeTrue
        }
    }
}
