# Acceptance record

## Software acceptance

Offline validation passed locally on Windows with PowerShell 7.6.6, Azure CLI
2.83.0, Terraform 1.14.5, Pester 5.7.1 and PSScriptAnalyzer 1.25.0.
AzureRM is pinned to 4.48.0; the provider lock file is committed.

| Check | Actual result |
|---|---|
| PowerShell parsing | All module, customer, guest, fixture and integration scripts passed |
| Configured static analysis | Module, customer, guest and integration scripts passed |
| Decision/orchestration tests | 168 Pester tests passed; no failures, skips or unrun tests. Includes atomic create/replace, transient/persistent reader locks, read-only failures, unchanged journal phase/intent on publication failure, encryption-at-host/security drift, real Run Command response shapes, SCSI LUN identity, built-in/compressed NVMe boot drivers, consent-bound connectivity, restoration evidence/gates, rejected-validation evidence persistence, and exact live-support catalog scope. Upstream catalog hashes verified against locally fetched copies |
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

## Earlier live observations (2026-10-11, original lab removed)

The first explicitly approved Sweden Central disposable lab was deployed using
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

The repository is public; privacy and provenance checks apply to every
publication. Raw lab evidence never belongs in the public repository. Later
approved runs and their separate evidence are recorded below.

## Preparation limits

Ubuntu's exact approved azure-vm-utils package was already present and left
unchanged; package installation/removal was not exercised live. Windows MANA
artifact installation is operator-supplied and untested. Ubuntu's actual
kernel has built-in NVMe drivers: `modinfo` plus `modules.builtin` verifies
this build, not a generic version assumption. Preparation records bounded
originals and verifies timeout/readiness after reboot. The snapshot restore
exercise is separate from guest rollback and must not be inferred from backup
creation.

### Historical restoration failures and evidence boundaries

The initial failures below describe the first recovery-harness attempts; the
corrected complete harness subsequently passed in the approved diag-04 run.

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
and bounded absence polling. At that time the revised complete harness had
not been rerun; its fresh end-to-end result is recorded in the diag-04 section.

### Evidence still required before final owner acceptance

The exact Ubuntu 24.04 AMD profile has now passed a fresh complete corrected
harness run. Together with the earlier verified migration, this is repeat
evidence for one profile, not broad configuration coverage; it also does not
make the historical repeat's missing failure observation diagnosable. Any
additional paid test requires a separate exact scope and user approval. A
module-staged Ubuntu image still needs exact publisher/package/kernel source
evidence before it is a viable candidate; do not assume another release
exercises a modular NVMe driver. Windows and other configurations likewise
need separately scoped evidence before support claims expand.

| Configuration / gap | Classification |
|---|---|
| Exact Ubuntu 24.04 AMD builtin-driver path | Two successful live migrations observed; one fresh corrected full-cycle preparation/migration/restore run passed. One intervening repeat failed health validation without retaining the failed observation. Owner acceptance remains conditional |
| Ubuntu 22.04 / module-staged drivers / same-interface resize | Offline implementation only; additional live evidence required. The exact Ubuntu 24.04 live profile covers D2as_v5/SCSI to D2as_v6/NVMe only, not same-interface resize |
| Windows Server 2022, signed MANA installation | Offline candidate lab path; operator-supplied artifact and separate Windows live scope required; not a proven supported migration |
| Other Linux distributions / other Windows builds | Assessment-only, outside declared automated support |
| ADE/CMK, temp/complex storage, special placement, Gen1/architecture changes | Hard execution blocks; separate workflows, not implicit test authorization |
| Trusted Launch enablement / application certification | Separate explicit security/workload workflow; not covered by this lab |
| Actual MANA VF traffic / fleet retirement discovery coverage | Unproven; no claim inferred from driver presence or single-VM evidence |

Conditional acceptance alone does not authorize paid scope. The earlier journal
must remain `verified`, not `reconciled`, until final owner acceptance is
explicitly supplied.

