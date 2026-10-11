mock_provider "azurerm" {}

variables {
  subscription_id                           = "00000000-0000-0000-0000-000000000000"
  location                                  = "westeurope"
  resource_group_name                       = "azvm-upgrade-lab-offline"
  source_size                               = "Standard_D2s_v5"
  target_size                               = "Standard_D2s_v6"
  deployment_approved                       = true
  egress_mode                               = "default"
  encryption_at_host_prerequisites_verified = true
  estimated_hourly_cost                     = 0.20
  budget_limit                              = 2
  maximum_hours                             = 8
  ssh_public_key                            = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC/bvqjeVfT0rFCTZHW8/N6egHNB/Om7Qxb+7Y0hZ1iczFUdSPRVv+crYVfNVeSXVqXn9SCJoq71rHE9+NCWnKBD5fjmx3kZKSLOH4rT6QBs8uww5MVsDPdckpePIz81RjCPki5a581g1M+a86Itsl1EAh0JbDNPDEB0mgjKN3JEeM965D2awbDwPDT1eMUwtkg2EkmUwhZgfWaDSzf9kW5b3eTkLEoqB8c+9G4BjJfCct3c3itSlrDZIMVJqweo/OT+0W/v6iuLO9BVZMHn0pfePoNG62XlhGCfAnBdPCKzv2U6XXRswN63EVcmJDGXGYSmwb6w/jlYvXwRt6RlyE9 offline-fixture-public-only"
  image = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "0.0.0"
  }
}

run "linux_plan" {
  command = plan
  assert {
    condition     = length(azurerm_linux_virtual_machine.test) == 1 && length(azurerm_windows_virtual_machine.test) == 0
    error_message = "A deployment must contain exactly one VM."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.test[0].disk_controller_type == "SCSI"
    error_message = "Baseline controller must be explicit."
  }
  assert {
    condition     = one(azurerm_network_security_group.test.security_rule).access == "Deny"
    error_message = "Public inbound access is not allowed."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.test[0].encryption_at_host_enabled
    error_message = "The minimal lab must retain encryption at host."
  }
  assert {
    condition     = azurerm_subnet.test.default_outbound_access_enabled && length(azurerm_public_ip.egress) == 0 && length(azurerm_nat_gateway.test) == 0
    error_message = "Explicitly approved default outbound lab must have no paid IP or NAT."
  }
  assert {
    condition     = one(azurerm_network_interface.test.ip_configuration).public_ip_address_id == null
    error_message = "A VM public IP is forbidden."
  }
}

run "nat_egress_plan" {
  command = plan
  variables {
    egress_mode = "nat"
  }
  assert {
    condition     = !azurerm_subnet.test.default_outbound_access_enabled && length(azurerm_nat_gateway.test) == 1 && length(azurerm_public_ip.egress) == 1
    error_message = "NAT is explicit, separately priced egress; never combine with default subnet outbound."
  }
  assert {
    condition     = one(azurerm_network_interface.test.ip_configuration).public_ip_address_id == null
    error_message = "NAT public IP must never be attached to the VM."
  }
}

run "encryption_feature_gate" {
  command = plan
  variables {
    encryption_at_host_prerequisites_verified = false
  }
  expect_failures = [azurerm_linux_virtual_machine.test[0]]
}

run "approval_gate" {
  command = plan
  variables {
    deployment_approved = false
  }
  expect_failures = [azurerm_resource_group.test]
}

run "windows_plan" {
  command = plan
  variables {
    profile                = "windows"
    windows_admin_password = "OfflineFixture-NotARealCredential-123!"
    image = {
      publisher = "MicrosoftWindowsServer"
      offer     = "WindowsServer"
      sku       = "2022-datacenter-g2"
      version   = "0.0.0"
    }
  }
  assert {
    condition     = length(azurerm_windows_virtual_machine.test) == 1 && length(azurerm_linux_virtual_machine.test) == 0
    error_message = "Windows profile must create exactly one VM."
  }
  assert {
    condition     = azurerm_windows_virtual_machine.test[0].encryption_at_host_enabled
    error_message = "Windows must also preserve the explicit host encryption setting."
  }
}

run "suse_assessment_plan" {
  command = plan
  variables {
    profile = "suse-sap"
    image = {
      publisher = "SUSE"
      offer     = "sles-sap-15-sp5"
      sku       = "gen2"
      version   = "0.0.0"
    }
  }
  assert {
    condition     = length(azurerm_linux_virtual_machine.test) == 1
    error_message = "SUSE assessment profile must create one Linux VM."
  }
}
