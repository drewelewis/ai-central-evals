// =============================================================
// Module: rbac-rg.bicep
// Resource-group-scoped role assignments for the Function App MI.
// Called from main.bicep with scope: rg
// =============================================================

param functionAppPrincipalId string
param logAnalyticsWorkspaceResourceId string
param dataCollectionRuleResourceId string
param storageAccountName string
param aiServicesAccountName string
@description('Principal ID of the user running azd provision (for local testing RBAC)')
param principalId string = ''

// ---- Built-in role IDs ----
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
var monitoringContributorRoleId      = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var storageBlobDataOwnerRoleId       = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
// AI Services roles
var cognitiveServicesOpenAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var azureAiDeveloperRoleId = '64702f94-c441-49e6-a78b-ef80e0188fee'

// Reference the storage account (already deployed by storage.bicep in same RG)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

// ---- Resource Group: Monitoring Metrics Publisher (covers LA workspace + DCR) ----
resource rgMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, functionAppPrincipalId, monitoringMetricsPublisherRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Monitoring Contributor on RG (for Log Analytics custom log ingestion) ----
resource rgMonitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, functionAppPrincipalId, monitoringContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Storage: Blob Data Owner (Flex Consumption deployment packages + AzureWebJobsStorage MI) ----
resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, storageBlobDataOwnerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Storage: Queue Data Contributor (AzureWebJobsStorage MI — timer trigger locks) ----
resource storageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, storageQueueDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- Storage: Table Data Contributor (AzureWebJobsStorage MI — durable state) ----
resource storageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, storageTableDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Reference the AI Services account (deployed by foundry.bicep in same RG)
resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aiServicesAccountName
}

// ---- AI Services: Cognitive Services OpenAI User (Function App MI) ----
// Required for quality evaluators (Groundedness, Relevance, Coherence, Fluency)
// which call the Azure OpenAI API as an LLM judge.
resource funcAppOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiServices
  name: guid(aiServices.id, functionAppPrincipalId, cognitiveServicesOpenAiUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- AI Services: Azure AI Developer (Function App MI) ----
// Required for safety evaluators (Violence, Hate, Sexual, SelfHarm)
// which call the Azure AI Content Safety service on the Foundry project.
resource funcAppAiDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiServices
  name: guid(aiServices.id, functionAppPrincipalId, azureAiDeveloperRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloperRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---- AI Services: Cognitive Services OpenAI User (deployer — local testing) ----
resource deployerOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: aiServices
  name: guid(aiServices.id, principalId, cognitiveServicesOpenAiUserRoleId, 'deployer')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

// ---- AI Services: Azure AI Developer (deployer — local testing) ----
resource deployerAiDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: aiServices
  name: guid(aiServices.id, principalId, azureAiDeveloperRoleId, 'deployer')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloperRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

// ---- Storage: Blob Data Contributor (deployer — upload Run-From-Package zip) ----
resource deployerStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: storageAccount
  name: guid(storageAccount.id, principalId, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: 'User'
  }
}