## Approved sequential follow-up (2026-10-11)

The owner separately approved one final-harness repeat and one exact Ubuntu
22.04 module-staged candidate, sequentially in Sweden Central, within a new
USD 3/four-hour window and an absolute 18:00 UTC teardown deadline. Neither
approval constitutes final workload-owner acceptance.

| Follow-up | Actual result |
|---|---|
| Ubuntu 24.04 repeat | Final preparation harness passed apply, reboot, fresh reassessment, checksum/health, real source Terraform no-op and rollback/reboot. Guarded D2as_v5/SCSI to D2as_v6/NVMe reached `started`, then failed instance-health validation. No verification/restore success claimed |
| Repeat failure evidence | Last successful start evidence was healthy, but the subsequent failing observation was not retained by the previous engine. Exact Azure condition cannot be determined retrospectively. Executor now persists validation evidence before assertions and includes observed status codes in health errors, without advancing phase/fingerprint |
| Repeat cleanup | Failure finalizer removed the exact repeat group and verified absence before the next deployment |
| Ubuntu 22.04 candidate | Exact pinned image `Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202608060` booted kernel `6.8.0-1064-azure`; both NVMe drivers reported `(builtin)`. The mandatory module-staged gate failed; no initialization, preparation or resize was attempted |
| Follow-up cleanup/cost | Both exact groups absent with zero retained resources, verified at 15:11:26 UTC. Elapsed 1.264 hours; conservative USD 0.32 envelope estimate below the USD 3 cap. Final itemized bill unknown; delayed telemetry is not a real-time total |
| Final corrected restore harness repeat | Passed in the later approved diag-04 fresh run; the earlier failed repeat still has no recoverable failure snapshot |

No kernel upgrade, image substitution, hidden retry of mutation, security
change, registration or quota increase was used to force a successful result.
The earlier verified lab journal remains `verified`; the failed repeat remains
`started`. The later diag-04 journal is also `verified`. None is accepted or
reconciled on the owner's behalf.

The diagnostic-only scope below completed a clean fresh run of the corrected
full harness for this exact pinned Ubuntu 24.04 AMD profile. It does not
retrospectively explain the previous failed repeat because its failing
observation was not captured.

## Approved diagnostic repeat (2026-10-11, exact diag-04 scope)

The owner separately approved one Sweden Central repeat in
`azvm-upgrade-lab-20261011-diag-04`, capped at USD 2 and four hours from
first create, with an absolute 20:00 UTC deadline and a 45-minute cleanup
reserve. The exact pinned Ubuntu 24.04 Gen2 image, D2as_v5/SCSI to D2as_v6/
NVMe, host encryption, private network, no public IP/NAT/Bastion, one
synthetic data disk and exact-group cleanup were used. No quota changes,
registrations, substitutions or module-profile tests were made.

| Path | Actual result |
|---|---|
| Fresh gates | Sweden regional/DASv5/Dav6 quota 100/0; selected sizes unrestricted; exact Gen2 image Active; host-encryption feature/provider, cost and inherited policy checks passed. Quota is not a capacity guarantee |
| Disk identity and initialization | Passed. ARM exact attachment and disk ownership, IMDS LUN, Microsoft Azure SCSI udev mapping and captured serial independently identified only the newly created empty disposable LUN0 before initialization |
| Preparation, reboot, reassessment | Passed. Ubuntu 24.04 NVMe preparation applied; reboot and fresh assessment accepted; data checksum, persistent mount and health sentinel passed |
| Guest rollback | Passed. Toolkit-owned bounded changes were restored; rollback reboot and fresh boot/data/mount/health evidence passed. This does not prove restoration of arbitrary guest changes |
| Source Terraform plan | Real normal source plan was no-op before migration |
| Migration and health diagnostic | D2as_v5/SCSI to D2as_v6/NVMe completed. This repeat's post-start instance view explicitly reported `ProvisioningState/succeeded` and `PowerState/running`; guest NVMe boot, agent, mounts, checksum, application health and approved HTTPS probe passed. The earlier repeat's absent failure snapshot remains unknowable, not retroactively diagnosed |
| Snapshot restore | Two LRS snapshots and exact copied disks were used sequentially. The original was deallocated while a private host-encrypted D2as_v5/SCSI recovery VM booted; mounted data/checksum and health passed. Recovery resources were removed; original target VM restarted and reverified. This is not application-consistent backup certification or guaranteed future SKU allocation |
| Final Terraform plan | Real normal target plan after restore had zero changes; no ignore_changes or state manipulation |
| Cleanup and cost | Exact diag-04 group absent; zero residual resources. Elapsed 1.576 hours, conservative USD 0.25/hour envelope USD 0.394. Delayed subscription month-to-date telemetry moved from USD 1.7112065 to USD 1.8906065 (USD 0.1794 delta); attribution is not isolated, and this is not a final itemized bill or hard-stop meter |

