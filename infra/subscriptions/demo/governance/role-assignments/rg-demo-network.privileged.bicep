targetScope = 'resourceGroup'

// The Owner role assignment on the resource group rg-demo-network. This module is called by privileged.bicep with
// its scope set to that group, because a role assignment on a group is written at the group's own scope. Owner is one
// of the three roles the production tier may not write, so it lives here, in the privileged tier.

@description('Object ID of the identity that becomes Owner of the group. privileged.bicepparam sets it.')
param ownerPrincipalId string

// The Owner role (8e3af657-a8ff-443c-a75c-2fe8c4bcb635). The name is a GUID built from the group, the principal and
// the role, so it is the same on every deployment and a second deployment finds the same assignment.
resource roleAssignment_owner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, ownerPrincipalId, '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
  properties: {
    principalId: ownerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635') // Owner
  }
}
