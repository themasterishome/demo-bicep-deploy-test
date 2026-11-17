using './main.bicep'

// Parameter file of the unit demo-tenant-shape in deploy/units.json. The `using` line names the template these values
// are for.

param parentName = 'mg-demo-stk'
param childManagementGroupName = 'mg-demo-stk-child'
param childManagementGroupDisplayName = 'Demo stack child'
param childSubscriptionId = ''
