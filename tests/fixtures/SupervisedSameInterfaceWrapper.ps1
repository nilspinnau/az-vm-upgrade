param([Parameter(Mandatory)][string]$WrapperPath)
BeforeAll {
    & (Get-Module AzVmUpgrade) {
        param($Path)
        $script:currentWrapperPath = $Path
        $text = Get-Content $Path -Raw
        $script:wrapperSub = [regex]::Match($text, "(?m)^\`$sub='([^']+)'").Groups[1].Value
        $script:wrapperGroup = [regex]::Match($text, "(?m)^\`$rg='([^']+)'").Groups[1].Value
        if (-not $script:wrapperSub -or -not $script:wrapperGroup) { throw 'Unsupported wrapper scope declaration' }
    } $WrapperPath
}
InModuleScope AzVmUpgrade {
    Describe 'Current wrapper in an actual separately supervised worker, mocked cloud' {
        BeforeAll {
            $script:realProcess = ${function:Invoke-UpgradeProcess}
            $text = Get-Content (Join-Path $script:RepositoryRoot 'tests\integration\Invoke-BoundedLabCycle.ps1') -Raw
            $body = $text.Substring($text.IndexOf('    param($wrapper,'))
            $script:supervisedBody = [scriptblock]::Create($body.Substring(0, $body.LastIndexOf('} $wrapper $SubscriptionId')))
        }
        BeforeEach {
            $script:scopeFile = Join-Path $TestDrive "scope-$([guid]::NewGuid().ToString('N')).json"
            $script:supervisedOutput = "$script:scopeFile.supervisor.json"
            Write-UpgradeJson @{exists=$false} $script:scopeFile
            $script:parentDeleted = $false
            Mock Invoke-UpgradeAz {
                param($Arguments)
                switch ($Arguments[0]+':'+$Arguments[1]) {
                    'account:show' { @{id=$script:wrapperSub} }
                    'group:exists' { (Read-UpgradeJson $script:scopeFile).exists }
                    'group:show' { @{name=$script:wrapperGroup;location='swedencentral';tags=@{'az-vm-upgrade-disposable'='true'}} }
                    'group:delete' {
                        $script:cleanupObservedStage = (Read-UpgradeJson $script:scopeFile).stage
                        $script:parentDeleted = $true
                        if ($script:supervisedScenario -ne 'cleanup') { Write-UpgradeJson @{exists=$false} $script:scopeFile }
                    }
                    'resource:list' { @() }
                    default { throw 'Unmocked parent cloud operation blocked' }
                }
            }
            Mock Assert-LabWorkDeadline {
                if ($script:supervisedScenario -eq 'cleanup' -and $script:parentDeleted) { throw 'Synthetic parent cleanup poll deadline reached' }
            }
            Mock Invoke-UpgradeProcess {
                param($StartInfo,$TimeoutSeconds,$Deadline,$ObservationPath,$Operation)
                $fixture = Join-Path $script:RepositoryRoot 'tests\fixtures\SameInterfaceWrapper.ps1'
                $qFixture = $fixture.Replace("'", "''")
                $qWrapper = $script:currentWrapperPath.Replace("'", "''")
                $qScope = $script:scopeFile.Replace("'", "''")
                $code = @"
Import-Module Pester -MinimumVersion 5.5
`$c=New-PesterConfiguration
`$c.Run.Container=New-PesterContainer -Path '$qFixture' -Data @{WrapperPath='$qWrapper';Scenario='$script:supervisedScenario';SharedScopePath='$qScope'}
`$c.Run.PassThru=`$true
`$c.Filter.Tag='WorkerChild'
`$c.Output.Verbosity='Detailed'
`$r=Invoke-Pester -Configuration `$c
if(`$r.PassedCount -ne 1 -or `$r.FailedCount -or `$r.FailedContainersCount){exit 1}
"@
                $child = [Diagnostics.ProcessStartInfo]::new($StartInfo.FileName)
                $child.UseShellExecute=$false
                $child.RedirectStandardOutput=$true; $child.RedirectStandardError=$true
                $child.WorkingDirectory=$script:RepositoryRoot
                foreach ($name in @('AZVM_LAB_WORK_DEADLINE','AZVM_LAB_COMMAND_JOURNAL_DIRECTORY')) { $child.Environment[$name]=$StartInfo.Environment[$name] }
                foreach ($arg in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))) { $child.ArgumentList.Add($arg) }
                & $script:realProcess -StartInfo $child -TimeoutSeconds $TimeoutSeconds -Deadline $Deadline -ObservationPath $ObservationPath -Operation $Operation
            }
        }
        It 'runs current explicit wrapper through supervised <Case> without live boundaries' -ForEach @(
            @{Case='success'}, @{Case='contradiction'}, @{Case='stall'},
            @{Case='reserve'}, @{Case='cleanup'}, @{Case='journal'}
        ) {
            $script:supervisedScenario = $Case
            $deadline = [DateTimeOffset]::UtcNow.AddMinutes(45).AddSeconds($(if($Case -eq 'stall'){10}else{30}))
            if ($Case -eq 'success') {
                & $script:supervisedBody $script:currentWrapperPath $script:wrapperSub $script:wrapperGroup 'swedencentral' $deadline $script:supervisedOutput
            } elseif ($Case -eq 'cleanup') {
                { & $script:supervisedBody $script:currentWrapperPath $script:wrapperSub $script:wrapperGroup 'swedencentral' $deadline $script:supervisedOutput } | Should -Throw '*operator intervention*'
            } else {
                { & $script:supervisedBody $script:currentWrapperPath $script:wrapperSub $script:wrapperGroup 'swedencentral' $deadline $script:supervisedOutput } | Should -Throw
            }
            $supervised = Read-UpgradeJson $script:supervisedOutput
            $supervised.cleanup | Should -Be $(if($Case -eq 'cleanup'){'unverified'}else{'pass'})
            $worker = Read-UpgradeJson "$script:supervisedOutput.worker.json"
            Get-Process -Id $worker.pid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            if ($Case -eq 'stall') {
                $worker.error | Should -Match 'wall-clock deadline'
                $script:parentDeleted | Should -BeTrue
                $script:cleanupObservedStage | Should -Be 'evidence-collection'
                $supervised.status | Should -Be 'failed'
                Should -Invoke Invoke-UpgradeAz -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'group' -and $Arguments[1] -eq 'delete' -and '--no-wait' -in $Arguments }
            } else {
                $cycle = Read-UpgradeJson "$script:scopeFile.cycle.json"
                if ($Case -eq 'success') {
                    $cycle.status | Should -Be 'completed'
                    $cycle.steps.name | Should -Contain 'final-normal-terraform-noop'
                } elseif ($Case -eq 'cleanup') {
                    $cycle.status | Should -Be 'completed'
                    $cycle.cleanupError | Should -Match 'Synthetic cleanup timeout'
                    $cycle.cleanup | Should -Not -Be 'pass'
                    $supervised.status | Should -Be 'failed'
                } else {
                    $cycle.status | Should -Be 'failed'
                    if ($Case -ne 'cleanup') { $cycle.steps.name | Should -Not -Contain 'preparation-reboot-reassessment-rollback-reboot' }
                }
                if ($Case -eq 'contradiction') {
                    $j = Read-UpgradeJson "$script:scopeFile.initialization.json"
                    $j.status | Should -Be 'failed'
                    $j.observations.initialization.value[0].message | Should -Match 'synthetic-wrong-disk'
                }
                if ($Case -eq 'reserve') { $cycle.error | Should -Match 'Lab work deadline' }
                if ($Case -eq 'journal') { $cycle.error | Should -Match 'durable evidence publication failed' }
                if ($Case -in @('reserve','journal')) {
                    $stages = Read-UpgradeJson "$script:scopeFile.stages.json"
                    $stages.baselineExists | Should -BeFalse
                    $stages.preparationExists | Should -BeFalse
                    (Read-UpgradeJson "$script:scopeFile.initialization.json").status | Should -Be 'initialized'
                }
            }
        }
    }
}
