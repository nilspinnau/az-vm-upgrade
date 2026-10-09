Import-Module (Join-Path $PSScriptRoot '..\src\AzVmUpgrade.psd1') -Force

InModuleScope AzVmUpgrade {
    BeforeAll {
        . (Join-Path $script:RepositoryRoot 'tests\Fixtures.ps1')
        $script:realOwnerAcceptance = ${function:Assert-OwnerAcceptance}
    }

    Describe 'Evidence and lifecycle contracts' {
        It 'validates complete synthetic evidence and guest schema' {
            $e = New-FixtureEvidence
            Test-UpgradeDocument $e evidence | Should -BeTrue
            Test-UpgradeDocument $e.guest guest | Should -BeTrue
        }
        It 'rejects a missing identity instead of defaulting it' {
            $e = New-FixtureEvidence
            $e.Remove('tenantId')
            { Test-UpgradeDocument $e evidence } | Should -Throw
        }
        It 'retains unknown forward-compatible fields' {
            $e = New-FixtureEvidence
            $e.extraProviderField = 'unknown future metadata'
            Test-UpgradeDocument $e evidence | Should -BeTrue
        }
        It 'hashes maps deterministically without losing array ordering' {
            Get-UpgradeHash @{ b = 2; a = 1 } | Should -Be (Get-UpgradeHash @{ a = 1; b = 2 })
            Get-UpgradeHash @(1,2) | Should -Not -Be (Get-UpgradeHash @(2,1))
            Get-UpgradeHash @() | Should -Not -Be (Get-UpgradeHash $null)
        }
        It 'preserves the exact plan hash across JSON date and numeric roundtrips' {
            $p = New-FixturePlan
            $path = Join-Path $TestDrive 'roundtrip.json'
            Write-UpgradeJson $p $path
            $copy = Read-UpgradeJson $path
            $unsigned = @{} + $copy; $unsigned.Remove('hash')
            Get-UpgradeHash $unsigned | Should -Be $p.hash
        }
        It 'normalizes absent zones and empty data disk collections without phantom devices' {
            $model = @{id=(New-FixtureEvidence).vm.id;location='westeurope';properties=@{
                hardwareProfile=@{vmSize='Standard_D2s_v5'};storageProfile=@{osDisk=@{osType='Linux'}}
                networkProfile=@{networkInterfaces=@()}
            }}
            $bounded = Get-BoundedVmModel $model
            $bounded.zones.Count | Should -Be 0
            $bounded.storageProfile.dataDisks.Count | Should -Be 0
            $bounded.ContainsKey('osProfile') | Should -BeFalse
        }
        It 'matches only the intended anchored lifecycle series' {
            $catalog = Read-UpgradeJson (Join-Path $script:RepositoryRoot 'catalog\lifecycle.json')
            @(Get-LifecycleFinding 'Standard_D2s_v3' $catalog).Count | Should -Be 1
            @(Get-LifecycleFinding 'Standard_DS2_v2' $catalog).Count | Should -Be 1
            @(Get-LifecycleFinding 'Standard_D2s_v6' $catalog).Count | Should -Be 0
            @(Get-LifecycleFinding 'Standard_D2as_v5' $catalog).Count | Should -Be 0
            @(Get-LifecycleFinding 'Standard_B2s_v2' $catalog).Count | Should -Be 0
        }
        It 'marks an old lifecycle catalog as stale' {
            $catalog = @{ reviewedAt = '2000-01-01T00:00:00Z'; entries = @(@{ pattern = '^Standard_D2s_v3$'; series = 'test' }) }
            (Get-LifecycleFinding 'Standard_D2s_v3' $catalog).catalogStale | Should -BeTrue
        }
        It 'rejects stale and future timestamps' {
            { Assert-FreshEvidence '2000-01-01T00:00:00Z' } | Should -Throw
            { Assert-FreshEvidence ([DateTimeOffset]::UtcNow.AddDays(1).ToString('o')) } | Should -Throw
        }
        It 'rejects scale-set and multi-VM IDs' {
            { Get-VmIdentity '/subscriptions/x/resourceGroups/y/providers/Microsoft.Compute/virtualMachineScaleSets/z/virtualMachines/0' } | Should -Throw
        }
    }

    Describe 'Quota and compatibility' {
        It 'subtracts existing source cores only from the same family' {
            $same = Get-QuotaProjection (New-FixtureSku) (New-FixtureSku 'Standard_D4s_v5' 'standardDSv5Family' 4) (New-FixtureUsage)
            $same.status | Should -Be 'pass'
            ($same.checks | Where-Object name -EQ 'cores').projected | Should -Be 12
            ($same.checks | Where-Object name -EQ 'standardDSv5Family').projected | Should -Be 6
            ($same.checks | Where-Object name -EQ 'virtualMachines').delta | Should -Be 0
        }
        It 'calculates cross-family usage and retains deallocated source accounting' {
            $cross = Get-QuotaProjection (New-FixtureSku) (New-FixtureSku 'Standard_D4s_v6' 'standardDSv6Family' 4) (New-FixtureUsage)
            ($cross.checks | Where-Object name -EQ 'standardDSv6Family').projected | Should -Be 6
            ($cross.checks | Where-Object name -EQ 'standardDSv5Family').projected | Should -Be 2
        }
        It 'uses full vCPUs rather than constrained vCPUsAvailable for quota' {
            $sku = New-FixtureSku 'Standard_E8-2s_v5' 'standardDSv5Family' 8
            ($sku.capabilities | Where-Object name -EQ 'vCPUsAvailable').value = '2'
            $usage = New-FixtureUsage
            ($usage | Where-Object { $_.name.value -eq 'standardDSv5Family' }).currentValue = 8
            $q = Get-QuotaProjection $sku (New-FixtureSku 'Standard_D2s_v6' 'standardDSv6Family' 2) $usage
            ($q.checks | Where-Object name -EQ 'cores').delta | Should -Be -6
        }
        It 'fails insufficient quota and preserves missing quota as unknown' {
            $usage = New-FixtureUsage
            ($usage | Where-Object { $_.name.value -eq 'standardDSv6Family' }).limit = 1
            (Get-QuotaProjection (New-FixtureSku) (New-FixtureSku 'Standard_D2s_v6' 'standardDSv6Family') $usage).status | Should -Be 'failed'
            (Get-QuotaProjection (New-FixtureSku) (New-FixtureSku) @()).status | Should -Be 'unknown'
        }
        It 'does not convert missing controller capability into a pass' {
            $e = New-FixtureEvidence
            $sku = $e.skus[1]
            $sku.capabilities = @($sku.capabilities | Where-Object name -NE 'DiskControllerTypes')
            @(Test-TargetCompatibility $e $e.skus[0] $sku NVMe | Where-Object status -EQ 'unknown').Count | Should -BeGreaterThan 0
        }
        It 'blocks a different zone, architecture, temp storage and restricted target' {
            $e = New-FixtureEvidence
            $target = $e.skus[1]
            $target.locationInfo[0].zones = @('2')
            ($target.capabilities | Where-Object name -EQ 'CpuArchitectureType').value = 'Arm64'
            ($target.capabilities | Where-Object name -EQ 'MaxResourceVolumeMB').value = '100'
            $target.restrictions = @(@{ type = 'Location'; values = @('westeurope'); reasonCode = 'NotAvailableForSubscription' })
            $checks = @(Test-TargetCompatibility $e $e.skus[0] $target NVMe)
            @($checks | Where-Object status -EQ 'unsupported').Count | Should -BeGreaterOrEqual 4
        }
        It 'does not treat disk performance downgrade as compatible' {
            $e = New-FixtureEvidence
            ($e.skus[1].capabilities | Where-Object name -EQ 'UncachedDiskIOPS').value = '1'
            @(Test-TargetCompatibility $e $e.skus[0] $e.skus[1] NVMe | Where-Object status -EQ 'unsupported').Count | Should -BeGreaterThan 0
        }
        It 'permits a metadata-compatible regional VM without selecting a zone' {
            $e = New-FixtureEvidence; $e.vm.zones = @()
            @(Test-TargetCompatibility $e $e.skus[0] $e.skus[1] NVMe | Where-Object status -NE 'pass').Count | Should -Be 0
        }
    }

    Describe 'Planning and safe action scripts' {
        It 'creates a ready synthetic lab plan without claiming capacity' {
            $p = New-FixturePlan
            $p.classification | Should -Be 'ready'
            $p.executionBoundary | Should -Be 'disposable-lab-only'
            $p.capacity.status | Should -Be 'unknown'
            Test-UpgradeDocument $p plan | Should -BeTrue
        }
        It 'never automatically selects a ranked target' {
            $p = New-VmUpgradePlan (New-FixtureEvidence) -Controller NVMe -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'needs-preparation'
            $p.targetSize | Should -BeNullOrEmpty
        }
        It 'requires fresh consented guest evidence' {
            $e = New-FixtureEvidence; $e.guest = $null
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'incomplete-evidence'
        }
        It 'distinguishes driver readiness from actual device use' {
            $e = New-FixtureEvidence; $e.guest.manaInUse = 'unknown'; $e.guest.accelerationInUse = 'unknown'
            $p = New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)
            $p.classification | Should -Be 'ready'
            $p.evidence.guest.manaInUse | Should -Be 'unknown'
        }
        It 'rejects evidence tampering' {
            $e = New-FixtureEvidence; $e.vm.hardwareProfile.vmSize = 'changed'
            { New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 } | Should -Throw '*fingerprint*'
        }
        It 'classifies stale evidence as incomplete' {
            $e = New-FixtureEvidence; $e.observedAt = '2000-01-01T00:00:00Z'
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'incomplete-evidence'
        }
        It 'classifies Gen1 NVMe as rebuild and ADE as blocked' {
            $e = New-FixtureEvidence; $e.disks[0].hyperVGeneration = 'V1'
            $e.fingerprint = Get-ConfigurationFingerprint $e
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'requires-rebuild'
            $e = New-FixtureEvidence; $e.disks[0].adeEnabled = $true
            $e.fingerprint = Get-ConfigurationFingerprint $e
            (New-VmUpgradePlan $e -TargetSize Standard_D2s_v6 -Controller NVMe -WorkloadReview (New-FixtureReview)).classification | Should -Be 'blocked'
        }
        It 'generates launchers only for ready plans and removes stale launchers' {
            $p = New-FixturePlan
            $dir = Join-Path $TestDrive 'report'
            Export-VmUpgradeReport $p $dir | Out-Null
            Test-Path (Join-Path $dir 'upgrade.ps1') | Should -BeTrue
            $p.classification = 'blocked'
            Export-VmUpgradeReport $p $dir | Out-Null
            Test-Path (Join-Path $dir 'upgrade.ps1') | Should -BeFalse
            Test-Path (Join-Path $dir 'upgrade.sh') | Should -BeFalse
            Get-Content (Join-Path $dir 'guide.md') -Raw | Should -Match 'No executable upgrade'
        }
    }

    Describe 'Terraform exact mappings and replacement gates' {
        BeforeEach {
            $script:tf = @{
                format_version = '1.2'; resource_changes = @(@{
                    address = 'azurerm_linux_virtual_machine.test[0]'; type = 'azurerm_linux_virtual_machine'
                    change = @{
                        actions = @('update'); replace_paths = @()
                        before = @{ id = (New-FixtureEvidence).vm.id; size = 'Standard_D2s_v5'; disk_controller_type = 'SCSI' }
                        after = @{ id = (New-FixtureEvidence).vm.id; size = 'Standard_D2s_v6'; disk_controller_type = 'NVMe' }
                        after_unknown = @{}
                    }
                })
            }
            $script:mapping = @{ vmAddress = 'azurerm_linux_virtual_machine.test[0]' }
        }
        It 'accepts only exact size/controller in-place changes' {
            (Test-TerraformUpgradePlan $script:tf $script:mapping (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe).status | Should -Be 'pass'
        }
        It 'rejects resource replacement and incorrect VM mapping' {
            $script:tf.resource_changes[0].change.actions = @('delete','create')
            (Test-TerraformUpgradePlan $script:tf $script:mapping (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe).status | Should -Be 'failed'
            $script:tf.resource_changes[0].change.actions = @('update')
            (Test-TerraformUpgradePlan $script:tf @{vmAddress='wrong'} (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe).status | Should -Be 'failed'
        }
        It 'rejects unrelated changes and unknown post-change values' {
            $script:tf.resource_changes[0].change.after.image = 'different'
            (Test-TerraformUpgradePlan $script:tf $script:mapping (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe).status | Should -Be 'failed'
            $script:tf.resource_changes[0].change.after.Remove('image')
            $script:tf.resource_changes[0].change.after_unknown = @{ source_image_reference = @(@{ version = $true }) }
            (Test-TerraformUpgradePlan $script:tf $script:mapping (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe).status | Should -Be 'failed'
        }
        It 'requires a normal no-op reconciliation plan' {
            (Test-TerraformUpgradePlan $script:tf $script:mapping (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe -Reconciliation).status | Should -Be 'failed'
            $script:tf.resource_changes[0].change.actions = @('no-op')
            (Test-TerraformUpgradePlan $script:tf $script:mapping (New-FixtureEvidence).vm.id Standard_D2s_v6 NVMe -Reconciliation).status | Should -Be 'pass'
        }
    }

    Describe 'Inventory coverage and pagination' {
        BeforeEach { $script:pageCalls = 0 }
        It 'paginates until all results are read and deduplicates identical IDs' {
            Mock Invoke-UpgradeAz {
                $script:pageCalls++
                if ($script:pageCalls -eq 1) {
                    @{ data = @(@{id='/vm/a'; subscriptionId='00000000-0000-0000-0000-000000000000';size='Standard_D2s_v3'}); '$skipToken'='next' }
                } else {
                    @{ data = @(@{id='/vm/a'; subscriptionId='00000000-0000-0000-0000-000000000000';size='Standard_D2s_v3'},
                        @{id='/vm/b'; subscriptionId='00000000-0000-0000-0000-000000000000';size='Standard_D2s_v6'}); resultTruncated='false' }
                }
            }
            $inventory = Get-VmInventory -SubscriptionId '00000000-0000-0000-0000-000000000000'
            $inventory.complete | Should -BeTrue
            $inventory.vms.Count | Should -Be 2
            $script:pageCalls | Should -Be 2
        }
        It 'reports denied scope explicitly' {
            Mock Invoke-UpgradeAz { throw '403 Forbidden' }
            $inventory = Get-VmInventory -SubscriptionId '00000000-0000-0000-0000-000000000000'
            $inventory.complete | Should -BeFalse
            $inventory.scopes[0].status | Should -Be 'denied'
        }
        It 'fails coverage when truncation has no token' {
            Mock Invoke-UpgradeAz { @{data=@(); resultTruncated='true'} }
            (Get-VmInventory -SubscriptionId '00000000-0000-0000-0000-000000000000').scopes[0].status | Should -Be 'failed'
        }
        It 'rejects conflicting duplicates and repeated pagination tokens' {
            Mock Invoke-UpgradeAz {
                $script:pageCalls++
                @{data=@(@{id='/vm/a';subscriptionId='00000000-0000-0000-0000-000000000000';size="$script:pageCalls"});'$skipToken'='same'}
            }
            (Get-VmInventory -SubscriptionId '00000000-0000-0000-0000-000000000000').complete | Should -BeFalse
        }
    }

    Describe 'Advisor optional cross-check' {
        BeforeEach {
            $script:advisorVmA = (New-FixtureEvidence).vm.id
            $script:advisorVmB = $script:advisorVmA -replace '/testvm$','/secondvm'
            $script:advisorInventory = @{
                scopes=@(@{subscriptionId='00000000-0000-0000-0000-000000000000';status='complete'})
                vms=@(@{id=$script:advisorVmA;lifecycle=@(@{series='legacy'})},@{id=$script:advisorVmB;lifecycle=@()})
            }
            Mock Get-ScopedGraphRecords {
                @{scopes=@(@{subscriptionId='00000000-0000-0000-0000-000000000000';status='complete'})
                    rows=@(@{id='/recommendation/1';subscriptionId='00000000-0000-0000-0000-000000000000'
                        resourceId=$script:advisorVmB;serviceId='type1';state='unknown'})}
            }
            Mock Get-AdvisorRetirementMetadata {
                @{type1=@{retirementDate='2028-01-01';retirementFeatureName='synthetic feature';source='synthetic metadata'}}
            }
        }
        It 'flags both SKU-only and Advisor-only VMs without authorizing or blocking execution' {
            $result = Get-AdvisorRetirementCrossCheck -SubscriptionId '00000000-0000-0000-0000-000000000000' -Inventory $script:advisorInventory -VmQuery 'Resources | project id'
            $result.coverageGaps.kind | Should -Contain 'sku-only'
            $result.coverageGaps.kind | Should -Contain 'advisor-only'
            $result.skuCoverageVerified | Should -BeFalse
            $result.recommendations[0].retirementDate | Should -Be '2028-01-01'
            $result.recommendations[0].state | Should -Be 'unknown'
        }
        It 'cannot filter unknown data as if its recommendation state were active' {
            { Get-AdvisorRetirementCrossCheck -SubscriptionId '00000000-0000-0000-0000-000000000000' -Inventory $script:advisorInventory -VmQuery 'Resources' -State active } | Should -Throw '*observed*'
        }
        It 'supports an explicit observed state field and rejects query injection' {
            $result = Get-AdvisorRetirementCrossCheck -SubscriptionId '00000000-0000-0000-0000-000000000000' -Inventory $script:advisorInventory -VmQuery 'Resources' -State active -StatePropertyPath 'properties.extendedProperties.observedState'
            $result.stateFilter | Should -Contain 'active'
            { Get-AdvisorRetirementCrossCheck -Inventory $script:advisorInventory -StatePropertyPath 'properties.state | union Resources' } | Should -Throw '*property*'
        }
        It 'keeps a metadata denial separate from a valid recommendation list' {
            Mock Get-AdvisorRetirementMetadata { throw '403 Forbidden' }
            $result = Get-AdvisorRetirementCrossCheck -SubscriptionId '00000000-0000-0000-0000-000000000000' -Inventory $script:advisorInventory -VmQuery 'Resources'
            $result.metadataScopes[0].status | Should -Be 'denied'
            $result.recommendations[0].metadataStatus | Should -Be 'unknown'
            $result.recommendations[0].retirementDate | Should -BeNullOrEmpty
        }
        It 'reports comparison unknown, not an empty Advisor list, for incomplete scopes' {
            Mock Get-ScopedGraphRecords { @{scopes=@(@{subscriptionId='00000000-0000-0000-0000-000000000000';status='denied'});rows=@()} }
            $result = Get-AdvisorRetirementCrossCheck -SubscriptionId '00000000-0000-0000-0000-000000000000' -Inventory $script:advisorInventory -VmQuery 'Resources'
            $result.coverageGaps[0].kind | Should -Be 'unknown'
        }
    }

    Describe 'Application health contract' {
        It 'allows bounded HTTPS health checks and optional body digests' {
            { Assert-ApplicationHealthChecks @(@{uri='https://example.invalid/health';expectedStatus=200;bodySha256=('a'*64)}) } | Should -Not -Throw
        }
        It 'rejects credentials, secret query strings, insecure URLs and excessive endpoints' {
            foreach ($uri in @('http://example.invalid','https://user:password@example.invalid','https://example.invalid?token=x')) {
                { Assert-ApplicationHealthChecks @(@{uri=$uri;expectedStatus=200}) } | Should -Throw
            }
            $tooMany = @(@{uri='https://example.invalid/health';expectedStatus=200}) * 5
            { Assert-ApplicationHealthChecks $tooMany } | Should -Throw
        }
        It 'does not invoke arbitrary customer hooks or infer absent health checks' {
            Mock Invoke-ApplicationHealthCheck { throw 'Must not be called' }
            @(Get-ApplicationHealthEvidence (New-FixtureReview)).Count | Should -Be 0
            Should -Invoke Invoke-ApplicationHealthCheck -Times 0 -Exactly
        }
        It 'surfaces configured application health failure' {
            Mock Invoke-ApplicationHealthCheck { throw 'Application is unhealthy' }
            $review = New-FixtureReview
            $review.healthChecks = @(@{uri='https://example.invalid/health';expectedStatus=200})
            { Get-ApplicationHealthEvidence $review } | Should -Throw '*unhealthy*'
        }
    }

    Describe 'ARM asynchronous-operation contract' {
        BeforeEach {
            $script:ExecutingVmId = (New-FixtureEvidence).vm.id
            $script:MutationTenantId = '00000000-0000-0000-0000-000000000000'
            $script:MutationJournal = $null
            $script:lroCalls = 0
            Mock Invoke-UpgradeAz { @{accessToken='offline-placeholder-only';tenant='00000000-0000-0000-0000-000000000000'} }
            Mock Start-Sleep {}
        }
        AfterEach {
            $script:ExecutingVmId = $null; $script:MutationTenantId = $null
            $script:MutationJournal = $null; $script:MutationJournalPath = $null
        }
        It 'polls the server operation to completion and durably records operation IDs' {
            $script:MutationJournal = @{pendingOperation=@{name='patch'}}
            $script:MutationJournalPath = Join-Path $TestDrive 'lro.json'
            Mock Invoke-ArmHttpRequest {
                param($Uri,$Method,$Body,$Token,$Headers)
                $script:lroCalls++
                if ($Method -eq 'PATCH') {
                    @{statusCode=202;body=@{};headers=@{'Azure-AsyncOperation'='https://management.azure.com/operations/synthetic';'x-ms-request-id'='server-id';'x-ms-correlation-request-id'='correlation-id'}}
                } else { @{statusCode=200;body=@{status='Succeeded'};headers=@{}} }
            }
            Invoke-ArmMutation $script:ExecutingVmId '2024-07-01' PATCH @{properties=@{}} 'client-id' | Out-Null
            $script:lroCalls | Should -Be 2
            (Read-UpgradeJson $script:MutationJournalPath).pendingOperation.serverRequestId | Should -Be 'server-id'
        }
        It 'surfaces failed operations and never retries mutation requests' {
            Mock Invoke-ArmHttpRequest {
                param($Uri,$Method)
                if ($Method -eq 'PATCH') { @{statusCode=202;headers=@{'Azure-AsyncOperation'='https://management.azure.com/operations/synthetic'}} }
                else { @{statusCode=200;headers=@{};body=@{status='Failed'}} }
            }
            { Invoke-ArmMutation $script:ExecutingVmId '2024-07-01' PATCH @{properties=@{}} 'client-id' } | Should -Throw '*Failed*'
            Should -Invoke Invoke-ArmHttpRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }
        It 'rejects accepted operations without polling URLs and bounded timeouts' {
            Mock Invoke-ArmHttpRequest { @{statusCode=202;headers=@{}} }
            { Invoke-ArmMutation $script:ExecutingVmId '2024-07-01' POST @{} 'client-id' } | Should -Throw '*uncertain*'
            Mock Invoke-ArmHttpRequest { @{statusCode=202;headers=@{'Azure-AsyncOperation'='https://management.azure.com/operations/synthetic'}} }
            { Invoke-ArmMutation $script:ExecutingVmId '2024-07-01' POST @{} 'client-id' -TimeoutSeconds 0 } | Should -Throw '*timed out*'
        }
        It 'rejects tenant mismatches and mutations outside the approved subscription' {
            Mock Invoke-UpgradeAz { @{accessToken='offline-placeholder-only';tenant='different'} }
            { Invoke-ArmMutation $script:ExecutingVmId '2024-07-01' PATCH @{} 'client-id' } | Should -Throw '*tenant*'
            { Invoke-ArmMutation '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/other/providers/Microsoft.Compute/virtualMachines/test' '2024-07-01' PATCH @{} 'client-id' } | Should -Throw '*subscription*'
        }
        It 'never sends ARM credentials to redirects or a non-ARM endpoint' {
            { Invoke-ArmHttpRequest -Uri 'https://example.invalid/operations' -Method GET -Token 'offline-placeholder-only' -Headers @{} } | Should -Throw '*credentials*'
            { Invoke-ArmHttpRequest -Uri 'http://management.azure.com/operations' -Method GET -Token 'offline-placeholder-only' -Headers @{} } | Should -Throw '*credentials*'
        }
    }

    Describe 'Post-verification owner acceptance' {
        BeforeEach {
            $script:ownerPlan = New-FixturePlan
            $script:ownerJournal = @{
                expectedFingerprint=$script:ownerPlan.fingerprint
                events=@(@{phase='verified';status='completed';at=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')})
            }
            $script:ownerRecord = @{
                schemaVersion='acceptance/1.0';planHash=$script:ownerPlan.hash;vmId=$script:ownerPlan.vmId
                validationFingerprint=$script:ownerPlan.fingerprint;accepted=$true
                acceptedAt=[DateTimeOffset]::UtcNow.ToString('o');reference='Synthetic owner review'
            }
            $script:ownerPath = Join-Path $TestDrive 'owner.json'
        }
        It 'rejects missing acceptance instead of claiming completion' {
            { Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal '' } | Should -Throw '*not complete*'
        }
        It 'accepts an exact post-verification owner record' {
            Write-UpgradeJson $script:ownerRecord $script:ownerPath
            (Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal $script:ownerPath).accepted | Should -BeTrue
        }
        It 'rejects a different plan, VM or verified fingerprint' {
            foreach ($field in @('planHash','vmId','validationFingerprint')) {
                $record = @{} + $script:ownerRecord
                $record[$field] = if ($field -eq 'vmId') { '/different-vm' } else { '0' * 64 }
                Write-UpgradeJson $record $script:ownerPath
                { Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal $script:ownerPath } | Should -Throw '*does not match*'
            }
        }
        It 'rejects acceptance made before verification and an absent verification event' {
            $script:ownerRecord.acceptedAt = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
            Write-UpgradeJson $script:ownerRecord $script:ownerPath
            { Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal $script:ownerPath } | Should -Throw '*after technical verification*'
            $script:ownerJournal.events = @()
            { Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal $script:ownerPath } | Should -Throw '*after technical verification*'
        }
        It 'rejects an unaccepted or stale owner record' {
            $script:ownerRecord.accepted = $false
            Write-UpgradeJson $script:ownerRecord $script:ownerPath
            { Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal $script:ownerPath } | Should -Throw
            $script:ownerRecord.accepted = $true
            $script:ownerRecord.acceptedAt = '2000-01-01T00:00:00Z'
            Write-UpgradeJson $script:ownerRecord $script:ownerPath
            { Assert-OwnerAcceptance $script:ownerPlan $script:ownerJournal $script:ownerPath } | Should -Throw '*Stale*'
        }
    }

    Describe 'Fail-closed execution and recovery' {
        BeforeEach {
            $script:plan = New-FixturePlan
            $script:approval = New-FixtureApproval $script:plan
            $script:simulation = New-FixtureEvidence
            $script:planPath = Join-Path $TestDrive 'plan.json'
            $script:approvalPath = Join-Path $TestDrive 'approval.json'
            $script:journalDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Write-UpgradeJson $script:plan $script:planPath
            Write-UpgradeJson $script:approval $script:approvalPath
            $script:requireRealOwnerAcceptance = $false
            Mock Assert-OwnerAcceptance {
                param($Plan,$Journal,$Path)
                if ($script:requireRealOwnerAcceptance) { return & $script:realOwnerAcceptance $Plan $Journal $Path }
                return @{accepted=$true;reference='synthetic post-verification owner acceptance'}
            }
            Mock Get-VmEvidence {
                $copy = $script:simulation | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
                $copy.fingerprint = Get-ConfigurationFingerprint $copy
                $copy.observedAt = [DateTimeOffset]::UtcNow.ToString('o')
                $copy.guest.observedAt = $copy.observedAt
                return $copy
            }
            Mock Invoke-UpgradeAz { throw 'Unexpected unmocked Azure CLI operation' }
            Mock Invoke-ArmPowerAction {
                param($VmId,$Action,$RequestId)
                if ($Action -eq 'deallocate') { $script:simulation.instanceView.statuses[1].code = 'PowerState/deallocated' }
                if ($Action -eq 'start') { $script:simulation.instanceView.statuses[1].code = 'PowerState/running' }
            }
            Mock Invoke-MinimalArmPatch {
                param($Id,$ApiVersion,$Body,$RequestId,$ETag)
                if ($Id -match '/disks/') { $script:simulation.disks[0].supportedCapabilities.diskControllerTypes = 'SCSI, NVMe' }
                else {
                    $script:simulation.vm.hardwareProfile.vmSize = $Body.properties.hardwareProfile.vmSize
                    $script:simulation.vm.storageProfile.diskControllerType = $Body.properties.storageProfile.diskControllerType
                    $script:simulation.guest.actualController = $Body.properties.storageProfile.diskControllerType
                    ($script:simulation.usage | Where-Object {$_.name.value -eq 'standardDSv5Family'}).currentValue = 2
                    ($script:simulation.usage | Where-Object {$_.name.value -eq 'standardDSv6Family'}).currentValue = 4
                }
            }
            Mock Invoke-ArmRead {
                param($Id,$ApiVersion)
                if ($Id -match '/disks/') { return @{properties=@{provisioningState='Succeeded';supportedCapabilities=@{diskControllerTypes='SCSI, NVMe'}}} }
                if ($Id -match '/instanceView$') { return @{statuses=$script:simulation.instanceView.statuses} }
                return @{properties=@{provisioningState='Succeeded';hardwareProfile=$script:simulation.vm.hardwareProfile;storageProfile=$script:simulation.vm.storageProfile}}
            }
            Mock Start-Sleep {}
        }
        It 'executes the full NVMe state machine offline and is idempotent after completion' {
            $journal = Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false
            $journal.phase | Should -Be 'reconciled'
            $journal.events.phase | Should -Contain 'protected'
            $journal.events.phase | Should -Contain 'verified'
            $journal.pendingOperation | Should -BeNullOrEmpty
            $again = Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false
            $again.phase | Should -Be 'reconciled'
            Should -Invoke Invoke-MinimalArmPatch -Times 2 -Exactly
        }
        It 'rejects altered plans and approvals without disruptive commands' {
            $script:plan.targetSize = 'Standard_D4s_v6'
            Write-UpgradeJson $script:plan $script:planPath
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -Confirm:$false } | Should -Throw '*hash*'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'stops at verified until actual owner acceptance and resumes without repeating mutations' {
            $script:requireRealOwnerAcceptance = $true
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false } | Should -Throw '*not complete*'
            $journal = Read-UpgradeJson (Get-ChildItem $script:journalDir -Filter *.journal.json).FullName
            $journal.phase | Should -Be 'verified'
            $ownerPath = Join-Path $TestDrive 'post-upgrade-owner.json'
            Write-UpgradeJson @{
                schemaVersion='acceptance/1.0';planHash=$script:plan.hash;vmId=$script:plan.vmId
                validationFingerprint=$journal.expectedFingerprint;accepted=$true
                acceptedAt=[DateTimeOffset]::UtcNow.ToString('o');reference='Synthetic post-upgrade acceptance'
            } $ownerPath
            (Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Resume -OwnerAcceptancePath $ownerPath -Confirm:$false).phase | Should -Be 'reconciled'
            Should -Invoke Invoke-MinimalArmPatch -Times 2 -Exactly
            Should -Invoke Invoke-ArmPowerAction -Times 2 -Exactly
        }
        It 'requires protection, downtime and exact disposable scope' {
            $script:approval.downtime = $false
            { Assert-UpgradeApproval $script:plan $script:approval } | Should -Throw '*downtime*'
            $script:approval.downtime = $true; $script:approval.protection.type = 'snapshot'
            { Assert-UpgradeApproval $script:plan $script:approval } | Should -Throw
            $script:approval.protection.type = 'accepted-recovery-method'; $script:approval.testResourceGroup = 'production'
            { Assert-UpgradeApproval $script:plan $script:approval } | Should -Throw '*resource group*'
        }
        It 'rejects stale plans before cloud writes' {
            $script:approval.expiresAt = '2000-01-01T00:00:00Z'
            { Assert-UpgradeApproval $script:plan $script:approval } | Should -Throw '*expired*'
        }
        It 'rejects changed live configuration before deallocation' {
            $script:simulation.vm.tags.changed = 'true'
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false } | Should -Throw '*changed*'
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
        It 'rejects a concurrent local VM lock' {
            [IO.Directory]::CreateDirectory($script:journalDir) | Out-Null
            $lockFile = Join-Path $script:journalDir "$((Get-UpgradeHash $script:plan.vmId.ToLowerInvariant())).lock"
            $held = [IO.File]::Open($lockFile,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try {
                { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false } | Should -Throw '*lock*'
            } finally { $held.Dispose() }
        }
        It 'retains uncertain allocation failure and refuses blind resume' {
            Mock Invoke-ArmPowerAction { param($VmId,$Action,$RequestId) if ($Action -eq 'start') { throw 'AllocationFailed' }; $script:simulation.instanceView.statuses[1].code='PowerState/deallocated' }
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false } | Should -Throw '*AllocationFailed*'
            $journalFile = (Get-ChildItem $script:journalDir -Filter *.journal.json).FullName
            $journal = Read-UpgradeJson $journalFile
            $journal.phase | Should -Be 'updated'
            $journal.pendingOperation.name | Should -Be 'start'
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Resume -Confirm:$false } | Should -Throw '*uncertain*'
            Get-VmRecoveryGuide $journalFile | Should -Match 'not guaranteed'
        }
        It 'does not replay a completed request if the following read failed' {
            Mock Get-VmEvidence {
                if ($script:simulation.vm.hardwareProfile.vmSize -eq 'Standard_D2s_v6') { throw 'Simulated post-update read failure' }
                $copy = $script:simulation | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
                $copy.fingerprint = Get-ConfigurationFingerprint $copy
                return $copy
            }
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false } | Should -Throw '*read failure*'
            $journal = Read-UpgradeJson (Get-ChildItem $script:journalDir -Filter *.journal.json).FullName
            $journal.pendingOperation.name | Should -Be 'size-controller-update'
        }
        It 'resumes an interrupted completed protection phase and finishes safely' {
            $script:readCalls = 0
            Mock Get-VmEvidence {
                $script:readCalls++
                if ($script:readCalls -eq 3) { throw 'Transient assessment read failed before deallocation' }
                $copy = $script:simulation | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
                $copy.fingerprint = Get-ConfigurationFingerprint $copy
                return $copy
            }
            { Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false } | Should -Throw '*before deallocation*'
            $journal = Read-UpgradeJson (Get-ChildItem $script:journalDir -Filter *.journal.json).FullName
            $journal.phase | Should -Be 'protected'
            $journal.pendingOperation | Should -BeNullOrEmpty
            (Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Resume -Confirm:$false).phase | Should -Be 'reconciled'
        }
        It 'executes a compatible same-controller resize without disk-capability changes' {
            $script:plan = New-VmUpgradePlan (New-FixtureEvidence) -TargetSize Standard_D2s_v6 -Controller SCSI -WorkloadReview (New-FixtureReview)
            $script:approval = New-FixtureApproval $script:plan
            Write-UpgradeJson $script:plan $script:planPath
            Write-UpgradeJson $script:approval $script:approvalPath
            (Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -Confirm:$false).phase | Should -Be 'reconciled'
            Should -Invoke Invoke-MinimalArmPatch -Times 1 -Exactly
        }
        It 'rejects missing MANA use, mismatched data and unproved VF use after start' {
            $live = New-FixtureEvidence
            $live.vm.hardwareProfile.vmSize = $script:plan.targetSize
            $live.vm.storageProfile.diskControllerType = 'NVMe'; $live.guest.actualController = 'NVMe'
            $live.guest.manaInUse = 'unknown'
            { Test-PostUpgradeGuest $script:plan $live } | Should -Throw '*MANA*'
            $live.guest.manaInUse = 'pass'; $live.guest.sentinelHash = 'different'
            { Test-PostUpgradeGuest $script:plan $live } | Should -Throw '*checksum*'
            $live.guest.sentinelHash = $script:plan.evidence.guest.sentinelHash; $live.guest.accelerationInUse = 'unknown'
            { Test-PostUpgradeGuest $script:plan $live } | Should -Throw '*VF*'
        }
        It 'fails operation timeouts and provisioning failures explicitly' {
            Mock Invoke-ArmRead { @{properties=@{provisioningState='Failed'}} }
            { Wait-VmState $script:plan.vmId 'running' -TimeoutSeconds 0 } | Should -Throw '*failed*'
            Mock Invoke-ArmRead { @{properties=@{provisioningState='Updating'};statuses=@()} }
            { Wait-VmState $script:plan.vmId 'running' -TimeoutSeconds 0 } | Should -Throw '*Timed out*'
        }
        It 'never formats disks or auto-restores a VM in the execution engine' {
            $source = Get-Content (Join-Path $script:RepositoryRoot 'src\Execution.ps1') -Raw
            $source | Should -Not -Match 'Format-Volume|Initialize-Disk|mkfs|wipefs|Remove-AzVM|az vm delete'
        }
        It 'WhatIf performs no cloud calls' {
            Invoke-VmUpgrade $script:planPath $script:approvalPath -JournalDirectory $script:journalDir -WhatIf | Out-Null
            Should -Invoke Get-VmEvidence -Times 0 -Exactly
            Should -Invoke Invoke-UpgradeAz -Times 0 -Exactly
        }
    }
}
