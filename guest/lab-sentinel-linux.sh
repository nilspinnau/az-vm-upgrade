#!/usr/bin/env bash
set -euo pipefail
if [ "${AZVM_INITIALIZE_CONSENT:-}" != "format-new-disposable-test-data-disk" ]; then
  echo "Formatting is off by default. Explicit new-lab-data-disk approval is required." >&2; exit 2
fi
[ "$(id -u)" -eq 0 ] || { echo "Root required" >&2; exit 2; }
: "${AZVM_EXPECTED_DISK_ID:?Exact Terraform data_disk_id required}"
: "${AZVM_EXPECTED_SCSI_SERIAL:?Captured serial from the independently LUN-mapped SCSI disk required}"
command -v python3 >/dev/null
command -v curl >/dev/null
command -v wipefs >/dev/null
command -v mkfs.ext4 >/dev/null
command -v udevadm >/dev/null
device=/dev/disk/azure/scsi1/lun0
[ -b "$device" ] || { echo "Initial SCSI LUN 0 symlink is absent; no fallback by device name/order" >&2; exit 2; }
metadata="$(curl --noproxy '*' --fail --silent --show-error --max-time 10 -H Metadata:true 'http://169.254.169.254/metadata/instance/compute/storageProfile?api-version=2021-02-01')"
properties="$(udevadm info --query=property --name="$device")"
hctl="$(lsblk -dn -o HCTL "$device" | tr -d '[:space:]')"
METADATA="$metadata" UDEV_PROPERTIES="$properties" HCTL="$hctl" python3 - <<'PY'
import json, os
def verify_scsi_identity(metadata, properties, hctl, expected_id, expected_serial):
    disks = metadata.get("dataDisks", [])
    at_lun = [d for d in disks if str(d.get("lun")) == "0"]
    if len(at_lun) != 1 or at_lun[0].get("managedDisk", {}).get("id", "").lower() != expected_id.lower():
        raise RuntimeError("Exact managed disk identity and unique LUN not confirmed by IMDS")
    if properties.get("ID_BUS") != "scsi" or properties.get("AZURE_DISK_TYPE") != "data" or properties.get("AZURE_DISK_LUN") != "0":
        raise RuntimeError("Azure udev mapping does not prove a managed SCSI data disk at LUN 0")
    if len(hctl.split(":")) != 4 or hctl.split(":")[-1] != "0":
        raise RuntimeError("SCSI HCTL does not corroborate LUN 0")
    serial = properties.get("ID_SERIAL_SHORT", "")
    if not expected_serial or not serial or serial != expected_serial:
        raise RuntimeError("Mapped SCSI serial changed since read-only identity capture")
properties = dict(line.split("=", 1) for line in os.environ["UDEV_PROPERTIES"].splitlines() if "=" in line)
verify_scsi_identity(json.loads(os.environ["METADATA"]), properties, os.environ["HCTL"],
                     os.environ["AZVM_EXPECTED_DISK_ID"], os.environ["AZVM_EXPECTED_SCSI_SERIAL"])
PY
serial="$(lsblk -dn -o SERIAL "$device" | tr -d '[:space:]-' | tr '[:upper:]' '[:lower:]')"
expected="$(printf '%s' "$AZVM_EXPECTED_SCSI_SERIAL" | tr -d '[:space:]-' | tr '[:upper:]' '[:lower:]')"
[ -n "$serial" ] && [ "$serial" = "$expected" ] || { echo "lsblk serial does not corroborate the captured udev identity" >&2; exit 2; }
[ "$(lsblk -n -o TYPE "$device" | wc -l)" -eq 1 ] || { echo "Partitions/children exist; stop" >&2; exit 2; }
[ -z "$(lsblk -n -o MOUNTPOINTS "$device" | tr -d '[:space:]')" ] || { echo "Disk is mounted; stop" >&2; exit 2; }
[ -z "$(wipefs --no-act --noheadings --output TYPE "$device")" ] || { echo "Existing disk signatures; never erase them" >&2; exit 2; }
root_device="$(findmnt -n -o SOURCE /)"
[ "$(readlink -f "$root_device")" != "$(readlink -f "$device")" ] || { echo "OS disk exclusion" >&2; exit 2; }
if lsblk -sn -o NAME "$root_device" | grep -qx "$(basename "$(readlink -f "$device")")"; then
  echo "OS disk ancestry exclusion" >&2; exit 2
fi
[ ! -e /mnt/upgrade-test/azvm-sentinel.txt ] || { echo "Existing sentinel; stop rather than overwrite" >&2; exit 2; }
[ ! -d /mnt/upgrade-test ] || [ -z "$(ls -A /mnt/upgrade-test)" ] || { echo "Mount directory is not empty; stop" >&2; exit 2; }
! grep -Eq '^[^#]*[[:space:]]/mnt/upgrade-test[[:space:]]' /etc/fstab || { echo "Existing test mount entry; stop" >&2; exit 2; }
[ ! -e /var/lib/az-vm-upgrade/lab-fstab.before ] || { echo "Existing lab fstab backup; preserve it and stop" >&2; exit 2; }
mkdir -p /var/lib/az-vm-upgrade
cp -p /etc/fstab /var/lib/az-vm-upgrade/lab-fstab.before
mkfs.ext4 "$device"
uuid="$(blkid -s UUID -o value "$device")"
mkdir -p /mnt/upgrade-test /var/lib/az-vm-upgrade
mount "$device" /mnt/upgrade-test
printf 'az-vm-upgrade synthetic managed-data sentinel\n' > /mnt/upgrade-test/azvm-sentinel.txt
printf 'healthy\n' > /var/lib/az-vm-upgrade/healthy
printf 'UUID=%s /mnt/upgrade-test ext4 defaults,nofail 0 2\n' "$uuid" >> /etc/fstab
sha256sum /mnt/upgrade-test/azvm-sentinel.txt
echo "Only the explicitly identified new test data disk was initialized. No temporary disk is formatted."
