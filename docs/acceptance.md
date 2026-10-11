# Acceptance record

## Software acceptance

Offline validation passed locally on Windows with PowerShell 7.6.6, Azure CLI
2.83.0, Terraform 1.14.5, Pester 5.7.1 and PSScriptAnalyzer 1.25.0.
AzureRM is pinned to 4.48.0; the provider lock file is committed.

| Check | Actual result |
|---|---|
| PowerShell parsing | All module, customer, guest, fixture and integration scripts passed |
| Configured static analysis | Module, customer, guest and integration scripts passed |
| Decision/orchestration tests | 141 Pester tests passed; no failures, skips or unrun tests. Includes encryption-at-host/security drift, real Run Command response shapes, SCSI LUN identity, built-in/compressed NVMe boot drivers, consent-bound connectivity and restoration evidence/gates. Upstream catalog hashes verified against locally fetched copies |
| Guest script syntax | Bash syntax and embedded Python AST parsing passed; no guest script executed |
| Terraform format/validate | Passed |
| Installed provider schema | Linux/Windows size/controller/host-encryption and NIC acceleration attributes verified |
| Mocked Terraform profiles | Six runs passed: Linux, deployment approval, encryption prerequisite, NAT/private NIC, Windows and SUSE assessment |
| Synthetic customer output | Guide, evidence, plan and CSV generated; incomplete evidence correctly suppresses executable launchers |
| Native Azure CLI adapter | Local version and approved live ARM/Run Command calls verified; all calls explicitly subscription-scoped |

Pester covers schema/hash preservation, unknown/stale evidence, lifecycle
matching, regional and family quota arithmetic, SKU restrictions, target
compatibility, Terraform mapping/replacement/reconciliation, inventory
pagination/denied scopes, optional Advisor gaps/state mapping, bounded health
contracts, ARM operation polling, approval/drift/lock gates, simulated resize
and NVMe transitions, uncertain interruption and safe resume. Actual
post-verification owner acceptance is tested separately, including a run that
stops at `verified` and resumes without repeating mutations.

Reproduce from the repository root:

```powershell
.\scripts\Test-Offline.ps1
.\scripts\New-SyntheticExample.ps1
```

The generated sample is entirely synthetic and goes to ignored
`out/synthetic-example`. Offline Terraform uses mocks, not Azure deployments.
Provider schema does not establish replacement behavior; the pinned provider
source and exact resource plans must also be reviewed as explained in
[Terraform guidance](terraform.md).

## Live observations (2026-10-11, lab removed)

One explicitly approved Sweden Central disposable lab was deployed using
Ubuntu 24.04 Gen2 x64, `Standard_D2as_v5` with encryption at host, one ordinary
Standard SSD OS disk and one 8-GiB data disk. No VM public IP, NAT or Bastion:
Run Command uses explicitly enabled lab-only subnet default outbound access.
The approved target is `Standard_D2as_v6` NVMe. This is AMD, not an assumption
that AMD placement is always available. Poland discovery showed subscription
restrictions; no second-region deployment was attempted. Raw identities,
state and evidence are ignored and are not published.

| Path | Status / required evidence |
|---|---|
| Azure inventory/Advisor cross-check | Not run against a selected subscription; VM-SKU retirement coverage unverified |
| Ubuntu / Windows guest probes and preparation | Ubuntu apply, reboot, fresh reassessment and guest rollback/reboot passed with mount/checksum/health preserved; Windows not run |
| Test disk sentinel initialization | Exact new SCSI LUN0 initialized after ARM attachment + IMDS ID/LUN + Microsoft Azure udev/HCTL/captured-serial checks; UUID mount, checksum and bounded fstab backup recorded |
| Compatible resize and SCSI-to-NVMe | D2as_v5/SCSI to D2as_v6/NVMe completed; actual ARM polling, boot, host encryption, upstream LUN mapping, UUID mounts, checksum and health passed. Validation resumed without repeating mutations after correcting missing NVMe udev ID_BUS |
| Actual MANA / Accelerated Networking | Measured Accelerated Networking VF traffic and bounded HTTPS connectivity passed on source/target; MANA traffic unknown, not claimed |
| Restart and deallocate/start persistence | Preparation and rollback restarts passed; migration deallocate/update/start passed; original deallocated during restore, then restarted and reverified |
| Workload-owner acceptance / recovery exercise | Technical journal reached verified; owner acceptance remains conditional on further configuration testing. Copied OS/data snapshots booted on a sequential private D2as_v5/SCSI VM with host encryption; UUID mounts, checksum, health and HTTPS passed. Failure/correction details below |
| Terraform live reconciliation | Normal target plans before and after recovery have zero resource changes, without ignore_changes or state-file edits; journal completion still requires owner acceptance |
| Exact-scope cleanup | Exact inspected disposable group deleted and absence verified at 13:42:54 UTC; zero retained lab resources; no pre-existing workload was modified |

