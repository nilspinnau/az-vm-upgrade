# Permissions, authentication and data handling

Use least privilege at the approved subscriptions/resource groups. The toolkit
never requests role assignments, provider registration or preview registration.

| Activity | Required access |
|---|---|
| Resource Graph inventory | Read access to each explicitly selected scope; `Microsoft.ResourceGraph/resources/read` through an applicable role |
| Fresh evidence | VM, instance-view, managed-disk and NIC reads; `Microsoft.Compute/virtualMachines/vmSizes/read` for per-VM resize options; Compute SKU and regional usage reads |
| Associated capacity reservation evidence | `Microsoft.Compute/capacityReservationGroups/read` and `Microsoft.Compute/capacityReservationGroups/capacityReservations/read` on the exact referenced group/members; no write, purchase, deletion or quantity-change permission is requested |
| Optional Advisor cross-check | Advisor recommendation and metadata reads plus Resource Graph scope visibility |
| Guest probes/preparation | Explicit owner consent plus `Microsoft.Compute/virtualMachines/runCommand/action` and a healthy guest agent |
| Lab execution | VM write, start/deallocate actions and OS disk write for an eligible controller transition; exact test scope |
| Terraform test creation | Explicit paid-deployment approval and needed Compute/Network/resource-group permissions in the dedicated lab scope |
| Protection/recovery | Independently verified backup or accepted recovery procedure; not synthesized by this toolkit |

Exact RBAC action availability can vary by role and cloud API. Verify your
organization's custom role and deny assignments in the approved scope.
Reader is sufficient for many control-plane reads, but **does not grant Run
Command**. Contributor is broader than necessary; do not recommend it as a
default production access shortcut.

Azure CLI provides authentication. All resource reads carry an explicit
subscription. ARM mutations obtain a token through Azure CLI, keep it in
memory, restrict HTTPS to `management.azure.com`, disable redirects and never
serialize the token to evidence or journals. Run Command scripts contain no
customer credentials and do not install permanent extensions.

Treat evidence, IP configurations, resource IDs, health endpoints, approval
references, logs and Terraform output as potentially sensitive customer data.
Use an access-controlled output directory and retention policy. Default
`out/`, logs, state, plans, tfvars, keys and customer-data directories are ignored.
Do not relocate live exports under `examples/` or another tracked folder.

PowerShell approval JSON is a local operator attestation, not cryptographic
identity verification. Only trusted operators should edit it. Hashes prevent
accidental or unapproved plan changes; they are not a defense against someone
who can replace both the plan and its approval. OS access control and your
change-management system remain required.

The local file lock prevents overlapping runs sharing the same journal folder
on one host. It is not a distributed Azure lease. The approval requires an
exclusive maintenance window; pause Terraform, automation and other writers.
No guarantee is made against an external writer racing after a final read
where the service does not expose enforceable ETags.
