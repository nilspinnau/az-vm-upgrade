# Verified sources and licensing

Reviewed 2026-10-09. These are factual references; no third-party conversion
utility, customer material or SAP project implementation is bundled.

| Subject | Source and constraint |
|---|---|
| Resize | https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/resize-vm |
| Platform NVMe prerequisites / minimal controller capability sequence | https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux |
| Community utility support / no-temp-disk / ADE / Gen1 exclusions | https://learn.microsoft.com/en-us/azure/virtual-machines/migration/scsi-to-nvme-migration |
| MANA architecture and Mellanox coexistence | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview |
| Actual Linux VF/MANA use | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-linux |
| Actual Windows MANA use | https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-windows |
| Standard quota tiers, deallocated consumption, capacity distinction | https://learn.microsoft.com/en-us/azure/virtual-machines/quotas |
| Lifecycle catalog | https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions |
| ARG eventual consistency | https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview |
| Advisor retirement metadata / coverage limits | https://learn.microsoft.com/en-us/azure/advisor/advisor-how-to-use-service-upgrade-retirement-recommendations |
| Advisor workbook limitations | https://learn.microsoft.com/en-us/azure/advisor/advisor-workbook-service-retirement |
| Pinned Linux VM schema and controller/size Update implementation | https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.48.0/internal/services/compute/linux_virtual_machine_resource.go |
| Optional conversion backend (MIT), commit `f27603bf4189f436da577ba3e945b3857d508c9c` | https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities/tree/f27603bf4189f436da577ba3e945b3857d508c9c/Azure-NVMe-Utils |
| azure-vm-utils (MIT), tag v0.7.0 = commit `7989a36fcf233e4c4bd5fbc20964f3f038b08060` | https://github.com/Azure/azure-vm-utils/tree/7989a36fcf233e4c4bd5fbc20964f3f038b08060 |
| MANA Windows driver entry point (mutable redirect, not pinned) | https://aka.ms/manawindowsdrivers |
| Pinned Windows VM schema and controller/size Update implementation | https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.48.0/internal/services/compute/windows_virtual_machine_resource.go |

Provider source was reviewed rather than copied. Installed AzureRM 4.48.0
schema/validation and mocked plans confirm attribute spelling and module
configuration. Customer-specific and live replacement/reconciliation behavior
still needs exact normal Terraform plan evidence.

The broader NVMe platform page and conversion-utility page describe
temporary-disk paths differently. This release conservatively excludes them.
MANA capability does not imply actual host placement or traffic; probes keep
those facts separate. Advisor's published coverage is incomplete and is never
the sole SKU-retirement authority.

`MS-mikeo/VM_Lifecycle_Reporting` was supplied as a reference-only suggestion;
no implementation was copied. Cost Management/Excel reporting and cost-impact
calculation remain out of scope.

Original code/documentation is MIT; see LICENSE and NOTICE. The Azure NVMe
conversion script and azure-vm-utils are MIT-licensed Microsoft projects that
are only referenced by commit and SHA256 in `catalog/backends.json`; none of
their code is vendored or redistributed here, and the toolkit never downloads
them. See [nvme-backend.md](nvme-backend.md). External Azure
CLI, Terraform, provider and PowerShell test dependencies retain their own
licenses and are not redistributed as binaries. Redistribution/publication
must still be reviewed for any future third-party additions and customer data.
