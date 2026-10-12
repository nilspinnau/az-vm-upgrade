#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null || { echo "python3 is required for structured guest evidence" >&2; exit 2; }
python3 - <<'PY'
import datetime, hashlib, json, os, pathlib, re, shutil, subprocess, time, urllib.error, urllib.request

def run(args, optional=False):
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30).stdout
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        if optional:
            return None
        raise

def module(name):
    builtin = pathlib.Path("/lib/modules/" + os.uname().release + "/modules.builtin")
    if builtin.exists() and re.search(r"/" + re.escape(name) + r"\.ko(?:\n|$)", builtin.read_text()):
        return True
    return run(["modinfo", name], optional=True) is not None

def builtin_module(name):
    filename = run(["modinfo", "-F", "filename", name], optional=True)
    builtin = pathlib.Path("/lib/modules/" + os.uname().release + "/modules.builtin")
    pattern = r"/" + re.escape(name).replace("_", "[-_]") + r"\.ko(?:\n|$)"
    return filename is not None and filename.strip() == "(builtin)" and builtin.exists() and re.search(pattern, builtin.read_text()) is not None

release = {}
for line in pathlib.Path("/etc/os-release").read_text().splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        release[key] = value.strip('"')
layout = json.loads(run(["lsblk", "--json", "-o", "NAME,TYPE,UUID,MOUNTPOINTS,PKNAME,TRAN,SERIAL"]))
all_devices = []
def walk(items):
    for item in items:
        all_devices.append(item)
        walk(item.get("children", []))
walk(layout["blockdevices"])
fstab = pathlib.Path("/etc/fstab").read_text()
entries = [line.split() for line in fstab.splitlines() if line.strip() and not line.lstrip().startswith("#")]
stable = all(fields[0].startswith(("UUID=", "PARTUUID=", "LABEL=")) or
             fields[0] in ("none", "tmpfs", "proc", "sysfs", "devpts", "overlay") or
             (len(fields) > 2 and fields[2] in ("tmpfs", "proc", "sysfs", "devpts"))
             for fields in entries if fields)
unsupported_layout = any(item["type"] in ("lvm", "crypt", "raid0", "raid1", "raid5", "raid10", "md") for item in all_devices)
swap_lines = pathlib.Path("/proc/swaps").read_text().splitlines()[1:]
temporary_dependency = pathlib.Path("/dev/disk/azure/resource").exists() or any("/mnt" in str(fields) for fields in entries if fields[-1:] == ["swap"])
persistent = sorted((item.get("uuid"), sorted(p for p in (item.get("mountpoints") or []) if p))
                    for item in all_devices if item.get("uuid") and any(item.get("mountpoints") or []))
