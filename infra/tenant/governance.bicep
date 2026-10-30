targetScope = 'managementGroup'

// The role assignment made on the management group mg-demo. This file is the template of the unit
// demo-tenant-governance in deploy/units.json, with governance.mg-demo.bicepparam beside it. It deploys at management
// group scope against mg-demo, which the unit demo-tenant-management-group creates, so that unit runs first. The
// pipeline runs it through the mirror-privileged-tenant environment.

@description('Object ID of the identity that gets the Reader role on the management group. governance.mg-demo.bicepparam sets it.')
param readerPrincipalId string

// The Reader role (acdd72a7-3385-48ef-bd42-f606fba81ae7). The name is a GUID built from the group, the principal and a
// fixed word, so it is the same on every deployment and a second deployment finds the same assignment.
resource roleAssignment_reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, readerPrincipalId, 'reader')
  properties: {
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
  }
}
