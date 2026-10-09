function Assert-ApplicationHealthChecks {
    param([AllowNull()][AllowEmptyCollection()][array]$Checks)
    if ($Checks.Count -gt 4) { throw 'At most four approved application health endpoints are allowed.' }
    foreach ($check in $Checks) {
        $uri = $null
        if (-not [uri]::TryCreate($check.uri,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw 'Health endpoints must be HTTPS URLs without credentials, query secrets or fragments.'
        }
        if ($check.expectedStatus -notin (200..299)) { throw 'Health endpoint expectedStatus must be a successful HTTP status.' }
        if ($check.bodySha256 -and $check.bodySha256 -notmatch '^[0-9a-f]{64}$') { throw 'Health endpoint bodySha256 must be a lowercase SHA256 digest.' }
    }
}

function Invoke-ApplicationHealthCheck {
    param([hashtable]$Check)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Check.uri)
    $response = $null
    $stream = $null
    try {
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne $Check.expectedStatus) { throw "Application health failed at $($Check.uri): HTTP $([int]$response.StatusCode)." }
        $digest = $null
        if ($Check.bodySha256) {
            $stream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
            $buffer = [byte[]]::new(65537)
            $length = 0
            do {
                $read = $stream.ReadAsync($buffer,$length,$buffer.Length - $length,$cancel.Token).GetAwaiter().GetResult()
                $length += $read
            } while ($read -gt 0 -and $length -lt $buffer.Length)
            if ($length -gt 65536) { throw 'Health response exceeds the approved 64 KiB observation limit.' }
            $payload = [byte[]]::new($length)
            [Array]::Copy($buffer,$payload,$length)
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
            if ($digest -cne $Check.bodySha256) { throw "Application health content digest mismatch at $($Check.uri)." }
        }
        @{ uri=$Check.uri; status='pass'; httpStatus=[int]$response.StatusCode; bodySha256=$digest; observedAt=[DateTimeOffset]::UtcNow.ToString('o') }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose(); $cancel.Dispose(); $client.Dispose(); $handler.Dispose()
    }
}

function Get-ApplicationHealthEvidence {
    param($WorkloadReview)
    if (-not $WorkloadReview.healthChecks) { return }
    $checks = @($WorkloadReview.healthChecks)
    Assert-ApplicationHealthChecks $checks
    foreach ($check in $checks) { Invoke-ApplicationHealthCheck $check }
}
