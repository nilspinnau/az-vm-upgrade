function Get-Field {
    param($Object, [string]$Path)
    $value = $Object
    foreach ($part in $Path.Split('.')) {
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($part)) { return $null }
            $value = $value[$part]
        } else {
            if ($null -eq $value -or $null -eq $value.PSObject.Properties[$part]) { return $null }
            $value = $value.$part
        }
    }
    return $value
}

function Read-UpgradeJson {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path), [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { $json = $reader.ReadToEnd() }
    finally { $reader.Dispose() }
    $json | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}

function Write-UpgradeJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    $temporary = "$full.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100))
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if ([IO.File]::Exists($full)) {
                # Overwrite-mode Move can deny replacement even with delete-sharing readers on Windows.
                [IO.File]::Replace($temporary, $full, [System.Management.Automation.Language.NullString]::Value)
            } else {
                [IO.File]::Move($temporary, $full)
            }
            return
        } catch [IO.IOException], [UnauthorizedAccessException] {
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            $code = $failure.HResult -band 0xffff
            $replacementBlocked = [IO.File]::Exists($full) -and
                (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReadOnly) -eq 0)
            if ($attempt -eq 5 -or -not $IsWindows -or $code -notin @(5, 32, 33) -or -not $replacementBlocked) {
                throw [IO.IOException]::new(
                    "Atomic evidence publication failed for '$full'. Previous evidence was not overwritten; unpublished evidence remains at '$temporary'. No cloud operation may be replayed based on this write failure.",
                    $failure)
            }
            if ($attempt -eq 1) {
                Write-Warning "Atomic evidence replacement was blocked for '$full'; retrying only the local rename, at most five attempts."
            }
            Start-Sleep -Milliseconds (100 * [Math]::Pow(2, $attempt - 1))
        }
    }
}

function ConvertTo-CanonicalValue {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-CanonicalValue $Value[$key]
        }
        return $result
    }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        return ,@($Value | ForEach-Object { ConvertTo-CanonicalValue $_ })
    }
    return $Value
}

function Get-UpgradeHash {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Value)
    $json = ConvertTo-Json -InputObject (ConvertTo-CanonicalValue $Value) -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-UpgradeDocument {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][ValidateSet('evidence','plan','approval','acceptance','journal','guest','inventory','preparation','preparation-manifest')][string]$Kind)
    $schema = Join-Path $script:RepositoryRoot "schemas\$Kind.schema.json"
    $json = $Document | ConvertTo-Json -Depth 100
    if (-not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)) {
        throw "Invalid $Kind document."
    }
    return $true
}

function Assert-FreshEvidence {
    param($Timestamp, [int]$MaxAgeMinutes = 60)
    if (-not $Timestamp) { throw 'Evidence timestamp is missing.' }
    $time = [DateTimeOffset]::Parse($Timestamp)
    $age = [DateTimeOffset]::UtcNow - $time
    if ($age.TotalMinutes -gt $MaxAgeMinutes -or $age.TotalMinutes -lt -5) {
        throw "Stale or future evidence: $Timestamp"
    }
}

function Get-VmIdentity {
    param([Parameter(Mandatory)][string]$VmId)
    if ($VmId -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/([A-Za-z0-9_.()-]{1,90})/providers/Microsoft\.Compute/virtualMachines/([A-Za-z0-9_-]{1,64})$') {
        throw 'Exactly one standalone VM ARM resource ID is required.'
    }
    @{
        subscriptionId = $Matches[1]; resourceGroup = $Matches[2]
        name = $Matches[3]; id = $VmId.ToLowerInvariant()
    }
}

