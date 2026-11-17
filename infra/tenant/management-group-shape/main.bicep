targetScope = 'managementGroup'

// A child management group of the group the unit deploys against, and the link of one subscription to that child.
// This file is the template of the unit demo-tenant-shape in deploy/units.json, with main.bicepparam beside it. It has
// the shape of the template that declares a management group under the Tenant Root Group and places a subscription
// under it: the child group is a resource with `scope: tenant()`, and the link is a child resource of that group. The
// unit deploys at management group scope against mg-demo-stk, a group created by hand for it, so nothing is assigned
// at the tenant root.

@description('Name of the management group the unit deploys against. It is the parent of the child group.')
param parentName string

@description('Name of the child management group to create.')
param childManagementGroupName string

@description('Display name shown for the child management group.')
param childManagementGroupDisplayName string

@description('Whether the template declares the child management group. Off leaves it out of the template.')
param declareChild bool = true

@description('Subscription ID to link to the child management group. Empty links none.')
param childSubscriptionId string = ''

resource childManagementGroup 'Microsoft.Management/managementGroups@2023-04-01' = if (declareChild) {
  scope: tenant()
  name: childManagementGroupName
  properties: {
    displayName: childManagementGroupDisplayName
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', parentName)
      }
    }
  }
}

// `parent:` places the link under the child group, and its name is the subscription ID.
resource subscriptionLink 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = if (declareChild && !empty(childSubscriptionId)) {
  parent: childManagementGroup
  name: childSubscriptionId
}
