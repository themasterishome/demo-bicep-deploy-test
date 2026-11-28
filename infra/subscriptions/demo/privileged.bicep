targetScope = 'subscription'

// The privileged part of the demo subscription: the Owner role assignment on the resource group rg-demo-network and
// the custom role definition Demo Reader Plus. This file is the template of the unit demo-privileged in
// deploy/units.json, deployed with privileged.bicepparam beside it. Only the subscription's govern identity writes
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

// The Role Based Access Control Administrator of the deploy identity id-mirror-deploy-demo, with the condition that limits which roles it may assign.
// A deployment writes the assignment as it is declared, so the condition must stay with it, or Azure removes it.
resource roleAssignment_deployIdentityCondition 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'ffa17cf3-49f5-47e6-b1b5-ec2221a215b4'
  properties: {
    principalId: '0d43c706-ffc6-4320-b895-90a49fad6a25'
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')
  }
}

// The User Access Administrator of the govern identity id-mirror-govern-demo, with the condition that limits which roles it may assign.
// A deployment writes the assignment as it is declared, so the condition must stay with it, or Azure removes it.
resource roleAssignment_governIdentityCondition 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'ceb0f226-35c2-4a9c-b64e-c7f2a0a72e26'
  properties: {
    principalId: '624a20b2-4a7b-41ab-a228-bab53009c5f2'
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9')
  }
}