storage_hash = hashlib.sha256(json.dumps(persistent, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
data_mappings = []
for link in sorted(pathlib.Path("/dev/disk/azure/data/by-lun").glob("*")):
    if not link.name.isdigit():
        continue
    matches = [item for item in all_devices if item["name"] == link.resolve().name and item["type"] == "disk"]
    if len(matches) != 1:
        raise RuntimeError("Azure data LUN symlink does not resolve to a unique disk")
    mapped = matches[0]
    properties_text = run(["udevadm", "info", "--query=property", "--name", str(link)])
    properties = dict(line.split("=", 1) for line in properties_text.splitlines() if "=" in line)
    if properties.get("AZURE_DISK_TYPE") != "data" or properties.get("AZURE_DISK_LUN") != link.name:
        raise RuntimeError("Microsoft Azure udev data/LUN mapping is inconsistent")
    members = []
    def mapped_members(item):
        if item.get("uuid"):
            members.append(item["uuid"])
        for child in item.get("children", []):
            mapped_members(child)
    mapped_members(mapped)
    device_subsystem = (pathlib.Path("/sys/class/block") / link.resolve().name / "device/subsystem").resolve().name
    data_mappings.append({"lun": int(link.name), "uuids": sorted(members),
                          "controller": "NVMe" if device_subsystem == "nvme" else "SCSI" if device_subsystem == "scsi" and properties.get("ID_BUS") == "scsi" else "unknown"})
root = next((item for item in all_devices if "/" in (item.get("mountpoints") or [])), None)
root_parent = next((item for item in all_devices if root and item["name"] == (root.get("pkname") or root["name"])), root)
actual = "unknown"
if root_parent:
    if root_parent.get("tran") == "nvme" or root_parent["name"].startswith("nvme"):
        actual = "NVMe"
    elif root_parent.get("tran") == "scsi" or root_parent["name"].startswith("sd"):
        actual = "SCSI"
initramfs = None
for args in (["lsinitramfs", "/boot/initrd.img-" + os.uname().release],
             ["lsinitrd", "/boot/initrd-" + os.uname().release]):
    initramfs = run(args, optional=True)
    if initramfs is not None:
        break
boot = "unknown"
if initramfs is not None:
    has_boot_driver = (builtin_module("nvme") or re.search(r"/nvme\.ko(?:\.(?:xz|zst|gz))?(?:\n|$)", initramfs) is not None) and (
        builtin_module("nvme_core") or re.search(r"/nvme[-_]core\.ko(?:\.(?:xz|zst|gz))?(?:\n|$)", initramfs) is not None)
    timeout_path = pathlib.Path("/sys/module/nvme_core/parameters/io_timeout")
    timeout_ready = timeout_path.exists() and timeout_path.read_text().strip() == "240"
    boot = "pass" if has_boot_driver and timeout_ready else "failed"

interfaces = {}
for path in pathlib.Path("/sys/class/net").iterdir():
    if path.name == "lo":
        continue
    driver_path = path / "device/driver"
    driver = driver_path.resolve().name if driver_path.exists() else "unknown"
    counters = run(["ethtool", "-S", path.name], optional=True)
    vf = sum(int(v) for v in re.findall(r"vf_(?:rx|tx)_packets:\s*(\d+)", counters or ""))
    packet_count = None
    if driver in ("mana", "mlx4_core", "mlx4_en", "mlx5_core"):
        packet_count = int((path / "statistics/rx_packets").read_text()) + int((path / "statistics/tx_packets").read_text())
    interfaces[path.name] = (driver, vf, packet_count)
connectivity = "unknown"
if os.environ.get("AZVM_NETWORK_PROBE_CONSENT") == "approved-azure-https-probe":
    try:
        with urllib.request.urlopen(urllib.request.Request("https://management.azure.com/", method="HEAD"), timeout=10) as response:
            connectivity = "pass"
    except urllib.error.HTTPError:
        connectivity = "pass"  # HTTP error still proves unauthenticated HTTPS endpoint reachability.
    except (urllib.error.URLError, TimeoutError):
        connectivity = "failed"
time.sleep(2)
mana_in_use = "unknown"
acceleration = "unknown"
for name, (driver, previous, previous_packets) in interfaces.items():
    counters = run(["ethtool", "-S", name], optional=True)
    vf = sum(int(v) for v in re.findall(r"vf_(?:rx|tx)_packets:\s*(\d+)", counters or ""))
    if vf > previous:
        acceleration = "pass"
    if previous_packets is not None:
        net = pathlib.Path("/sys/class/net") / name
        packets = int((net / "statistics/rx_packets").read_text()) + int((net / "statistics/tx_packets").read_text())
        if packets > previous_packets:
            acceleration = "pass"
            if driver == "mana":
                mana_in_use = "pass"
def pci_ids(device):
    try:
        return (device / "vendor").read_text().strip(), (device / "device").read_text().strip()
    except OSError:
        return None, None
mana_pci = any(pci_ids(d) == ("0x1414", "0x00ba") for d in pathlib.Path("/sys/bus/pci/devices").glob("*"))
nvme_id = shutil.which("azure-nvme-id") is not None
disk_links = pathlib.Path("/dev/disk/azure").is_dir()
vm_utils = "pass" if nvme_id and disk_links else ("failed" if not nvme_id and not disk_links else "unknown")
agent = run(["systemctl", "is-active", "walinuxagent"], optional=True)
if agent is None:
    agent = run(["systemctl", "is-active", "waagent"], optional=True)
pending = pathlib.Path("/var/run/reboot-required").exists()
if release.get("ID") not in ("ubuntu", "debian"):
    pending = None  # distro-specific restart detection is not inferred
sentinel = pathlib.Path("/mnt/upgrade-test/azvm-sentinel.txt")
sentinel_hash = hashlib.sha256(sentinel.read_bytes()).hexdigest() if sentinel.exists() and sentinel.stat().st_size <= 65536 else None
health = pathlib.Path("/var/lib/az-vm-upgrade/healthy")
health_status = "pass" if health.exists() and health.read_text().strip() == "healthy" else "unknown"
runtime = {"status": "failed", "vmSize": None, "logicalProcessors": os.cpu_count(), "rawResponse": None, "error": None}
try:
    request = urllib.request.Request("http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text",
                                     headers={"Metadata": "true"})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=5) as response:
        raw_size = response.read(257)
    runtime["rawResponse"] = raw_size[:256].decode("utf-8", errors="replace")
    runtime["vmSize"] = runtime["rawResponse"].strip()
    if len(raw_size) > 256 or not re.fullmatch(r"(Standard|Basic)_[A-Za-z0-9_]+", runtime["vmSize"]):
        raise ValueError("IMDS compute vmSize is missing or malformed")
    runtime["status"] = "collected"
except (urllib.error.URLError, TimeoutError, ValueError, TypeError, AttributeError) as error:
    runtime["error"] = str(error)[:160]
probe = {
    "schemaVersion": "guest/1.0", "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "complete": True, "osProfile": release.get("ID", "unknown") + ":" + release.get("VERSION_ID", "unknown") + ":" + os.uname().machine,
    "kernel": os.uname().release, "bootMode": "UEFI" if pathlib.Path("/sys/firmware/efi").exists() else "BIOS",
    "agentReady": agent is not None and agent.strip() == "active", "pendingReboot": pending,
    "runtimeSizeEvidence": runtime,
    "nvmeDriver": "pass" if module("nvme") else "failed", "nvmeBoot": boot,
    "manaDriver": "pass" if module("mana") else "failed",
    "mellanoxDriver": "pass" if module("mlx4_core") and module("mlx5_core") else "failed",
    "actualController": actual, "persistentMounts": stable,
    "layoutSupported": not unsupported_layout and not temporary_dependency and not swap_lines,
    "storageIdentityHash": storage_hash, "sentinelHash": sentinel_hash,
    "managedDataMappings": sorted(data_mappings, key=lambda item: item["lun"]),
    "applicationHealth": health_status, "accelerationInUse": acceleration, "manaInUse": mana_in_use,
    "azureHttpsConnectivity": connectivity,
    "azureVmUtils": vm_utils, "manaDevicePresent": mana_pci,
    "bootId": pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
    "diskCount": sum(item["type"] == "disk" for item in all_devices),
    "swapCount": len(swap_lines), "interfaces": [{"name": n, "driver": d} for n, (d, _, _) in sorted(interfaces.items())][:8],
    "limitations": "No application secrets/configuration dumps; no package changes; idle VF traffic is unknown, not a pass."
}
text = json.dumps(probe, separators=(",", ":"))
if len(text.encode()) > 3700:
    raise RuntimeError("Evidence exceeds Run Command output budget")
print("AZVM_EVIDENCE_BEGIN\n" + text + "\nAZVM_EVIDENCE_END")
PY
