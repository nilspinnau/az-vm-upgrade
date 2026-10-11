# Disposable test deployment and acceptance

**Do not deploy from the example values.** The exact lab scope and results
are recorded in [acceptance](acceptance.md). Other subscriptions, regions,
resources, registration and cleanup require their own concrete approval.
Test scripts are opt-in, never called by offline CI.

## Deploy only after approvals

`infra/test-vm` creates one VM in a new `azvm-upgrade-lab-*` resource group:

- One Linux, Windows or assessment-only SUSE/SAP-oriented image profile.
- A NIC without a public IP and an NSG denying all inbound traffic
  (including VNet inbound); no SSH/RDP. Guest access is via Run Command.
- Explicit `egress_mode`: `none` is the safe default; `default` deliberately
  sets subnet `default_outbound_access_enabled=true` for an approved low-cost
  disposable lab; `nat` creates a separately priced NAT Gateway/public IP.
  The NAT IP is never attached to the VM. No Bastion.
- Managed OS/data disks, LUN 0 for a checksum sentinel, explicit controller and
  Accelerated Networking and encryption at host enabled by default.
  No automatic guest formatting or extension.

Parameters cover subscription, location, zone, source/target size, concrete
Gen2 image, optional Marketplace purchase plan and data-disk layout. Choose
temporary-storage source/target sizes only for **assessment**, not the executable
paths in this release. Temporary-disk formatting is always off.

Validate exact images at runtime. Examples of profile intent, not verified URNs:
Canonical Ubuntu Jammy Gen2, Microsoft Windows Server 2022 Gen2, and a supported
SUSE SLES-for-SAP Gen2 offer. Query the actual publisher/offers/SKUs/versions in
the approved region, confirm image plan/terms/licensing and pin a concrete
version. Never accept Marketplace terms automatically. SUSE is assessment-only.

Preflight is read-only:

```powershell
.\scripts\Test-TestVmPreflight.ps1 -SubscriptionId '<approved-subscription>' `
  -Location '<approved-region>' -SourceSize '<source>' -TargetSize '<target>' `
  -ImageUrn '<publisher:offer:sku:concrete-version>' `
  -EstimatedHourlyCost '<reviewed-all-in-estimate>' -BudgetLimit '<approved-budget>' `
  -MonthlyBudgetLimit '<approved-monthly-ceiling>' -CostSafetyReserve 25
```

Add `-Zone` only when the explicit test zone is approved. The estimate must
include source/target VM, licensing, disks, snapshots/restore disks, IP,
transactions and data transfer. It is
neither an Azure billing cap nor a request to create a budget/reservation.
Preflight reads USD month-to-date actual pretax cost, subtracts the safety
reserve and rejects a lab budget exceeding reported remaining headroom. It
rejects missing cost totals, unregistered Compute/Network providers and
EncryptionAtHost feature, or missing source/target support. The reserve is not
a proof of current spend: telemetry is delayed, taxes/other usage may apply.
Empty quota responses are unknown, never unlimited. Do not increase quota
or register features/providers automatically.
Preflight checks publication/quota, not host capacity. Do it immediately
before a separately approved plan/apply.

For approved Linux connectivity/VF tests, `Get-VmEvidence` and
`New-VmUpgradePlan.ps1` accept `-GuestNetworkProbeConsent` alongside
`-GuestConsent`. This performs one bounded unauthenticated HTTPS HEAD request
to the fixed Azure ARM endpoint while observing actual interface counters.
Set `guestNetworkProbeConsent=true` in the reviewed workload contract to bind
the same test to execution/post-verification. HTTP error responses prove
endpoint reachability, not authentication or service success. TLS/network
failures are reported as failed; no traffic consent means unknown, not pass.
No credentials or customer identifiers are sent by this connectivity test.

Copy the example tfvars to an ignored file. Linux uses a supplied public key.
Supply Windows password securely at runtime, for example via an appropriate
secret-backed `TF_VAR_windows_admin_password`, never a committed tfvars.
Set `deployment_approved=true` **only** for the explicitly approved paid test.
Set `encryption_at_host_prerequisites_verified=true` only after Registered
feature evidence, both SKU capabilities and a fresh non-ADE image/platform-key
disk layout are verified. No encryption disable is an acceptable fallback.

