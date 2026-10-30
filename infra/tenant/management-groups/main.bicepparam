using './main.bicep'

// Parameter file of the unit demo-tenant-management-group in deploy/units.json. The `using` line names the template
// these values are for. The unit is disabled until it is enabled in a pull request.

// The name and the display name of the management group.
param managementGroupName = 'mg-demo'
param managementGroupDisplayName = 'Demo'
