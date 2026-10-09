variable "subscription_id" {
  type = string
}
variable "location" {
  type = string
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
variable "data_disk_size_gb" {
  type    = number
  default = 8
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
