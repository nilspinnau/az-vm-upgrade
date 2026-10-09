# Guest evidence and preparation

Guest Run Command always requires explicit consent, even for observation.
The probe emits marked structured JSON and refuses oversized/truncated output.
It does not dump environment variables, application files or secrets.

Linux observations include OS/kernel/architecture and boot mode, guest agent,
pending reboot, NVMe/MANA/Mellanox module presence, NVMe boot image/timeout,
block layout, stable filesystem identifiers, mounts, swap and bounded VF
traffic counters. LVM/RAID/crypt and temporary-storage dependencies are excluded
from execution. A missing tool or boot image does not become readiness.

Windows observations include OS build/architecture, boot-disk controller,
stornvme service start configuration, adapters/driver observations, pagefile
locations, disk state, drive assignments, persistent volume identities and
bounded VF traffic. Non-present MANA/Mellanox drivers can remain unknown.

The lab managed-data sentinel is `/mnt/upgrade-test/azvm-sentinel.txt` on Linux
or `F:\azvm-sentinel.txt` on Windows. The application sentinel is respectively
`/var/lib/az-vm-upgrade/healthy` or `C:\ProgramData\az-vm-upgrade\healthy`,
containing `healthy`. Richer approved health checks can be supplied separately
in the plan-bound workload contract.

## Reversible preparation

Preparation is separate from disruptive execution. The engine expects a
fresh ready guest and makes **no hidden package, kernel, mount or driver
installation changes**.

`guest/prepare-ubuntu-nvme.sh` is restricted to Ubuntu 22.04/24.04 lab profiles.
It preserves the original initramfs module file and NVMe config, stages
`nvme`/`nvme_core`, configures `io_timeout=240` and rebuilds the current kernel's
initramfs. It refuses unstable device-name mounts; it does not rewrite arbitrary
fstab entries. Run only after separate guest-change approval, with
`AZVM_PREPARE_CONSENT=approved-disposable-lab`. Reboot under separate approval,
then reassess. Do not mistake a rebuilt initramfs for a proved post-reboot boot.

`guest/prepare-windows-nvme.ps1 -ApprovedDisposableLab` preserves the original
stornvme start value and sets boot start, for Server 2022 only. Driver packages
must be obtained/reviewed from Microsoft or the supported distribution, never
an arbitrary downloaded executable or unreviewed community hook.

Preparation backups remain inside the guest, under the documented preparation
directory. Restore original files/registry settings only in a separately
reviewed recovery procedure and only after confirming controller compatibility.

## Test-data initialization is not temporary-disk formatting

The two `lab-sentinel-*` scripts can initialize **only an explicitly identified,
new Terraform test data disk**, after separate destructive approval. They
require exact ARM disk ID/unique ID, IMDS LUN corroboration, guest serial match,
OS-disk exclusion and an untouched RAW/no-signature disk. They never select by
device name, order, model or size alone. Any mismatch stops; platform-specific
serial mapping may need a reviewed manual procedure.

The initialization scripts are not part of the upgrade engine and are not
invoked automatically by Terraform or the test suite. They are off by default.
No temporary disk is formatted anywhere. Existing managed data is never
reinitialized to make a probe pass.
