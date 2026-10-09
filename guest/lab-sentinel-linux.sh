#!/usr/bin/env bash
set -euo pipefail
if [ "${AZVM_INITIALIZE_CONSENT:-}" != "format-new-disposable-test-data-disk" ]; then
  echo "Formatting is off by default. Explicit new-lab-data-disk approval is required." >&2; exit 2
fi
[ "$(id -u)" -eq 0 ] || { echo "Root required" >&2; exit 2; }
: "${AZVM_EXPECTED_DISK_ID:?Exact Terraform data_disk_id required}"
: "${AZVM_EXPECTED_DISK_UNIQUE_ID:?Exact ARM disk properties.uniqueId required}"
command -v python3 >/dev/null
command -v curl >/dev/null
command -v wipefs >/dev/null
command -v mkfs.ext4 >/dev/null
device=/dev/disk/azure/scsi1/lun0
[ -b "$device" ] || { echo "Initial SCSI LUN 0 symlink is absent; no fallback by device name/order" >&2; exit 2; }
metadata="$(curl --noproxy '*' --fail --silent --show-error --max-time 10 -H Metadata:true 'http://169.254.169.254/metadata/instance/compute/storageProfile?api-version=2021-02-01')"
METADATA="$metadata" python3 - <<'PY'
import json, os
disks = json.loads(os.environ["METADATA"]).get("dataDisks", [])
matches = [d for d in disks if str(d.get("lun")) == "0" and d.get("managedDisk", {}).get("id", "").lower() == os.environ["AZVM_EXPECTED_DISK_ID"].lower()]
if len(matches) != 1:
    raise RuntimeError("Exact managed disk identity and LUN not confirmed by IMDS")
PY
serial="$(lsblk -dn -o SERIAL "$device" | tr -d '[:space:]-' | tr '[:upper:]' '[:lower:]')"
expected="$(printf '%s' "$AZVM_EXPECTED_DISK_UNIQUE_ID" | tr -d '[:space:]-' | tr '[:upper:]' '[:lower:]')"
[ -n "$serial" ] && [ "$serial" = "$expected" ] || { echo "Guest serial does not match ARM uniqueId; stop for reviewed manual initialization" >&2; exit 2; }
[ "$(lsblk -n -o TYPE "$device" | wc -l)" -eq 1 ] || { echo "Partitions/children exist; stop" >&2; exit 2; }
[ -z "$(lsblk -n -o MOUNTPOINTS "$device" | tr -d '[:space:]')" ] || { echo "Disk is mounted; stop" >&2; exit 2; }
[ -z "$(wipefs --no-act --noheadings --output TYPE "$device")" ] || { echo "Existing disk signatures; never erase them" >&2; exit 2; }
root_device="$(findmnt -n -o SOURCE /)"
[ "$(readlink -f "$root_device")" != "$(readlink -f "$device")" ] || { echo "OS disk exclusion" >&2; exit 2; }
if lsblk -sn -o NAME "$root_device" | grep -qx "$(basename "$(readlink -f "$device")")"; then
  echo "OS disk ancestry exclusion" >&2; exit 2
fi
[ ! -e /mnt/upgrade-test/azvm-sentinel.txt ] || { echo "Existing sentinel; stop rather than overwrite" >&2; exit 2; }
mkfs.ext4 "$device"
uuid="$(blkid -s UUID -o value "$device")"
mkdir -p /mnt/upgrade-test /var/lib/az-vm-upgrade
mount "$device" /mnt/upgrade-test
printf 'az-vm-upgrade synthetic managed-data sentinel\n' > /mnt/upgrade-test/azvm-sentinel.txt
printf 'healthy\n' > /var/lib/az-vm-upgrade/healthy
printf 'UUID=%s /mnt/upgrade-test ext4 defaults,nofail 0 2\n' "$uuid" >> /etc/fstab
sha256sum /mnt/upgrade-test/azvm-sentinel.txt
echo "Only the explicitly identified new test data disk was initialized. No temporary disk is formatted."
