# Verified sources and licensing

Reviewed 2026-10-09. These are factual references; no third-party conversion
utility, customer material or SAP project implementation is bundled.

The public [Trusted Launch FAQ](https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch-faq#can-i-disable-trusted-launch-for-a-new-vm-deployment)
documents explicit Standard security with Compute API `2025-11-01` or newer.
The restoration harness requires that API rather than using older CLI create
templates that require an additional subscription feature. No security
conversion or extra feature registration is performed.

Encryption-at-host and SKU capability additions reviewed 2026-10-11:

- https://learn.microsoft.com/en-us/azure/virtual-machines/linux/disks-enable-host-based-encryption-cli
  documents Registered feature, `EncryptionAtHostSupported`, resize validation
  and the current/ever-ADE exclusion. The toolkit retains encryption, never
  registers or disables it automatically.
- https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview
  distinguishes SSE/platform keys, DES/CMK, host encryption and ADE. The
  published ADE retirement date is September 15, 2028; ADE migration remains
  out of scope, not silently ignored.
- Dsv5/Dsv6 primary size pages document no local storage, cache support and
  uncached limits:
  https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv5-series
  and https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv6-series.
  Read-only live SKU discovery exposes `CombinedTempDiskAndCached*` rather
  than synthetic `CachedDisk*` fields. Combined limits are used as cache
  limits only when no temp disk is proved; read/write throughput is checked
  separately. Legacy source SKU controller omission is not interpreted as
  missing current ARM/guest controller evidence; target support stays required.
- The public Azure Retail Prices API is used only for scoped lab estimates,
  not retirement cost-impact reporting. Meter currency/unit/OS/Spot distinction
  matters; delayed Cost Management totals are not a spending cap.
- https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dasv6-series
  verifies AMD EPYC, no local storage, Gen2/NVMe image requirements and the
  `Dav6`/`Dasv6` naming difference. Exact regional SKU capabilities/restrictions,
  quota and actual allocation remain authoritative for the chosen lab.

| Subject | Source and constraint |
|---|---|
| Resize | https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/resize-vm |
| Platform NVMe prerequisites / minimal controller capability sequence | https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux |
| Linux distributions endorsed on Azure (Ubuntu LTS platform-image families; does not certify a specific kernel config) | https://learn.microsoft.com/en-us/azure/virtual-machines/linux/endorsed-distros |
| Azure VM utilities pinned README (`azure-nvme-id`, udev links, image test harness requiring SSH and default 50 reboots) | https://github.com/Azure/azure-vm-utils/blob/7989a36fcf233e4c4bd5fbc20964f3f038b08060/README.md |
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

## Native guest preparation sources (verified 2026-10-09)

- Ubuntu package archive pages (packages.ubuntu.com) list `azure-vm-utils`
  `0.6.0-4~ubuntu0.22.04.1` (jammy-updates) and `0.6.0-4~ubuntu0.24.04.1`
  (noble-updates); these exact versions are the only automated channel in
  `catalog/preparation.json`. Other distributions remain manual.
- The initramfs `nvme`/`nvme_core` staging, `io_timeout` and Windows
  `stornvme`/`vpci` boot-start procedures follow the MIT-licensed
  Azure/SAP-on-Azure-Scripts-and-Utilities procedures (commit pinned in
  `catalog/backends.json`) and are re-implemented with bounded backups; no
  upstream code is vendored and the full conversion script is never nested.
- The Windows MANA driver link is a mutable redirect, so only an
  operator-supplied, hash- and signature-verified package is accepted.

## Live integration fixes and identity authority (2026-10-11)

- https://learn.microsoft.com/en-us/azure/virtual-machines/linux/azure-to-guest-disk-mapping
  documents correlating the VM's ARM data-disk LUN with guest SCSI HCTL.
  https://learn.microsoft.com/en-us/azure/virtual-machines/linux/azure-virtual-machine-utilities
  documents Microsoft-provided stable symlinks. Guest SCSI
  NAA serial is not ARM managed-disk `uniqueId`. The lab initializer uses
  exact IMDS disk ID/unique LUN, Microsoft-provided Azure udev properties,
  HCTL and the captured serial; no size/order inference or cloud-init formatting.
- The MIT `azure-vm-utils` pinned upstream
  [80-azure-disk.rules](https://github.com/Azure/azure-vm-utils/blob/7989a36fcf233e4c4bd5fbc20964f3f038b08060/udev/80-azure-disk.rules)
  exposes `AZURE_DISK_TYPE`, `AZURE_DISK_LUN` and
  `/dev/disk/azure/data/by-lun/*` for both SCSI and remote NVMe, using
  `azure-nvme-id --udev` for NVMe. The toolkit consumes these interfaces;
  it does not reimplement the upstream mapping algorithm. Preserve filesystem
  UUID mounts across controllers; controller serials are observations, not
  a promised cross-controller managed-resource identifier.
- https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch-existing-vm
  documents a separate existing-Gen2 security upgrade, Linux `SBInfo`
  compatibility checks and Enhanced Backup policy. Review ASR-specific
  documentation; do not generalize the page's Gen1 ASR wording to every
  Gen2 workload. Public rollback guidance includes tool/API prerequisites
  and a one-way re-enablement restriction. This toolkit only adds an optional
  assessment advisory and never enables/disables Trusted Launch. Azure Migrate
  importing Gen2 servers is a different workflow from this existing-Azure-VM lab.

### IMDS request and initialization policy review (2026-10-11)

The initializer requests
`http://169.254.169.254/metadata/instance/compute/storageProfile?api-version=2021-02-01`
with `Metadata:true` and proxy bypass. Microsoft's
[IMDS reference](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)
lists that API version and documents nested-property filtering with JSON as
the default for objects. Data-disk `lun` and `managedDisk` are documented
since `2019-06-01`; the sample contains `managedDisk.id`. This is not an
unsupported API-version or leaf-format request.

The reference describes attached data disks but gives no data-disk update
latency guarantee. Its FAQ discusses metadata refresh for older VM creation
dates and disk changes; it does not establish that this lab's empty array
is a known hot-attachment limitation or propagation bug. Terraform attaches
the test disk through a separate attachment resource after VM creation;
that ordering is established, but its relationship to the empty response
is not. Updating the API version or adding retries is not a proven remedy.

Requiring exact independent IMDS ID/LUN proof is an additional toolkit
initialization policy, not a prerequisite in Microsoft's ARM-to-guest LUN
mapping procedure. The current guard remains unchanged and fail-closed.
Using fresh exact ARM attachment/ownership/provenance plus Microsoft Azure
udev data-disk/LUN mapping and SCSI HCTL is a documented alternative mapping
basis, but changing the approved identity policy requires explicit approval
before implementation or live formatting. All serial continuity, unique
LUN, OS-ancestry, empty-signature and unmounted-disk guards must remain;
size/order inference is not an alternative. Contradictory identity evidence
must not be ignored. No new live test is justified merely by this review.
## Live device-mapping correction

The probe consumes azure-vm-utils' `data/by-lun` links and Azure disk/LUN
properties, rather than duplicating NVMe namespace mapping. NVMe udev does
not necessarily provide `ID_BUS`; the resolved block device's kernel sysfs
subsystem establishes the controller independently. SCSI additionally requires
its udev bus property. The lab observed this difference with unchanged LUN,
filesystem UUID, mount and checksum after conversion.

## NVMe boot-driver configuration evidence boundary (2026-10-11)

Microsoft's [Linux/Windows NVMe migration guidance](https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux)
requires OS readiness, initramfs/boot-driver checks and post-conversion guest
verification, but does not name an Ubuntu image/kernel with
`CONFIG_BLK_DEV_NVME=m` and `CONFIG_NVME_CORE=m`. The Ubuntu endorsed-distros
page documents distribution/image families, not a particular Marketplace
image's kernel configuration. The pinned `azure-vm-utils` project supplies
NVMe identity/udev utilities, not an alternative kernel driver or proof that a
driver is modular.

Accordingly, no supported pinned module-staged image is currently
source-qualified. This is a hard block for claiming or planning a
module-staged Ubuntu test; it is not a blocker for the exact tested
Ubuntu 24.04 builtin-driver profile. The approved Ubuntu 22.04 candidate's
running guest reported both `nvme` and `nvme_core` as `(builtin)`. The
Ubuntu 24.04 diag-04 guest did likewise. These are exact runtime observations,
not source proof for every image of either release. Qualifying a future module
profile requires a publisher-controlled source/package/config tied to the
exact immutable Marketplace image and boot-kernel package, demonstrating both
NVMe options as modules; deterministic offline tests must then prove initramfs
contains both matching modules and the preparation/rollback logic handles that
package/kernel. A separately approved live boot is needed to verify the
actually installed package, running kernel, module paths and initramfs on that
exact image. Until then do not substitute an image/kernel or add another
distro by inference.
