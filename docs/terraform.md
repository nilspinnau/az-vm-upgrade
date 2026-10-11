# Terraform ownership and reconciliation

Terraform remains the source of desired configuration. Do not infer ownership
from tags, mutate arbitrary HCL or edit state JSON.

The test module pins AzureRM **4.48.0**. Installed schema checks confirm:

| Resource | Relevant attributes |
|---|---|
| `azurerm_linux_virtual_machine` | `size`, `disk_controller_type`, `encryption_at_host_enabled` |
| `azurerm_windows_virtual_machine` | `size`, `disk_controller_type`, `encryption_at_host_enabled` |
| `azurerm_network_interface` | `accelerated_networking_enabled` |

The exact pinned provider source implements both VM size and controller updates
in its Update path; controller changes deallocate, and size changes can shut
down/deallocate when needed. These attributes are not globally a promise of
in-place change: resource combinations, image/security changes and exact
customer plans still govern replacement behavior. Provider schema JSON alone
does not expose every ForceNew rule.

## Before the maintenance window

For a simple same-interface resize already supported by the customer provider,
prefer updating desired HCL and using the customer's approved Terraform
workflow, after guest/workload/protection/quota review. The toolkit's
production execution remains disabled.

For a lab guest-preparation/controller transition, pause ordinary automation,
prepare/reassess, and update the desired size/controller before orchestration.
Supply an explicit mapping and normal Terraform plan JSON:

```powershell
terraform plan -out=desired.tfplan
terraform show -json desired.tfplan > '.\out\desired-plan.json'
```

In an actual Terraform working directory, ensure output paths exist and remain
ignored/access-controlled. Pass the exact address, for example:

```json
{"vmAddress":"azurerm_linux_virtual_machine.test[0]"}
```

The gate verifies the mapped `before.id`, expected AzureRM VM type, explicit
desired size/controller, no replacement/create/delete, no unrelated managed
resource changes and no unknown post-change values. Suggested edits come from
that mapping. NIC properties are retained; network changes must be reviewed
separately. Data-source reads that appear as changing actions also require
review instead of being silently whitelisted.

## After orchestration

Keep desired HCL aligned with the approved target. Regenerate plans; an earlier
saved plan is stale after out-of-band orchestration and must not be applied.

```powershell
terraform plan -refresh-only -out=refresh.tfplan
# Review the exact refresh-only changes and apply only under the customer's approval:
terraform apply refresh.tfplan
terraform plan -out=normal.tfplan
terraform show -json normal.tfplan > '.\out\normal-clean-plan.json'
```

The final normal plan must have no unintended changes or replacements and must
show the exact target. Supply it with `-TerraformReconciliationPath` and
post-verification owner acceptance during explicit resume. No plan/apply is
run by the upgrade engine.

Preserve `encryption_at_host_enabled = true` when the approved VM has host
encryption. Both desired and reconciliation plans must match the observed
VM setting; missing, disabled or unknown encryption is rejected even in a
claimed no-op plan. Host encryption is not ADE or a disk encryption set.
The pinned provider exposes the property as an optional boolean; no new
owner/AzAPI patch or lifecycle exclusion is needed. This is not a live no-op
claim. The live normal plan still must prove exact reconciliation.

Do not use `ignore_changes = all`, permanent size/controller exclusions or
overlapping AzAPI/AzureRM ownership of the same property. This implementation
generates **no lifecycle exclusion**. If a customer provider cannot represent
the target/controller or reconcile cleanly, the path is unsupported for
unattended IaC use until separately resolved. Narrow temporary exclusions, if
ever justified elsewhere, need explicit scope, expiry and removal evidence.

Protect state, even marked-sensitive attributes: a Windows password still
resides in Terraform state. The repository excludes all state/tfplans/tfvars
except synthetic `.example.tfvars`.
