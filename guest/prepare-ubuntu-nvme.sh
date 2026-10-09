#!/usr/bin/env bash
# Plan-bound Ubuntu 22.04/24.04 guest preparation (apply | rollback | status).
# Values arrive as AZVM_* variables injected by Invoke-GuestPreparation after
# validation. Outputs a bounded manifest between AZVM_PREP_BEGIN/END markers.
# Never resizes, deallocates, reboots, upgrades kernels, rewrites fstab or
# touches temporary disks. NVMe boot-staging follows the reviewed procedure
# class used by Azure/SAP-on-Azure-Scripts-and-Utilities (MIT) but only for
# initramfs module staging, with recorded originals.
set -euo pipefail

ACTION="${AZVM_PREP_ACTION:-}"
PLAN_HASH="${AZVM_PLAN_HASH:-}"
COMPONENTS="${AZVM_COMPONENTS:-}"
UTILS_VERSION="${AZVM_UTILS_VERSION:-}"
STATE=/var/lib/az-vm-upgrade/preparation
CHANGES="$(mktemp)"
trap 'rm -f "$CHANGES"' EXIT
STATUS=ok

[[ "$ACTION" =~ ^(apply|rollback|status)$ ]] || { echo "AZVM_PREP_ACTION must be apply, rollback or status" >&2; exit 2; }
[[ "$PLAN_HASH" =~ ^[0-9a-f]{64}$ ]] || { echo "AZVM_PLAN_HASH is required" >&2; exit 2; }
[[ "$COMPONENTS" =~ ^(nvme-boot|azure-vm-utils|mana-linux-check)(,(nvme-boot|azure-vm-utils|mana-linux-check))*$ ]] || { echo "Invalid AZVM_COMPONENTS" >&2; exit 2; }
if [ "$ACTION" != status ]; then
  [ "${AZVM_PREPARE_CONSENT:-}" = "approved-guest-preparation" ] || { echo "Explicit guest-change consent is required" >&2; exit 2; }
fi
if [ "$ACTION" = rollback ]; then
  [ "${AZVM_ROLLBACK_ACK:-}" = "restored-controller-confirmed" ] || { echo "Rollback requires confirmation that the VM controller/size is compatible" >&2; exit 2; }
fi
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 2; }
. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" =~ ^(22\.04|24\.04)$ && "$(uname -m)" == "x86_64" ]] || { echo "Unsupported preparation profile" >&2; exit 2; }
if [ "$ACTION" = apply ] && grep -Eq '^[[:space:]]*/dev/(sd[a-z]|nvme[0-9])' /etc/fstab; then
  echo "Unstable device-name mounts require a reviewed persistent-ID correction first" >&2; exit 2
fi
mkdir -p "$STATE"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CHANGES"; }
has() { [[ ",$COMPONENTS," == *",$1,"* ]]; }

apply_nvme_boot() {
  command -v update-initramfs >/dev/null || { record nvme-boot initramfs failed "update-initramfs missing"; return 1; }
  modinfo nvme >/dev/null 2>&1 || grep -q '/nvme\.ko' "/lib/modules/$(uname -r)/modules.builtin" || { record nvme-boot nvme-module failed "nvme module unavailable"; return 1; }
  if [ ! -e "$STATE/original-recorded" ]; then
    cp -a /etc/initramfs-tools/modules "$STATE/modules.original"
    if [ -e /etc/modprobe.d/az-vm-upgrade-nvme.conf ]; then cp -a /etc/modprobe.d/az-vm-upgrade-nvme.conf "$STATE/nvme-conf.original"
    else touch "$STATE/nvme-conf.was-absent"; fi
    date -u +%FT%TZ > "$STATE/original-recorded"
  fi
  grep -qxF nvme /etc/initramfs-tools/modules || printf '\nnvme\n' >> /etc/initramfs-tools/modules
  grep -qxF nvme_core /etc/initramfs-tools/modules || printf 'nvme_core\n' >> /etc/initramfs-tools/modules
  printf 'options nvme_core io_timeout=240\n' > /etc/modprobe.d/az-vm-upgrade-nvme.conf
  update-initramfs -u -k "$(uname -r)" >/dev/null
  local image="/boot/initrd.img-$(uname -r)"
  if [ -e "$image" ] && lsinitramfs "$image" | grep -Eq '(^|/)nvme(-core)?\.ko'; then
    record nvme-boot initramfs verified "$(basename "$image") contains nvme; reboot and reassess"
  else
    record nvme-boot initramfs unverified "nvme not visible in rebuilt initramfs"; return 1
  fi
}

rollback_nvme_boot() {
  [ -e "$STATE/original-recorded" ] || { record nvme-boot rollback skipped "no recorded original"; return 0; }
  cp -a "$STATE/modules.original" /etc/initramfs-tools/modules
  if [ -e "$STATE/nvme-conf.original" ]; then cp -a "$STATE/nvme-conf.original" /etc/modprobe.d/az-vm-upgrade-nvme.conf
  else rm -f /etc/modprobe.d/az-vm-upgrade-nvme.conf; fi
  update-initramfs -u -k "$(uname -r)" >/dev/null
  rm -f "$STATE/original-recorded" "$STATE/modules.original" "$STATE/nvme-conf.original" "$STATE/nvme-conf.was-absent"
  record nvme-boot rollback restored "originals restored; initramfs rebuilt for current kernel only"
}

