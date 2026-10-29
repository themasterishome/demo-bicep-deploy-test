// Resource group rg-demo-network in the demo subscription. It holds every resource in the group, written out exactly
// as it is live. This is the resource group file, the one file to edit for a change to these resources. It holds one
// network security group and one virtual network with one subnet, which the network security group protects. Both
// are free.
// It is deployed by the unit rg-demo-network in deploy/units.json, with rg-demo-network.bicepparam beside it. A unit
// is the smallest set of files that is approved and deployed together, and every unit stays disabled until it is
// enabled in a pull request.

// The file's one parameter. @description(...) is the text shown for it, and param declares a value that the parameter
// file can set. rg-demo-network.bicepparam sets it to uksouth, and every resource with location: location uses it.
@description('Azure region for resources in this resource group. Defaults to the resource group location.')
param location string = resourceGroup().location

// The name after the word resource, such as networkSecurityGroup_nsg_demo, is the symbol name Bicep uses inside this
// file, built from the resource type and the live name. Renaming a symbol is safe for Azure, but every reference to it
// must change with it.

// The network security group of the subnet snet-default. It has no rules of its own, so only the default rules
// Azure adds to every network security group apply. Those default rules are not declared, because Azure keeps them
// apart from securityRules.
resource networkSecurityGroup_nsg_demo 'Microsoft.Network/networkSecurityGroups@2026-01-01' = {
  name: 'nsg-demo'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    securityRules: []
  }
}

// The virtual network, with its one subnet written inside it, as live returns it. The values below that are
// Azure's own defaults (enableDdosProtection, privateEndpointVNetPolicies and the two network policies of the
// subnet) are declared, because live returns them after the first write and a file that left them out would
// preview as Modify.
resource virtualNetwork_vnet_demo 'Microsoft.Network/virtualNetworks@2026-01-01' = {
  name: 'vnet-demo'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.250.0.0/24'
      ]
    }
    enableDdosProtection: false
    privateEndpointVNetPolicies: 'Disabled'
    subnets: [
      {
        name: 'snet-default'
        properties: {
          addressPrefix: '10.250.0.0/26'
          networkSecurityGroup: {
            id: networkSecurityGroup_nsg_demo.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          serviceEndpoints: []
          delegations: []
        }
      }
    ]
  }
}
