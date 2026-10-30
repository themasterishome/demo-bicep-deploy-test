using './privileged.bicep'

// Parameter file of the demo-privileged unit in deploy/units.json. The `using` line names the template these values
// belong to.

// The object ID of the demo privileged identity, which becomes Owner of the resource group rg-demo-network.
param ownerPrincipalId = '624a20b2-4a7b-41ab-a228-bab53009c5f2'
