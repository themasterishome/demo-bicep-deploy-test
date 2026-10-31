using './main.bicep'

// The preview-only parameter file of the demo-subscription unit. It holds the same values as parameters.bicepparam,
// except that deployIdentityGroup is on. A preview of main.bicep with this file also previews the contents of
// rg-demo-identities in resource-groups/rg-demo-identities.deploy-excluded.bicep, which the unit demo-subscription
// never writes.
// Do NOT deploy from this file. The deploy identity holds no role on rg-demo-identities, so Azure refuses the write
// with AuthorizationFailed, and that refusal is by design. The group is changed by hand, at the setup steps of the guide.
// If you change a value in parameters.bicepparam, change it here too, so the preview keeps showing what the unit
// deploys.

param location = 'uksouth'
param deployIdentityGroup = true
