// Resource group rg-demo-identities in the demo subscription. The file declares the group's resources, written out as
// they are live. main.bicep deploys this file only when deployIdentityGroup is on. parameters.bicepparam leaves it off
// and parameters.verify.bicepparam, which a preview turns on, switches it on.
// This is a deploy-excluded file. The group holds the pipeline's own plumbing: the four user-assigned managed
// identities the pipeline signs in with, their federated credentials, and the vault that holds the secrets a
// deployment reads at deploy time. The deploy identity holds Contributor on the three workload groups only, so a
// deployment from the pipeline could never write here, and that is what keeps the identity from changing its own
// credentials or granting itself a read of the vault. The group is changed by hand, at the setup steps of the guide.
// Edit a block here only to bring it in line with live, and preview it with parameters.verify.bicepparam.
// Do NOT turn deployIdentityGroup on in parameters.bicepparam. The pipeline's own preview of the unit would then fail
// on this group with AuthorizationFailed, which is the right answer.
// The group has a lock of its own, set by hand and not declared here.

// The one parameter is the region of the group. A resource with `location: location` uses that region.
@description('Azure region for resources in this resource group. Defaults to the resource group location.')
param location string = resourceGroup().location

// The reader identity. It signs in for every preview and writes nothing. clientId, principalId and tenantId are
// reported by the provider and are not declared. isolationScope is Azure's default, declared because live returns it.
resource userAssignedIdentity_id_mirror_reader 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-mirror-reader'
  location: location
  tags: {}
  properties: {
    isolationScope: 'None'
  }
}

// The reader's two federated credentials, one per environment it signs in from. The subject names the repository
// and the environment, with the owner and repository IDs, which is the form GitHub uses for a repository created
// after its cut-off.
resource federatedCredential_mirror_reader 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: userAssignedIdentity_id_mirror_reader
  name: 'mirror-reader'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:themasterishome@49098959/demo-bicep-deploy-test@1440203771:environment:mirror-reader'
  }
}

resource federatedCredential_mirror_reader_dispatch 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: userAssignedIdentity_id_mirror_reader
  name: 'mirror-reader-dispatch'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:themasterishome@49098959/demo-bicep-deploy-test@1440203771:environment:mirror-reader-dispatch'
  }
}

// The deploy identity of the production units.
resource userAssignedIdentity_id_mirror_deploy_demo 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-mirror-deploy-demo'
  location: location
  tags: {}
  properties: {
    isolationScope: 'None'
  }
}

resource federatedCredential_mirror_production_demo 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: userAssignedIdentity_id_mirror_deploy_demo
  name: 'mirror-production-demo'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:themasterishome@49098959/demo-bicep-deploy-test@1440203771:environment:mirror-production-demo'
  }
}

// The govern identity of the subscription's privileged unit.
resource userAssignedIdentity_id_mirror_govern_demo 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-mirror-govern-demo'
  location: location
  tags: {}
  properties: {
    isolationScope: 'None'
  }
}

resource federatedCredential_mirror_privileged_demo 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: userAssignedIdentity_id_mirror_govern_demo
  name: 'mirror-privileged-demo'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:themasterishome@49098959/demo-bicep-deploy-test@1440203771:environment:mirror-privileged-demo'
  }
}

// The govern identity of the two tenant units.
resource userAssignedIdentity_id_mirror_govern_tenant 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-mirror-govern-tenant'
  location: location
  tags: {}
  properties: {
    isolationScope: 'None'
  }
}

resource federatedCredential_mirror_privileged_tenant 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: userAssignedIdentity_id_mirror_govern_tenant
  name: 'mirror-privileged-tenant'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:themasterishome@49098959/demo-bicep-deploy-test@1440203771:environment:mirror-privileged-tenant'
  }
}

// The vault that holds the secrets a deployment needs, read with getSecret in a unit's parameter file. The first
// secret is demo-automation-password. Azure role-based access, soft delete for 90 days and purge protection, which
// cannot be turned off again. enabledForTemplateDeployment is what lets Azure Resource Manager read a secret for a
// deployment. Public network access is disabled, so only Azure's trusted services (the template deployment service is
// one) and the private endpoint pe-kv-demo-mirror-secrets in rg-demo-network reach it.
resource vault_kv_demo_mirror_secrets 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: 'kv-demo-mirror-secrets'
  location: location
  tags: { purpose: 'demo-bicep-deploy' }
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enableRbacAuthorization: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

// Key Vault Secrets Officer on the vault for the person who writes the values. The pipeline's identities never hold a
// secrets role here. A role assignment's name is the GUID Azure gave it live. The vault has no audit log, because the
// demo subscription has no Log Analytics workspace of its own to send it to.
resource roleAssignment_kv_demo_mirror_secrets_secrets_officer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: '0cf89ffa-3af2-47aa-a5da-a8df7e99f2a3'
  scope: vault_kv_demo_mirror_secrets
  properties: {
    principalId: '59908e41-4a5e-4e5c-be85-1d8bca08039c'
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets Officer
  }
}

// Mirror Key Vault Deployment on the vault for the deploy identity. The role carries
// Microsoft.KeyVault/vaults/deploy/action and nothing else, which is what lets a deployment of the identity's units
// read a secret with getSecret. It does not let the identity read the secret itself.
resource roleAssignment_kv_demo_mirror_secrets_deployment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: '24a9203a-74f4-4390-86fc-388443288b38'
  scope: vault_kv_demo_mirror_secrets
  properties: {
    principalId: '0d43c706-ffc6-4320-b895-90a49fad6a25'
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c23b19bf-688f-476d-b4ae-f485fb0c6cab') // Mirror Key Vault Deployment
  }
}
