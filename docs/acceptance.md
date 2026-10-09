# Acceptance record

## Software acceptance

Offline validation passed locally on Windows with PowerShell 7.6.6, Azure CLI
2.83.0, Terraform 1.14.5, Pester 5.7.1 and PSScriptAnalyzer 1.25.0.
AzureRM is pinned to 4.48.0; the provider lock file is committed.

| Check | Actual result |
|---|---|
| PowerShell parsing | All module, customer, guest, fixture and integration scripts passed |
| Configured static analysis | Module, customer, guest and integration scripts passed |
| Decision/orchestration tests | 80 Pester tests passed (12 cover the pinned backend, azure-vm-utils and MANA guidance); no failures, skips or unrun tests. Upstream catalog hashes were also verified against locally fetched copies. No live Azure, guest or backend execution was performed |
| Guest script syntax | Bash syntax and embedded Python AST parsing passed; no guest script executed |
| Terraform format/validate | Passed |
| Installed provider schema | Linux/Windows size/controller and NIC acceleration attributes verified |
| Mocked Terraform profiles | Four runs passed: Linux, deployment-approval gate, Windows and SUSE assessment |
| Synthetic customer output | Guide, evidence, plan and CSV generated; incomplete evidence correctly suppresses executable launchers |
| Native Azure CLI adapter | Local `az version` checked; no subscription/guest command invoked |

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

## Live acceptance: not run

| Path | Status / required evidence |
|---|---|
| Azure inventory/Advisor cross-check | Not run against a selected subscription; VM-SKU retirement coverage unverified |
| Ubuntu / Windows guest probes and preparation | Not run on Azure VMs; driver-store, initramfs and actual device observations unverified |
| Test disk sentinel initialization | Not run; serial/IMDS/unique-ID corroboration must pass before any formatting |
| Compatible resize and SCSI-to-NVMe | Not run; actual ARM headers/ETags, allocation and guest boot remain unverified |
| Actual MANA / Accelerated Networking | Not run; driver availability is not host placement or traffic proof |
| Restart and deallocate/start persistence | Not run; separate opt-in integration runner supplied |
| Workload-owner acceptance / recovery exercise | Not run; approval cannot pre-grant final owner acceptance |
| Terraform live reconciliation | Not run; normal no-op plan required after desired HCL/state reconciliation |
| Exact-scope cleanup | Not run; no cloud resources were created by this work |

**The executor remains disposable-lab-only, with no production bypass.**
Neither mocks nor a `ready` assessment establish customer production readiness.
Capacity is unknown even when quota and advertised availability pass.
Advisor retirement coverage is incomplete and eventually consistent; its
optional gaps never authorize or block execution.

## Remaining authorization gates

Before live tests, select an exact tenant/subscription, region/zone, disposable
resource group, concrete image versions, source/target sizes, approved budget
and protection procedure. Obtain separate guest, paid-deployment, disruption,
exclusive-window and recovery-exercise consent. Cleanup needs its own exact
scope and approval. Follow [test guidance](testing.md).

GitHub publication is separate: confirm the intended personal owner and
visibility before creating a remote repository or pushing. The software local
commit is authorized; no remote creation or publication was performed.
