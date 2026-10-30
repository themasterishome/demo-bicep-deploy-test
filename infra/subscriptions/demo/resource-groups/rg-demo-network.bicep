// Resource group rg-demo-network in the demo subscription. It holds every resource in the group, written out exactly
// as it is live. This is the resource group file, the one file to edit for a change to these resources. It holds one
// network security group and one virtual network with one subnet, which the network security group protects, and the
// group's own lock, policy assignment and Reader role assignment. All of them are free.
// It is deployed by the unit rg-demo-network in deploy/units.json, with rg-demo-network.bicepparam beside it. A unit
// is the smallest set of files that is approved and deployed together, and every unit stays disabled until it is
// enabled in a pull request.

// The file's two parameters. @description(...) is the text shown for each, and param declares a value that the parameter
// file can set. rg-demo-network.bicepparam sets location to uksouth, and every resource with location: location uses it.
@description('Azure region for resources in this resource group. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Object ID of the demo reader identity, the principal that gets the Reader role on this resource group. rg-demo-network.bicepparam sets it.')
param readerPrincipalId string

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

// The lock on the resource group. CanNotDelete lets every write through and refuses only a delete, of the group or
// of anything in it. Its name is fixed, so a second deployment finds the same lock. To delete the group, remove the
// lock first.
resource lock_rg_demo_network 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'lock-rg-demo-network'
  properties: {
    level: 'CanNotDelete'
    notes: 'Keeps the demo network group from being deleted by accident.'
  }
}

// The built-in policy "Audit resource location matches resource group location", assigned to this resource group.
// Its effect is audit, so it only reports a resource placed in another region and blocks nothing. The assignment
// name is a GUID built from the group's ID and a fixed word, so it is the same on every deployment.
resource policyAssignment_resource_location 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: guid(resourceGroup().id, 'audit-resource-location')
  properties: {
    displayName: 'Audit resource location matches resource group location'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '0a914e76-4921-4c19-b460-a2d36003525a')
    enforcementMode: 'Default'
    definitionVersion: '2.*.*'
  }
}

// The Reader role (acdd72a7-3385-48ef-bd42-f606fba81ae7) for the demo reader identity on this resource group. Reader
// is not one of the three roles the production tier may not write, so this record deploys with the rest of the
// group. The name is a GUID built from the group, the principal and the role, so it is the same on every deployment.
resource roleAssignment_reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, readerPrincipalId, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}
