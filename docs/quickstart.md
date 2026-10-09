# Quickstart

## Prerequisites and safe defaults

Use PowerShell 7.5 or newer (date strings must survive JSON hashing unchanged),
Azure CLI, Bash and Python 3 for Linux script checks, and Terraform 1.7+ for the test module.
On Windows, the CLI runner supports the official MSI's bundled Python or a
native executable; it deliberately avoids passing JSON through `cmd.exe`.

Authenticate with your usual Azure CLI process. Every read is explicitly
subscription-scoped. This release supports Azure public cloud only.
Do not paste credentials into scripts, JSON documents or source control.

Assessment is not execution authorization. Resource Graph inventory is
eventually consistent; execution uses fresh ARM and guest evidence.

## Inventory

```powershell
.\scripts\Get-VmInventory.ps1 -SubscriptionId '<subscription-a>','<subscription-b>' `
  -ResourceGroup '<optional-rg>' -Location '<optional-region>' `
  -TagName 'environment' -TagValue 'test' -OutputDirectory '.\out\inventory'
```

The output includes `inventory.json`, `inventory.csv` and `coverage.md`. A
denied/failed inventory scope makes the command fail after saving partial
evidence. Do not describe partial coverage as a complete estate review.

## Select and assess one VM

```powershell
.\scripts\New-VmUpgradePlan.ps1 -VmId '<exact-VM-ARM-ID>' `
  -GuestConsent -TargetSize '<explicit-size>' -Controller NVMe `
  -WorkloadReviewPath '.\out\review.json' -OutputDirectory '.\out\vm-plan'
```

Copy `examples/workload-review.example.json` into the ignored output folder,
review the workload and fill it truthfully. Exclude clustering, appliances,
third-party boot/storage filters and temporary-data dependencies. Set
`requireManaInUse` if actual MANA traffic is an acceptance requirement.
Network drivers being installed is not proof of MANA host placement.

Optional application health checks are bounded HTTPS GETs from the
orchestrator, without inline credentials, query strings or arbitrary hooks:

```json
{
  "healthChecks": [
    {"uri": "https://application.example/health", "expectedStatus": 200}
  ]
}
```

Merge this field into the reviewed workload contract, not into a separate
unbound script. Up to four checks are allowed, each with a ten-second timeout.
An optional `bodySha256` checks at most 64 KiB without saving the response body.
The orchestrator must have network access to the endpoint. Application-specific
credentials, failover or richer tests need a separate reviewed procedure.

For Terraform-managed resources, also supply:

```powershell
-TerraformMappingPath '.\out\mapping.json' -TerraformPlanPath '.\out\desired-plan.json'
```

Use an exact `vmAddress`, never inferred tags. No target selection occurs when
`-TargetSize` is omitted; the report contains ranked candidates instead.
Resolve non-pass checks, prepare only supported guest settings, then recollect
evidence. Offline re-reporting uses `-EvidencePath` and never calls Azure.

## Review outputs and approvals

`guide.md`, `plan.json`, `evidence.json` and `inventory.csv` are generated from
the same plan. Blocked/incomplete/preparation plans have **no executable
launcher**. Re-exporting such a plan removes earlier launchers.

Only a ready disposable-lab plan may run. Copy `examples/approval.example.json`
to an ignored folder and fill the exact VM/tenant/subscription/target, plan hash,
expiry, test resource group, guest/downtime/temp-loss/exclusive-window approvals
and protection evidence. The file is an operator attestation, not a digital
signature or a substitute for organizational change approval.

```powershell
.\scripts\Invoke-VmUpgrade.ps1 -PlanPath '.\out\vm-plan\plan.json' `
  -ApprovalPath '.\out\approval.json' -WhatIf
```

WhatIf checks the local approval contract but does not call Azure.
Removing WhatIf is a disruptive action and requires separate test approval.
The VM must be tagged `az-vm-upgrade-disposable=true`; production VMs are refused.

Technical verification leaves the journal at `verified` until actual
post-verification owner acceptance and, where declared, Terraform reconciliation:

```powershell
.\scripts\Invoke-VmUpgrade.ps1 -PlanPath '.\out\vm-plan\plan.json' `
  -ApprovalPath '.\out\approval.json' -Resume `
  -OwnerAcceptancePath '.\out\owner-acceptance.json' `
  -TerraformReconciliationPath '.\out\normal-clean-plan.json'
```

Use `examples/owner-acceptance.example.json` as the shape. Bind it to the plan
hash and verified journal fingerprint, with a timestamp after technical
verification and an owner-review reference. Do not alter the original approval
to pre-grant acceptance. `reconciled` is the final completed state.
