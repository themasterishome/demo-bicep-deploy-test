# Adoption evidence for demo-privileged

The gate accepted every record of this unit.

This file is written by adoption/adoption.py from saved previews and is never edited by hand. A deployment stack has no baseline before its first apply, so the first preview of this unit still lists differences that Azure reports and a deployment does not change. This file gives the reason for each of those records, so the approver of the unit's first run does not have to judge them by eye. It is deleted after the unit's first run.

## Counts

| NoChange | Modify | Ignore | Create | Delete |
|---|---|---|---|---|
| 4 | 0 | 0 | 0 | 0 |

Each count is the number of resources with that result in the plain preview (what-if) of the unit's template. A stack preview lists only the resources the template declares, so the Ignore records do not appear in it. The scope of the unit is subscription 77488719-1168-4d53-af9a-f5c3bc9291d7.

Every record of this unit is NoChange, so there is nothing to explain.

## Source

The records come from the read-only preview of the demo units, preview file `demo-privileged.json`. The gate judged them offline with scripts/deploy-unit.ps1 and deploy/boundaries.json, and its result for the unit is PASS.

The files of the unit the previews were taken from. The template has the hash that Bicep writes into its compiled template, which holds every module the template calls. The parameters file has the SHA256 of its text (line endings left out). The plan of the unit's first run computes both from the files of its commit and fails when one differs, because this evidence then belongs to another version of the unit.

- `infra/subscriptions/demo/privileged.bicep` compiled template hash `2113791887482179645`
- `infra/subscriptions/demo/privileged.bicepparam` SHA256 `079c0b7f0390814dda77748e9982e23e3e0783486373cd7fb87269c225b90c91`
