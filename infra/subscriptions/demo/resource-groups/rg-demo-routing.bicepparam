// Parameter file of the unit rg-demo-routing in deploy/units.json. Its using line names the template,
// rg-demo-routing.bicep. The deploy script and the sweep find the template through it.
using './rg-demo-routing.bicep'

// The region of every resource in the group.
param location = 'uksouth'

// The password of the Automation credential demo-cred, read at deployment from the secret demo-automation-password in
// the vault kv-demo-mirror-secrets. The four arguments are the vault's subscription ID, its resource group, its name
// and the secret's name. The deploy identity needs the role Mirror Key Vault Deployment on the vault to use this.
param demoCredPassword = az.getSecret('77488719-1168-4d53-af9a-f5c3bc9291d7', 'rg-demo-identities', 'kv-demo-mirror-secrets', 'demo-automation-password')