For workspaces with a separate Azure CLI session directory, set
`$env:AZURE_CONFIG_DIR` in the process running the CLI/Terraform. A working
directory alone does not select that session. Never copy token caches or
credential files into this repository; repository `.azure/deployment-plan.md`
is separate from the external CLI configuration directory. Every toolkit
cloud command is explicitly subscription-scoped.

For this project's local test session, the intended CLI directory is
`projects\.azure`, not `projects\personal\az-vm-upgrade\.azure` and not the
home-directory default. Set the projects-root path explicitly in every new
process before checking the approved subscription:

```powershell
$ProjectsRoot = (Resolve-Path '..\..').Path # From this repository's local checkout
$env:AZURE_CONFIG_DIR = Join-Path $ProjectsRoot '.azure'
az account show --subscription '<approved-subscription-id>'
```

An authentication error from a different config directory does not establish
that the intended session is signed out. Verify the path first; do not copy
credentials or initiate a new login to compensate for a wrong path.

```powershell
terraform -chdir=infra\test-vm init
terraform -chdir=infra\test-vm plan -var-file='<approved-ignored-tfvars>' -out='<ignored-plan>'
# Only after approval of that exact paid plan:
terraform -chdir=infra\test-vm apply '<ignored-plan>'
```

The module's cost/approval preconditions fail closed. It does not register
providers or use any permanent ignore_changes. Retain state in an approved
secure location. OS disks are not silently deleted by the VM-delete provider
setting; inspect retained resources during exact-scope cleanup.

## Initialize and protect test data

Record `vm_id` and `data_disk_id` from Terraform, then read the disk's ARM
attachment, `properties.uniqueId`, creation provenance and disposable tags.
`uniqueId` identifies the ARM resource for drift checks; it is **not** the
guest SCSI NAA serial. The pinned AzureRM resource does not export it.

Under separately approved guest/destructive initialization consent, review the
`guest/lab-sentinel-linux.sh` and supply `AZVM_EXPECTED_DISK_ID` plus
`AZVM_EXPECTED_SCSI_SERIAL` from a read-only `udevadm info` capture of
`/dev/disk/azure/scsi1/lun0`. Before invocation, corroborate the exact new
disposable disk in the current VM ARM attachment at unique LUN 0. The script
checks exact IMDS ID/unique LUN, Azure udev `data`/SCSI/LUN properties, HCTL,
unchanged captured serial and lsblk agreement. It refuses OS ancestry,
partitions, mounts, existing signatures, nonempty mount directories and existing
fstab entries/backups. It records a bounded fstab backup before initialization.
It initializes only the approved **SCSI** test disk, not an NVMe/local disk.
After migration, use Microsoft's `azure-nvme-id` and
`/dev/disk/azure/data/by-lun/0` mapping to verify the same persistent filesystem
UUID and checksum; never assume the SCSI/NVMe serial schemes are interchangeable.
Windows identity mapping remains unverified/manual; do not use ARM uniqueId as
a Windows serial or infer disk identity from number/size/model.

Record the managed-data checksum, application health and accepted backup or
documented recovery method before any upgrade. Resolve driver/boot/mount
readiness and reboot under explicit approval before planning.

## Acceptance sequence

Assess and review a source VM, select a compatible target explicitly and follow
the plan/approval/execution flow. Then prove:

| Check | Required evidence |
|---|---|
| Compatible resize | Complete Azure operation, desired model and healthy guest |
| NVMe transition | Gen2/source suitability, staged boot driver, actual guest NVMe boot/controller |
| Managed data | Persistent disk identities/mounts and unchanged checksum |
| Networking | Retained AN configuration, driver capability, incrementing VF traffic; actual MANA when required |
| Applications | Sentinel/approved bounded endpoint checks and post-verification owner acceptance |
| Persistence | Restart plus deallocate/start checks, not just immediate conversion |
| Recovery | Separately approved operator rollback/restore exercise with actual results |
| Terraform | Desired HCL aligned, supported refresh/reconciliation, normal plan without unintended change/replacement |
| Encryption at host | Enabled property preserved, both SKU capabilities and Registered feature, platform-key disks; recovered VM explicitly enables the property (snapshot contents alone do not prove host encryption) |

