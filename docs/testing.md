# Disposable test deployment and acceptance

**Do not deploy from the example values.** The exact lab scope and results
are recorded in [acceptance](acceptance.md). Other subscriptions, regions,
resources, registration and cleanup require their own concrete approval.
Test scripts are opt-in, never called by offline CI.

**Paid testing is currently suspended following the resize-08 time-bound
breach. The historical commands below are procedures, not permission to run.**

## Bounded lab worker supervision

`tests/integration/Invoke-BoundedLabCycle.ps1` is an opt-in parent for an
exact reviewed lab wrapper, not a deployment generator or spending approval.
It requires distinct paid-wrapper and exact cleanup consent, a fresh result
path, absent exact group, correct subscription, a deadline within four hours
and a 45-minute reserve. The reviewed wrapper still owns image, resources,
identity method, formatting consent, cost and execution gates.

The parent starts the wrapper in a separate PowerShell process and stops
that entire process tree at reserve, even if a Terraform or other child
hangs. In the worker, `AZVM_LAB_WORK_DEADLINE` bounds Azure CLI commands and
pre-mutation checks. `AZVM_LAB_COMMAND_JOURNAL_DIRECTORY` retains command
family, PID, start/deadline/end, exit/failure and available stdout/stderr;
arguments, credentials and script payloads are not logged as command labels.
Treat all resulting stdout/stderr/evidence as sensitive and keep them ignored.
Preparation also checks expiry after evidence collection and refreshes raw
power state immediately before restart; non-running/unknown states refuse,
not implicitly start or retry.

On worker failure/deadline, the parent's finalizer rechecks exact group
name/location/disposable tag and submits only that group's deletion with
`--no-wait`. Command waits and absence polling are bounded by the cleanup
deadline. Independent resource-list absence is required for success.
Unverified cleanup produces an explicit intervention error, never a pass.
If execution resumes after deadline, it records a breach and attempts only
exact cleanup within a 15-minute emergency grace, not renewed lab work.

**A local supervisor cannot guarantee cleanup during host sleep, shutdown,
process termination or loss of cloud access.** Both processes stop executing
when the host suspends. Future paid testing needs an agreed awake/reliable
host and operator cleanup coverage; externally hosted cleanup would require
separate design/scope approval and has not been deployed. No unattended
deadline or hard invoice guarantee is claimed.

Offline regressions run real local child-process success/stall/termination
and the actual supervisor body with mocked cloud ownership/deletion/absence,
including a real stalled worker followed by mocked cleanup. They also cover
cleanup timeout, ownership refusal and overdue-resume behavior. These prove
local control flow, not live Azure deletion deadlines or the complete
same-interface acceptance sequence.

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
Set `os_disk_size_gb` to the approved whole-GiB capacity when the lab has an
explicit disk/cost bound; its default `null` preserves the image default.
Never reduce it below the image's minimum or substitute an image to bypass
the bound. A rejected create must stop and trigger exact-scope cleanup.

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

The initializer emits `AZVM_DISK_IDENTITY_OBSERVATION=` JSON before its
identity assertion, containing the exact IMDS storage profile, expected ARM
disk ID, mapped udev properties/serial and HCTL. Retain the raw Run Command
response even when the guest fails; ARM `ProvisioningState/succeeded` only
means Run Command completed, not that formatting or validation succeeded.
The observation can contain private resource identities and belongs only in
protected, ignored evidence. Missing, malformed, duplicate or mismatched
IMDS identities still stop before formatting. Do not substitute size/order
inference, retry formatting or declare metadata propagation as the cause
without actual response evidence.

