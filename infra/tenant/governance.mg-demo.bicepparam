using './governance.bicep'

// Parameter file of the unit demo-tenant-governance in deploy/units.json. The `using` line names the template these
// values are for. The unit is disabled until it is enabled in a pull request. Preview it with the command below.
//   az deployment mg what-if --management-group-id mg-demo --location uksouth --name whatif-$(date +%s)
//     --parameters <this file> --result-format FullResourcePayloads --validation-level ProviderNoRbac

// The object ID of the demo reader identity, which gets the Reader role on the group.
param readerPrincipalId = '3cb6119a-252a-4c48-9b48-60e7f4d8c7c5'
