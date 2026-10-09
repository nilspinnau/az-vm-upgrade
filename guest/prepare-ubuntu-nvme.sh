#!/usr/bin/env bash
set -euo pipefail
if [ "${AZVM_PREPARE_CONSENT:-}" != "approved-disposable-lab" ]; then
  echo "Explicit guest-change consent is required. See docs/guest-preparation.md." >&2; exit 2
fi
[ "$(id -u)" -eq 0 ] || { echo "Run as root only in the approved lab" >&2; exit 2; }
. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" =~ ^(22\.04|24\.04)$ ]] || { echo "Unsupported preparation profile" >&2; exit 2; }
for entry in /etc/fstab; do
  if grep -Eq '^[[:space:]]*/dev/(sd[a-z]|nvme[0-9])' "$entry"; then
    echo "Unstable mounts require a reviewed persistent-ID correction first" >&2; exit 2
  fi
done
command -v update-initramfs >/dev/null
modinfo nvme >/dev/null
backup=/var/lib/az-vm-upgrade/preparation
mkdir -p "$backup"
if [ ! -e "$backup/original-recorded" ]; then
  cp -a /etc/initramfs-tools/modules "$backup/modules.original"
  if [ -e /etc/modprobe.d/az-vm-upgrade-nvme.conf ]; then
    cp -a /etc/modprobe.d/az-vm-upgrade-nvme.conf "$backup/nvme-conf.original"
  else
    touch "$backup/nvme-conf.was-absent"
  fi
  date -u +%FT%TZ > "$backup/original-recorded"
fi
grep -qxF nvme /etc/initramfs-tools/modules || printf '\nnvme\n' >> /etc/initramfs-tools/modules
grep -qxF nvme_core /etc/initramfs-tools/modules || printf 'nvme_core\n' >> /etc/initramfs-tools/modules
printf 'options nvme_core io_timeout=240\n' > /etc/modprobe.d/az-vm-upgrade-nvme.conf
update-initramfs -u -k "$(uname -r)"
echo "Prepared current kernel only. Reboot under separate approval and reassess. Originals: $backup"
