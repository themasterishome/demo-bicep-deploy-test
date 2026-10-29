// Parameter file of the unit rg-demo-network in deploy/units.json. Its using line names the template,
// rg-demo-network.bicep. The deploy script and the sweep find the template through it.
using './rg-demo-network.bicep'

// The region of every resource in the group.
param location = 'uksouth'
