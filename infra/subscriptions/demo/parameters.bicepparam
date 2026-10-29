using './main.bicep'

// Parameter file of the demo-subscription unit in deploy/units.json. It holds the values main.bicep deploys with.
// The `using` line names the template these values belong to.

// The region of the three resource groups.
param location = 'uksouth'
