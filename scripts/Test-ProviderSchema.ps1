#Requires -Version 7.5
param([string]$TerraformDirectory = (Join-Path $PSScriptRoot '..\infra\test-vm'))
$ErrorActionPreference = 'Stop'
$text = & terraform "-chdir=$TerraformDirectory" providers schema -json
if ($LASTEXITCODE -ne 0) { throw 'Provider schema retrieval failed; initialize the pinned provider first.' }
$schema = $text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
$resources = $schema.provider_schemas['registry.terraform.io/hashicorp/azurerm'].resource_schemas
foreach ($type in @('azurerm_linux_virtual_machine','azurerm_windows_virtual_machine')) {
    foreach ($name in @('size','disk_controller_type')) {
        if ($resources[$type].block.attributes[$name].type -ne 'string') { throw "$type.$name schema mismatch." }
    }
}
if ($resources.azurerm_network_interface.block.attributes.accelerated_networking_enabled.type -ne 'bool') { throw 'NIC accelerated_networking_enabled schema mismatch.' }
Write-Output 'Pinned AzureRM VM size/controller and NIC acceleration schema verified; ForceNew behavior still requires source review and exact customer plans.'
