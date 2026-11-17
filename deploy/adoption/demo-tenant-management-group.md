# Adoption evidence for demo-tenant-management-group

The gate accepted every record of this unit.

This file is written by adoption/adoption.py from saved previews and is never edited by hand. A deployment stack has no baseline before its first apply, so the first preview of this unit still lists differences that Azure reports and a deployment does not change. This file gives the reason for each of those records, so the approver of the unit's first run does not have to judge them by eye. It is deleted after the unit's first run.

## Counts

| NoChange | Modify | Ignore | Create | Delete |
|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 0 |

Each count is the number of resources with that result in the plain preview (what-if) of the unit's template. A stack preview lists only the resources the template declares, so the Ignore records do not appear in it. The scope of the unit is management group d1a349ef-6ac8-4588-a88d-5dab272c700b.

Every record of this unit is NoChange, so there is nothing to explain.

## Source

The records come from the read-only preview of the demo units, preview file `demo-tenant-management-group.json`. The gate judged them offline with scripts/deploy-unit.ps1 and deploy/boundaries.json, and its result for the unit is PASS.

The files of the unit the previews were taken from, each with the SHA256 of its text (line endings left out). The plan of the unit's first run compares them with the files of its commit and fails when one differs, because this evidence then belongs to another version of the unit.

- `infra/tenant/management-groups/main.bicep` SHA256 `7a8db5109dd4087cf6073542cf3f4e939e98b02001f44f79f5c5f9caae6af523`
- `infra/tenant/management-groups/main.bicepparam` SHA256 `69931495bb49469bd8b2f697762de95e7f81429587164e9a82fb1828d3c50515`
