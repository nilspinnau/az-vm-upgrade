function Assert-UpgradeApproval {
    param($Plan, $Approval)
    Test-UpgradeDocument $Plan plan | Out-Null
    Test-UpgradeDocument $Approval approval | Out-Null
    $unsigned = @{} + $Plan
    $unsigned.Remove('hash')
    if ((Get-UpgradeHash $unsigned) -cne $Plan.hash) { throw 'Plan hash mismatch; reassess and reapprove.' }
    if ($Plan.classification -ne 'ready' -or $Plan.executionBoundary -ne 'disposable-lab-only') { throw 'Only ready disposable-lab plans can execute.' }
    if ([DateTimeOffset]::Parse($Plan.expiresAt) -le [DateTimeOffset]::UtcNow -or
        [DateTimeOffset]::Parse($Approval.expiresAt) -le [DateTimeOffset]::UtcNow) { throw 'Plan or approval expired.' }
    foreach ($name in @('vmId','tenantId','subscriptionId','targetSize','targetController')) {
        if ($Approval[$name] -ine $Plan[$name]) { throw "Approval $name mismatch." }
    }
    if ($Approval.planHash -cne $Plan.hash) { throw 'Approval is not bound to the exact plan.' }
    foreach ($consent in @('labOnly','downtime','temporaryDataLoss','guestCommands','exclusiveWindow')) {
        if ($Approval[$consent] -ne $true) { throw "Explicit $consent approval is required." }
    }
    if (-not $Approval.protection.reference -or $Approval.protection.type -notin @('application-consistent-backup','accepted-recovery-method') -or
        $Approval.protection.accepted -ne $true) {
        throw 'Approved application-consistent protection or an explicitly accepted recovery method is required; a bare snapshot is insufficient.'
    }
    Assert-FreshEvidence $Approval.protection.verifiedAt -MaxAgeMinutes 43200
    $identity = Get-VmIdentity $Plan.vmId
    if ($identity.resourceGroup -ine $Approval.testResourceGroup) { throw 'Disposable test resource group approval does not match.' }
    if ((Get-Field $Plan.evidence.vm 'tags.az-vm-upgrade-disposable') -ne 'true') { throw 'VM is not tagged as disposable test infrastructure.' }
}

function Wait-VmState {
    param([string]$VmId, [string]$PowerState, [string]$Size, [string]$Controller, [int]$TimeoutSeconds = 600)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $model = Invoke-ArmRead $VmId '2024-07-01'
        $instance = Invoke-ArmRead "$VmId/instanceView" '2024-07-01'
        $provisioning = $model.properties.provisioningState
        if ($provisioning -eq 'Failed' -or @($instance.statuses | Where-Object code -EQ 'ProvisioningState/failed').Count) {
            throw 'Azure reports failed VM provisioning; inspect journal and recover manually.'
        }
        $powerMatches = @($instance.statuses | Where-Object code -IEQ "PowerState/$PowerState").Count -eq 1
        $configurationMatches = (-not $Size -or $model.properties.hardwareProfile.vmSize -ceq $Size) -and
            (-not $Controller -or $model.properties.storageProfile.diskControllerType -ceq $Controller)
        if ($powerMatches -and $configurationMatches -and $provisioning -eq 'Succeeded') { return $model }
        Start-Sleep -Seconds 5
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Timed out waiting for VM $PowerState and desired configuration; do not assume the operation failed or retry blindly."
}

