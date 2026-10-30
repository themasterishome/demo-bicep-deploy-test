targetScope = 'subscription'

// The privileged part of the demo subscription: the Owner role assignment on the resource group rg-demo-network and
// the custom role definition Demo Reader Plus. This file is the template of the unit demo-privileged in
// deploy/units.json, deployed with privileged.bicepparam beside it. Only the subscription's privileged identity writes
// these, after approval in the environment mirror-privileged-demo, so the identity that deploys the rest of the
// subscription never has the right to grant itself or anyone else these roles. The other role assignments stay in the
// resource group files, deployed with their own units.
// A deployment never deletes, so removing a block here leaves the role in Azure until someone removes it by hand.

@description('Object ID of the identity that becomes Owner of rg-demo-network. privileged.bicepparam sets it.')
param ownerPrincipalId string

// The Owner assignment is written by a module, because it sits on the resource group and not on the subscription.
// `scope: resourceGroup('rg-demo-network')` points the module at that group, which the unit demo-subscription creates.
module roleAssignments_rg_demo_network 'governance/role-assignments/rg-demo-network.privileged.bicep' = {
  name: 'roleAssignments-rg-demo-network'
  scope: resourceGroup('rg-demo-network')
  params: {
    ownerPrincipalId: ownerPrincipalId
  }
}

// The custom role Demo Reader Plus. It reads resource groups and nothing else, and it can be assigned only in this
// subscription. The role's ID is a GUID built from the subscription ID and a fixed word, so it is the same on every
// deployment.
resource roleDefinition_demo_reader_plus 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'demo-reader-plus')
  properties: {
    roleName: 'Demo Reader Plus'
    description: 'Reads resource groups. Shows a custom role in the privileged tier.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Resources/subscriptions/resourceGroups/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}
