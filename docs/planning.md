# Compatibility, quota and evidence

`Get-VmEvidence` reads the selected VM and instance view, each managed disk and
NIC, the complete subscription-filtered regional SKU list and regional usage.
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
