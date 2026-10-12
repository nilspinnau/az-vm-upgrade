#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WrapperPath)
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
$path = (Resolve-Path -LiteralPath $WrapperPath).Path
$fixture = Join-Path $PSScriptRoot '..\tests\fixtures\SameInterfaceWrapper.ps1'
$container = @(
    New-PesterContainer -Path $fixture -Data @{ WrapperPath = $path }
)
$explicit = (Get-Content -LiteralPath $path -Raw) -match 'Invoke-LabDiskInitialization\.ps1\b'
if ($explicit) {
    $container += New-PesterContainer -Path (Join-Path $PSScriptRoot '..\tests\fixtures\SupervisedSameInterfaceWrapper.ps1') -Data @{ WrapperPath = $path }
}
$config = New-PesterConfiguration
$config.Run.Container = $container
$config.Run.PassThru = $true
$config.Filter.ExcludeTag = 'WorkerChild'
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
$expected = if ($explicit) { 11 } else { 5 }
if ($result.FailedCount -or $result.FailedContainersCount -or $result.PassedCount -ne $expected) {
    throw 'Offline top-level wrapper tests failed; no live readiness is established.'
}
if ($explicit) {
    Write-Output 'Eleven wrapper tests passed, including six real supervised child scenarios and unknown-shape refusal with synthetic external boundaries; no Azure or guest operation executed.'
} else {
    Write-Output 'Five legacy-wrapper tests passed with synthetic external boundaries; separate-worker proof requires the current explicit helper wrapper.'
}
