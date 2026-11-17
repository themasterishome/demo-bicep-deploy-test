// The template of the unit lifecycle-proof in deploy/units.json. It deploys into rg-demo-lifecycle, a resource group
// created by hand for this unit alone, and declares free resources only. The unit exists to show a stack's whole life
// in the pipeline: a first run that only creates, an update, a resource that leaves the template and is detached,
// and a resource that leaves it and is deleted.
targetScope = 'resourceGroup'

@description('Azure region of the resources. lifecycle.bicepparam sets it.')
param location string

resource networkSecurityGroup_nsg_life_a 'Microsoft.Network/networkSecurityGroups@2026-01-01' = {
  name: 'nsg-life-a'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    securityRules: []
  }
}