The diagnostic migration journal is `verified`, not owner-accepted or
`reconciled`. Conditional acceptance still requires different supported
configurations and owner review. The module-staged Ubuntu path remains blocked:
the tested Jammy candidate had built-in NVMe drivers, and no pinned,
publisher-source-qualified modular candidate is known. Windows, other Linux
builds, complex storage, Trusted Launch conversion, Gen1/architecture
conversion and application certification remain unproven or separate
workflows. No production promotion is implied.

## Approved same-interface attempt (resize-05, 2026-10-11 UTC)

The separately approved Sweden Central lab used the pinned image
`Canonical:ubuntu-24_04-lts:server:24.04.202609040`, D2as_v5/SCSI with
D4as_v5/SCSI intended, host encryption, Standard security, a bounded 64-GiB
OS disk and exactly one 8-GiB synthetic data disk. Private networking, no
public IP/NAT/Bastion, at most two snapshots/two restored disks and sequential
recovery were approved within USD 2/four hours, with a 45-minute cleanup
reserve. Approval did not authorize recreation after failure.

| Gate | Retained result |
|---|---|
| Fresh subscription/image/quota/feature/price/permissions and saved Terraform plan | Passed; exactly nine creates, no updates/deletes, approved private topology |
| Deployment and exact test-disk identity/initialization | Passed |
| Source Terraform plan | Retained normal source plan JSON has zero non-no-op changes, generated before the preparation harness |
| Preparation | Apply (two changes), restart, accepted fresh reassessment and checksum/mount/health passed |
| Preparation-result publication | Failed with `Exception calling "Move" with "3" argument(s): "Access to the path is denied."` at the per-step `Write-UpgradeJson` call for `resize-prep-acceptance.json`. The last persisted steps end at managed-data-and-health. The next code step is Terraform no-op validation/publication; its pass is not durably recorded |
| Rollback, resize, snapshots, restore, original restart, target Terraform no-op | Not completed or claimed; the run stopped before these gates |
| Cleanup | Exact owned group deleted; independent existence check returned false and residual-resource count was zero |

The run window was 21:30:03Z to 21:50:14Z, **0.336301 hours**. For the actual
one-source-VM/two-disk sequence, conservatively rounding to one billed hour:
compute USD 0.092; disk capacity USD 0.007397
(`(4.8 + 0.6) / 730`); bounded transaction estimate USD 0.024596
(`(81,200 + 13,400) / 10,000 * 0.0026`); subtotal **USD 0.123993**.
Retaining the packet's USD 0.50 network/metering reserve gives
**USD 0.623993**, below USD 2 as a model, not an invoice or hard billing cap.
No recovery compute, snapshots or restored disks were created. Final retained
month-to-date telemetry remained USD 1.92628324367656, unchanged from
preflight; it is delayed and does not isolate this lab. Taxes, concurrent
subscription use and unmetered/delayed network or transaction variation are
not proven by this estimate.

