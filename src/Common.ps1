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
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}

function Write-UpgradeJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    $temporary = "$full.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $full, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
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
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][ValidateSet('evidence','plan','approval','acceptance','journal','guest','inventory')][string]$Kind)
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
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start Azure CLI.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Azure CLI timed out after $TimeoutSeconds seconds; inspect Azure operation state before retry."
        }
        $text = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Azure CLI failed ($($process.ExitCode)): $errorText" }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String)
    } finally { $process.Dispose() }
}

function Invoke-ArmRead {
    param([string]$Id, [string]$ApiVersion)
    if ($Id -notmatch '^/subscriptions/([0-9a-f-]{36})/') { throw 'An explicitly subscription-scoped ARM resource ID is required.' }
    Invoke-UpgradeAz @('rest','--method','get','--subscription',$Matches[1],'--url',"$Id`?api-version=$ApiVersion")
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
