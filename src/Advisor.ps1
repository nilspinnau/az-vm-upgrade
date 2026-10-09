function Get-AdvisorRetirementMetadata {
    param([string]$SubscriptionId)
    $filter = [uri]::EscapeDataString("recommendationSubCategory eq 'ServiceUpgradeAndRetirement'")
    $url = '/providers/Microsoft.Advisor/metadata?api-version=2025-01-01&$filter=' + $filter + '&$expand=ibiza'
    $types = @{}
    $visited = @{}
    do {
        if ($visited.ContainsKey($url)) { throw 'Repeated Advisor metadata continuation URL.' }
        $visited[$url] = $true
        $page = Invoke-UpgradeAz @('rest','--method','get','--subscription',$SubscriptionId,'--url',$url)
        if ($null -eq $page.value) { throw 'Advisor metadata response has no value envelope.' }
        foreach ($metadata in $page.value) {
            foreach ($item in @($metadata.properties.supportedValues)) {
                if (-not $item.id) { continue }
                $retirement = Get-Field $item 'sourceProperties.serviceRetirement'
                if (-not $retirement) { continue }
                $type = @{
                    serviceId = $item.id; retirementDate = $retirement.retirementDate
                    retirementFeatureName = $retirement.retirementFeatureName
                    source = 'Advisor metadata API 2025-01-01, sourceProperties.serviceRetirement'
                }
                if ($types.ContainsKey($item.id) -and (Get-UpgradeHash $types[$item.id]) -ne (Get-UpgradeHash $type)) {
                    throw "Conflicting Advisor metadata for recommendation type $($item.id)."
                }
                $types[$item.id] = $type
            }
        }
        $url = $page.nextLink
        if ($url) {
            $next = [uri]$url
            if (-not $next.IsAbsoluteUri -or $next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com' -or -not $next.IsDefaultPort -or $next.UserInfo) {
                throw 'Untrusted Advisor metadata continuation URL.'
            }
        }
    } while ($url)
    return $types
}

function Get-AdvisorRetirementCrossCheck {
    param([string[]]$SubscriptionId, $Inventory, [string]$VmQuery,
        [string[]]$State = @('active','completed','postponed','dismissed','unknown'),
        [string]$StatePropertyPath)
    if ($StatePropertyPath -and $StatePropertyPath -notmatch '^properties(?:\.[A-Za-z_][A-Za-z0-9_]*)+$') {
        throw 'Advisor state property must be an observed properties.* path, not a KQL expression.'
    }
    if (-not $StatePropertyPath -and 'unknown' -notin $State) {
        throw 'State-specific filtering requires an observed Advisor state property mapping. No state is inferred from absence or suppression IDs.'
    }
    $query = Get-Content (Join-Path $script:RepositoryRoot 'queries\advisor-retirements.kql') -Raw
    $stateExpression = if ($StatePropertyPath) { "tolower(tostring($StatePropertyPath))" } else { "'unknown'" }
    $query = $query.Replace('{{stateExpression}}',$stateExpression).Replace('{{states}}',(ConvertTo-Json -InputObject $State -Compress)).Replace('{{vmQuery}}',$VmQuery)
    $data = Get-ScopedGraphRecords -SubscriptionId $SubscriptionId -Query $query
    $metadataCoverage = [Collections.Generic.List[object]]::new()
    $retirements = @()
    foreach ($scope in $data.scopes) {
        $metadata = @{}
        if ($scope.status -eq 'complete') {
            try {
                $metadata = Get-AdvisorRetirementMetadata $scope.subscriptionId
                $metadataCoverage.Add(@{subscriptionId=$scope.subscriptionId;status='complete';error=$null})
            } catch {
                $status = if ($_.Exception.Message -match '403|Forbidden|AuthorizationFailed') { 'denied' } else { 'failed' }
                $metadataCoverage.Add(@{subscriptionId=$scope.subscriptionId;status=$status;error=$_.Exception.Message})
            }
        } else { $metadataCoverage.Add(@{subscriptionId=$scope.subscriptionId;status='not-read';error='Recommendation scope is incomplete.'}) }
        foreach ($row in @($data.rows | Where-Object subscriptionId -EQ $scope.subscriptionId)) {
            $info = $metadata[$row.serviceId]
            $retirements += @{
                recommendationId = $row.id; vmId = $row.resourceId; subscriptionId = $row.subscriptionId
                state = $row.state; stateSource = if ($StatePropertyPath) { $StatePropertyPath } else { 'unknown; not observed' }
                serviceId = $row.serviceId
                retirementDate = if ($info) { $info.retirementDate } else { $null }
                retirementFeatureName = if ($info) { $info.retirementFeatureName } else { $null }
                metadataStatus = if ($info) { 'matched' } else { 'unknown' }
                metadataSource = if ($info) { $info.source } else { 'No matching metadata; no retirement date inferred.' }
            }
        }
    }
    $skuIds = @($Inventory.vms | Where-Object { $_.lifecycle.Count -gt 0 } | ForEach-Object { $_.id.ToLowerInvariant() })
    $advisorIds = @($retirements | ForEach-Object { $_.vmId.ToLowerInvariant() } | Sort-Object -Unique)
    $gaps = @()
    foreach ($scope in $data.scopes) {
        $inventoryScope = @($Inventory.scopes | Where-Object subscriptionId -EQ $scope.subscriptionId)
        if ($scope.status -ne 'complete' -or $inventoryScope.Count -ne 1 -or $inventoryScope[0].status -ne 'complete') {
            $gaps += @{subscriptionId=$scope.subscriptionId;kind='unknown';vmId=$null;detail='Cannot compare incomplete scopes.'}
            continue
        }
        foreach ($id in $skuIds | Where-Object { $_ -like "/subscriptions/$($scope.subscriptionId)/*" -and $_ -notin $advisorIds }) {
            $gaps += @{subscriptionId=$scope.subscriptionId;kind='sku-only';vmId=$id;detail='Not in the selected Advisor state set; do not assume unaffected.'}
        }
        foreach ($id in $advisorIds | Where-Object { $_ -like "/subscriptions/$($scope.subscriptionId)/*" -and $_ -notin $skuIds }) {
            $gaps += @{subscriptionId=$scope.subscriptionId;kind='advisor-only';vmId=$id;detail='Advisor retirement may concern a VM feature/extension rather than the VM SKU.'}
        }
    }
    @{
        observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        source = 'Resource Graph Advisor cross-check (eventually consistent)'
        stateFilter = $State; scopes = $data.scopes; metadataScopes = @($metadataCoverage)
        recommendations = $retirements; coverageGaps = $gaps
        skuCoverageVerified = $false
        limitations = 'No live SKU-retirement coverage test performed. Advisor coverage is not comprehensive; discrepancies flag discovery gaps, never authorize or block execution.'
    }
}
