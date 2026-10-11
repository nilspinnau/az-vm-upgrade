param(
    [Parameter(Mandatory)][switch]$ApprovedNewDisposableTestDataDisk,
    [Parameter(Mandatory)][string]$ExpectedDiskId,
    [Parameter(Mandatory)][string]$ExpectedDiskUniqueId
)
$ErrorActionPreference = 'Stop'
if (-not $ApprovedNewDisposableTestDataDisk) { throw 'Formatting is off by default; approve the exact new test data disk.' }
if (-not $ExpectedDiskId -or -not $ExpectedDiskUniqueId) { throw 'Exact ARM resource identity is required for a reviewed manual procedure.' }
throw 'Windows test-disk initialization is manual until authoritative controller/LUN mapping is validated. ARM uniqueId is not a guest serial; no formatting or size/order fallback is permitted.'