The default IMDS prerequisite is an additional toolkit safety policy, not a
Microsoft-required step in ARM-to-guest LUN mapping. The request uses a
documented API version and object endpoint. Resize-07 returned an empty
data-disk array despite confirmed ARM/guest attachment; no documented
freshness guarantee or underlying cause was established. See the
[public-source review](sources.md#imds-request-and-initialization-policy-review-2026-10-11).
The default guard is unchanged. The explicitly approved offline alternative
is described below; earlier lab approvals do not authorize live formatting
with the changed method.

### Explicit synthetic SCSI lab identity mode

`tests/integration/Invoke-LabDiskInitialization.ps1` defaults to
`imds-required`. The alternative `arm-azure-udev` is opt-in, only for a
new empty managed SCSI data disk in an exact tagged disposable lab group.
It requires separate formatting, identity-method and exclusive-window
consent. **Approval to implement this mode offline does not authorize
running the command below.**

```powershell
# Only within a separately approved exact paid/formatting scope:
.\tests\integration\Invoke-LabDiskInitialization.ps1 `
  -VmId '<exact-approved-vm-id>' -DiskId '<exact-new-test-disk-id>' `
  -TestResourceGroup '<approved-azvm-upgrade-lab-group>' `
  -ExpiresAt '<approved-cleanup-reserve-time>' `
  -IdentityMode arm-azure-udev -LiveTestConsent `
  -ArmUdevIdentityConsent -ExclusiveWindowConsent `
  -OutputPath '<protected-ignored-initialization-journal.json>'
```

The harness retains raw account/group/VM/disk/serial observations before
validation, then refreshes ARM attachment and disk ownership after serial
capture. Both reads require exact scoped IDs, disposable tags, `Empty`
creation provenance, one unique LUN0, SCSI, OS-disk exclusion and matching
`managedBy`. Disk `uniqueId` must remain unchanged; it is an ARM resource
incarnation identifier, never a substitute for the captured guest serial.
The protected initialization journal binds the chosen mode, exact resources,
expiry, fresh ARM proof, serial and raw guest response. The guest marker emits
only the ARM proof header and consumed udev properties, not full ARM
resources, to avoid duplicating large payloads in bounded Run Command output;
full ARM observations/proof stay in the protected local journal. A wrapper must also
record its selected mode in its cycle journal before invoking this helper,
then use its existing stop-and-exact-cleanup finalizer on refusal.

The guest checks proof freshness (at most ten minutes, at most 30 seconds
future-clock skew) and unexpired consent bounded to four hours. IMDS is still
queried and retained. An empty `dataDisks` array is allowed **only in the
explicit alternative mode**, with matching IMDS OS identity and valid
ARM proof. Nonempty metadata must corroborate the exact single disk/LUN;
wrong IDs/LUNs, duplicate or extra attachments, conflicting OS identity,
malformed metadata and transport failures remain refusals. No automatic
fallback or metadata retry is added. Microsoft Azure udev data/SCSI/LUN
properties, HCTL, captured serial/lsblk agreement and every existing
OS-ancestry, partition, mount, signature and fstab guard remain mandatory.
The mode does not support production or NVMe initialization. Exclusive
window consent is an operator declaration, not a distributed lock.

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

### Evidence-before-assertion readiness checklist

| Stage | Retention and offline proof | Remaining live gate |
|---|---|---|
| Test initialization | Exact IMDS/udev/expected inputs emitted before refusal; two positive and sixteen refusal fixtures. Raw Run Command must be retained by the caller | Resize-06 actual IMDS response is irrecoverable; fresh independent identity must pass before formatting |
| Guest probes | Optional `Get-VmEvidence -ObservationPath` retains account/model/instance view, raw guest Run Command and assembled evidence before parsing/schema/health rejection; no optional path means existing read-only callers keep their behavior | Real guest completeness, boot, identity and networking |
| Preparation and rollback | Actual harness body mocked through success, rejected reassessment, health, no-op and rollback preservation; raw preparation responses and fresh reassessment/rollback probes retained before validation | Real reboot/rollback/data preservation on the new exact scope |
| Migration | Same-interface state machine mocked through completion without OS capability mutation; gate, ARM poll/async/disk-capability, validation and reconciliation observations persisted before assertions | Allocation, resize health and real unchanged data/network |
| Recovery | Actual same-interface harness body mocked through copied-disk/VM creation, sequential cleanup and original restart; original health, provider/API, snapshot, NIC, restored guest, original restart and cleanup-ownership failures retain observations | Real snapshot provenance/boot/health and original restart |
| Terraform | Six provider-mocked profiles; input plan retained by caller and engine retains reconciliation JSON before rejection | Real normal source/target no-op |
| Exact group teardown | Prior lab failure finalizers independently verified absent groups; recovery offline ordering prohibits original start before marked-resource cleanup | Future paid scope must again prove exact group absence |

The standard suite provides **component control-flow proof**. The optional
runner below additionally executes the unchanged private same-interface
wrapper as one program, in an isolated synthetic checkout with all Azure,
Terraform, guest and nested-harness boundaries mocked:

```powershell
.\scripts\Test-SameInterfaceWrapperOffline.ps1 -WrapperPath '<reviewed-private-wrapper.ps1>'
```

Four separately run tests cover legacy success/refusal and explicit
ARM-mode success/refusal through final no-op or early-stop exact cleanup.
The runner targets the reviewed wrapper's scope declarations and derives its
isolated output directory from the exact `$out=(Resolve-Path ...).Path`
declaration, never a general arbitrary script runner.
The two new tests replace only the reviewed initialization block with the
actual initialization-helper body and explicit mode/journal binding; they
do not claim to run an unchanged future paid wrapper. All cloud/guest
responses remain synthetic. The runner supplies nested preparation/recovery stubs; their actual bodies are
covered separately by the standard tests. No real formatting or deployment
occurs. Empty mocked inventory also exercises explicit inventory-publication
failure without preventing exact cleanup. This is orchestration proof, not
guest or cloud acceptance. CLI transport failures with no response remain
exceptions, not fabricated observations. Offline tests cannot establish Azure
allocation, metadata propagation, billing or production support.
Preparation/recovery observations use protected sidecars alongside their
outputs; engine observations remain in the journal or adjacent sidecars.
Any write failure stops progression and preserves unpublished evidence;
do not turn on mutation replay to compensate. Recovery lock release occurs
even if final result publication fails.

## Local evidence publication failures

JSON evidence is written to a unique same-directory temporary file, flushed
to disk and atomically published: `File.Replace` for an existing destination,
`File.Move` without overwrite for a new one. Toolkit readers share deletion
so a reader can finish reading the old complete snapshot during replacement.
Do not edit evidence in place or permit multiple writers for the same journal.

On Windows only, an existing non-read-only destination blocked by access,
sharing or lock errors gets at most five local publication attempts with
1.5 seconds total backoff and an explicit warning. No cloud or guest operation
is retried. Read-only targets fail immediately; persistent ACL/lock failures
still throw. The last published evidence stays unchanged and the unpublished
same-directory `.tmp` is retained at the path reported in the error. These
files can contain private evidence and must be protected like journals,
never committed. Inspect both files and the original inner exception; do not
rename a pending file into place to claim success or replay a migration
because logging failed. Phase and operation-intent changes are admitted to
the in-memory journal only after publication succeeds.

The resize-05 failure was reproduced in ordinary local temporary storage.
Overwrite-mode `File.Move` failed with an open delete-sharing reader, while
`File.Replace` succeeded. The actual historical handle owner is unknown;
the evidence file's reparse-point attribute alone does not identify OneDrive
as the cause. See [acceptance](acceptance.md) for the retained run boundary.

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
