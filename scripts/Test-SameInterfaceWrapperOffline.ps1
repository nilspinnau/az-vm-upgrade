#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WrapperPath)
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
$path = (Resolve-Path -LiteralPath $WrapperPath).Path
$fixture = Join-Path $PSScriptRoot '..\tests\fixtures\SameInterfaceWrapper.ps1'
$container = New-PesterContainer -Path $fixture -Data @{ WrapperPath = $path }
$result = Invoke-Pester -Container $container -Output Detailed -PassThru
if ($result.FailedCount -or $result.FailedContainersCount -or $result.PassedCount -ne 4) {
    throw 'Offline top-level wrapper tests failed; no live readiness is established.'
}
Write-Output 'Four top-level wrapper tests passed (legacy and explicit ARM-mode integration) with synthetic external boundaries; no Azure or guest operation executed.'
