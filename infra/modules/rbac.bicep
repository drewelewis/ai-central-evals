// =============================================================
// Module: rbac.bicep
// Subscription-scoped role assignments only.
// Resource-group-scoped assignments live in rbac-rg.bicep.
// =============================================================
targetScope = 'subscription'

param functionAppPrincipalId string
param principalId string   // current deployer — used for local test grants

// ---- Built-in role IDs ----
var readerRoleId        = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
// Azure AI Developer: grants data-plane access to all AI Services accounts in the
// subscription — required to enumerate agents and run safety evaluators (Violence,
// Hate, Sexual, SelfHarm, ProtectedMaterial) across every discovered Foundry project.
var azureAiDeveloperRoleId = '64702f94-c441-49e6-a78b-ef80e0188fee'

// ---- Subscription-level: Reader (for ARG queries) ----
resource argReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionAppPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Subscription-level: Azure AI Developer (Function App MI) ----
// Covers all Foundry projects/AI accounts across the subscription so the function
// can enumerate agents and invoke safety evaluators on every discovered project.
resource funcAppAiDeveloperSub 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionAppPrincipalId, azureAiDeveloperRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloperRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Optional: grant deployer principal Reader at sub level for testing ----
resource deployerReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(subscription().id, principalId, readerRoleId, 'deployer')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

// ---- Optional: Azure AI Developer for deployer (local testing against any project) ----
resource deployerAiDeveloperSub 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(subscription().id, principalId, azureAiDeveloperRoleId, 'deployer')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloperRoleId)
    principalId: principalId
    principalType: 'User'
  }
}
