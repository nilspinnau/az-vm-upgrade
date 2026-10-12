# Compatibility, quota and evidence

`Get-VmEvidence` reads the selected VM and instance view, each managed disk and
NIC, the per-VM native resize-options list, the complete subscription-filtered
regional SKU list and regional usage.
It exports only bounded model fields, not OS-profile passwords, secret
references, environment dumps or application configuration files.

Checks retain separate pass, disabled, required, unknown, stale, unsupported,
denied and failed outcomes. Plan classes are ready, needs-preparation, blocked,
requires-rebuild, requires-application-specific-work and incomplete-evidence.
The most restrictive known path takes precedence over an unrelated unknown.

Evidence older than sixty minutes or more than five minutes in the future is
not executable. Plans expire after one hour. Configuration hashes cover the VM
model, attached disks and NICs, including real ETags where available. They do
not treat volatile usage counters as configuration drift. Dates are preserved
as strings, and dictionary ordering is canonicalized before hashing.

## Candidates

Explicit target selection is required for execution. Candidate ranking uses
metadata compatibility and minimum vCPU/memory, not a cost model, price,
workload benchmark or platform allocation guarantee.

Checks include architecture, current boot generation, target controller, disk
and NIC limits, premium storage, retained Accelerated Networking and encryption
support, region, exact existing zone, subscription restrictions, temporary
storage, and advertised cached/uncached disk performance. Missing capability
metadata is unknown. Unsupported specialized configurations are explicitly
excluded rather than modeled as universal conversions.

Workload certification and performance acceptance remain separate owner
decisions. No other zone, region, security type, boot generation or image is
selected implicitly. Reservation-associated paths require a separate review.

## Quota arithmetic

`vCPUs` and `family` come from SKU metadata. `vCPUsAvailable` is the active
constrained-core count and is not used as quota consumption.

For an existing standard VM with source quota cores **S**, target cores **T**:

| Usage tier | Same-family resize | Cross-family resize |
|---|---|---|
| Total regional cores | current + T - S | current + T - S |
| Target family | current + T - S | current + T |
| Source family | included above | current - S |
| VM count | unchanged | unchanged |

Allocated **and deallocated** VMs consume quota. The usage records must include
the existing source VM; missing/ambiguous records or impossible source usage
are unknown, not sufficient quota. Spot is excluded, so low-priority usage is
not mixed with standard-family accounting. Offline tests cover same/cross-family
and constrained-core arithmetic; live resize allocation remains untested.

The lab deployment preflight uses conservative **new VM** additions instead:
regional/family usage plus the full selected size cores, and VM count plus one.
It checks source and target separately. This is intentionally more conservative
than steady-state resize quota.

Quota permission, published SKU/zone availability and actual allocation
capacity are separate. No paid reservation, quota request or preview
registration is performed. Allocation can fail after deallocation, and the
original size may not be available for rollback.

## Non-NVMe targets

For an existing SCSI VM, explicitly select `-Controller SCSI` and a target
advertising SCSI. The same-controller state machine retains all managed disk
controller capabilities and uses a **size-only native Azure VM PATCH**: no
controller field update, NVMe conversion, NVMe guest boot staging, utility
package installation or mandatory preparation/rollback cycle. It still
requires actual SCSI identity, stable mounts/data, both relevant network
drivers, health/protection, exact SKU/quota/security/placement checks and
Terraform reconciliation. Source/target temporary-disk exclusions are
unchanged. This is an implemented offline-tested path, not accepted live
same-interface/production coverage. It does not authorize NVMe-to-SCSI
conversion or another configuration merely because a target uses SCSI.

### Portal cluster warning and the exact native workflow

The portal warning **"This size is not currently available on the underlying
cluster"** is a placement signal, not proof that quota is exhausted or that
the target is incompatible. A running VM's native resize list reflects the
current cluster. Plans/reports distinguish a target listed there from an
absent target that requires deallocation/reassessment; unknown, stale or
denied observations never become availability proof.

Ordinary native running resize is possible for a compatible listed size, but
it **restarts** the VM. The toolkit's existing bounded single-VM executor
deliberately retains the explicitly approved cold sequence:

1. Read exact ownership, per-VM resize options, regional SKU/restrictions,
   quotas, disks/security/placement and guest/data/network/application health.
   Obtain protection, downtime, temporary-data-loss and exclusive-window consent.
2. Deallocate only the selected VM. This releases its current allocation;
   dynamic IP addresses and temporary data can be lost. No other VM is stopped.
3. Refresh and retain the deallocated native resize list. If the exact target
   is still absent, or the list is unknown/denied/incomplete, stop before the
   size update. Do not select another size, zone or region or replay a failed
   allocation automatically.