function Assert-LabWorkDeadline {
    if ($env:AZVM_LAB_WORK_DEADLINE -and [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($env:AZVM_LAB_WORK_DEADLINE)) {
        throw 'Lab work deadline reached; stop new work and initiate exact approved cleanup.'
    }
}

function Invoke-UpgradeProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 900,
        [DateTimeOffset]$Deadline = [DateTimeOffset]::MaxValue,
        [string]$ObservationPath,
        [string]$Operation
    )
    Assert-LabWorkDeadline
    $started = [DateTimeOffset]::UtcNow
    $end = $started.AddSeconds($TimeoutSeconds)
    if ($Deadline -lt $end) { $end = $Deadline }
    if ($env:AZVM_LAB_WORK_DEADLINE) {
        $work = [DateTimeOffset]::Parse($env:AZVM_LAB_WORK_DEADLINE)
        if ($work -lt $end) { $end = $work }
    }
    if ($end -le $started) { throw 'External command deadline reached before start.' }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $observation = @{ startedAt = $started.ToString('o'); deadline = $end.ToString('o')
        executable = [IO.Path]::GetFileName($StartInfo.FileName); status = 'starting' }
    if ($Operation) { $observation.operation = $Operation }
    if ($ObservationPath) { Write-UpgradeJson $observation $ObservationPath }
    $stdout = $null; $stderr = $null; $launched = $false
    try {
        if (-not $process.Start()) { throw 'Could not start external command.' }
        $launched = $true
        $observation.pid = $process.Id; $observation.status = 'running'
        if ($ObservationPath) { Write-UpgradeJson $observation $ObservationPath }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.HasExited -or -not $stdout.IsCompleted -or -not $stderr.IsCompleted) {
            if ([DateTimeOffset]::UtcNow -ge $end) { throw 'External command wall-clock deadline reached; remote operation outcome may be unknown; do not replay.' }
            Start-Sleep -Milliseconds 100
        }
        if ([DateTimeOffset]::UtcNow -ge $end) { throw 'External command returned after its wall-clock deadline; stop and clean up.' }
        $observation.status = 'exited'; $observation.exitCode = $process.ExitCode
        @{ exitCode = $process.ExitCode; stdout = $stdout.GetAwaiter().GetResult(); stderr = $stderr.GetAwaiter().GetResult() }
    } catch {
        $observation.status = 'failed'; $observation.error = $_.Exception.Message
        throw
    } finally {
        try {
            if ($launched -and -not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { Write-Warning "Child process $($process.Id) did not exit after termination; exact cleanup still required." }
            }
            if ($stdout -and $stdout.IsCompletedSuccessfully) { $observation.stdout = $stdout.Result }
            if ($stderr -and $stderr.IsCompletedSuccessfully) { $observation.stderr = $stderr.Result }
        } finally {
            $process.Dispose()
            $observation.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
            if ($ObservationPath) { Write-UpgradeJson $observation $ObservationPath }
        }
    }
}

function Invoke-UpgradeAz {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 900)
    $command = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $allArgs = @($Arguments) + @('--only-show-errors','--output','json')
    if ($IsWindows -and [IO.Path]::GetExtension($command) -in @('.cmd','.bat')) {
        # Bypass cmd parsing by calling the official Windows MSI's bundled interpreter.
        $python = [IO.Path]::GetFullPath((Join-Path (Split-Path $command -Parent) '..\python.exe'))
        if (-not (Test-Path -LiteralPath $python)) { throw 'Unsupported Azure CLI batch launcher: use the official MSI or a native az executable.' }
        $start.FileName = $python
        $start.Environment['AZ_INSTALLER'] = 'MSI'
        foreach ($arg in @('-IBm','azure.cli') + $allArgs) { $start.ArgumentList.Add($arg) }
    } else {
        $start.FileName = $command
        foreach ($arg in $allArgs) { $start.ArgumentList.Add($arg) }
    }
    $observationPath = if ($env:AZVM_LAB_COMMAND_JOURNAL_DIRECTORY) {
        Join-Path $env:AZVM_LAB_COMMAND_JOURNAL_DIRECTORY "command-$([guid]::NewGuid().ToString('N')).json"
    } else { $null }
    $operation = [Collections.Generic.List[string]]::new()
    foreach ($arg in $Arguments) {
        if ($arg -notmatch '^[a-z][a-z0-9-]*$') { break }
        $operation.Add($arg)
        if ($operation.Count -ge 3) { break }
    }
    if ($Arguments[0] -eq 'rest') {
        $methodIndex = [array]::IndexOf($Arguments, '--method')
        if ($methodIndex -ge 0 -and $methodIndex + 1 -lt $Arguments.Count -and $Arguments[$methodIndex + 1] -match '^(get|post|put|patch|delete)$') {
            $operation.Add($Arguments[$methodIndex + 1].ToUpperInvariant())
        }
    }
    $result = Invoke-UpgradeProcess -StartInfo $start -TimeoutSeconds $TimeoutSeconds -ObservationPath $observationPath -Operation ($operation -join ' ')
    if ($result.exitCode -ne 0) { throw "Azure CLI failed ($($result.exitCode)): $($result.stderr)" }
    if ([string]::IsNullOrWhiteSpace($result.stdout)) { return $null }
    return ($result.stdout | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String)
}

function Invoke-ArmRead {
    param([string]$Id, [string]$ApiVersion)
    if ($Id -notmatch '^/subscriptions/([0-9a-f-]{36})/') { throw 'An explicitly subscription-scoped ARM resource ID is required.' }
    Invoke-UpgradeAz @('rest','--method','get','--subscription',$Matches[1],'--url',"$Id`?api-version=$ApiVersion")
}

