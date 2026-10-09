terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.48.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {
    virtual_machine {
      delete_os_disk_on_deletion = false
    }
  }
}
