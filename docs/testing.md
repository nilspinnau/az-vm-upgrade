# Disposable test deployment and acceptance

**Do not deploy from the example values.** No subscription, region, budget,
downtime, test scope or cleanup approval has been selected for this repository.
Live tests have not run. Test scripts are opt-in, never called by offline CI.

## Deploy only after approvals

`infra/test-vm` creates one VM in a new `azvm-upgrade-lab-*` resource group:

- One Linux, Windows or assessment-only SUSE/SAP-oriented image profile.
- A private NIC, no NIC public IP, and an NSG denying all inbound traffic.
- Explicit outbound-only NAT/public IP for guest agent/Run Command connectivity;
  no implicit subnet outbound access. **NAT and IP have additional cost.**
- Managed OS/data disks, LUN 0 for a checksum sentinel, explicit controller and
  Accelerated Networking. No automatic guest formatting or extension.

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
  -EstimatedHourlyCost '<reviewed-all-in-estimate>' -BudgetLimit '<approved-budget>'
```

Add `-Zone` only when the explicit test zone is approved. The estimate must
include source/target VM, licensing, disks, NAT/IP and data transfer. It is
neither an Azure billing cap nor a request to create a budget/reservation.
Preflight checks publication/quota, not host capacity. Do it immediately
before a separately approved plan/apply.

Copy the example tfvars to an ignored file. Linux uses a supplied public key.
Supply Windows password securely at runtime, for example via an appropriate
secret-backed `TF_VAR_windows_admin_password`, never a committed tfvars.
Set `deployment_approved=true` **only** for the explicitly approved paid test.

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
`properties.uniqueId` through Azure CLI. The pinned AzureRM resource does **not**
export `unique_id`; the toolkit does not invent it or add overlapping AzAPI
ownership to obtain it.

Under separately approved guest/destructive initialization consent, review the
`guest/lab-sentinel-*` scripts and supply exact disk ID/unique ID. They corroborate
IMDS LUN and guest serial, refuse OS/existing/ambiguous disks and write a small
sentinel. If serial mapping is not proved, stop and use a reviewed manual test
initialization procedure. Do not weaken the identity gates.

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
cleanup results. No cleanup command is executed by this toolkit.

## Offline coverage

`scripts/Test-Offline.ps1` parses PowerShell/Bash and embedded Python, runs the configured security/
correctness static rules, Pester decision/orchestration fixtures, exact pinned
provider schema checks, Terraform format/validate and mocked profile tests.
It does not call guest code or Azure. Offline mocks are never labeled live success.

## Preparation live harness (not run)

After separate approval, `tests\integration\Invoke-LabPreparationAcceptance.ps1`
exercises apply, restart, reassessment, optional Terraform no-op evidence and
optional rollback on a disposable VM; see [guest-preparation.md](guest-preparation.md).
Record data-sentinel, mount, connectivity and health results in the output
file. Offline CI never invokes it.
