targetScope = 'tenant'

// The tenant-level view of the demo estate. This file is compiled as a wiring check and is never deployed. It is
// not a unit in deploy/units.json, and no unit may be made from it. preflight-validate.ps1, which the validate
// workflow runs too, builds it to prove that the management group and the role assignment made on it fit together
// in one template.
// The parts that do deploy are units of their own, all disabled until they are enabled in a pull request:
// demo-tenant-management-group (management-groups/main.bicep) and demo-tenant-governance (governance.bicep), which
// the pipeline deploys through the mirror-privileged-tenant environment.
// A management group is a container above subscriptions, and access and policy set on it reach every subscription
// below it. The Tenant Root Group is the top one, and its name is the tenant ID. A module is another Bicep file
// called from this one, deployed as a nested deployment into the scope it names.

// A `param` is a value a parameter file can set, and `@description(...)` explains it. No parameter file uses this
// view, so the defaults are the values. They are the same as management-groups/main.bicepparam and
// governance.mg-demo.bicepparam hold, so a change to one must be made in the others too.
@description('Name of the demo management group.')
param managementGroupName string = 'mg-demo'

@description('Display name of the demo management group.')
param managementGroupDisplayName string = 'Demo'

@description('Object ID of the demo reader identity, which gets the Reader role on the management group.')
param readerPrincipalId string = '3cb6119a-252a-4c48-9b48-60e7f4d8c7c5'

// The management group mg-demo (unit demo-tenant-management-group).
module managementGroups './management-groups/main.bicep' = {
  name: 'demo-tenant-management-group'
  scope: managementGroup(tenant().tenantId)
  params: {
    managementGroupName: managementGroupName
    managementGroupDisplayName: managementGroupDisplayName
  }
}

// The Reader role assignment made on mg-demo (unit demo-tenant-governance). It waits for the group to exist.
module governanceDemo './governance.bicep' = {
  name: 'demo-tenant-governance'
  scope: managementGroup(managementGroupName)
  params: {
    readerPrincipalId: readerPrincipalId
  }
  dependsOn: [
    managementGroups
  ]
}
