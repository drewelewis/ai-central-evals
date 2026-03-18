// =============================================================
// Module: foundry.bicep
// Creates: Azure AI Services account (Foundry hub) +
//          AI Foundry Project +
//          gpt-4.1 model deployment (Standard / regional)
//
// Uses Standard (regional) SKU rather than GlobalStandard so it draws
// from a separate quota pool — useful when GlobalStandard is exhausted.
// =============================================================
param location string
param tags object

@description('Name of the Azure AI Services account (Foundry hub)')
param aiServicesAccountName string

@description('Name of the AI Foundry project (child of the account)')
param aiProjectName string

@description('Name of the gpt-4.1 deployment (used as AZURE_OPENAI_DEPLOYMENT)')
param gptDeploymentName string = 'gpt-4.1'

@description('Capacity in thousands of tokens per minute for the Standard (regional) deployment')
param gptCapacityK int = 50

@description('Set to false to skip creating a new GPT deployment (use when quota is exhausted)')
param deployGptModel bool = true

// ---- AI Services account (Foundry hub) ----
resource aiServices 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: aiServicesAccountName
  location: location
  tags: tags
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    // customSubDomainName drives the endpoint hostname:
    //   https://<customSubDomainName>.cognitiveservices.azure.com/
    customSubDomainName: aiServicesAccountName
    // Required to create AI Foundry projects as child resources
    allowProjectManagement: true
  }
}

// ---- AI Foundry Project (child resource) ----
// Discoverable via ARG: type == 'microsoft.cognitiveservices/accounts/projects'
resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: aiServices
  name: aiProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// ---- gpt-4.1 deployment ----
// Deployed on the account (not the project) — projects inherit deployments
// from their parent account in the new Foundry resource model.
// Uses Standard (regional) SKU which has a separate quota pool from GlobalStandard.
resource gptDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployGptModel) {
  parent: aiServices
  name: gptDeploymentName
  dependsOn: [aiProject]
  sku: {
    name: 'Standard'
    capacity: gptCapacityK
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1'
      version: '2025-04-14'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

// ---- Outputs ----
// aiServicesEndpoint: https://<name>.cognitiveservices.azure.com/
// This is the Azure OpenAI-compatible endpoint for AI Services accounts
// and is accepted by AzureOpenAIModelConfiguration in azure-ai-evaluation.
output aiServicesEndpoint string = aiServices.properties.endpoint
output aiServicesAccountId string = aiServices.id
output aiServicesAccountName string = aiServices.name
output aiProjectId string = aiProject.id
output aiProjectName string = aiProject.name
output gptDeploymentName string = gptDeploymentName
