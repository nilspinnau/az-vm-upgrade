# Guest preparation (plan-bound; one exact Ubuntu profile live-observed)

Preparation changes **guest** settings before an upgrade. It never resizes,
deallocates, changes the controller or touches Terraform, and it is not the
upgrade. The cycle has separate consent gates:

1. Fresh assessment and an approved upgrade plan (`New-VmUpgradePlan`).
2. `scripts\Invoke-VmPreparation.ps1 -Mode New -PlanPath <plan> -Component nvme-boot,azure-vm-utils -GuestChangeConsent`
   writes `out\preparation.json` (`preparation/1.0`), bound to the plan hash,
   live-configuration fingerprint, guest-evidence age (30 min), catalog and OS profile.
3. `-Mode Apply -GuestChangeConsent` runs the bounded guest script through Run
   Command under the per-VM lock with a journal written *before* the call.
   Drift, an expired request or an interrupted earlier call block it.
4. `-Mode Restart -RebootConsent` is a separate, restart-only step.
5. `-Mode Verify -GuestChangeConsent` collects fresh evidence and accepts only
   when the boot ID changed, Azure VM/disk/NIC configuration is unchanged,
   mounts/disk identities are unchanged, Mellanox/synthetic networking is
   retained and each component verified.
6. Create a **new** upgrade plan and approval. Preparation evidence does not
   authorize an upgrade and does not prove a later boot on NVMe.

`-Mode Status`, `Rollback -RollbackAcknowledged` and `Guide` support recovery.

## Components

| Component | Platform | What it does | Not done |
|---|---|---|---|
| `nvme-boot` | Ubuntu 22.04/24.04 x86_64 | Records originals, stages `nvme`/`nvme_core` in initramfs modules when they are loadable modules, sets `nvme_core.io_timeout=240` modprobe option, rebuilds initramfs, verifies with `lsinitramfs`; built-in drivers are detected and left built-in | No kernel upgrade; refuses `/dev/sd*`/`/dev/nvme*` fstab entries; **never rewrites fstab** |
| `nvme-boot` | Windows Server 2022 (20348) | Records `stornvme`/`vpci` Start and StartOverride per ControlSet, sets boot start, removes StartOverride, verifies | Other builds refused |
| `azure-vm-utils` | Ubuntu only | Installs the exact catalog version offered by the Ubuntu archive after a simulated install that must not remove or touch kernel/boot/systemd/udev/ssh/cloud-init packages; marker file enables rollback | Other distributions stay manual |
| `mana-linux-check` | Ubuntu | Detect-only report | No kernel or package automation; kernel version is not a gate |
| `mana-windows-driver` | Windows | Installs an **operator-supplied** zip: SHA256 must match the reviewed value, no executables, every `.cat/.sys/.dll` Authenticode-valid with a Microsoft signer, exactly one INF for `VEN_1414&DEV_00BA`, installed with `pnputil` | Microsoft's download link is mutable, so no artifact is pinned or downloaded |

Driver presence, host placement and real VF traffic remain distinct checks.
Temp-disk initialization, fstab edits and kernel changes are out of scope.

## Recovery boundaries

Each run saves a manifest (`preparation-manifest/1.0`) and journal. Rollback
restores only recorded values or artifacts this toolkit installed. On the
exact Ubuntu 24.04 AMD disposable profile, apply/reboot/reassessment and
rollback/reboot/fresh preservation checks passed once in the diag-04 harness.
This is not proof for other guest configurations and is **not** a VM restore;
backup files and recorded values alone are not proof of restoration. The
upstream full conversion is never nested; see [nvme-backend.md](nvme-backend.md).

## Consent-gated live harness

`tests\integration\Invoke-LabPreparationAcceptance.ps1` runs apply, restart,
reassessment, an optional Terraform no-op evidence check and an optional
rollback. It requires `-LiveTestConsent` and a context bound to the preparation
hash (`labOnly`, `guestConsent`, `restartApproved`, `exclusiveWindow`, test
resource group, data-sentinel note, expiry). It passed once as part of the
full exact-profile diag-04 harness; see [acceptance.md](acceptance.md) for
measured scope and limits. This is not live evidence for Windows or Ubuntu
22.04.

Sources: [sources.md](sources.md) (MIT-licensed upstream procedures are
re-implemented with attribution; no upstream or customer script is copied).
