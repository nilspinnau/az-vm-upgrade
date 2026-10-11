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
import base64, datetime, json, os
def verify_scsi_identity(metadata, properties, hctl, expected_id, expected_serial, mode="imds-required", arm=None):
    print("AZVM_DISK_IDENTITY_OBSERVATION=" + json.dumps({
        "schemaVersion": "lab-disk-identity/1.1",
        "identityMode": mode,
        "armEvidence": {key: arm.get(key) for key in ("schemaVersion", "identityMode", "observedAt", "expiresAt", "labOnly")} if isinstance(arm, dict) else arm,
        "expectedManagedDiskId": expected_id,
        "expectedScsiSerial": expected_serial,
        "storageProfile": metadata,
        "udev": {key: properties.get(key) for key in ("ID_BUS", "AZURE_DISK_TYPE", "AZURE_DISK_LUN", "ID_SERIAL_SHORT")},
        "hctl": hctl,
    }), flush=True)
    if mode not in ("imds-required", "arm-azure-udev"):
        raise RuntimeError("Unknown identity mode; no fallback")
    if mode == "arm-azure-udev":
        if not isinstance(arm, dict) or arm.get("schemaVersion") != "lab-arm-identity/1.0" or arm.get("identityMode") != mode or arm.get("labOnly") is not True:
            raise RuntimeError("Explicit synthetic lab ARM identity evidence required")
        now = datetime.datetime.now(datetime.timezone.utc)
        observed = datetime.datetime.fromisoformat(arm["observedAt"])
        expires = datetime.datetime.fromisoformat(arm["expiresAt"])
        if observed.tzinfo is None or expires.tzinfo is None or not -30 <= (now - observed).total_seconds() <= 600 or not observed < expires or not now < expires <= observed + datetime.timedelta(hours=4):
            raise RuntimeError("ARM identity evidence or consent is stale/invalid")
        vm, disk = arm["vm"], arm["disk"]
        vm_id = vm["id"]
        group = arm["testResourceGroup"]
        if not isinstance(group, str) or not group.startswith("azvm-upgrade-lab-") or not vm_id.lower().endswith("/providers/microsoft.compute/virtualmachines/" + arm["vmName"].lower()):
            raise RuntimeError("Not an exact synthetic lab VM scope")
        scope = "/subscriptions/" + arm["subscriptionId"] + "/resourceGroups/" + group
        if not vm_id.lower().startswith(scope.lower() + "/providers/microsoft.compute/virtualmachines/") or not expected_id.lower().startswith(scope.lower() + "/providers/microsoft.compute/disks/"):
            raise RuntimeError("VM/disk outside exact approved lab scope")
        profile = vm["properties"]["storageProfile"]
        attached = profile["dataDisks"]
        if vm.get("tags", {}).get("az-vm-upgrade-disposable") != "true" or disk.get("tags", {}).get("az-vm-upgrade-disposable") != "true" or profile.get("diskControllerType") != "SCSI":
            raise RuntimeError("Disposable ownership/SCSI controller not proved")
        if disk["id"].lower() != expected_id.lower() or disk.get("managedBy", "").lower() != vm_id.lower() or disk["properties"]["creationData"]["createOption"] != "Empty" or not disk["properties"].get("uniqueId"):
            raise RuntimeError("Exact owned new empty managed disk not proved")
        if len(attached) != 1 or str(attached[0].get("lun")) != "0" or attached[0]["managedDisk"]["id"].lower() != expected_id.lower() or profile["osDisk"]["managedDisk"]["id"].lower() == expected_id.lower():
            raise RuntimeError("Exact unique ARM LUN/OS exclusion not proved")
        if arm.get("expectedScsiSerial") != expected_serial:
            raise RuntimeError("ARM evidence serial binding changed")
    if not isinstance(metadata, dict) or not isinstance(metadata.get("dataDisks"), list):
        raise RuntimeError("IMDS storageProfile/dataDisks response shape is missing or invalid; see retained identity observation")
    disks = metadata["dataDisks"]
    if any(not isinstance(d, dict) or not isinstance(d.get("managedDisk"), dict)
           or not isinstance(d["managedDisk"].get("id"), str) for d in disks):
        raise RuntimeError("IMDS managed disk identity is missing or invalid; see retained identity observation")
    at_lun = [d for d in disks if str(d.get("lun")) == "0"]
    if mode == "arm-azure-udev" and metadata.get("osDisk", {}).get("managedDisk", {}).get("id", "").lower() != arm["vm"]["properties"]["storageProfile"]["osDisk"]["managedDisk"]["id"].lower():
        raise RuntimeError("IMDS OS identity contradicts or cannot corroborate ARM evidence")
    if (mode == "imds-required" or disks) and (len(at_lun) != 1 or at_lun[0]["managedDisk"]["id"].lower() != expected_id.lower()):
        raise RuntimeError("Exact managed disk identity and unique LUN not confirmed by IMDS; see retained identity observation")
    if mode == "arm-azure-udev" and disks and len(disks) != 1:
        raise RuntimeError("IMDS attachment count contradicts exact single ARM data disk")
    if properties.get("ID_BUS") != "scsi" or properties.get("AZURE_DISK_TYPE") != "data" or properties.get("AZURE_DISK_LUN") != "0":
        raise RuntimeError("Azure udev mapping does not prove a managed SCSI data disk at LUN 0")
    if len(hctl.split(":")) != 4 or hctl.split(":")[-1] != "0":
        raise RuntimeError("SCSI HCTL does not corroborate LUN 0")
    serial = properties.get("ID_SERIAL_SHORT", "")
    if not expected_serial or not serial or serial != expected_serial:
        raise RuntimeError("Mapped SCSI serial changed since read-only identity capture")
properties = dict(line.split("=", 1) for line in os.environ["UDEV_PROPERTIES"].splitlines() if "=" in line)
arm_encoded = os.environ.get("AZVM_ARM_IDENTITY_BASE64")
verify_scsi_identity(json.loads(os.environ["METADATA"]), properties, os.environ["HCTL"],
                     os.environ["AZVM_EXPECTED_DISK_ID"], os.environ["AZVM_EXPECTED_SCSI_SERIAL"],
                     os.environ.get("AZVM_IDENTITY_MODE", "imds-required"),
                     json.loads(base64.b64decode(arm_encoded, validate=True)) if arm_encoded else None)
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
