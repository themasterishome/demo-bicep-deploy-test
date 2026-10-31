// Resource group rg-demo-network in the demo subscription. It holds every resource in the group, written out exactly
// as it is live. This is the resource group file, the one file to edit for a change to these resources. It holds one
// network security group and one virtual network with one subnet, which the network security group protects, and the
// group's own lock, policy assignment and Reader role assignment, and the private endpoint of the secrets vault with
// its DNS zone, link and zone group. All of them are free except the private endpoint, which costs a few pounds a month.
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

// The private DNS zone for private endpoints of Key Vault. A private endpoint's address is registered in this zone, so
// a machine on the linked network resolves the vault's name to the private address. A private DNS zone is global, so
// its location is the word global. It is the same zone name the project's vault endpoint uses.
resource privateDnsZone_privatelink_vaultcore_azure_net 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {}
}

// The link that makes the zone visible on vnet-demo. Registration is off, because only the endpoint's zone group
// writes records here.
resource virtualNetworkLink_link_vnet_demo 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone_privatelink_vaultcore_azure_net
  name: 'link-vnet-demo'
  location: 'global'
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    registrationEnabled: false
    resolutionPolicy: 'Default'
    virtualNetwork: {
      id: virtualNetwork_vnet_demo.id
    }
  }
}

// The private endpoint of the demo's secrets vault kv-demo-mirror-secrets, which lives in rg-demo-identities. The vault
// has public network access disabled, so a person who writes a secret reaches it only through this address in the
// subnet snet-default. A private endpoint must sit in the subscription of its network, which is why it is declared
// here and not with the vault. A deployment that reads a secret with getSecret needs no endpoint, because Azure
// Resource Manager is a trusted service of the vault. NIC, IP, DNS and connection status are reported by the provider
// and are not declared. The API version is 2025-09-01, not 2026-01-01, because the newer version previews the
// provider-set billingSku as a change.
resource privateEndpoint_pe_kv_demo_mirror_secrets 'Microsoft.Network/privateEndpoints@2025-09-01' = {
  name: 'pe-kv-demo-mirror-secrets'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    ipVersionType: 'IPv4'
    manualPrivateLinkServiceConnections: []
    privateLinkServiceConnections: [
      {
        name: 'kv-demo-mirror-secrets'
        properties: {
          privateLinkServiceId: resourceId(subscription().subscriptionId, 'rg-demo-identities', 'Microsoft.KeyVault/vaults', 'kv-demo-mirror-secrets')
          groupIds: [
            'vault'
          ]
        }
      }
    ]
    subnet: {
      id: '${virtualNetwork_vnet_demo.id}/subnets/snet-default'
    }
  }
}

// The endpoint's record in the zone above, so that the vault's name resolves to the private address on vnet-demo.
resource privateDnsZoneGroup_pe_kv_demo_mirror_secrets_default 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-01-01' = {
  parent: privateEndpoint_pe_kv_demo_mirror_secrets
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vaultcore'
        properties: {
          privateDnsZoneId: privateDnsZone_privatelink_vaultcore_azure_net.id
        }
      }
    ]
  }
}
