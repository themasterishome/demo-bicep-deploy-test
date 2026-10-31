// Resource group rg-demo-routing in the demo subscription. It holds every resource in the group, written out exactly
// as it is live. This is the resource group file, the one file to edit for a change to these resources. It holds one
// route table with no routes and one application security group, and an Automation account with one credential whose
// password comes from the secrets vault. All of them are free.
// It is deployed by the unit rg-demo-routing in deploy/units.json, with rg-demo-routing.bicepparam beside it. A unit
// is the smallest set of files that is approved and deployed together, and every unit stays disabled until it is
// enabled in a pull request.

// The file's one parameter. @description(...) is the text shown for it, and param declares a value that the parameter
// file can set. rg-demo-routing.bicepparam sets it to uksouth, and every resource with location: location uses it.
@description('Azure region for resources in this resource group. Defaults to the resource group location.')
param location string = resourceGroup().location

// The password of the Automation credential demo-cred. @secure() keeps the value out of the deployment history and the
// logs. The parameter has no default, so the value must come from rg-demo-routing.bicepparam, which reads it from the
// vault kv-demo-mirror-secrets with az.getSecret. The routine pipeline never sees the value.
@secure()
@description('Password of the Automation credential demo-cred. rg-demo-routing.bicepparam reads it from the vault with az.getSecret.')
param demoCredPassword string

// The name after the word resource, such as routeTable_rt_demo, is the symbol name Bicep uses inside this file, built
// from the resource type and the live name. Renaming a symbol is safe for Azure, but every reference to it must change
// with it.

// The route table. It has no routes and is linked to no subnet, so it changes no traffic. disableBgpRoutePropagation
// is Azure's default, declared because live returns it after the first write.
resource routeTable_rt_demo 'Microsoft.Network/routeTables@2026-01-01' = {
  name: 'rt-demo'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    disableBgpRoutePropagation: false
    routes: []
  }
}

// The application security group. It groups network cards by role for the rules of a network security group. No
// network card and no rule uses it, and it has no settings of its own.
resource applicationSecurityGroup_asg_demo 'Microsoft.Network/applicationSecurityGroups@2026-01-01' = {
  name: 'asg-demo'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {}
}

// The Automation account, on the Free tier, with no runbooks. It exists to hold the credential below, so a unit that
// reads a secret from the vault has something to write it into.
resource automationAccount_aa_demo_secrets 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: 'aa-demo-secrets'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    sku: {
      name: 'Free'
    }
  }
}

// The credential demo-cred. Its user name is plain text. Its password is the secure parameter above, which the
// deployment reads from the vault. Azure never returns a password, so the preview cannot compare it, and the
// deployment's second check proves only that nothing else differs.
resource automationCredential_demo_cred 'Microsoft.Automation/automationAccounts/credentials@2024-10-23' = {
  parent: automationAccount_aa_demo_secrets
  name: 'demo-cred'
  properties: {
    userName: 'demo-user'
    password: demoCredPassword
    description: 'Demo credential whose password is read from kv-demo-mirror-secrets.'
  }
}