4. PATCH only `hardwareProfile.vmSize`, retaining controller, disks, NICs,
   security and reservation association. Start and wait for successful Azure
   operation/provisioning and running state.
5. Verify fresh guest IMDS compute `vmSize` and actual logical CPU count against
   target `vCPUsAvailable` (or `vCPUs` when not constrained), plus the existing
   controller/data/mount/network/health checks. A displayed ARM/portal target
   after failed allocation is not runtime success. Missing/contradictory guest
   observations are retained and refuse verification; CPU count alone cannot
   distinguish equal-core SKUs.
6. Obtain owner acceptance and reconcile Terraform desired `size`, preserving
   the existing controller/association and requiring the normal no-op plan.

The native list is not an allocation guarantee even after deallocation.
Quota and capacity remain separate. Availability sets still need a wider
coordinated resize and are blocked; the toolkit never deallocates their other
members. Microsoft's current resize page supports Linux local-temp/no-temp
transitions but not direct Windows transitions; this release intentionally
keeps its narrower temporary-disk exclusions for both paths. SCSI compatibility
alone does not relax generation, storage, security or workload restrictions.
Explicit preparation exercises in a full-cycle test harness test that separate
feature; they are not prerequisites for an ordinary SCSI-only resize.

## Capacity reservations

**A reservation is not required for an unassociated VM.** Quota is permission
to deploy; capacity is the physical allocation available in the exact region
and zone. A quota pass or published SKU never proves capacity. An on-demand
capacity reservation is size/location/quantity-specific, costs money even
unused, and its creation can itself fail quota/capacity checks. Reserved
Instances and Savings Plans provide discounts, not physical capacity.
No reservation is purchased, created, associated, detached, reduced or deleted
by this toolkit. Quota is still freshly verified before an approved execution;
an owner's expectation that it is sufficient does not bypass that check.

When ARM reports an existing capacity reservation group association,
`Get-VmEvidence` follows only that exact same-subscription group and its
unique member IDs using Compute API `2024-07-01` with `$expand=instanceView`.
Raw group/member responses are retained before identity/refusal checks when
`-ObservationPath` is supplied. Denied/missing/contradictory evidence is an
explicit check, not an assumption of unreserved availability. Shared or
cross-subscription groups need separate review.

The plan reports group identity/region, zonal-versus-regional compatibility,
exact target SKU and zone, reservation provisioning/runtime state, configured
quantity, actual `instanceView.utilizationInfo.currentCapacity` and
`virtualMachinesAllocated`. A succeeded matching member with observed units
for this VM is `compatible-observed`, **not** a lock or allocation guarantee.
Missing target, failed reservation, mismatched placement, exhausted capacity,
over-allocation or inconsistent runtime evidence yields an actionable
`incompatible`/`unknown` result. Special placement (availability sets,
dedicated host, PPG, scale sets, Spot) remains separately blocked.

Quota projection remains conservative: it does not credit unused reserved
quota or model Azure's exemption for deployment within reserved quantity.
Associated capacity is not silently subtracted from usage or treated as a
free target allocation. These paths require owner/provider-specific quota
and reservation accounting review before any associated execution.

**Associated-VM execution and restoration remain assessment-only**, including
when observed compatibility passes. A generic single-VM workflow cannot
silently assume shared reservation/protection semantics. Reports bind the
association to evidence/plan hashes and suppress upgrade launchers; execution
also independently refuses a forged ready classification with an association.
Reservation changes require a separate owner-reviewed plan and consent, not
an implicit step in resizing.

### Target missing from the associated group

Microsoft documents two choices before resizing: create a matching target
reservation or remove the association. Creating/increasing a reservation is
paid/shared scope and may require extra quota; it is not part of current
authorization. Changing quantity can affect every associated VM and unused
billing. No alternative group/zone/region is selected automatically.

### Can it be removed while the VM is running?

The documented usual procedure is **deallocate the VM, detach its association,
then restart if desired**. This introduces downtime and unreserved restart
capacity risk. Detachment alone does not delete the reservation or stop its
unused-capacity charge.

Microsoft also documents **set the relevant reserved quantity to zero, then
detach**, for a VM that cannot be deallocated. This is not a harmless
running-VM flag toggle: it relinquishes that reservation's protection and can
affect other associated VMs; restoring quantity later requires capacity/quota
and might fail. It needs explicit shared-impact, billing, placement,
protection/recovery and Terraform-owner approval. Do not copy mutation
commands into a generated action launcher or use this as an automatic fallback.

Public procedures:
[overview](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-overview),
[resize/modify](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-modify),
[remove association](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-remove-vm).
