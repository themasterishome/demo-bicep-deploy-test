targetScope = 'managementGroup'

// The management group mg-demo, a container above subscriptions. This file is the template of the unit
// demo-tenant-management-group in deploy/units.json, with main.bicepparam beside it. It deploys at management group
// scope against the Tenant Root Group, whose name is the tenant ID, so nothing is ever assigned at the tenant root `/`.
// The group has no subscription link, so it holds nothing yet. The pipeline runs it through the
// mirror-privileged-tenant environment.

// A `param` is a value the parameter file sets, and `@description(...)` explains it.
@description('Name of the management group to create under the Tenant Root Group.')
param managementGroupName string

@description('Display name shown for the management group.')
param managementGroupDisplayName string

// `scope: tenant()` creates the group at the top of the tenant. `details.parent` places it directly under the Tenant
// Root Group, whose name is the tenant ID.
resource managementGroup 'Microsoft.Management/managementGroups@2023-04-01' = {
  scope: tenant()
  name: managementGroupName
  properties: {
    displayName: managementGroupDisplayName
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', tenant().tenantId)
      }
    }
  }
}
