# Execution, acceptance and recovery

State progression:

`assessed -> planned -> approved -> prepared -> protected -> deallocated ->
updated -> started -> verified -> reconciled`

Only one explicit standalone VM ID can execute. A plan must be ready, fresh,
unaltered and restricted to a VM tagged as a disposable lab. Approval binds
tenant, subscription, VM, target size/controller, plan hash, exact test resource
group, downtime, temporary loss, guest invocation, exclusive maintenance window
and accepted protection evidence. A bare disk snapshot is not accepted as
application-consistent protection.

## Before disruption

Fresh ARM/instance/disk/NIC reads are compared against the approved or last
completed configuration fingerprint. SKU restrictions, exact region/zone,
compatibility and quotas are rechecked before the relevant phases. Guest
readiness, storage identity and sentinel consistency are recollected before
deallocation; guest commands are not attempted on a deallocated VM.

Only known reversible preparation belongs before this boundary. The engine
marks prepared after proving the guest is ready; it does not silently install
drivers or change mounts during execution.

Real ETags are used for conditional updates where exposed. Otherwise the
equivalent fingerprint and exclusive-window contract detect observed drift.
The service may not provide an atomic precondition for every operation;
multi-host/external automation races are not claimed solved.

## Mutations and operation evidence

The journal records intent **before** an operation. Azure client request IDs,
server request/correlation IDs and asynchronous-operation/location URLs are
persisted when returned. Azure CLI remains the discovery/authentication
interface; small authenticated ARM HTTP requests preserve response headers for
mutation polling without dumping verbose authorization logs.

PATCH payloads contain only required properties, never the entire VM or data
disk collection. This avoids accidental changes to data-disk IOPS/throughput,
security, image, networking or placement. No mutation is retried automatically.
Operation polling is bounded, honors bounded Retry-After and rejects failed,
cancelled or unexpected states. Running/model size alone is insufficient.

For an eligible SCSI-to-NVMe transition the OS disk capability is widened to
SCSI/NVMe, then size/controller are updated while deallocated. No storage tier,
data disk, NIC or boot/security generation is changed.

Every completed phase is checked against the original VM security profile and
disk encryption evidence before a new fingerprint is recorded. Enabled
encryption at host is retained, not included as a disableable workaround.
Source and target must advertise support and the subscription feature must be
Registered. Current/retained ADE settings and ADE extensions remain blocked.
Existing host encryption support does not enable ADE migration, DES/CMK,
confidential VM or Trusted Launch recovery.

## Verification and acceptance

The engine requires healthy provisioning/running state, actual guest OS-disk
controller, unchanged persistent identities/mounts and managed-data checksum,
agent/reboot state, application sentinel, retained networking driver capability,
and actual VF traffic where Accelerated Networking is configured. Explicit
MANA-use requirements must be proved; host placement is never inferred from
the SKU name.

Approved HTTPS health checks run before disruption and after start. Owner
acceptance is a separate post-verification document bound to the exact journal
fingerprint and plan hash. It cannot be pre-granted by the original approval.
Terraform-managed VMs also require a normal no-op reconciliation plan.
Until these arrive the journal stays `verified`, not completed `reconciled`.

## Resume, rollback and restore

- **Safe resume:** explicit `-Resume` on the same immutable plan/approval,
  with no pending operation, rechecks live context/drift and continues a completed
  phase. Reconciled journals do not replay writes.
- **Uncertain interruption:** a pending operation or failed follow-up read
  cannot be blindly replayed. Inspect Azure operation IDs/Activity Log, instance
  state and guest health. Preserve the journal; do not clear fields to force a run.
- **Rollback:** original size/controller are in the original evidence.
  A new, explicitly approved recovery plan must recheck compatibility, source
  quota and available capacity. Allocation back to the original SKU is not guaranteed.
- **Restore:** follow the accepted protection procedure with owner approval.
  The toolkit never deletes a VM, detaches disks, formats existing storage or
  launches a destructive restore automatically.

Generate a case-specific guide:

```powershell
.\scripts\Get-VmRecoveryGuide.ps1 -JournalPath '.\out\journals\<hash>.journal.json'
```

Expired approvals remain expired during recovery. They are not silently extended.
Record recovery failures explicitly and use your Azure support/change process
for unsupported or uncertain paths.

Disk snapshots contain storage contents, not VM host-encryption configuration.
A recovery VM must explicitly retain `securityProfile.encryptionAtHost=true`,
use a compatible SKU and the Registered subscription feature. Recovery disks
must retain their platform-key encryption. Creating a snapshot is not a
successful restore, and no original-SKU allocation is promised.

## Guest preparation journals

Preparation has its own journal (`out\journals\prep-*.journal.json`) written
before each guest call. An `in-progress` journal means the outcome is unknown:
run `Invoke-VmPreparation.ps1 -Mode Status` and review; apply/rollback are
refused until then. Guest rollback restores recorded values only, is not a VM
restore, and has not been proven live. See [guest-preparation.md](guest-preparation.md).
## Rejected validation evidence

The executor stores `validationEvidence` in the ignored VM journal before
post-start checks. A failed observation never updates the expected fingerprint
or promotes the phase to `verified`. Instance-health failures include observed
status codes. Preserve this evidence and operation history before cleanup;
the last successful start snapshot cannot establish the cause of a later
failed observation.
