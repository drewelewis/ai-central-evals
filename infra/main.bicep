// =============================================================
// Main Bicep entry point — AI Central Evals
// =============================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (used to generate resource names)')
param environmentName string

@description('Primary Azure region for all resources')
param location string

@description('Principal ID of the user running azd provision (for local testing RBAC)')
param principalId string = ''

@description('Set to false to skip creating a gpt-4.1 deployment when quota is exhausted')
param deployGptModel bool = true

@description('Override endpoint for quality evaluators when reusing an existing deployment. Leave blank to use the provisioned AI Services account.')
param existingOpenAiEndpoint string = ''

@description('Override deployment name when reusing an existing deployment.')
param existingOpenAiDeployment string = ''

@description('Timestamp injected at provision time — forces the workbook resource to update on every azd provision.')
param deploymentTimestamp string = utcNow()

// ---- Derived naming ----
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName, solution: 'ai-central-evals' }

// ---- Resource Group ----
resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// ---- Core infra modules ----
module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
  }
}

module storage './modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    location: location
    tags: tags
    storageAccountName: '${abbrs.storageStorageAccounts}${resourceToken}'
  }
}

module dataCollection './modules/dataCollection.bicep' = {
  name: 'dataCollection'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    logAnalyticsWorkspaceName: monitoring.outputs.logAnalyticsWorkspaceName
    dataCollectionEndpointName: '${abbrs.insightsDce}${resourceToken}'
    dataCollectionRuleName: '${abbrs.insightsDcr}${resourceToken}'
  }
}

module foundry './modules/foundry.bicep' = {
  name: 'foundry'
  scope: rg
  params: {
    location: location
    tags: tags
    aiServicesAccountName: '${abbrs.cognitiveServicesAIServices}${resourceToken}'
    aiProjectName: '${abbrs.cognitiveServicesProjects}${resourceToken}'
    deployGptModel: deployGptModel
  }
}

// Resolve effective OpenAI endpoint/deployment — prefer explicit overrides,
// fall back to what foundry.bicep provisioned.
var effectiveOpenAiEndpoint = !empty(existingOpenAiEndpoint) ? existingOpenAiEndpoint : foundry.outputs.aiServicesEndpoint
var effectiveOpenAiDeployment = !empty(existingOpenAiDeployment) ? existingOpenAiDeployment : foundry.outputs.gptDeploymentName

module functionApp './modules/functionApp.bicep' = {
  name: 'functionApp'
  scope: rg
  params: {
    location: location
    tags: tags
    functionAppName: '${abbrs.webSitesFunctions}${resourceToken}'
    appServicePlanName: '${abbrs.webServerFarms}${resourceToken}'
    storageAccountName: storage.outputs.storageAccountName
    applicationInsightsConnectionString: monitoring.outputs.applicationInsightsConnectionString
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    dataCollectionEndpointUri: dataCollection.outputs.dataCollectionEndpointUri
    dataCollectionRuleImmutableId: dataCollection.outputs.dataCollectionRuleImmutableId
    subscriptionId: subscription().subscriptionId
    azureOpenAiEndpoint: effectiveOpenAiEndpoint
    azureOpenAiDeployment: effectiveOpenAiDeployment
    // deploymentPackageUrl removed — deploy.ps1/deploy.sh sets WEBSITE_RUN_FROM_PACKAGE after uploading the zip
  }
}

module workbook './modules/workbook.bicep' = {
  name: 'workbook'
  scope: rg
  params: {
    location: location
    tags: tags
    workbookName: '${abbrs.insightsWorkbooks}${resourceToken}'
    workbookDisplayName: 'AI Foundry — Nightly Evals'
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    contentVersion: deploymentTimestamp
  }
}

// Subscription-scoped role assignments (ARG Reader)
module rbac './modules/rbac.bicep' = {
  name: 'rbac'
  scope: subscription()
  params: {
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
    principalId: principalId
  }
}

// Resource-group-scoped role assignments (LA + DCR ingestion roles + storage MI roles + AI Services roles)
module rbacRg './modules/rbac-rg.bicep' = {
  name: 'rbac-rg'
  scope: rg
  params: {
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceId
    dataCollectionRuleResourceId: dataCollection.outputs.dataCollectionRuleId
    storageAccountName: storage.outputs.storageAccountName
    aiServicesAccountName: foundry.outputs.aiServicesAccountName
    principalId: principalId
  }
}

// ---- Outputs (picked up by azd) ----
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_SUBSCRIPTION_ID string = subscription().subscriptionId
output AZURE_RESOURCE_GROUP string = rg.name
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output DATA_COLLECTION_ENDPOINT_URI string = dataCollection.outputs.dataCollectionEndpointUri
output DATA_COLLECTION_RULE_IMMUTABLE_ID string = dataCollection.outputs.dataCollectionRuleImmutableId
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output FUNCTION_APP_NAME string = functionApp.outputs.functionAppName
output AZURE_STORAGE_ACCOUNT string = storage.outputs.storageAccountName
output WORKBOOK_ID string = workbook.outputs.workbookId
output AZURE_OPENAI_ENDPOINT string = effectiveOpenAiEndpoint
output AZURE_OPENAI_DEPLOYMENT string = effectiveOpenAiDeployment
output AZURE_OPENAI_API_VERSION string = '2024-08-01-preview'