function Invoke-ArmHttpRequest {
    param([uri]$Uri, [string]$Method, [string]$Body, [string]$Token, [hashtable]$Headers)
    if ($Uri.Scheme -ne 'https' -or $Uri.Host -ne 'management.azure.com' -or
        -not $Uri.IsDefaultPort -or $Uri.UserInfo) { throw 'Refusing to send credentials outside the Azure public-cloud ARM endpoint.' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Uri)
    $response = $null
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
        foreach ($key in $Headers.Keys) { $request.Headers.Add($key,[string]$Headers[$key]) }
        if ($Body) { $request.Content = [Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json') }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $responseHeaders = @{}
        foreach ($header in $response.Headers) { $responseHeaders[$header.Key] = @($header.Value) -join ',' }
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            $detail = $text.Substring(0,[Math]::Min(2000,$text.Length))
            throw "ARM $Method failed with HTTP $([int]$response.StatusCode): $detail"
        }
        @{
            statusCode = [int]$response.StatusCode; headers = $responseHeaders
            body = if ($text.Trim()) { $text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String } else { $null }
        }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-ArmMutation {
    param([string]$Id, [string]$ApiVersion, [ValidateSet('PATCH','POST')][string]$Method,
        [hashtable]$Body, [string]$RequestId, [string]$ETag, [int]$TimeoutSeconds = 900)
    $identity = Get-VmIdentity $script:ExecutingVmId
    if (-not $Id.StartsWith("/subscriptions/$($identity.subscriptionId)/",[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Mutation resource is outside the explicitly approved subscription.'
    }
    $auth = Invoke-UpgradeAz @('account','get-access-token','--subscription',$identity.subscriptionId,'--resource','https://management.azure.com/')
    if (-not $auth.accessToken -or $auth.tenant -ine $script:MutationTenantId) { throw 'ARM credential tenant mismatch.' }
    $headers = @{ 'x-ms-client-request-id' = $RequestId }
    if ($ETag) { $headers['If-Match'] = $ETag }
    $bodyJson = if ($Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '{}' }
    $initial = Invoke-ArmHttpRequest -Uri "https://management.azure.com$Id`?api-version=$ApiVersion" `
        -Method $Method -Body $bodyJson -Token $auth.accessToken -Headers $headers
    if ($script:MutationJournal) {
        $script:MutationJournal.pendingOperation.serverRequestId = $initial.headers['x-ms-request-id']
        $script:MutationJournal.pendingOperation.correlationId = $initial.headers['x-ms-correlation-request-id']
        $script:MutationJournal.pendingOperation.asyncOperationUri = $initial.headers['Azure-AsyncOperation']
        $script:MutationJournal.pendingOperation.locationUri = $initial.headers['Location']
        Write-UpgradeJson $script:MutationJournal $script:MutationJournalPath
    }
    $pollUri = $initial.headers['Azure-AsyncOperation']
    $statusEnvelope = [bool]$pollUri
    if (-not $pollUri) { $pollUri = $initial.headers['Location'] }
    if (-not $pollUri) {
        if ($initial.statusCode -eq 202) { throw 'ARM accepted a mutation without an operation polling URL; outcome uncertain.' }
        return $initial.body
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $retryAfter = 5
    do {
        if ([DateTimeOffset]::UtcNow.AddSeconds($retryAfter) -gt $deadline) { break }
        Start-Sleep -Seconds $retryAfter
        $poll = Invoke-ArmHttpRequest -Uri $pollUri -Method GET -Token $auth.accessToken -Headers @{}
        $state = if ($statusEnvelope) { $poll.body.status } else { $poll.body.properties.provisioningState }
        if ($state -in @('Failed','Canceled','Cancelled')) { throw "Azure asynchronous operation $state. Inspect the recorded operation IDs and accepted recovery method." }
        if ($state -eq 'Succeeded' -or (-not $statusEnvelope -and $poll.statusCode -in @(200,204) -and -not $state)) { return $initial.body }
        if ($state -notin @('InProgress','Running','Accepted','Updating','Creating','Deleting',$null)) { throw "Unknown asynchronous operation state: $state" }
        $seconds = 0
        if ([int]::TryParse([string]$poll.headers['Retry-After'],[ref]$seconds)) { $retryAfter = [Math]::Clamp($seconds,1,30) }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Azure asynchronous operation timed out after $TimeoutSeconds seconds; never replay an uncertain mutation."
}

function Invoke-MinimalArmPatch {
    param([string]$Id, [string]$ApiVersion, [hashtable]$Body, [string]$RequestId, [string]$ETag)
    Invoke-ArmMutation -Id $Id -ApiVersion $ApiVersion -Method PATCH -Body $Body -RequestId $RequestId -ETag $ETag
}

function Invoke-ArmPowerAction {
    param([string]$VmId, [ValidateSet('deallocate','start','restart')][string]$Action, [string]$RequestId)
    Invoke-ArmMutation -Id "$VmId/$Action" -ApiVersion '2024-07-01' -Method POST -RequestId $RequestId | Out-Null
}

function Assert-LiveUpgradeGate {
    param($Plan, $Approval, $Journal, [switch]$Guest)
    Assert-UpgradeApproval $Plan $Approval
    $live = Get-VmEvidence -VmId $Plan.vmId -GuestConsent:$Guest -GuestNetworkProbeConsent:($Guest -and $Plan.workloadReview.guestNetworkProbeConsent -eq $true)
    Assert-UpgradeSecurityPreserved $Plan.evidence $live
    if ($live.tenantId -ine $Approval.tenantId -or $live.subscriptionId -ine $Approval.subscriptionId) { throw 'Azure account context changed.' }
    if ((Get-Field $live.vm 'tags.az-vm-upgrade-disposable') -ne 'true') { throw 'Disposable tag removed; stop.' }
    if ($live.fingerprint -cne $Journal.expectedFingerprint) { throw 'Live resources changed since approval or last completed phase; stop and reassess.' }
    if (@($live.checks | Where-Object status -in @('failed','denied','unsupported')).Count) { throw 'Live resource reads failed or access was denied.' }
    $sourceSize = $live.vm.hardwareProfile.vmSize
    $source = @($live.skus | Where-Object name -CEQ $sourceSize)
    $target = @($live.skus | Where-Object name -CEQ $Plan.targetSize)
    if ($source.Count -ne 1 -or $target.Count -ne 1) { throw 'Fresh source/target SKU metadata is missing or ambiguous.' }
    $compatibility = @(Test-TargetCompatibility $live $source[0] $target[0] $Plan.targetController)
    if (@($compatibility | Where-Object status -NE 'pass').Count) { throw 'Fresh target compatibility or restrictions check did not pass.' }
    $quota = Get-QuotaProjection $source[0] $target[0] $live.usage
    if ($quota.status -ne 'pass') { throw 'Fresh quota check did not pass.' }
    if ($Guest) {
        if (-not $live.guest) { throw 'Fresh guest readiness is unavailable.' }
        $freshPlan = New-VmUpgradePlan -Evidence $live -TargetSize $Plan.targetSize -Controller $Plan.targetController -WorkloadReview $Plan.workloadReview
        if ($freshPlan.classification -ne 'ready') { throw "Fresh guest assessment is $($freshPlan.classification); do not deallocate." }
        if ($live.guest.storageIdentityHash -cne $Plan.evidence.guest.storageIdentityHash -or
            $live.guest.sentinelHash -cne $Plan.evidence.guest.sentinelHash) { throw 'Guest storage or application sentinel changed after approval.' }
        $live.applicationHealthChecks = @(Get-ApplicationHealthEvidence $Plan.workloadReview)
    }
    return $live
}

function Save-UpgradePhase {
    param($Journal, [string]$Path, [string]$Phase, $Evidence)
    if ($Evidence) { Assert-UpgradeSecurityPreserved $Journal.originalEvidence $Evidence }
    $Journal.phase = $Phase
    $Journal.pendingOperation = $null
    $Journal.lastError = $null
    if ($Evidence) {
        $Journal.expectedFingerprint = $Evidence.fingerprint; $Journal.lastEvidence = $Evidence
    }
    $Journal.events += @{ phase = $Phase; status = 'completed'; at = [DateTimeOffset]::UtcNow.ToString('o') }
    Write-UpgradeJson $Journal $Path
}

function Start-UpgradeOperation {
    param($Journal, [string]$Path, [string]$Operation)
    $Journal.pendingOperation = @{ name = $Operation; requestId = [guid]::NewGuid().ToString(); at = [DateTimeOffset]::UtcNow.ToString('o') }
    $Journal.events += @{ phase = $Operation; status = 'intent-recorded'; at = $Journal.pendingOperation.at; requestId = $Journal.pendingOperation.requestId }
    Write-UpgradeJson $Journal $Path
    return $Journal.pendingOperation.requestId
}

function Test-PostUpgradeGuest {
    param($Plan, $Live)
    Assert-UpgradeSecurityPreserved $Plan.evidence $Live
    if ($Live.vm.hardwareProfile.vmSize -cne $Plan.targetSize -or
        $Live.vm.storageProfile.diskControllerType -cne $Plan.targetController) { throw 'Post-upgrade model does not match target.' }
    if (@($Live.instanceView.statuses | Where-Object code -EQ 'PowerState/running').Count -ne 1 -or
        @($Live.instanceView.statuses | Where-Object code -EQ 'ProvisioningState/succeeded').Count -ne 1) {
        throw "VM instance is not healthy and running. Observed status codes: $(@($Live.instanceView.statuses.code) -join ', ')."
    }
    $guest = $Live.guest
    if (-not $guest -or $guest.complete -ne $true -or $guest.agentReady -ne $true -or
        $guest.pendingReboot -ne $false -or $guest.persistentMounts -ne $true) { throw 'Post-upgrade guest/agent health check failed.' }
    if ($Plan.targetController -eq 'NVMe' -and $guest.actualController -ne 'NVMe') { throw 'Guest did not prove NVMe OS-disk use.' }
    if ($Plan.targetController -eq 'SCSI' -and $guest.actualController -ne 'SCSI') { throw 'Guest did not prove SCSI OS-disk use.' }
    if ($guest.storageIdentityHash -cne $Plan.evidence.guest.storageIdentityHash) { throw 'Persistent disk identities/mounts changed.' }
    if ($Plan.evidence.guest.ContainsKey('managedDataMappings')) {
        $before = @($Plan.evidence.guest.managedDataMappings | ForEach-Object { @{ lun = $_.lun; uuids = $_.uuids } })
        $after = @($guest.managedDataMappings | ForEach-Object { @{ lun = $_.lun; uuids = $_.uuids } })
        if ((Get-UpgradeHash $before) -cne (Get-UpgradeHash $after) -or
            @($guest.managedDataMappings | Where-Object controller -NE $Plan.targetController).Count) {
            throw 'Microsoft Azure data LUN mapping, filesystem identities or actual controller changed unexpectedly.'
        }
    }
    if (-not $Plan.evidence.guest.sentinelHash -or $guest.sentinelHash -cne $Plan.evidence.guest.sentinelHash) { throw 'Managed data checksum sentinel is missing or changed.' }
    if ($guest.applicationHealth -ne 'pass') { throw 'Configured lab application health sentinel is not healthy.' }
    if ($Plan.workloadReview.guestNetworkProbeConsent -eq $true -and $guest.azureHttpsConnectivity -ne 'pass') {
        throw 'Approved bounded Azure HTTPS connectivity probe did not pass.'
    }
    if ($guest.manaDriver -ne 'pass' -or $guest.mellanoxDriver -ne 'pass') { throw 'Post-upgrade networking driver capability failed.' }
    if (@($Live.nics | Where-Object acceleratedNetworking -EQ $true).Count -and $guest.accelerationInUse -ne 'pass') {
        throw 'Accelerated Networking is configured but actual VF traffic use is not proved.'
    }
    if ($Plan.workloadReview.requireManaInUse -eq $true -and $guest.manaInUse -ne 'pass') { throw 'Target did not prove MANA traffic use; host placement is not guaranteed.' }
    $Live.applicationHealthChecks = @(Get-ApplicationHealthEvidence $Plan.workloadReview)
}

function Assert-OwnerAcceptance {
    param($Plan, $Journal, [string]$Path)
    if (-not $Path) { throw 'VM technically verified; supply post-verification owner acceptance JSON with -OwnerAcceptancePath and -Resume. This run is not complete.' }
    $acceptance = Read-UpgradeJson $Path
    Test-UpgradeDocument $acceptance acceptance | Out-Null
    if ($acceptance.planHash -cne $Plan.hash -or $acceptance.vmId -ine $Plan.vmId -or
        $acceptance.validationFingerprint -cne $Journal.expectedFingerprint) { throw 'Owner acceptance does not match the exact verified VM/plan/configuration.' }
    Assert-FreshEvidence $acceptance.acceptedAt
    $verified = @($Journal.events | Where-Object { $_.phase -eq 'verified' -and $_.status -eq 'completed' } | Select-Object -Last 1)
    if ($verified.Count -ne 1 -or [DateTimeOffset]::Parse($acceptance.acceptedAt) -lt [DateTimeOffset]::Parse($verified[0].at)) {
        throw 'Owner acceptance must be recorded after technical verification, not before the upgrade.'
    }
    return $acceptance
}

function Invoke-VmUpgrade {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$PlanPath, [Parameter(Mandatory)][string]$ApprovalPath,
        [string]$JournalDirectory = (Join-Path $script:RepositoryRoot 'out\journals'),
        [switch]$Resume, [string]$TerraformReconciliationPath, [string]$OwnerAcceptancePath
    )
    $plan = Read-UpgradeJson $PlanPath
    $approval = Read-UpgradeJson $ApprovalPath
    Assert-UpgradeApproval $plan $approval
    if (-not $PSCmdlet.ShouldProcess($plan.vmId, "Disposable-lab upgrade to $($plan.targetSize)/$($plan.targetController)")) { return }
    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($JournalDirectory)) | Out-Null
    $key = Get-UpgradeHash $plan.vmId.ToLowerInvariant()
    $lockPath = Join-Path $JournalDirectory "$key.lock"
    $journalPath = Join-Path $JournalDirectory "$key.journal.json"
    $lock = $null
    $journal = $null
    try {
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { throw 'Another local run owns this VM lock. Do not run on another host; the exclusive maintenance window is required.' }
        if (Test-Path -LiteralPath $journalPath) {
            $journal = Read-UpgradeJson $journalPath
            Test-UpgradeDocument $journal journal | Out-Null
            if ($journal.planHash -cne $plan.hash) { throw 'Existing journal belongs to a different plan. Preserve it and review recovery before any new run.' }
            if ($journal.phase -eq 'reconciled') { return $journal }
            if (-not $Resume) { throw 'An existing journal requires explicit -Resume.' }
            if ($journal.pendingOperation) { throw "Interrupted $($journal.pendingOperation.name) has uncertain outcome. Inspect Azure and follow recovery guide; it is never replayed automatically." }
        } else {
            if ($Resume) { throw 'No journal exists to resume.' }
            $journal = @{
                schemaVersion = 'journal/1.0'; vmId = $plan.vmId; planHash = $plan.hash; phase = 'assessed'
                expectedFingerprint = $plan.fingerprint; originalEvidence = $plan.evidence
                lastEvidence = $plan.evidence; pendingOperation = $null; lastError = $null; events = @()
                protection = $approval.protection; approvalHash = Get-UpgradeHash $approval
            }
            Save-UpgradePhase $journal $journalPath 'planned' $null
            Save-UpgradePhase $journal $journalPath 'approved' $null
        }
        if ($journal.approvalHash -cne (Get-UpgradeHash $approval)) { throw 'Resume approval differs from the original approval.' }
        $script:ExecutingVmId = $plan.vmId
        $script:MutationTenantId = $plan.tenantId
        $script:MutationJournal = $journal
        $script:MutationJournalPath = $journalPath
        if ($journal.phase -eq 'approved') {
            $live = Assert-LiveUpgradeGate $plan $approval $journal -Guest
            if (-not $live.guest.sentinelHash -or $live.guest.applicationHealth -ne 'pass') { throw 'Lab managed-data and health sentinels must be initialized and assessed first.' }
            Save-UpgradePhase $journal $journalPath 'prepared' $live
        }
        if ($journal.phase -eq 'prepared') {
            $live = Assert-LiveUpgradeGate $plan $approval $journal -Guest
            Save-UpgradePhase $journal $journalPath 'protected' $live
        }
        if ($journal.phase -eq 'protected') {
            $null = Assert-LiveUpgradeGate $plan $approval $journal -Guest
            $requestId = Start-UpgradeOperation $journal $journalPath 'deallocate'
            Invoke-ArmPowerAction $plan.vmId deallocate $requestId
            Wait-VmState $plan.vmId 'deallocated' $plan.sourceSize $plan.sourceController | Out-Null
            $live = Get-VmEvidence $plan.vmId
            Save-UpgradePhase $journal $journalPath 'deallocated' $live
        }
        if ($journal.phase -eq 'deallocated') {
            $live = Assert-LiveUpgradeGate $plan $approval $journal
            if ($plan.sourceController -ne $plan.targetController) {
                $osDisk = @($live.disks | Where-Object id -IEQ $live.vm.storageProfile.osDisk.managedDisk.id)
                $capability = Get-Field $osDisk[0] 'supportedCapabilities.diskControllerTypes'
                if ($capability -notmatch 'NVMe') {
                    $requestId = Start-UpgradeOperation $journal $journalPath 'os-disk-capability'
                    Invoke-MinimalArmPatch $osDisk[0].id '2024-03-02' @{
                        properties = @{ supportedCapabilities = @{ diskControllerTypes = 'SCSI, NVMe' } }
                    } $requestId $osDisk[0].etag | Out-Null
                    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
                    do {
                        $disk = Invoke-ArmRead $osDisk[0].id '2024-03-02'
                        if ($disk.properties.provisioningState -eq 'Failed') { throw 'OS disk capability update failed.' }
                        if ($disk.properties.provisioningState -eq 'Succeeded' -and $disk.properties.supportedCapabilities.diskControllerTypes -match 'NVMe') { break }
                        Start-Sleep -Seconds 5
                    } while ([DateTimeOffset]::UtcNow -lt $deadline)
                    if ($disk.properties.provisioningState -ne 'Succeeded' -or $disk.properties.supportedCapabilities.diskControllerTypes -notmatch 'NVMe') { throw 'OS disk capability update timed out.' }
                    $live = Get-VmEvidence $plan.vmId
                    Save-UpgradePhase $journal $journalPath 'deallocated' $live
                }
            }
            $live = Assert-LiveUpgradeGate $plan $approval $journal
            $requestId = Start-UpgradeOperation $journal $journalPath 'size-controller-update'
            Invoke-MinimalArmPatch $plan.vmId '2024-07-01' @{
                properties = @{
                    hardwareProfile = @{ vmSize = $plan.targetSize }
                    storageProfile = @{ diskControllerType = $plan.targetController }
                }
            } $requestId $live.vm.etag | Out-Null
            Wait-VmState $plan.vmId 'deallocated' $plan.targetSize $plan.targetController | Out-Null
            $live = Get-VmEvidence $plan.vmId
            Save-UpgradePhase $journal $journalPath 'updated' $live
        }
        if ($journal.phase -eq 'updated') {
            $null = Assert-LiveUpgradeGate $plan $approval $journal
            $requestId = Start-UpgradeOperation $journal $journalPath 'start'
            Invoke-ArmPowerAction $plan.vmId start $requestId
            Wait-VmState $plan.vmId 'running' $plan.targetSize $plan.targetController | Out-Null
            $live = Get-VmEvidence $plan.vmId
            Save-UpgradePhase $journal $journalPath 'started' $live
        }
        if ($journal.phase -eq 'started') {
            Assert-UpgradeApproval $plan $approval
            $live = Get-VmEvidence -VmId $plan.vmId -GuestConsent -GuestNetworkProbeConsent:($plan.workloadReview.guestNetworkProbeConsent -eq $true)
            $journal.validationEvidence = $live
            Write-UpgradeJson $journal $journalPath
            if ($live.fingerprint -cne $journal.expectedFingerprint) { throw 'Unexpected configuration drift before validation.' }
            Test-PostUpgradeGuest $plan $live
            Save-UpgradePhase $journal $journalPath 'verified' $live
        }
        if ($journal.phase -eq 'verified') {
            $journal.ownerAcceptance = Assert-OwnerAcceptance $plan $journal $OwnerAcceptancePath
            if ($plan.terraform.managed) {
                if (-not $TerraformReconciliationPath) { throw 'Guest verified; provide a clean normal Terraform plan JSON to reconcile with -Resume. Do not apply an obsolete plan.' }
                $tfPlan = Read-UpgradeJson $TerraformReconciliationPath
                $result = Test-TerraformUpgradePlan -Plan $tfPlan -Mapping $plan.terraform.check.mapping -VmId $plan.vmId `
                    -TargetSize $plan.targetSize -Controller $plan.targetController -Reconciliation `
                    -ExpectedEncryptionAtHost (Get-Field $plan.evidence.vm 'securityProfile.encryptionAtHost')
                if ($result.status -ne 'pass') { throw $result.detail }
                $journal.terraformPlanHash = Get-UpgradeHash $tfPlan
            }
            $live = Get-VmEvidence -VmId $plan.vmId -GuestConsent -GuestNetworkProbeConsent:($plan.workloadReview.guestNetworkProbeConsent -eq $true)
            if ($live.fingerprint -cne $journal.expectedFingerprint) { throw 'Unexpected drift during reconciliation.' }
            Test-PostUpgradeGuest $plan $live
            Save-UpgradePhase $journal $journalPath 'reconciled' $live
        }
        return $journal
    } catch {
        if ($journal -and $lock) {
            $journal.lastError = @{ at = [DateTimeOffset]::UtcNow.ToString('o'); detail = $_.Exception.Message }
            Write-UpgradeJson $journal $journalPath
        }
        throw
    } finally {
        $script:ExecutingVmId = $null
        $script:MutationTenantId = $null
        $script:MutationJournal = $null
        $script:MutationJournalPath = $null
        if ($lock) { $lock.Dispose() }
    }
}

function Get-VmRecoveryGuide {
    param([Parameter(Mandatory)][string]$JournalPath)
    $journal = Read-UpgradeJson $JournalPath
    Test-UpgradeDocument $journal journal | Out-Null
    $original = $journal.originalEvidence.vm
    @"
# Recovery for $($journal.vmId)

Last completed phase: **$($journal.phase)**
Pending operation: **$($journal.pendingOperation.name)**
Last error: $($journal.lastError.detail)

1. Preserve this journal and the approval; inspect ARM model, instance view and Azure Activity Log using the recorded request IDs.
2. Do not replay an uncertain operation or clear a pending journal entry to force progress.
3. For a completed phase, -Resume reruns live identity, expiry, drift, restrictions and quota gates. Expired plans require operator-reviewed recovery, not an automatic reapproval.
4. If the guest cannot boot, review serial console/boot diagnostics. A separate, explicitly approved maintenance plan may restore controller $($original.storageProfile.diskControllerType) and size $($original.hardwareProfile.vmSize). Recheck original-family quota and capacity first.
5. Original-SKU allocation is not guaranteed. A rollback can fail; never delete the VM, detach disks, format storage or perform an automatic destructive restore.
6. Protection reference: $($journal.protection.reference). Restore using the accepted recovery procedure and application-owner approval.
7. Restore any recorded guest preparation settings only after confirming the restored controller is compatible. Reconcile Terraform desired HCL and use supported refresh/import workflows; never edit state JSON.
8. Preserve the original security profile, including encryptionAtHost=$((Get-Field $original 'securityProfile.encryptionAtHost')). Snapshots protect disk contents, not VM host-encryption configuration: a restored VM must explicitly retain encryption at host, use a supported SKU and have the Registered subscription feature. Never disable encryption to regain capacity. DES/CMK, ADE and confidential security are separate unsupported recovery paths.

This guide is instructions, not authorization or a runnable restore script.
"@
}

function Assert-UpgradeSecurityPreserved {
    param([Parameter(Mandatory)]$Original, [Parameter(Mandatory)]$Live)
    if ((Get-UpgradeHash (Get-Field $Original.vm 'securityProfile')) -cne
        (Get-UpgradeHash (Get-Field $Live.vm 'securityProfile'))) {
        throw 'VM security profile changed, including encryption at host; stop rather than accept or disable encryption.'
    }
    foreach ($disk in $Original.disks) {
        $current = @($Live.disks | Where-Object id -IEQ $disk.id)
        if ($current.Count -ne 1) { throw 'Disk security evidence is missing or ambiguous.' }
        foreach ($field in @('encryption','adeEnabled','adeSettingsPresent','securityProfile')) {
            if ((Get-UpgradeHash (Get-Field $disk $field)) -cne (Get-UpgradeHash (Get-Field $current[0] $field))) {
                throw "Disk $field changed; stop and review encryption/recovery."
            }
        }
    }
}
