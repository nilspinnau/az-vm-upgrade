subscription_id       = "00000000-0000-0000-0000-000000000000"
location              = "westeurope"
resource_group_name   = "azvm-upgrade-lab-example"
profile               = "linux"
source_size           = "Standard_D2s_v5"
target_size           = "Standard_D2s_v6"
disk_controller_type  = "SCSI"
deployment_approved   = false
estimated_hourly_cost = 0.20 # Example only; replace with reviewed VM+disk/licensing pricing.
budget_limit          = 2
maximum_hours         = 8
image = {
  publisher = "Canonical"
  offer     = "0001-com-ubuntu-server-jammy"
  sku       = "22_04-lts-gen2"
  version   = "REPLACE_WITH_RUNTIME_VALIDATED_VERSION"
}