### Diagnosed software issue and remaining live proof

The original failure files and exception remain private and unchanged.
Offline Windows reproduction outside the synced checkout proved that
overwrite-mode `File.Move` can return the same access-denied exception while
a reader holds the destination, including a delete-sharing reader.
`File.Replace` succeeded with that delete-sharing reader. Existing ACLs
allowed full control and the historical destination was not read-only;
its reparse-point metadata does not identify the cause. No handle-owner
capture exists from the failure, so actual reader/process, provider or
transient ACL involvement remains unknown.

The corrected shared helper flushes a unique same-directory file, atomically
replaces existing evidence, permits delete-sharing readers and bounds
transient Windows publication retries without retrying mutations. Persistent
failure throws with the original inner exception and retained unpublished
evidence. Journal phase and operation intent stay unchanged on write failure.
Seven offline regressions exercise creation/replacement, held-reader
compatibility, transient release, persistent lock, read-only refusal and
failed phase/intent publication. This is software proof, not a rerun of
resize-05.

The minimum remaining same-interface live proof is a **new separately
approved** run of this exact full sequence: fresh gates and absent group;
bounded 64-GiB OS/8-GiB data deployment; identity initialization;
preparation/reboot/reassessment/rollback/reboot; source no-op; D2as_v5/SCSI
to D4as_v5/SCSI with data/health/HTTPS/VF evidence; exactly two snapshots,
two restored disks and one sequential private source-size recovery VM;
recovery cleanup, original restart, normal target no-op, then exact-group
deletion and independent absence verification. Refresh prices and the USD 2
projection, choose a new explicit group/deadline, preserve the four-hour
maximum/45-minute cleanup reserve and stop/clean up on any gate failure.
The previous USD 1.811439 full-sequence envelope is not a fresh price gate or
permission to create resources.

No owner-accepted production path exists. The already observed exact Ubuntu
24.04 AMD builtin-driver SCSI-to-NVMe disposable path remains the only
live-observed migration boundary. Same-interface, Windows, module-staged
drivers and other distributions are not promoted; no modular image is
publisher-source-qualified.

## Approved resize-06 attempt (2026-10-11 UTC)

The owner approved a new exact same-interface scope with the same pinned
Ubuntu image, Sweden Central/no zone, D2as_v5/SCSI to D4as_v5/SCSI,
Standard security/host encryption, 64-GiB OS and one 8-GiB LUN0 disk,
private topology and bounded sequential recovery. USD 2/four hours and
exact cleanup were approved; the user monthly ceiling was **USD 500**,
not the subscription's separate budget.

Fresh preflight, quota/image/features/permissions, unchanged inherited
policy review, prices and a new isolated nine-create plan passed using
published atomic-write fix `49d2225`. Deployment passed at 22:12:11Z.
Read-only ARM attachment proved the exact owned data disk at unique LUN0;
udev independently reported SCSI/data/LUN0 and its captured serial. The
actual kernel again reported `6.17.0-1022-azure` with built-in NVMe drivers.

Initialization stopped **before formatting** with:
`RuntimeError: Exact managed disk identity and unique LUN not confirmed by IMDS`.
The raw Run Command response retained the traceback; successful ARM Run
Command provisioning was not treated as guest success. No preparation,
rollback, resize, snapshots or recovery was attempted. There was no atomic
publication error. Exact cleanup passed, followed by independent
`group exists=false` and zero residual resources.

Window: 22:09:04Z to 22:17:12Z, **0.135500 hours**, within the approval.
Conservatively rounding the actual source/two-disk sequence to one billed
hour gives the same USD 0.123993 component estimate plus USD 0.50
network/metering reserve = **USD 0.623993**, not a bill. The refreshed full
approved sequence model was USD 1.811439. Retained delayed month-to-date
ActualCost was USD 2.01741901191173 before and after; attribution and final
invoice remain unknown. USD 500 minus reported cost minus USD 25 reserve
left USD 472.982581 illustrative headroom, not spending authorization.

