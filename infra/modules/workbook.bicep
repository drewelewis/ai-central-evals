// =============================================================
// Module: workbook.bicep
// Creates: Azure Monitor Workbook for FoundryEvals_CL dashboard
// =============================================================
param location string
param tags object
param workbookName string
param workbookDisplayName string
param logAnalyticsWorkspaceId string
param contentVersion string = '1.0'

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: guid(resourceGroup().id, workbookName)
  location: location
  tags: union(tags, { 'hidden-title': workbookDisplayName, 'workbook-content-version': contentVersion })
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: loadTextContent('../workbook.json')
    version: contentVersion
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceId
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
