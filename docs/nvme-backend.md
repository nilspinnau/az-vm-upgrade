# Optional pinned NVMe backend, azure-vm-utils and MANA guidance

## Verified upstream facts (reviewed 2026-08-31)

| Item | Verified fact |
|---|---|
| Source | `Azure/SAP-on-Azure-Scripts-and-Utilities`, `Azure-NVMe-Utils`, MIT |
| Pin | commit `f27603bf4189f436da577ba3e945b3857d508c9c` (script version 2026082514), unsigned commit; not "latest" |
| `Azure-NVMe-Conversion.ps1` SHA256 | `fbf1d7e61a6f40be669b438e4cee3a82040fe86cba6212eba18baa68ffcfc4d5` |
| `windows-manual-nvme-prepare.ps1` SHA256 | `f4080a1f9cbaa4e0fea876b3dddfb313c21300fe75f87ed9f524de7dd1622e1a` |
| Parameters | `ResourceGroupName`, `VMName`, `VMSize`, `NewControllerType`, `StartVM`, `WriteLogfile`, `FixOperatingSystemSettings`, `SleepSeconds`, `Ignore{SKUCheck,WindowsVersionCheck,AzureModuleCheck,OSCheck}` |
| ARM ownership | Stops/deallocates, updates OS disk capability, resizes through a direct ARM call, optionally starts. **There is no prep-only switch.** |
| Guest changes | Only with `-FixOperatingSystemSettings`: Linux initramfs/dracut staging and an fstab device-name→UUID rewrite (`/etc/fstab.bak`); Windows `stornvme`/`vpci` registry changes. A separate Windows preparation script exists |
| Network access | Requires Az modules and an interactive Azure context; fetches `version.json` from the `main` branch for a notice only |
| Boundaries | Rejects ADE for Linux and Gen1; Ignore switches can skip other checks |
| azure-vm-utils | MIT, tag `v0.7.0` = commit `7989a36fcf233e4c4bd5fbc20964f3f038b08060`, tarball SHA256 `844e36c5475334cebce15bb04ddcd5f3628c0ef9d37f4ad8d6708dd2d07d244b`; no release assets. Provides `azure-nvme-id` and `/dev/disk/azure` udev symlinks and a udev NVMe `io_timeout` rule |
| MANA Windows | Microsoft documents a driver download via a redirecting entry point; no published hash policy was verified, so it is operator-only |

## Why the backend is not nested into the engine

The full script owns the deallocate/resize/start sequence, so running it
inside `Invoke-VmUpgrade` would bypass plan-hash approval, drift and ETag
checks, the local VM lock, journals and recovery. It is therefore an
**opt-in, separately supported manual backend**, never invoked by the toolkit.

```powershell
Import-Module .\src\AzVmUpgrade.psd1
# 1. Operator downloads the exact pinned commit file and reviews it. The toolkit never downloads.
# 2. Fresh evidence + plan (guest probe already proved NVMe boot readiness on SCSI).
$b = New-ExternalBackendPlan $plan .\Azure-NVMe-Conversion.ps1 `
       -AcceptNoToolkitControls -AcceptDowntime -AcceptNoAutomaticRollback
$b.command   # exact pinned command; no Ignore*, no -FixOperatingSystemSettings
# 3. Operator runs it manually in a maintenance window, then reassesses:
Test-ExternalBackendResult $b $postEvidence -ExitCode $LASTEXITCODE
```

`New-ExternalBackendPlan` refuses: hash mismatch, expired plan, stale guest
evidence, anything but an explicit SCSI→NVMe target, any unresolved check
(except the lab-only `os-support` check), or missing acknowledgements.
`Test-ExternalBackendResult` accepts only a post-run reassessment proving
target size/controller, running VM, fresh guest evidence, NVMe root, stable
mounts and retained MANA and Mellanox drivers. Acceptance covers software
checks; application health and restart/deallocate-start resilience remain
owner-tested. SCSI rollback is not promised.

## What was deliberately not integrated

- `-FixOperatingSystemSettings`: its fstab rewrite lacks per-entry identity resolution evidence and bounded rollback in this toolkit. Use the toolkit's own consented preparation scripts or a reviewed manual change.
- Windows registry changes: documented upstream, reviewed manually; Windows `StartOverride` can be recreated by a SCSI boot, so deallocate immediately after preparation.
- Temporary-disk initialization (the local `SetupEphemeralDisk` idea): stays separately approved and exact-identity-gated; no temp-disk path is executable.
- MANA driver/azure-vm-utils package installation: no automatic install. Absence is advisory evidence in the plan (`advisories`) and the customer report, never a replacement for NVMe boot-driver and stable-mount verification, and never inferred from kernel version alone.

## azure-vm-utils and MANA guidance

Probes report `azureVmUtils` (`azure-nvme-id` plus `/dev/disk/azure`) and
`manaDevicePresent` (PCI `1414:00ba`) alongside existing driver and VF-traffic
checks. Linux operators should consume `/dev/disk/azure/*` paths and install
azure-vm-utils from their distribution channel when available. For Windows, the
operator obtains the MANA driver from the Microsoft entry point, verifies the
Authenticode signature of the catalog and binaries, installs it, reboots and
reassesses. MANA capability is distinct from actual VF use, and MANA hardware
placement is host-dependent: keep Mellanox and synthetic networking.
