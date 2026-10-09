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
