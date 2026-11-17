# Adoption evidence for rg-demo-identities-deploy-excluded

The gate accepted every record of this unit.

This file is written by adoption/adoption.py from saved previews and is never edited by hand. A deployment stack has no baseline before its first apply, so the first preview of this unit still lists differences that Azure reports and a deployment does not change. This file gives the reason for each of those records, so the approver of the unit's first run does not have to judge them by eye. It is deleted after the unit's first run.

## Counts

| NoChange | Modify | Ignore | Create | Delete |
|---|---|---|---|---|
| 12 | 0 | 0 | 0 | 0 |

Each count is the number of resources with that result in the plain preview (what-if) of the unit's template. A stack preview lists only the resources the template declares, so the Ignore records do not appear in it. The scope of the unit is 77488719-1168-4d53-af9a-f5c3bc9291d7 / rg-demo-identities.

Every record of this unit is NoChange, so there is nothing to explain.

## Source

The records come from the read-only preview of the demo units, preview file `rg-demo-identities.deploy-excluded.json`. The gate judged them offline with scripts/deploy-unit.ps1 and deploy/boundaries.json, and its result for the unit is PASS.

The files of the unit the previews were taken from, each with the SHA256 of its text (line endings left out). The plan of the unit's first run compares them with the files of its commit and fails when one differs, because this evidence then belongs to another version of the unit.

- `infra/subscriptions/demo/resource-groups/rg-demo-identities.deploy-excluded.bicep` SHA256 `764be4015e98611701c364220c303d85c5da99f83c730a6f25c4c052507885c5`
- `infra/subscriptions/demo/resource-groups/rg-demo-identities.deploy-excluded.bicepparam` SHA256 `2d3032906490f0ea6aacfcdf3144c8004b61bbe605d975a8fc8189d78662d880`