**The executor remains disposable-lab-only, with no production bypass.**
Neither mocks nor a `ready` assessment establish customer production readiness.
Capacity is unknown even when quota and advertised availability pass.
Advisor retirement coverage is incomplete and eventually consistent; its
optional gaps never authorize or block execution.

The lab existed for 2.133 hours, inside the four-hour window. Conservative
USD 0.20/hour envelope accounting estimates **USD 0.43**, below the USD 3
approval. Delayed monthly telemetry changed from USD 1.6836065 to 1.7112065;
that difference is **not** the final itemized lab bill. Compute/Network
providers and EncryptionAtHost remain registered; they were not silently
unregistered or represented as deleted resources.

## Scope and remaining gates

The exact disposable lab scope, paid deployment, guest initialization,
preparation/reboot, guarded migration, sequential snapshot restoration and
exact-resource cleanup have been approved privately within four hours/USD 3.
This is not permission for customer operations, arbitrary regions, quota
increases or security conversion. New customer/live scopes still require
their own approval. Follow [test guidance](testing.md).

The existing public repository is the approved publication destination.
Commit/push require privacy and provenance checks; raw lab evidence never
belongs in the public repository.

## Preparation limits

Ubuntu's exact approved azure-vm-utils package was already present and left
unchanged; package installation/removal was not exercised live. Windows MANA
artifact installation is operator-supplied and untested. Ubuntu's actual
kernel has built-in NVMe drivers: `modinfo` plus `modules.builtin` verifies
this build, not a generic version assumption. Preparation records bounded
originals and verifies timeout/readiness after reboot. The snapshot restore
exercise is separate from guest rollback and must not be inferred from backup
creation.

### Restoration failures and evidence boundaries

The initial CLI-generated recovery deployment failed because its older Compute
API required `UseStandardSecurityType` for explicit Standard security. No
additional feature was registered. Public documentation and provider discovery
confirmed `2025-11-01`; the exact approved recovery VM was created through that
API using the retained, ownership-verified snapshot copies.

The continuation's checker wrongly required Standard security to serialize
explicitly; Azure returned the same implicit Standard profile as the original,
with host encryption enabled. The captured actual guest/ARM evidence passed
the correct bounded checks: SCSI boot, agent, unchanged mounts/UUID/checksum,
health and HTTPS. Failed outputs remain retained alongside the evidence review,
not overwritten or relabeled successful runs. Recovery deletion also exposed
an eventually consistent resource listing; the harness now uses typed deletes
and bounded absence polling. The revised complete harness has **not** been
rerun from scratch; actual restoration proof was established through the
documented exact-scope continuation.

### Additional evidence required before final owner acceptance

One configuration does not prove a generally reliable migration service.
The smallest next scope is sequential disposable testing, separately approved
and priced: first repeat this exact profile from scratch with the final
preparation/migration/restoration harnesses, then exercise a verified
module-staged Ubuntu profile and same-interface resize, including reboot,
deallocate/start, data/network/health checks, restore and Terraform no-op.
Select the exact image/kernel/SKUs through fresh discovery before approval;
do not assume another Ubuntu release exercises a modular NVMe driver.

| Configuration / gap | Classification |
|---|---|
| Exact Ubuntu 24.04 AMD builtin-driver path | Live observed; repeatability and final full-harness run still needed for conditional owner acceptance |
| Ubuntu 22.04 / module-staged drivers / same-interface resize | Offline implementation only; additional live evidence required |
| Windows Server 2022, signed MANA installation | Offline candidate lab path; operator-supplied artifact and separate Windows live scope required; not a proven supported migration |
| Other Linux distributions / other Windows builds | Assessment-only, outside declared automated support |
| ADE/CMK, temp/complex storage, special placement, Gen1/architecture changes | Hard execution blocks; separate workflows, not implicit test authorization |
| Trusted Launch enablement / application certification | Separate explicit security/workload workflow; not covered by this lab |
| Actual MANA VF traffic / fleet retirement discovery coverage | Unproven; no claim inferred from driver presence or single-VM evidence |

No further paid scope is authorized by conditional acceptance. The journal
must remain `verified`, not `reconciled`, until final owner acceptance is
explicitly supplied.
