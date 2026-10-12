# Acceptance record

## Software acceptance

Offline validation passed locally on Windows with PowerShell 7.6.6, Azure CLI
2.83.0, Terraform 1.14.5, Pester 5.7.1 and PSScriptAnalyzer 1.25.0.
AzureRM is pinned to 4.48.0; the provider lock file is committed.

| Check | Actual result |
|---|---|
| PowerShell parsing | All module, customer, guest, fixture and integration scripts passed |
| Configured static analysis | Module, customer, guest and integration scripts passed |
| Decision/orchestration tests | 257 Pester tests passed; no failures, skips or unrun tests. Includes wall-clock command bounds, real stalled-child termination and mocked supervisor cleanup, preparation expiry/fresh-power refusal, explicit ARM lab identity success/refusal and legacy IMDS preservation, atomic create/replace, transient/persistent reader locks, read-only failures, unchanged journal phase/intent on publication failure, encryption-at-host/security drift, real Run Command response shapes, SCSI LUN identity, built-in/compressed NVMe boot drivers, consent-bound connectivity, restoration evidence/gates, rejected-validation evidence persistence, and exact live-support catalog scope. Upstream catalog hashes verified against locally fetched copies |
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

## Explicit lab identity mode: offline implementation

Following public-source review, the owner explicitly approved **offline
implementation only** of `arm-azure-udev` for new synthetic SCSI lab disks.
Mandatory IMDS proof remains the default. The alternative binds fresh exact
ARM ownership/provenance/single LUN, unchanged resource incarnation and
captured serial with Microsoft's Azure udev/HCTL mapping, while retaining
all pre-format exclusions. Empty IMDS data-disk metadata may be accepted
only with this explicit mode/proof and matching OS identity; contradictory
or malformed metadata is refused. No API-version change, propagation
diagnosis, automatic fallback or retry was introduced.

