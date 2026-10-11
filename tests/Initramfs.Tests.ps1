Describe 'Ubuntu initramfs validation' {
    It 'consumes complete listings and requires both compressed driver modules' {
        $scriptPath = Join-Path $PSScriptRoot '..\guest\prepare-ubuntu-nvme.sh'
        $source = Get-Content $scriptPath -Raw
        $block = [regex]::Match($source, '(?s)  local listing\s+(.*?)\n    record nvme-boot initramfs verified').Groups[1].Value
        $block | Should -Not -BeNullOrEmpty
        $block = $block -replace 'if \[ -e "\$image" \] && ', 'if '
        $helper = [regex]::Match($source, '(?s)boot_driver_present\(\) \{.*?\n\}').Value
        $test = @'
set -euo pipefail
HELPER
modinfo() { printf '/lib/modules/synthetic/%s.ko\n' "$3"; }
check() {
  local listing image=synthetic
  REPLACE
    return 0
  else
    return 1
  fi
}
lsinitramfs() {
  printf '%s\n' kernel/drivers/nvme/host/nvme.ko.zst kernel/drivers/nvme/host/nvme-core.ko.zst
  for ((i=0; i<20000; i++)); do printf 'other-module-%s\n' "$i"; done
}
check || exit 1
lsinitramfs() { printf '%s\n' kernel/drivers/nvme/host/nvme.ko; }
if check; then exit 2; fi
lsinitramfs() { return 1; }
if check; then exit 3; fi
echo 'complete compressed listing and two refusal cases passed'
'@
        $test = $test.Replace('REPLACE', $block).Replace('HELPER', $helper)
        $result = $test | bash
        $LASTEXITCODE | Should -Be 0
        $result | Should -Match 'two refusal'
    }
    It 'requires explicit builtin metadata for both NVMe drivers' {
        $source = Get-Content (Join-Path $PSScriptRoot '..\guest\prepare-ubuntu-nvme.sh') -Raw
        $helper = [regex]::Match($source, '(?s)boot_driver_present\(\) \{.*?\n\}').Value
        $test = @'
set -euo pipefail
HELPER
modinfo() { printf '(builtin)\n'; }
grep() {
  if [[ "${3:-}" == */modules.builtin ]]; then
    printf '%s\n' "$BUILTINS" | command grep -E "$2"
  else
    command grep "$@"
  fi
}
BUILTINS=$'kernel/drivers/nvme/host/nvme.ko\nkernel/drivers/nvme/host/nvme-core.ko'
boot_driver_present nvme '' '(^|/)nvme\.ko$'
boot_driver_present nvme_core '' '(^|/)nvme[-_]core\.ko$'
BUILTINS='kernel/drivers/nvme/host/nvme.ko'
if boot_driver_present nvme_core '' '(^|/)nvme[-_]core\.ko$'; then exit 1; fi
echo 'builtin metadata positive and refusal passed'
'@
        $result = $test.Replace('HELPER', $helper) | bash
        $LASTEXITCODE | Should -Be 0
        $result | Should -Match 'positive and refusal'
    }
}
