// Parameter file of the unit rg-demo-routing in deploy/units.json. Its using line names the template,
// rg-demo-routing.bicep. The deploy script and the sweep find the template through it.
using './rg-demo-routing.bicep'

// The region of every resource in the group.
param location = 'uksouth'
