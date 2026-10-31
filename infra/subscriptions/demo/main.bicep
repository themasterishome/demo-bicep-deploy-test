targetScope = 'subscription'

// Demo subscription layer. It declares the four resource groups of the demo estate, written out as they are
// live: name, region and tags. It is the template of the unit demo-subscription in deploy/units.json, deployed
// with parameters.bicepparam. A unit is the smallest set of files that is approved and deployed together, and
// every unit stays disabled until it is enabled in a pull request.
// The resources inside the groups are not here. Each group has its own file, resource-groups/<group>.bicep,
// which is the template of a unit of its own, and this file calls none of them except the identity group's, behind a
// switch that is off. One group per unit means
// one dry run and one approval per group, and a failed deployment touches that group only.
// The groups are created by hand before the first deployment, as the set-up guide shows, with the same name,
// region and tags as below, so the preview of this file shows NoChange for each of them.

@description('Azure region of the three resource groups. parameters.bicepparam sets it.')
param location string

// The symbol after `resource`, such as resourceGroup_rg_demo_pilot, is the name Bicep uses for the resource
// inside this file. Renaming a symbol is safe for Azure, but every reference to it must change too.

// The group of the pipeline's identities and its secrets vault. The unit writes the group itself and never what is in
// it. The deploy identity holds Contributor on the three workload groups only, so a deployment from the pipeline could
// not write there, and that is the point of the group.
resource resourceGroup_rg_demo_identities 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-demo-identities'
  location: location
  tags: {}
}

// rg-demo-identities also has its own file, resource-groups/rg-demo-identities.deploy-excluded.bicep, which declares
// the four identities with their federated credentials, the vault and the role assignments on it, as they are live.
// `if (deployIdentityGroup)` makes the module depend on a switch. It is off in parameters.bicepparam, so the unit never
// writes the group's contents, and on in parameters.verify.bicepparam, so a preview still checks them.
module rg_demo_identities_excluded './resource-groups/rg-demo-identities.deploy-excluded.bicep' = if (deployIdentityGroup) {
  name: 'rg-demo-identities-excluded'
  scope: resourceGroup('rg-demo-identities')
  dependsOn: [
    resourceGroup_rg_demo_identities
  ]
}

@description('The contents of rg-demo-identities, the pipeline identity group no pipeline identity may write. Off for deployments. parameters.verify.bicepparam turns it on so a preview keeps checking them.')
param deployIdentityGroup bool = false

// The group of the pilot unit, pilot-empty-rg. It stays empty.
resource resourceGroup_rg_demo_pilot 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-demo-pilot'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
}

// The group of the unit rg-demo-network: one network security group and one virtual network.
resource resourceGroup_rg_demo_network 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-demo-network'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
}

// The group of the unit rg-demo-routing: one route table and one application security group.
resource resourceGroup_rg_demo_routing 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-demo-routing'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
}

// The Defender for Cloud plan for virtual machines, at the value it has live. The deploy identity writes it through
// the custom role Mirror Platform Deployment, so the subscription unit shows how that role is used.
resource defenderPlan_VirtualMachines 'Microsoft.Security/pricings@2026-07-01' = {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Free'
  }
}