After a technically verified upgrade, run lifecycle cycles only with a **new
exact test context** binding the original plan hash and separately approved
restart/deallocate-start operations:

```powershell
.\tests\integration\Invoke-LabAcceptance.ps1 -PlanPath '.\out\vm-plan\plan.json' `
  -TestContextPath '.\out\live-test-context.json' -LiveTestConsent
```

This script makes real disruptive Azure calls. It checks tagged lab identity,
fresh restrictions/quota, guest data/network/application health and writes
`live-acceptance.json`. `cycles-verified` is not production support and does not
claim operator recovery or post-cycle Terraform reconciliation.
The context must attest to an exclusive maintenance window. Use the same
`-JournalDirectory` as the upgrade engine so its local per-VM lock is shared.
Configuration is compared across cycles without volatile ETags; an existing
test output is never overwritten. No multi-host distributed lock is claimed.

## Cleanup is a separate destructive approval

Record the exact test resource group and inspect its resources first. Obtain
approval of that scope before Terraform destroy or resource-group deletion.
Do not use a customer workload group, wildcards, automatic cleanup or delete a
VM to make rollback allocation succeed. Record retained disks and actual
cleanup results. The migration engine never deletes resources. The separately
consented restoration harness removes only its exact ownership-marked recovery
resources; final lab-group teardown remains an operator action.

## Offline coverage

`scripts/Test-Offline.ps1` parses PowerShell/Bash and embedded Python, runs the configured security/
correctness static rules, Pester decision/orchestration fixtures, exact pinned
provider schema checks, Terraform format/validate and mocked profile tests.
It does not call guest code or Azure. Offline mocks are never labeled live success.

## Preparation live harness

After separate approval, `tests\integration\Invoke-LabPreparationAcceptance.ps1`
exercises apply, restart, reassessment, optional normal Terraform plan JSON and
optional rollback plus another reboot and fresh mount/data/health evidence on
a disposable VM; see [guest-preparation.md](guest-preparation.md).
Supply `terraformVmAddress` in the context for normal-plan verification; a
`status: no-op` attestation alone is rejected. The preparation request must
contain the pre-initialized lab checksum and health baseline.
Record data-sentinel, mount, connectivity and health results in the output
file. Offline CI never invokes it.

## Sequential VM restoration harness

`tests\integration\Invoke-LabRestoreAcceptance.ps1` consumes an exact original
plan and a separately approved context containing `planHash`, `vmId`,
`testResourceGroup`, `expiresAt`, `osSnapshotId`, `dataSnapshotId`, and exact
`vmName`, `nicName`, `osDiskName`, `dataDiskName`. All consent flags must be
true: `labOnly`, `guestConsent`, `exclusiveWindow`, `deallocateApproved`,
`recoveryCreateApproved`, `cleanupApproved`, `restartApproved`. Provide
`-LiveTestConsent`. It refuses pre-existing target resources and an incomplete
upgrade journal; use the same journal directory/VM lock as the upgrade.

Only the bounded Standard-security, host-encrypted, one-data-disk Linux lab
is supported. It verifies exact snapshot source provenance, source-SKU quota
and encryption support, deallocates the original, creates two Standard SSD
snapshot copies and one private recovery NIC/VM, then checks real restored
boot, UUID mounts, checksum, health and Azure HTTPS connectivity. It explicitly
enables encryption at host on the recovered VM; snapshots do not preserve
that VM-level property by themselves. Explicit Standard security uses the
documented Compute `2025-11-01` API through Azure CLI REST; its availability
is required before disruption. Older CLI-generated create templates can
require `UseStandardSecurityType`; the harness does not register it or change
security to work around that failure. Restoration uses existing Azure CLI
interfaces, not a second migration engine or an automatic production rollback.

The result records exact targets and a context ownership hash before mutations.
Its finalizer deletes only exact recovery targets with the matching ownership
tag, verifies their absence, then restarts and rechecks the original. Any
uncertain create/delete/start is a failure requiring inspection, not a silent
success or automatic replay. Snapshots remain for the separately approved
exact-RG teardown. A successful synthetic restore is not application-consistent
backup certification or a guarantee of original-SKU capacity for a customer.
