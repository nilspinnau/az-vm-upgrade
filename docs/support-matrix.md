# Support matrix

**No path has live acceptance evidence in this release.** Offline tests exercise
the decision logic and simulated orchestration; they cannot establish guest
boot safety, Azure allocation, provider service behavior or customer support.
Execution is deliberately restricted to tagged, explicitly approved disposable
labs. There is no bypass for production, previews or unknown checks.

| Configuration | Assessment | Automatic execution boundary |
|---|---|---|
| Standalone Linux / Windows | ARM, guest evidence where probe prerequisites work | Lab-only profiles below |
| Ubuntu 22.04/24.04 x86_64 | Supported bounded probe | Candidate same-interface / Gen2 SCSI-to-NVMe lab paths; live tests not run |
| Windows Server 2022 build 20348 AMD64 | Supported bounded probe | Candidate same-interface / Gen2 SCSI-to-NVMe lab paths; live tests not run |
| SUSE/SLES SAP, RHEL, other builds | Evidence and action plan | Assessment-only; no inferred OS/version certification |
| No-temp-disk source and target | Capability/guest checks | Required for every executable path |
| Existing temp disk / NVMe local storage | Detects capabilities/dependencies | Blocked; reviewed rebuild/preview path outside this release |
| Gen1-to-Gen2 / architecture change | Detected and explained | Separate rebuild/conversion |
| Spot, availability set, VMSS, host/group, PPG, capacity reservation, edge zone | Detected and explained | Separate reviewed placement workflow; no neighboring VM shutdown |
| ADE, customer-managed encryption, confidential / Trusted Launch | Detected and explained | Separate validated encryption/security/recovery path |
| Ephemeral OS, RAID/LVM/crypt/shared disks, Ultra/Premium SSD v2 | Detected or explicitly gated | Assessment-only in this release |
| SAP/HPC, appliance, clustered workload, third-party boot/storage filters | Owner/certification review required | Separate application-specific work |

## Full-cycle gap matrix

Status: **Implemented** (offline-tested logic), **Partial**, **Blocked by
design** (refused/assessment-only), **Untested** (no live evidence). Nothing
here is live-validated.

| Upgrade-cycle area | Status | Notes |
|---|---|---|
| Pre-mutation protection and proven restore | Partial | Snapshot/restore-point evidence, recovery and preparation journals exist; guest rollback restores recorded values only. No restore has been proven live; SCSI rollback is not promised |
| Image/OS/kernel support | Partial | Ubuntu 22.04/24.04 and Windows Server 2022 probed; others assessment-only; no generic kernel gating |
| Gen1/Gen2/rebuild | Blocked by design | Detected; separate rebuild |
| Trusted Launch / ADE / CMK | Blocked by design | Detected and explained |
| RAID/LVM/crypt/shared, temp disk, pagefile, swap | Blocked by design | Detected; temp-disk initialization separately approved, not implemented |
| NIC acceleration, MANA actual use, connectivity | Partial | Capability vs device vs VF traffic reported separately; Windows driver install automated only for an operator-supplied, hash- and Microsoft-signature-verified zip; Linux MANA detect-only |
| azure-vm-utils / stable device paths | Partial | Detected; install automated for Ubuntu 22.04/24.04 exact archive versions only (software closed, offline-tested); other distros manual; never a substitute for boot-driver and mount verification |
| Guest preparation (NVMe boot drivers) | Implemented / Untested | Plan-bound, consent-gated, journaled for Ubuntu 22.04/24.04 and Windows Server 2022; reboot is a separate consent step; no live run |
| Reboot, reassessment, recovery harness | Implemented / Untested | Boot-ID, unchanged-config and mount checks; consent-gated live harness exists but has not run |
| Placement (availability set, PPG, VMSS) | Blocked by design | Detected and explained |
| Capacity failure and rollback | Partial | Dynamic SKU/quota readiness; allocation is only known at run time |
| Application health / workload certification | Blocked by design | Owner-supplied review required |
| Locks, policy, RBAC, guest agent, egress | Implemented / Untested | Checked in evidence; no live tenant validation |
| Terraform live no-op reconciliation | Partial | Mocked plans offline; harness checks operator-supplied no-op evidence; real normal plan needed |
| Evidence freshness | Implemented | Expiry and guest freshness enforced |
| Optional pinned upstream conversion | Partial | Manual, separately supported; see [nvme-backend.md](nvme-backend.md) |
| Live acceptance | Untested | No live matrix has been run |

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
