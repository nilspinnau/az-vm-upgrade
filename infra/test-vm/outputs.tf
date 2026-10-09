output "vm_id" {
  value = local.windows ? azurerm_windows_virtual_machine.test[0].id : azurerm_linux_virtual_machine.test[0].id
}
output "data_disk_id" {
  value = azurerm_managed_disk.sentinel.id
}
output "resource_group_name" {
  value = azurerm_resource_group.test.name
}
output "terraform_vm_address" {
  value = local.windows ? "azurerm_windows_virtual_machine.test[0]" : "azurerm_linux_virtual_machine.test[0]"
}
output "target_size_for_review" {
  value = var.target_size
}
output "estimated_budget" {
  value = {
    hourly_cost = var.estimated_hourly_cost
    hours       = var.maximum_hours
    estimate    = var.estimated_hourly_cost * var.maximum_hours
    budget      = var.budget_limit
  }
}