apply_vm_utils() {
  if dpkg -s azure-vm-utils 2>/dev/null | grep -q '^Status: install ok installed'; then
    record azure-vm-utils package present "$(dpkg-query -W -f='${Version}' azure-vm-utils); not modified"; return 0
  fi
  [[ "$UTILS_VERSION" =~ ^[0-9][A-Za-z0-9.+~:-]{1,60}$ ]] || { record azure-vm-utils package failed "exact approved package version required"; return 1; }
  apt-cache madison azure-vm-utils | awk '{print $3 " " $5}' | grep -F "$UTILS_VERSION " | grep -Eq 'ubuntu' ||
    { record azure-vm-utils package failed "approved version is not offered by an Ubuntu archive"; return 1; }
  local sim; sim="$(apt-get install -s --no-install-recommends "azure-vm-utils=$UTILS_VERSION" 2>&1)" ||
    { record azure-vm-utils package failed "installation simulation failed"; return 1; }
  if grep -q '^Remv ' <<<"$sim"; then record azure-vm-utils package failed "simulation would remove packages"; return 1; fi
  local names; names="$(grep '^Inst ' <<<"$sim" | awk '{print $2}')"
  if [ "$(wc -l <<<"$names")" -gt 5 ] || grep -Eq '^(linux-|grub|shim|initramfs|libc6|systemd|udev|openssh|cloud-init|walinuxagent)' <<<"$names"; then
    record azure-vm-utils package failed "simulation touches packages outside the approved bound"; return 1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "azure-vm-utils=$UTILS_VERSION" >/dev/null
  command -v azure-nvme-id >/dev/null && [ "$(dpkg-query -W -f='${Version}' azure-vm-utils)" = "$UTILS_VERSION" ] ||
    { record azure-vm-utils package unverified "installed but not verifiable"; return 1; }
  echo "$UTILS_VERSION" > "$STATE/azure-vm-utils.installed-by-toolkit"
  record azure-vm-utils package installed "$UTILS_VERSION from Ubuntu archive; installs: $(tr '\n' ' ' <<<"$names")"
}

rollback_vm_utils() {
  if [ -e "$STATE/azure-vm-utils.installed-by-toolkit" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y azure-vm-utils >/dev/null
    rm -f "$STATE/azure-vm-utils.installed-by-toolkit"
    record azure-vm-utils rollback removed "package removed (configuration retained)"
  else
    record azure-vm-utils rollback skipped "not installed by this toolkit"
  fi
}

check_mana() {
  if modinfo mana >/dev/null 2>&1 || grep -q '/mana\.ko' "/lib/modules/$(uname -r)/modules.builtin"; then
    record mana-linux-check module present "mana module exists for running kernel; host placement and VF traffic are separate evidence"
  else
    record mana-linux-check module manual-required "mana module not found; kernel change is not automated. Use a distribution-supported Azure kernel after owner review"
  fi
}

if [ "$ACTION" = apply ]; then
  if has nvme-boot; then apply_nvme_boot || STATUS=failed; fi
  if has azure-vm-utils; then apply_vm_utils || STATUS=failed; fi
  if has mana-linux-check; then check_mana; fi
elif [ "$ACTION" = rollback ]; then
  if has azure-vm-utils; then rollback_vm_utils || STATUS=failed; fi
  if has nvme-boot; then rollback_nvme_boot || STATUS=failed; fi
else
  if has mana-linux-check; then check_mana; fi
  if has azure-vm-utils; then
    if dpkg -s azure-vm-utils >/dev/null 2>&1; then record azure-vm-utils package present installed; else record azure-vm-utils package absent "not installed"; fi
  fi
  if has nvme-boot; then
    if [ -e "$STATE/original-recorded" ]; then record nvme-boot initramfs staged "originals recorded"; else record nvme-boot initramfs absent "no toolkit staging"; fi
  fi
fi

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"
export ACTION PLAN_HASH STATUS BOOT_ID CHANGES
python3 - <<'PY'
import datetime, json, os
changes = []
for line in open(os.environ["CHANGES"]).read().splitlines():
    component, item, state, detail = (line.split("\t", 3) + ["", "", "", ""])[:4]
    changes.append({"component": component, "item": item, "state": state, "detail": detail[:300]})
failed = [c for c in changes if c["state"] in ("failed", "unverified")]
status = "failed" if os.environ["STATUS"] != "ok" or failed else "ok"
manifest = {"schemaVersion": "preparation-manifest/1.0", "action": os.environ["ACTION"], "planHash": os.environ["PLAN_HASH"],
            "status": status, "bootId": os.environ["BOOT_ID"], "rebootRequired": os.environ["ACTION"] != "status",
            "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "changes": changes}
print("AZVM_PREP_BEGIN\n" + json.dumps(manifest, separators=(",", ":")) + "\nAZVM_PREP_END")
PY
[ "$STATUS" = ok ]
