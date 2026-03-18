// =============================================================
// Module: storage.bicep
// Creates: Storage Account for Function App
// =============================================================
param location string
param tags object
param storageAccountName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false  // MI-only access — no shared keys, no SAS tokens; Entra ID + RBAC required
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'    // Public data-plane access allowed; security relies on allowSharedKeyAccess=false + RBAC
      bypass: 'AzureServices'   // Trusted Azure services (Function App MI) always have access
      // Note: strict network isolation (defaultAction:Deny) requires a private endpoint for
      // WEBSITE_RUN_FROM_PACKAGE to work. Without VNet infrastructure, Entra ID auth + RBAC
      // is the security boundary.
    }
    encryption: {
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id

// Container for Run-From-Package deployment zips
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource deploymentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}
