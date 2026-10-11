locals {
  windows = var.profile == "windows"
  tags = {
    az-vm-upgrade-disposable = "true"
    purpose                  = "single-vm-upgrade-lab"
    profile                  = var.profile
  }
}

resource "azurerm_resource_group" "test" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
  lifecycle {
    precondition {
      condition     = var.deployment_approved
      error_message = "Paid deployment requires explicit subscription, region, budget and exact resource group approval."
    }
    precondition {
      condition     = var.estimated_hourly_cost > 0 && var.maximum_hours > 0 && var.estimated_hourly_cost * var.maximum_hours <= var.budget_limit
      error_message = "Supply a positive reviewed cost estimate and sufficient budget; this is not a billing cap."
    }
  }
}

resource "azurerm_virtual_network" "test" {
  name                = "${var.vm_name}-vnet"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  address_space       = ["10.197.0.0/24"]
  tags                = local.tags
}

resource "azurerm_subnet" "test" {
  name                            = "private"
  resource_group_name             = azurerm_resource_group.test.name
  virtual_network_name            = azurerm_virtual_network.test.name
  address_prefixes                = ["10.197.0.0/26"]
  default_outbound_access_enabled = var.egress_mode == "default"
}

resource "azurerm_public_ip" "egress" {
  count               = var.egress_mode == "nat" ? 1 : 0
  name                = "${var.vm_name}-egress"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "test" {
  count               = var.egress_mode == "nat" ? 1 : 0
  name                = "${var.vm_name}-nat"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "test" {
  count                = var.egress_mode == "nat" ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.test[0].id
  public_ip_address_id = azurerm_public_ip.egress[0].id
}

resource "azurerm_subnet_nat_gateway_association" "test" {
  count          = var.egress_mode == "nat" ? 1 : 0
  subnet_id      = azurerm_subnet.test.id
  nat_gateway_id = azurerm_nat_gateway.test[0].id
}

resource "azurerm_network_security_group" "test" {
  name                = "${var.vm_name}-nsg"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  tags                = local.tags
  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "test" {
  name                           = "${var.vm_name}-nic"
  resource_group_name            = azurerm_resource_group.test.name
  location                       = azurerm_resource_group.test.location
  accelerated_networking_enabled = var.accelerated_networking
  tags                           = local.tags
  ip_configuration {
    name                          = "private"
    subnet_id                     = azurerm_subnet.test.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "test" {
  network_interface_id      = azurerm_network_interface.test.id
  network_security_group_id = azurerm_network_security_group.test.id
}

resource "azurerm_linux_virtual_machine" "test" {
  count                           = local.windows ? 0 : 1
  name                            = var.vm_name
  resource_group_name             = azurerm_resource_group.test.name
  location                        = azurerm_resource_group.test.location
  zone                            = var.zone
  size                            = var.source_size
  disk_controller_type            = var.disk_controller_type
  encryption_at_host_enabled      = var.encryption_at_host_enabled
  admin_username                  = "labadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.test.id]
  provision_vm_agent              = true
  tags                            = local.tags
  admin_ssh_key {
    username   = "labadmin"
    public_key = var.ssh_public_key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }
  source_image_reference {
    publisher = var.image.publisher
    offer     = var.image.offer
    sku       = var.image.sku
    version   = var.image.version
  }
  dynamic "plan" {
    for_each = var.image_purchase_plan == null ? [] : [var.image_purchase_plan]
    content {
      name      = plan.value.name
      product   = plan.value.product
      publisher = plan.value.publisher
    }
  }
  boot_diagnostics {}
  depends_on = [azurerm_network_interface_security_group_association.test, azurerm_subnet_nat_gateway_association.test, azurerm_nat_gateway_public_ip_association.test]
  lifecycle {
    precondition {
      condition     = !var.encryption_at_host_enabled || var.encryption_at_host_prerequisites_verified
      error_message = "Verify EncryptionAtHost Registered, source/target SKU support, fresh non-ADE image and platform-key disks before deployment."
    }
    precondition {
      condition     = var.ssh_public_key != null
      error_message = "Linux lab profiles require a supplied public SSH key."
    }
  }
}

resource "azurerm_windows_virtual_machine" "test" {
  count                      = local.windows ? 1 : 0
  name                       = var.vm_name
  resource_group_name        = azurerm_resource_group.test.name
  location                   = azurerm_resource_group.test.location
  zone                       = var.zone
  size                       = var.source_size
  disk_controller_type       = var.disk_controller_type
  encryption_at_host_enabled = var.encryption_at_host_enabled
  admin_username             = "labadmin"
  admin_password             = var.windows_admin_password
  network_interface_ids      = [azurerm_network_interface.test.id]
  provision_vm_agent         = true
  tags                       = local.tags
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }
  source_image_reference {
    publisher = var.image.publisher
    offer     = var.image.offer
    sku       = var.image.sku
    version   = var.image.version
  }
  boot_diagnostics {}
  depends_on = [azurerm_network_interface_security_group_association.test, azurerm_subnet_nat_gateway_association.test, azurerm_nat_gateway_public_ip_association.test]
  lifecycle {
    precondition {
      condition     = !var.encryption_at_host_enabled || var.encryption_at_host_prerequisites_verified
      error_message = "Verify EncryptionAtHost Registered, source/target SKU support, fresh non-ADE image and platform-key disks before deployment."
    }
    precondition {
      condition     = var.windows_admin_password != null
      error_message = "Windows password must be supplied securely at runtime; state remains sensitive."
    }
  }
}

resource "azurerm_managed_disk" "sentinel" {
  name                 = "${var.vm_name}-sentinel"
  resource_group_name  = azurerm_resource_group.test.name
  location             = azurerm_resource_group.test.location
  zone                 = var.zone
  storage_account_type = var.data_disk_sku
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = local.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "sentinel" {
  managed_disk_id    = azurerm_managed_disk.sentinel.id
  virtual_machine_id = local.windows ? azurerm_windows_virtual_machine.test[0].id : azurerm_linux_virtual_machine.test[0].id
  lun                = 0
  caching            = "None"
}
