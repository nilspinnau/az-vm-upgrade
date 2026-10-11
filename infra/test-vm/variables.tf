variable "subscription_id" {
  type = string
}
variable "location" {
  type = string
}
variable "egress_mode" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["none", "default", "nat"], var.egress_mode)
    error_message = "Explicitly select none, default subnet outbound (lab only), or separately priced NAT. A VM public IP is never attached."
  }
}
variable "resource_group_name" {
  type = string
  validation {
    condition     = startswith(var.resource_group_name, "azvm-upgrade-lab-")
    error_message = "Use a new, dedicated azvm-upgrade-lab- resource group, never a workload group."
  }
}
variable "profile" {
  type    = string
  default = "linux"
  validation {
    condition     = contains(["linux", "windows", "suse-sap"], var.profile)
    error_message = "Choose linux, windows or the assessment-only suse-sap profile."
  }
}
variable "vm_name" {
  type    = string
  default = "testvm"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.vm_name))
    error_message = "Use a short DNS-safe name of at most 15 characters."
  }
}
variable "source_size" {
  type = string
}
variable "target_size" {
  type = string
}
variable "disk_controller_type" {
  type    = string
  default = "SCSI"
  validation {
    condition     = contains(["SCSI", "NVMe"], var.disk_controller_type)
    error_message = "Disk controller must be SCSI or NVMe."
  }
}
variable "zone" {
  type     = string
  default  = null
  nullable = true
}
variable "image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  validation {
    condition     = var.image.version != "latest"
    error_message = "Pin a concrete image version after runtime image validation."
  }
}
variable "image_purchase_plan" {
  type = object({
    name      = string
    product   = string
    publisher = string
  })
  default  = null
  nullable = true
}
variable "ssh_public_key" {
  type      = string
  default   = null
  nullable  = true
  sensitive = true
}
variable "windows_admin_password" {
  type      = string
  default   = null
  nullable  = true
  sensitive = true
}
variable "accelerated_networking" {
  type    = bool
  default = true
}
variable "encryption_at_host_enabled" {
  type    = bool
  default = true
}
variable "encryption_at_host_prerequisites_verified" {
  type    = bool
  default = false
}
variable "data_disk_size_gb" {
  type    = number
  default = 8
}
variable "os_disk_size_gb" {
  type     = number
  default  = null
  nullable = true
  validation {
    condition     = var.os_disk_size_gb == null ? true : var.os_disk_size_gb > 0 && floor(var.os_disk_size_gb) == var.os_disk_size_gb
    error_message = "Supply a positive whole-GiB OS disk size or null for the image default."
  }
}
variable "data_disk_sku" {
  type    = string
  default = "StandardSSD_LRS"
  validation {
    condition     = contains(["StandardSSD_LRS", "Premium_LRS"], var.data_disk_sku)
    error_message = "Only ordinary managed SSD lab layouts are supported."
  }
}
variable "deployment_approved" {
  type    = bool
  default = false
}
variable "estimated_hourly_cost" {
  type = number
}
variable "budget_limit" {
  type = number
}
variable "maximum_hours" {
  type    = number
  default = 8
}
