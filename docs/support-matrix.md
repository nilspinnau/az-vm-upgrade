# Support matrix

**Only the exact lab observations in [acceptance](acceptance.md) have live evidence.**
Offline tests exercise decision logic and simulated orchestration; they cannot establish guest
boot safety, Azure allocation, provider service behavior or customer support.
Execution is deliberately restricted to tagged, explicitly approved disposable
labs. There is no bypass for production, previews or unknown checks.

| Configuration | Assessment | Automatic execution boundary |
|---|---|---|
| Standalone Linux / Windows | ARM, guest evidence where probe prerequisites work | Lab-only profiles below |
| Ubuntu 22.04/24.04 x86_64 | Supported bounded probe | Candidate same-interface / Gen2 SCSI-to-NVMe lab paths; exact Ubuntu 24.04 preparation/reboot/rollback observed, not distro-wide certification |
| Windows Server 2022 build 20348 AMD64 | Supported bounded probe | Candidate same-interface / Gen2 SCSI-to-NVMe lab paths; live tests not run |
| SUSE/SLES SAP, RHEL, other builds | Evidence and action plan | Assessment-only; no inferred OS/version certification |
| No-temp-disk source and target | Capability/guest checks | Required for every executable path |
| Existing temp disk / NVMe local storage | Detects capabilities/dependencies | Blocked; reviewed rebuild/preview path outside this release |
| Gen1-to-Gen2 / architecture change | Detected and explained | Separate rebuild/conversion |
| Spot, availability set, VMSS, host/group, PPG, capacity reservation, edge zone | Detected and explained | Separate reviewed placement workflow; no neighboring VM shutdown |
| ADE, customer-managed encryption, confidential / Trusted Launch | Detected and explained | Separate validated encryption/security/recovery path |
| Encryption at host with platform-key ordinary managed disks | Source/target capability and Registered subscription feature required | Retained across the exact Ubuntu AMD SCSI-to-NVMe lab; post-phase security drift is rejected; no broader certification |
| Ephemeral OS, RAID/LVM/crypt/shared disks, Ultra/Premium SSD v2 | Detected or explicitly gated | Assessment-only in this release |
| SAP/HPC, appliance, clustered workload, third-party boot/storage filters | Owner/certification review required | Separate application-specific work |

## Full-cycle gap matrix

Status: **Implemented** (offline-tested logic), **Partial**, **Blocked by
design** (refused/assessment-only), **Untested** (no live evidence).
Live observations are scoped to the exact disposable profile, never a blanket promotion.

| Upgrade-cycle area | Status | Notes |
|---|---|---|
| Pre-mutation protection and proven restore | Partial live | Corrected full harness passed on exact Ubuntu 24.04 AMD profile: synthetic LRS snapshot copies booted on private host-encrypted SCSI recovery VM; UUID/checksum/health passed. Not app-consistent backup certification or an original-SKU allocation guarantee |
| Image/OS/kernel support | Partial | Ubuntu 22.04/24.04 and Windows Server 2022 probed; others assessment-only; no generic kernel gating |
| Gen1/Gen2/rebuild | Blocked by design | Detected; separate rebuild |
| Trusted Launch / ADE / CMK | Blocked by design | Detected and explained |
| Encryption at host | Implemented / Partial live | Exact Ubuntu AMD migration preserved the enabled setting; capability/feature and drift gates plus normal Terraform no-op passed. Recovery must restore the VM property separately from disk snapshots |
| RAID/LVM/crypt/shared, temp disk, pagefile, swap | Blocked by design | Detected; temp-disk initialization separately approved, not implemented |
| NIC acceleration, MANA actual use, connectivity | Partial | Capability vs device vs VF traffic reported separately; Windows driver install automated only for an operator-supplied, hash- and Microsoft-signature-verified zip; Linux MANA detect-only |
| azure-vm-utils / stable device paths | Partial | Detected; install automated for Ubuntu 22.04/24.04 exact archive versions only (software closed, offline-tested); other distros manual; never a substitute for boot-driver and mount verification |
| Guest preparation (NVMe boot drivers) | Implemented / Partial live | Ubuntu 24.04 builtin-driver path applied/rebooted/reassessed; Windows and module-staged Ubuntu variants untested; separate reboot consent |
| Reboot, reassessment, recovery harness | Implemented / Partial live | Fresh exact Ubuntu 24.04 repeat passed preparation/reboot/reassessment, rollback/reboot, migration deallocate/start, restored snapshot boot and original restart with data/health checks; previous failed repeat remains unexplained because its failed observation was not captured |
| Placement (availability set, PPG, VMSS) | Blocked by design | Detected and explained |
| Capacity failure and rollback | Partial | Dynamic SKU/quota readiness; allocation is only known at run time |
| Application health / workload certification | Blocked by design | Owner-supplied review required |
| Locks, policy, RBAC, guest agent, egress | Implemented / Partial live | Exact lab ARM/Run Command permissions, guest-agent and default outbound HTTPS exercised; arbitrary tenant policies and distributed locks not certified |
| Terraform live no-op reconciliation | Implemented / Partial live | Real normal target plan has zero resource changes; journal completion requires separate final owner acceptance |
| Evidence freshness | Implemented | Expiry and guest freshness enforced |
| Optional pinned upstream conversion | Partial | Manual, separately supported; see [nvme-backend.md](nvme-backend.md) |
| Live acceptance | Partial / exact repeat passed | Fresh complete final harness and Terraform no-op passed for exact pinned Ubuntu 24.04 AMD profile. Ubuntu 22.04 module candidate was builtin and stopped. Conditional owner acceptance, other configurations and production support remain unproven; see acceptance record |

Conservative exclusions are intentional. The documented no-temp-disk utility
boundary and the broader platform NVMe page describe temporary-disk transitions
differently; this toolkit does not silently pick a permissive interpretation
or register `VMTempDiskResizePreview`.

Drivers, initramfs/boot configuration, persistent mount identifiers, pending
reboot, agent health and actual device use are different checks. Linux probes
require Python 3, lsblk and distribution tools; unavailable evidence stops
readiness. VF traffic that does not increment during observation is unknown,
not proof of acceleration. Windows non-present driver capability can remain
unknown and requires reviewed driver installation.

The lab engine retains existing NIC configuration. To enable Accelerated
Networking, update the owner-managed desired configuration in a separate
approved maintenance step and reassess; the engine does not assume absent
properties are disabled or make a hidden network change.

After approved live tests, populate `catalog/support.json` with exact image,
kernel/build, source/target, region/zone, disks, networking, provider version,
restart/deallocate-start/recovery and normal Terraform plan evidence. Promote
production support only after review and a deliberate code/policy change.
