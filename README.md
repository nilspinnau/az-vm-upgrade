# Azure VM upgrade toolkit

Evidence-led inventory, readiness assessment, customer guides and **one-VM-at-a-time**
upgrade orchestration. PowerShell 7.5+, Azure CLI and a pinned Terraform test
deployment. No service, database or permanent guest extension is installed by
the toolkit.

**Release boundary:** assessment can cover standalone Linux/Windows VMs, but
the execution engine is **disposable-lab-only**. Exact live lab results are
recorded in [acceptance](docs/acceptance.md). A `ready` plan means collected checks passed,
not that the workload is production-certified or capacity is guaranteed.
There is no production bypass flag. See [support matrix](docs/support-matrix.md).

## What it delivers

| Surface | Result |
|---|---|
| Discovery | Scoped, paginated Resource Graph inventory, exact lifecycle matching, NIC/disk/placement queries, explicit denied/failed coverage |
| Optional Advisor cross-check | Microsoft's retirement recommendations and metadata; SKU-only/Advisor-only gaps, independent of execution readiness |
| Evidence | Fresh ARM VM/instance/disk/NIC/SKU/quota reads and explicitly consented, bounded Linux/Windows guest probes |
| Planning | Explicit target or ranked metadata-compatible candidates; separate quota, capacity, guest capability and actual hardware use |
| Capacity reservations | Read-only associated group/member/runtime discovery and exact target-size/region/zone/unit assessment; actionable blockers, never automatic purchase/detachment/quantity changes |
| Customer outputs | JSON evidence/plan, CSV inventory, Markdown guide and safe launchers for ready **lab** plans only |
| Execution | Exact plan-bound approval, protection, drift/concurrency gates, minimal PATCHes, Azure operation polling, durable journal, post-start validation |
| Recovery | Conservative resume and recovery guide; no automatic destructive restore, VM deletion or disk formatting |
| Guest preparation | Native plan-bound NVMe boot staging, exact Ubuntu azure-vm-utils channel, MANA detection/operator-supplied Windows artifact, separate reboot and rollback consent |
| Terraform | One private test VM, managed data disk, Linux/Windows/SUSE assessment profiles, exact mapping/replacement/no-op reconciliation checks |

The executor changes only VM size/controller and, when necessary, the OS disk's
supported controller capability. It does not silently change zone, region,
architecture, generation, security, image, disk tier or NIC configuration.
Existing encryption at host is preserved on compatible bounded profiles;
ADE/CMK/complex security layouts remain explicit exclusions. Optional Trusted
Launch assessment is separate, never a hidden part of a SKU migration.
Disposable integration harnesses can initialize an exact new lab data disk and
exercise sequential snapshot restoration only under their own explicit scope.
Both **SCSI-to-SCSI (non-NVMe target)** and SCSI-to-NVMe lab orchestration are
implemented. SCSI-to-SCSI is native **size-only resize**, not a conversion:
no NVMe boot staging, driver/package installation, controller PATCH or OS disk
capability change. Plans distinguish current-cluster resize options from
deallocation/reassessment; the executor retains explicit cold-resize downtime
consent and verifies guest runtime size/CPUs, not just ARM desired size.
Same-interface full-cycle live acceptance remains
unproven; paid tests remain suspended after the documented deadline breach.
See [capacity reservations and removal choices](docs/planning.md#capacity-reservations).

## Start with assessment

From the repository root in PowerShell:

```powershell
.\scripts\Get-VmInventory.ps1 -SubscriptionId '<subscription-id>' `
  -OutputDirectory '.\out\inventory'

.\scripts\New-VmUpgradePlan.ps1 -VmId '<one-VM-ARM-ID>' `
  -TargetSize 'Standard_D2s_v6' -Controller NVMe `
  -OutputDirectory '.\out\vm-plan'

# Same-controller migration to a non-NVMe target; select a real compatible SKU:
.\scripts\New-VmUpgradePlan.ps1 -VmId '<one-VM-ARM-ID>' `
  -TargetSize '<approved-SCSI-capable-target-size>' -Controller SCSI `
  -OutputDirectory '.\out\scsi-plan'
```

The second command **does not invoke guest code** by default. Missing evidence
is reported as unknown; it does not become a pass. Add `-GuestConsent` only
after the resource owner approves guest Run Command. Supply a reviewed workload
contract and any Terraform mapping/plan as described in [quickstart](docs/quickstart.md).
The sample size is illustrative, not a globally available recommendation.

```powershell
.\scripts\Get-VmInventory.ps1 -SubscriptionId '<subscription-id>' `
  -AdvisorCrossCheck -OutputDirectory '.\out\inventory'
```

Advisor is a cross-check, not a complete VM-SKU retirement authority.
See [discovery and coverage](docs/discovery.md).

## Local checks

Install external validation dependencies if missing:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
.\scripts\Test-Offline.ps1
```

Terraform 1.7+, Bash and Python 3 are also required for the full offline check. AzureRM is
pinned to **4.48.0** with a committed dependency lock. The Terraform tests use a
mock provider: **they do not create Azure resources**. CI has no cloud credentials.
To omit Terraform checks, use `-SkipTerraform`; guest syntax checks still require Bash and Python.

## Guides

- [Quickstart and approval flow](docs/quickstart.md)
- [Optional pinned NVMe backend, azure-vm-utils, MANA](docs/nvme-backend.md)
- [Permissions and privacy](docs/permissions.md)
- [Discovery, lifecycle and Advisor coverage](docs/discovery.md)
- [Target compatibility and quota arithmetic](docs/planning.md)
- [Guest preparation: plan-bound NVMe/azure-vm-utils/MANA preparation, reboot gate, recovery](docs/guest-preparation.md)
- [Execution, acceptance and recovery](docs/execution-recovery.md)
- [Terraform ownership and reconciliation](docs/terraform.md)
- [Disposable test environment and live acceptance](docs/testing.md)
- [Actual acceptance results and remaining gates](docs/acceptance.md)
- [Verified sources and redistribution](docs/sources.md)

All credentials, live evidence, logs, state, plans and customer exports belong
under an access-controlled ignored output location, never in Git. Example IDs
and test data are synthetic. Software is supplied under [MIT](LICENSE), as-is,
not as an official Microsoft supported product.