Offline regressions exercise the actual identity validator, actual
initialization harness body, retained observations on refusal, and both
legacy and explicit-mode whole-wrapper control flows with synthetic external
responses. These are mocked proofs, not live initialization or a successful
same-interface full cycle. No new Azure calls, resources or formatting were
authorized or performed. See [the explicit test procedure](testing.md#explicit-synthetic-scsi-lab-identity-mode).

The standard suite passed **180 Pester tests and six Terraform mocks**;
the optional whole-wrapper runner separately passed **four tests**.
The new guest-validator fixtures cover two positive and 34 refusal cases,
including sanitized empty metadata, contradictory IDs/OS/LUNs, stale proof,
wrong ownership/provenance/controller and unknown mode.

## Resize-08: partial identity proof and time-bound breach

**Paid testing is suspended. No further deployment is proposed or authorized.**
The owner separately approved the exact same-interface configuration and
explicit synthetic-disk formatting/ARM-Azure-udev/exclusive-window method.
The run used `383fae0`. Deployment, that initialization method and preparation
apply passed. Preparation restart returned HTTP 409 `OperationNotAllowed`:
`The operation requires the VM to be running (or set to run).`
No completed reboot, rollback, resize, snapshots or recovery is claimed.

| Recorded stage, UTC | Actual observation |
|---|---|
| Start, October 11 23:35:56.747151 | Four-hour deadline October 12 03:35:56; cleanup reserve 02:50:56 |
| Deployment 23:38:22; initialization 23:39:54 | Exact explicitly approved synthetic SCSI identity/formatting passed |
| Preparation apply 23:47:10 | Initramfs readiness verified; azure-vm-utils already present and unchanged |
| Instance view 23:47:17; evidence assembly October 12 02:30:25 | Old running state was reused after an approximately 2h43m evidence-collection gap |
| Restart intent 02:30:28; failure retained 02:30:43 | 409 above; actual fresh power state at the rejected request was not captured |
| Cleanup inventory 02:31:15; completion 06:35:43.757206 | Synchronous group-delete/finalizer span approximately 4h04m; exact server deletion completion unknown |

Elapsed **6.996392 hours**, exceeding the approved bound by approximately
**2h59m47s**. The time approval was breached. Exact cleanup subsequently
passed; an independent CLI process verified group absence and zero residual
resources. Read-only revalidation at 07:22Z reconfirmed absence.
Original failure evidence and timestamps remain protected and ignored.

Host logs establish Modern Standby, including a lid-triggered entry at
23:48:20 and transitions during the gaps. They do not establish precise
thread scheduling, the particular evidence subcommand waiting, or which
part of deletion elapsed server-side. Sleep, tool waits and Azure delays
must not be assigned invented durations.

Proven control defects were between-stage-only reserve checks, no independent
worker supervisor, relative process waits followed by potentially unbounded
stream/termination waits, untimed native Terraform children, and no
post-collection expiry/fresh-power check immediately before preparation
restart. Corrections use bounded UTC polling, command start/end/failure
sidecars, post-collection expiry checks and retained fresh power evidence.
The opt-in lab supervisor bounds the whole worker, kills a stalled child
tree and enters exact ownership-checked cleanup with nonwaiting delete and
bounded absence polling. Cleanup failure remains explicitly unverified.
It cannot run through host suspension/shutdown; see [operational limits](testing.md#bounded-lab-worker-supervision).

Offline proof comprises **193 Pester tests and six Terraform mocks**,
including real local stalled processes with mocked cloud cleanup, overdue
resume handling, ownership refusal and cleanup-poll timeout. Four existing
whole-wrapper mocks initially passed using the compatible resize-07 wrapper with
both legacy and spliced ARM-helper initialization. That fixture initially
rejected the resize-08 wrapper's changed explicit-helper call shape before
execution. At that checkpoint this was not current resize-08 whole-program proof;
the non-paid coverage extension below addresses that specific fixture gap.
No live mutation was replayed to validate these fixes.

For the actual source-only VM plus two disks, conservatively using **eight
rounded hours** rather than assuming seven billable hours models compute
USD 0.736, disks USD 0.059178, the retained full-rate transaction envelope
USD 0.196768 and USD 0.50 network/metering reserve: **USD 1.491946**.
This deliberately covers more than the measured seven-hour span; no target,
snapshot or recovery resources were created. It is not an invoice or hard
cap. Actual allocation/disk lifetimes, usage meters, transfer, rounding,
currency/tax effects and delayed attribution remain uncertain. The stale
four-hour/full-cycle USD 1.811439 model does not describe this attempt.
Refreshed subscription month-to-date ActualCost is USD 2.3201021104584
(07:22Z), up USD 0.302683098547 from the earlier reading; the delta is not
an attributed final lab charge. The user USD 500 ceiling grants no renewed
spending authority.

Same-interface full-cycle acceptance, corrected supervisor live behavior and
owner acceptance remain unresolved. An awake, reliable execution/cleanup
environment must be established before any future paid-test decision.
Windows, other distributions, module-staged drivers and production support
are not expanded.

### Current-wrapper supervised offline coverage extension

The reviewed whole-wrapper fixture now recognizes exactly the current
explicit helper invocation, preserving its consent arguments, and redirects
only that command to the actual initialization-helper body in the synthetic
module scope. Unknown, consent-altered and duplicate shapes refuse before
external operations. The retained resize-08 wrapper and its original
evidence were not edited or replayed against Azure.

The optional runner passes **11 top-level tests** on that current wrapper,
including **six real separate PowerShell children** supervised by the actual
parent body and bounded process adapter. Cases cover full mocked success
through preparation/resize/recovery/final no-op/cleanup, synthetic IMDS
contradiction with failed identity journal retained, evidence-collection
hang terminated at reserve with parent exact cleanup, actual deadline
refusal, failed durable baseline publication with no preparation/upgrade
promotion, and child plus parent cleanup timeout. Synthetic child failures
are expected and asserted by the parent; these are not failed live runs.
Nested preparation/recovery, guest responses, Azure and Terraform remain
mocked; the guest identity validator has separate standard regressions.

The timeout case retains the worker's historical `completed` technical-cycle
status plus `cleanupError`, without relabeling that original wrapper behavior
as overall success. The authoritative supervisor journal is `failed` with
cleanup `unverified`. Three standard entrypoint regressions additionally
reject mismatched/unknown literal wrapper scope before launching a process.
The standard suite passes **196 Pester tests and six Terraform mocks**.
Legacy wrapper compatibility retains five direct mocked tests, not current
separate-worker evidence.

The intended lab procedure now requires the supervised entrypoint rather
than direct wrapper execution and explicitly requires an awake/reliable host
and operator cleanup coverage. No sleep/power setting was changed. All paid
testing remains suspended; this strengthens offline control-flow proof but
does not establish a live cleanup deadline, same-interface full-cycle success
or production/owner acceptance.

### SCSI-only target and capacity reservation planning

Non-NVMe target migration uses the implemented same-controller SCSI engine.
Offline execution now explicitly covers a target advertising **only SCSI**
with NVMe guest readiness unknown: deallocate/size update/start/verification/
reconciliation passes, controller remains SCSI, and no disk controller
capability PATCH occurs. Both same-controller SCSI and eligible SCSI-to-NVMe
software paths exist; this does not promote same-interface live acceptance
or imply a generic NVMe-to-SCSI conversion.

Read-only evidence collection follows an associated exact same-subscription
capacity reservation group/member list and expanded runtime observations.
Plans/reports expose exact target-size/region/zone/state/unit compatibility,
unassociated optionality, quota-versus-capacity distinction and concrete
owner choices for missing target reservations. Association drift remains
fingerprint-bound, Terraform removal is refused in a size/controller-only
plan, forced ready associated execution is independently refused, and the
restore harness refuses associated originals before deallocation/create.
Compatible associations are **assessment-only**, not hidden permission for
reservation changes or a new live-tested placement path.

Synthetic regressions cover succeeded zonal/non-zonal matching, exhausted/
overallocated units, missing target, stale/denied/malformed/out-of-group/
duplicate evidence, raw contradictory response retention, untouched
unassociated discovery, reporting without launchers, reservation drift,
Terraform detachment and recovery refusal. No reservation purchase, creation,
association, detachment, quantity change or deletion was performed or added.

The standard validation passes **225 Pester tests and six Terraform mocks**;
the **11 current supervised wrapper tests** also pass. These remain offline
proof, with external Azure/guest/Terraform responses mocked. Fresh read-only
Sweden Central usage reported regional cores 0/100, DASv5 cores 0/100 and
VM count 0/25000 in the approved subscription/context. The attempted bounded
SKU metadata refresh timed out; no fresh compatibility/capacity guarantee is
claimed from that attempt. Paid testing remains suspended, with no new
deployment proposal, settings changes, guest command or mutation replay.
Fresh execution gates and the reliable-awake-host/operator cleanup prerequisite
remain mandatory before a separately approved live scope.

### Native size-only resize and portal placement observations

The same-controller execution now sends only `hardwareProfile.vmSize`, not
an unnecessary controller field. Its journal names that operation `size-update`.
SCSI targets do not require NVMe boot readiness or azure-vm-utils installation;
missing Windows stornvme service is an explicit failed NVMe-readiness observation,
not a fatal prerequisite for collecting SCSI evidence. Target, generation,
temporary-disk, driver/health, quota, security, protection, reservation,
exclusive-window and Terraform guards remain.

The per-VM Compute `vmSizes` response is retained before validation and kept
distinct from regional SKU advertising. Plans/reports distinguish current-
cluster listing, requires-deallocation, deallocated listing and unknown/
absent outcomes. Native cold execution refreshes the exact target list after
deallocation; unknown/absent targets refuse the size update without substitution.
This executor does not add a new running-resize mutation mode: its explicit
deallocation/start consent remains necessary.

Guest probes retain IMDS compute size, logical processor count and explicit
metadata failures. Post-upgrade verification requires these observations to
match the exact target and active constrained-core count, in addition to
successful mutation/start and existing guest/data/network checks. A target
displayed in ARM after failed allocation is insufficient. Runtime disagreement
remains durably in validation evidence with no `verified` phase promotion.

**257 standard Pester tests and six Terraform mocks pass**, including actual
native state-machine success with size-only payload, expansion of the target
list after deallocation, absent-target refusal before PATCH/start, retained
old-runtime evidence, denied/malformed/write-failure resize observations,
unknown/stale/listed placement distinctions, CPU/size refusal and constrained
cores. This is offline synthetic evidence, not a live resize or broader
production acceptance. No paid resources, guest calls or VM mutations occurred.
The 11 optional current whole-wrapper/supervised mocks also pass; nested
preparation/migration/recovery calls remain mocked in that fixture.
The actual Linux IMDS-size probe fragment also executes with synthetic text
responses: valid, empty, malformed and overlong observations retain raw bounded
content before refusal, with proxy bypass and five-second timeout assertions.
Stopped, missing and contradictory power states are not mislabeled deallocated.
