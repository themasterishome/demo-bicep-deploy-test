targetScope = 'subscription'

// Demo subscription layer. It declares the three resource groups of the demo estate, written out as they are
// live: name, region and tags. It is the template of the unit demo-subscription in deploy/units.json, deployed
// with parameters.bicepparam. A unit is the smallest set of files that is approved and deployed together, and
// every unit stays disabled until it is enabled in a pull request.
// The resources inside the groups are not here. Each group has its own file, resource-groups/<group>.bicep,
// which is the template of a unit of its own, and this file does not call those files. One group per unit means
// one dry run and one approval per group, and a failed deployment touches that group only.
// The groups are created by hand before the first deployment, as the set-up guide shows, with the same name,
// region and tags as below, so the preview of this file shows NoChange for each of them.

@description('Azure region of the three resource groups. parameters.bicepparam sets it.')
param location string

// The symbol after `resource`, such as resourceGroup_rg_demo_pilot, is the name Bicep uses for the resource
// inside this file. Renaming a symbol is safe for Azure, but every reference to it must change too.

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
