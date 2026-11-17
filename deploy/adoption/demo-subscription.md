# Adoption evidence for demo-subscription

The gate accepted every record of this unit.

This file is written by adoption/adoption.py from saved previews and is never edited by hand. A deployment stack has no baseline before its first apply, so the first preview of this unit still lists differences that Azure reports and a deployment does not change. This file gives the reason for each of those records, so the approver of the unit's first run does not have to judge them by eye. It is deleted after the unit's first run.

## Counts

| NoChange | Modify | Ignore | Create | Delete |
|---|---|---|---|---|
| 5 | 0 | 14 | 0 | 0 |

Each count is the number of resources with that result in the plain preview (what-if) of the unit's template. A stack preview lists only the resources the template declares, so the Ignore records do not appear in it. The scope of the unit is subscription 77488719-1168-4d53-af9a-f5c3bc9291d7.

## Accepted records that are not NoChange

Resources are written without the leading `/subscriptions/<ID>/`. The brackets after a property path hold what the preview reports for that property and the number of its reason. Create means the code sets the property and Azure does not return it, Delete means Azure returns it and the code leaves it out, Modify means the two values differ, and NoEffect means a deployment does not change it. The numbers in the Reason column point to the list under Reasons.

| Resource | Result | Property paths that differ | Reason |
|---|---|---|---|
| resourceGroups/rg-demo-identities/providers/Microsoft.KeyVault/vaults/kv-demo-mirror-secrets | Ignore |  | 1 |
| resourceGroups/rg-demo-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mirror-deploy-demo | Ignore |  | 1 |
| resourceGroups/rg-demo-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mirror-govern-demo | Ignore |  | 1 |
| resourceGroups/rg-demo-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mirror-govern-tenant | Ignore |  | 1 |
| resourceGroups/rg-demo-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mirror-reader | Ignore |  | 1 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/networkInterfaces/pe-kv-demo-mirror-secrets.nic.eb38a253-dbcb-4c80-aa62-49c7eb627724 | Ignore |  | 2 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/networkSecurityGroups/nsg-demo | Ignore |  | 3 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net | Ignore |  | 3 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net/virtualNetworkLinks/link-vnet-demo | Ignore |  | 3 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/privateEndpoints/pe-kv-demo-mirror-secrets | Ignore |  | 3 |
| resourceGroups/rg-demo-network/providers/Microsoft.Network/virtualNetworks/vnet-demo | Ignore |  | 3 |
| resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets | Ignore |  | 3 |
| resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo | Ignore |  | 3 |
| resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo | Ignore |  | 3 |

## Reasons

A boundary is a field Azure owns, whose difference the gate accepts (inert) or stops on for a person to read (review). A hold is a resource the gate refuses to deploy. An expected Ignore record is a live resource that is deliberately not declared in the unit that previews it.

1. Expected Ignore record. The identities and the secrets vault of rg-demo-identities. The unit demo-subscription writes the group and never what is in it, and a preview of the unit lists the contents as Ignore. They are declared in resource-groups/rg-demo-identities.deploy-excluded.bicep and previewed with parameters.verify.bicepparam. This reason applies to 5 records.
2. Expected Ignore record. The network card Azure creates for the private endpoint pe-kv-demo-mirror-secrets. Azure names it after the endpoint with a generated suffix and owns it, so the code does not declare it. This reason applies to 1 record.
3. The live resource is not declared in this unit, so a deployment of the unit leaves it alone. This reason applies to 8 records.

## Source

The records come from the read-only preview of the demo units, preview file `demo-subscription.json`. The gate judged them offline with scripts/deploy-unit.ps1 and deploy/boundaries.json, and its result for the unit is PASS.

The files of the unit the previews were taken from, each with the SHA256 of its text (line endings left out). The plan of the unit's first run compares them with the files of its commit and fails when one differs, because this evidence then belongs to another version of the unit.

- `infra/subscriptions/demo/main.bicep` SHA256 `b8f12c376ebeec59a52249e5d5437738ac8ef787cf984be9aa10138c8f748ed6`
- `infra/subscriptions/demo/parameters.bicepparam` SHA256 `9ec5596ca673156079347766d7954de80f9a4a642b7b462db31ef6f0a00f9293`