function Wait-LabCostRetry {
    param([ValidateRange(1,180)][int]$Seconds)
    $waitUntil=[DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $waitUntil) {
        Assert-LabWorkDeadline
        Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(1000,[Math]::Ceiling(($waitUntil-[DateTimeOffset]::UtcNow).TotalMilliseconds))))
    }
}

function Get-LabMonthToDateCost {
    param([Parameter(Mandatory)][guid]$SubscriptionId)
    $body = @{ type='ActualCost'; timeframe='MonthToDate'; dataset=@{
        granularity='None'; aggregation=@{totalCost=@{name='PreTaxCost';function='Sum'}}
    }} | ConvertTo-Json -Depth 10 -Compress
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    if ($env:AZVM_LAB_WORK_DEADLINE) {
        $work = [DateTimeOffset]::Parse($env:AZVM_LAB_WORK_DEADLINE)
        if ($work -lt $deadline) { $deadline=$work }
    }
    for ($attempt=1; $attempt -le 3; $attempt++) {
        Assert-LabWorkDeadline
        $remaining=[Math]::Floor(($deadline-[DateTimeOffset]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) { throw 'Cost query retry deadline reached; no stale cost fallback is allowed.' }
        try {
            return Invoke-UpgradeAz @('rest','--subscription',$SubscriptionId.ToString(),'--method','post',
                '--url',"https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2025-03-01",
                '--body',$body) -TimeoutSeconds ([int][Math]::Min(90,$remaining))
        } catch {
            # This fixed query is read-only despite POST; no generic ARM operation is retried.
            $message=$_.Exception.Message
            $throttled=$message -match '(?m)^Azure CLI failed \([0-9]+\):\s*ERROR:\s*\((429|TooManyRequests)\)'
            $errorBody=[regex]::Match($message,'^Azure CLI failed \([0-9]+\):\s*ERROR: Too Many Requests\((\{.*\})\)\s*$',[Text.RegularExpressions.RegexOptions]::Singleline)
            if ($errorBody.Success) {
                try { $throttled=($errorBody.Groups[1].Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop).error.code -ceq '429' }
                catch { $throttled=$false }
            }
            if ($attempt -eq 3 -or -not $throttled) { throw }
            $delay=[int](60 * [Math]::Pow(2,$attempt-1)) + (Get-Random -Minimum 0 -Maximum 6)
            $retryAfter=[regex]::Matches($message,'(?im)(?:x-ms-ratelimit-microsoft\.costmanagement-[a-z-]*retry-after|Retry-After)\s*[:=]\s*([0-9]+)')
            foreach ($header in $retryAfter) { $delay=[Math]::Max($delay,[double]$header.Groups[1].Value) }
            if ($delay -gt 180 -or [DateTimeOffset]::UtcNow.AddSeconds($delay+1) -ge $deadline) {
                throw 'Cost query throttle wait exceeds bounded deadline; no retry or stale cost fallback is allowed.'
            }
            Write-Warning "Cost query throttled; read-only retry $($attempt+1)/3 after $delay seconds. Azure CLI may not expose response headers; exponential backoff is used when absent."
            Wait-LabCostRetry -Seconds $delay
        }
    }
}

function Get-ConfigurationFingerprint {
    param($Evidence)
    # Hash only bounded model configuration, not volatile quota or instance status.
    Get-UpgradeHash @{
        vm = $Evidence.vm
        disks = @($Evidence.disks | Sort-Object { $_.id })
        nics = @($Evidence.nics | Sort-Object { $_.id })
    }
}

function New-Check {
    param([string]$Name, [ValidateSet('pass','disabled','unknown','stale','unsupported','denied','failed','required')][string]$Status,
        [string]$Detail, [string]$Source = 'assessment')
    @{ name = $Name; status = $Status; detail = $Detail; source = $Source; observedAt = [DateTimeOffset]::UtcNow.ToString('o') }
}
function Get-RunCommandStdout {
    param([Parameter(Mandatory)]$Result)
    $messages = @($Result.value | Where-Object { $_.code -match 'StdOut' })
    if ($messages.Count -eq 1) { return [string]$messages[0].message }
    if ($messages.Count -gt 1) { throw 'Run Command returned ambiguous stdout results.' }
    $combined = @($Result.value | Where-Object { $_.code -ceq 'ProvisioningState/succeeded' })
    if ($combined.Count -ne 1) { throw 'Run Command returned no unique successful output.' }
    $match = [regex]::Match([string]$combined[0].message, '(?s)\[stdout\]\r?\n(.*?)\r?\n\[stderr\](?:\r?\n|$)')
    if (-not $match.Success) { throw 'Run Command combined output is missing or truncated.' }
    return $match.Groups[1].Value
}