### Identity diagnosis and diagnostic correction

The generated expected disk ID exactly matched Terraform output and the
ARM-attached managed disk; generated serial exactly matched captured udev.
The generated initializer otherwise matched the previously successful
resize-05 script. Case-insensitive ARM-ID matching and both integer/string
LUN0 are already supported; no input/normalization defect was established.

**The actual IMDS response from this failure was not retained.** The old
initializer captured it only in a transient shell variable and raised a
generic assertion. Empty/missing metadata, wrong shape, duplicate LUN or an
ID mismatch cannot now be distinguished; eventual consistency or Azure
response changes are hypotheses, not diagnosed causes. Existing ARM and
udev evidence is not a substitute for that missing independent IMDS proof.
Original run evidence and generated inputs remain private and unchanged.

The initializer now emits the actual IMDS storage profile and exact
expected/mapped inputs as structured diagnostic JSON before assertions,
and rejects malformed metadata with explicit errors. Positive fixtures
cover integer/string LUN and ID case; sixteen refusal fixtures cover wrong
controller/type/LUN/serial/ID, duplicate/missing/null/malformed metadata and
identity. Every failure fixture verifies its actual observation survives.
No ownership, OS-ancestry, empty-signature or formatting guard was relaxed;
no automatic guest replay was added.

This closes the diagnostic-loss defect, not the unexplained live identity
failure. A future separately approved run can now distinguish actual IMDS
shape/identity failures before formatting; it must still stop and clean up
when exact identity is missing. Same-interface full-cycle success and
owner-accepted production readiness remain unproven.

## Approved resize-07 attempt (2026-10-11 UTC)

The separately approved fresh scope retained the resize-06 configuration,
USD 2 ceiling, four-hour maximum and 45-minute cleanup reserve, using
`6162226` plus the offline-tested wrapper fixture output-path correction.
Fresh read-only gates and the isolated nine-create plan passed.

Deployment passed at 23:02:11Z. Exact ARM attachment and Azure udev
SCSI/data/LUN0, captured serial and HCTL checks passed. Initialization
then refused **before formatting**. This time the durable raw Run Command
response included the actual structured observation: IMDS returned a valid
storage profile with **`dataDisks: []`**, while reporting the expected image
and an OS managed disk. It could not independently prove the expected
managed data-disk ID at LUN0. The retained exception was
`Exact managed disk identity and unique LUN not confirmed by IMDS`.
Successful Run Command provisioning did not override the guest refusal.

This establishes missing IMDS data-disk evidence for resize-07, not a
normalization/input defect. Why IMDS omitted the attached disk remains
unknown; neither metadata propagation nor platform causality is proven.
Resize-06's missing response still prevents diagnosing that earlier run.
No identity retry, guard weakening, formatting, preparation, resize,
snapshot or recovery followed. Same-interface support is not promoted.
The existing empty-metadata refusal regression now uses this sanitized
response shape and checks the exact refusal plus retained observation.

Exact cleanup passed; a separate CLI process verified the approved
subscription, group absence and zero residual resources. The run lasted
22:59:18Z to 23:07:07Z, **0.130294 hours**. The full authorized sequence
model remained **USD 1.811439**, not a guaranteed invoice cap. For this
actual source-VM/two-disk attempt, one conservatively rounded billed hour
models USD 0.123993 plus USD 0.50 network/metering reserve =
**USD 0.623993**, not an attributed bill. Delayed month-to-date ActualCost
remained USD 2.01741901191173 after cleanup; that unchanged total does not
establish a free run or its final cost. No paid resources remain.

The diagnostic-retention and failure-cleanup path is now live-observed.
The same-interface full cycle remains unproven: independent disk identity,
preparation/reboot/rollback, resize/data/network validation, sequential
snapshot recovery/original restart and final normal Terraform no-op must
all pass in a separately authorized future scope. No production or owner
acceptance is inferred from this failed run.
