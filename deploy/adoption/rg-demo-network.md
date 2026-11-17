# Adoption evidence for rg-demo-network

The gate accepted every record of this unit.

This file is written by adoption/adoption.py from saved previews and is never edited by hand. A deployment stack has no baseline before its first apply, so the first preview of this unit still lists differences that Azure reports and a deployment does not change. This file gives the reason for each of those records, so the approver of the unit's first run does not have to judge them by eye. It is deleted after the unit's first run.

## Counts

| NoChange | Modify | Ignore | Create | Delete |
|---|---|---|---|---|
| 8 | 1 | 1 | 0 | 0 |

Each count is the number of resources with that result in the plain preview (what-if) of the unit's template. A stack preview lists only the resources the template declares, so the Ignore records do not appear in it. The scope of the unit is 77488719-1168-4d53-af9a-f5c3bc9291d7 / rg-demo-network.

## Accepted records that are not NoChange

Resources are written without the leading `/subscriptions/<ID>/`. The brackets after a property path hold what the preview reports for that property and the number of its reason. Create means the code sets the property and Azure does not return it, Delete means Azure returns it and the code leaves it out, Modify means the two values differ, and NoEffect means a deployment does not change it. The numbers in the Reason column point to the list under Reasons.

| Resource | Result | Property paths that differ | Reason |
|---|---|---|---|
| resourceGroups/rg-demo-network/providers/Microsoft.Network/privateEndpoints/pe-kv-demo-mirror-secrets/privateDnsZoneGroups/default | Modify | `properties.privateDnsZoneConfigs[*].etag` (Delete, reason 1)<br>`properties.privateDnsZoneConfigs[*].id` (Delete, reason 2)<br>`properties.privateDnsZoneConfigs[*].properties.provisioningState` (Delete, reason 3)<br>`properties.privateDnsZoneConfigs[*].type` (Delete, reason 4) | 1, 2, 3, 4 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/networkInterfaces/pe-kv-demo-mirror-secrets.nic.eb38a253-dbcb-4c80-aa62-49c7eb627724 | Ignore |  | 5 |

## Reasons

A boundary is a field Azure owns, whose difference the gate accepts (inert) or stops on for a person to read (review). A hold is a resource the gate refuses to deploy. An expected Ignore record is a live resource that is deliberately not declared in the unit that previews it.

1. Inert boundary of Microsoft.Network/privateEndpoints/privateDnsZoneGroups at `properties.privateDnsZoneConfigs[*].etag`. Provider response field. Azure gives the zone group a new etag on every write, so the code cannot carry it (declaring it gives NoChange once and a Modify after every write). A rewrite without it is accepted, as for id. This reason applies to 1 record.
2. Inert boundary of Microsoft.Network/privateEndpoints/privateDnsZoneGroups at `properties.privateDnsZoneConfigs[*].id`. Provider response field on each zone config. A rewrite of the same zone group without it is accepted and leaves the A record untouched (same IP, TTL, id and record etag). This reason applies to 1 record.
3. Inert boundary of Microsoft.Network/privateEndpoints/privateDnsZoneGroups at `properties.privateDnsZoneConfigs[*].properties.provisioningState`. Provider response field. A rewrite without it is accepted and leaves the A record untouched, as for id. This reason applies to 1 record.
4. Inert boundary of Microsoft.Network/privateEndpoints/privateDnsZoneGroups at `properties.privateDnsZoneConfigs[*].type`. Provider response field. A rewrite without it is accepted and leaves the A record untouched, as for id. This reason applies to 1 record.
5. Expected Ignore record. The network card Azure creates for the private endpoint pe-kv-demo-mirror-secrets. Azure names it after the endpoint with a generated suffix and owns it, so the code does not declare it. This reason applies to 1 record.

## Source

The records come from the read-only preview of the demo units, preview file `rg-demo-network.json`. The gate judged them offline with scripts/deploy-unit.ps1 and deploy/boundaries.json, and its result for the unit is PASS.

The files of the unit the previews were taken from, each with the SHA256 of its text (line endings left out). The plan of the unit's first run compares them with the files of its commit and fails when one differs, because this evidence then belongs to another version of the unit.

- `infra/subscriptions/demo/resource-groups/rg-demo-network.bicep` SHA256 `29f673ef4d95a8ef36e1239700b911ef8392e1fb90bb90e8d03715c726208a36`
- `infra/subscriptions/demo/resource-groups/rg-demo-network.bicepparam` SHA256 `0c982d630a62bc692ad7a60a1545e6e0c09b9fd432fc9b371705d11937a1f8b0`
