// =============================================================
// Module: functionApp.bicep
// Creates: Basic (B1) Linux App Service Plan + Python Function App
//          with System-Assigned Managed Identity.
//
// Uses B1 dedicated plan to avoid policy restrictions in managed envs:
//   - Y1 Consumption requires SMB file share via shared-key auth (blocked)
//   - FC1 Flex Consumption is blocked by resource-group policy
// B1 dedicated Linux plans use zip/blob deployment and support
// MI-based AzureWebJobsStorage — no shared keys or file shares needed.
// =============================================================
param location string
param tags object
param functionAppName string
param appServicePlanName string
param storageAccountName string
param applicationInsightsConnectionString string
param logAnalyticsWorkspaceId string
param dataCollectionEndpointUri string
param dataCollectionRuleImmutableId string
param subscriptionId string
param azureOpenAiEndpoint string
param azureOpenAiDeployment string = 'gpt-4.1'
param azureOpenAiApiVersion string = '2024-08-01-preview'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'nightly-evals' })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: [
        // MI-based storage auth — no shared keys required
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccountName
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
        {
          name: 'AZURE_SUBSCRIPTION_ID'
          value: subscriptionId
        }
        {
          name: 'AZURE_RESOURCE_GROUP'
          value: resourceGroup().name
        }
        {
          name: 'LOG_ANALYTICS_WORKSPACE_ID'
          value: logAnalyticsWorkspaceId
        }
        {
          name: 'DATA_COLLECTION_ENDPOINT_URI'
          value: dataCollectionEndpointUri
        }
        {
          name: 'DATA_COLLECTION_RULE_IMMUTABLE_ID'
          value: dataCollectionRuleImmutableId
        }
        {
          name: 'EVAL_PACK_VERSION'
          value: '1.0.0'
        }
        {
          name: 'EVAL_SCORE_THRESHOLD'
          value: '0.7'
        }
        {
          name: 'EVAL_ENABLE_QUALITY'
          value: 'true'
        }
        {
          name: 'EVAL_ENABLE_SAFETY'
          value: 'true'
        }
        {
          name: 'EVAL_ENABLE_SIMILARITY'
          value: 'true'
        }
        {
          name: 'EVAL_ROW_DELAY_SECONDS'
          value: '2.0'
        }
        {
          name: 'AZURE_OPENAI_ENDPOINT'
          value: azureOpenAiEndpoint
        }
        {
          name: 'AZURE_OPENAI_DEPLOYMENT'
          value: azureOpenAiDeployment
        }
        // WEBSITE_RUN_FROM_PACKAGE is intentionally NOT set here.
        // deploy.ps1 / deploy.sh uploads the zip to blob storage and then sets this
        // app setting to the blob URL.  Setting it here (before the blob exists)
        // causes the platform container to fail on first boot and enter a permanent
        // 503 state because there is nothing to mount as the package filesystem.
        {
          name: 'AZURE_OPENAI_API_VERSION'
          value: azureOpenAiApiVersion
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
}

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppHostName string = functionApp.properties.defaultHostName
