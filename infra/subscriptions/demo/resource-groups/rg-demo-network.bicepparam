// Parameter file of the unit rg-demo-network in deploy/units.json. Its using line names the template,
// rg-demo-network.bicep. The deploy script and the sweep find the template through it.
using './rg-demo-network.bicep'

// The region of every resource in the group.
param location = 'uksouth'

// The object ID of the demo reader identity, which gets the Reader role on the group.
param readerPrincipalId = '3cb6119a-252a-4c48-9b48-60e7f4d8c7c5'
