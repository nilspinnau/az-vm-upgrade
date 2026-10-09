# Discovery, lifecycle and Advisor coverage

Use explicit subscription scopes. Inventory filters support resource group,
region, exact size and tag key/value. Resource Graph POST uses object-array
results, 1,000-row pages and continuation tokens. Repeated tokens, truncation
without a token, cross-scope rows and conflicting duplicates fail that scope.
Identical duplicates are removed. Partial records and denial/failure reasons
are preserved; they are not called complete.

`queries/inventory.kql`, `nics.kql`, `disks.kql` and `placement.kql` can also be
used in Resource Graph Explorer with an explicitly selected scope. Joins leave
missing data as null. Empty ARG strings are not proof of a disabled controller,
driver, encryption setting or placement feature.

`catalog/lifecycle.json` is a dated, curated public-cloud lifecycle catalog.
Anchored SKU regexes distinguish Dsv3 from newer D-series generations and
other unrelated sizes. Missing matches mean **not listed in this catalog**,
not unaffected. Catalog review older than ninety days is flagged. Sovereign
cloud lifecycle exceptions are not extrapolated. The standalone lifecycle
KQL query is clearly labeled a subset; the engine applies the full catalog.

## Optional Microsoft Advisor cross-check

`-AdvisorCrossCheck` reads Resource Graph Advisor recommendations in
`ServiceUpgradeAndRetirement`, excludes tracked records and joins lowercase
resource IDs against standalone VMs in the same inventory filter. The template
`queries/advisor-retirements.kql` is rendered by the engine; replace its
placeholders before using it directly in Explorer.

The engine reads recommendation metadata using API `2025-01-01`,
the retirement subcategory filter and `$expand=ibiza`, including next links.
Retirement date/feature come from the recommendation type's
`sourceProperties.serviceRetirement`. Missing metadata stays unknown;
metadata denial is reported separately from recommendation visibility.

All active, completed, postponed, dismissed and **unknown** states are included
by default. A recommendation's state is not guessed from empty properties or
suppression IDs. If a scoped read establishes the actual property path, supply:

```powershell
-AdvisorStatePropertyPath 'properties.extendedProperties.<observed-field>' `
-AdvisorState active,postponed,unknown
```

The property path is an explicit mapping to observed schema, not a claim that
the illustrated field exists. State-specific filtering without such a mapping
is rejected rather than falsely labeling records active.

`advisor-cross-check.json` and `coverage.md` distinguish SKU-only and
Advisor-only VMs. These are **coverage gaps**, not execution blockers. An
Advisor-only recommendation may concern a retiring extension or feature rather
than the VM SKU. Incomplete scopes make the comparison unknown, not SKU-only.

Microsoft documents that Advisor retirement coverage is not comprehensive.
No live subscription-level comparison has been run in this repository; VM SKU
retirement coverage is explicitly unverified. Both Advisor and ARG are
eventually consistent. Neither replaces the lifecycle source or fresh ARM
execution gates. Recommendation-state retention/visibility must also be
verified in the selected live scope.
