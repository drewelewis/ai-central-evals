// =============================================================
// Module: dataCollection.bicep
// Creates: Data Collection Endpoint + Rule for FoundryEvals_CL
// Uses Azure Monitor Ingestion API (Logs Ingestion API)
// =============================================================
param location string
param tags object
param logAnalyticsWorkspaceId string
param logAnalyticsWorkspaceName string
param dataCollectionEndpointName string
param dataCollectionRuleName string

// ---- Data Collection Endpoint ----
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dataCollectionEndpointName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---- Custom Log Analytics Table: FoundryEvals_CL ----
resource foundryEvalsTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: '${logAnalyticsWorkspaceName}/FoundryEvals_CL'
  properties: {
    schema: {
      name: 'FoundryEvals_CL'
      columns: [
        { name: 'TimeGenerated',          type: 'datetime', description: 'UTC timestamp the eval row was written' }
        { name: 'TenantId_s',             type: 'string',   description: 'Azure tenant ID' }
        { name: 'SubscriptionId_s',       type: 'string',   description: 'Azure subscription ID' }
        { name: 'ResourceGroup_s',        type: 'string',   description: 'Resource group of the Foundry project' }
        { name: 'FoundryProjectName_s',   type: 'string',   description: 'AI Foundry project name' }
        { name: 'FoundryProjectId_s',     type: 'string',   description: 'Full ARM resource ID of the Foundry project (hub/workspace)' }
        { name: 'TargetType_s',           type: 'string',   description: 'model | agent | dataset' }
        { name: 'TargetName_s',           type: 'string',   description: 'Deployment name, agent name, or dataset name' }
        { name: 'TargetVersion_s',        type: 'string',   description: 'Model version or agent version' }
        { name: 'EvalPackVersion_s',      type: 'string',   description: 'Version of the baseline eval pack executed' }
        { name: 'EvalRunId_s',            type: 'string',   description: 'Unique GUID for this eval run batch' }
        { name: 'EvalDatasetPath_s',      type: 'string',   description: 'Path/URI of the test dataset used' }
        { name: 'TriggerType_s',          type: 'string',   description: 'scheduled | manual | ci' }
        { name: 'EvaluatorName_s',        type: 'string',   description: 'Name of the individual evaluator' }
        { name: 'EvaluatorCategory_s',    type: 'string',   description: 'quality | safety | similarity | custom' }
        { name: 'Score_d',                type: 'real',     description: 'Numeric score (0.0 – 1.0 normalized)' }
        { name: 'Threshold_d',            type: 'real',     description: 'Minimum passing score for this evaluator' }
        { name: 'Passed_b',               type: 'boolean',  description: 'true if Score >= Threshold' }
        { name: 'Severity_s',             type: 'string',   description: 'info | warning | critical' }
        { name: 'ErrorMessage_s',         type: 'string',   description: 'Non-empty if the evaluator raised an exception' }
        { name: 'DurationMs_d',           type: 'real',     description: 'Evaluator wall-clock time in milliseconds' }
        { name: 'RawOutput_s',            type: 'string',   description: 'JSON-serialized raw evaluator output (truncated to 8 KB)' }
      ]
    }
    retentionInDays: 90
    totalRetentionInDays: 180
  }
}

// ---- Data Collection Rule ----
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dataCollectionRuleName
  location: location
  tags: tags
  dependsOn: [foundryEvalsTable]
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-FoundryEvals_CL': {
        columns: [
          { name: 'TimeGenerated',          type: 'datetime' }
          { name: 'TenantId_s',             type: 'string' }
          { name: 'SubscriptionId_s',       type: 'string' }
          { name: 'ResourceGroup_s',        type: 'string' }
          { name: 'FoundryProjectName_s',   type: 'string' }
          { name: 'FoundryProjectId_s',     type: 'string' }
          { name: 'TargetType_s',           type: 'string' }
          { name: 'TargetName_s',           type: 'string' }
          { name: 'TargetVersion_s',        type: 'string' }
          { name: 'EvalPackVersion_s',      type: 'string' }
          { name: 'EvalRunId_s',            type: 'string' }
          { name: 'EvalDatasetPath_s',      type: 'string' }
          { name: 'TriggerType_s',          type: 'string' }
          { name: 'EvaluatorName_s',        type: 'string' }
          { name: 'EvaluatorCategory_s',    type: 'string' }
          { name: 'Score_d',                type: 'real' }
          { name: 'Threshold_d',            type: 'real' }
          { name: 'Passed_b',               type: 'boolean' }
          { name: 'Severity_s',             type: 'string' }
          { name: 'ErrorMessage_s',         type: 'string' }
          { name: 'DurationMs_d',           type: 'real' }
          { name: 'RawOutput_s',            type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-FoundryEvals_CL']
        destinations: ['la-destination']
        transformKql: 'source'
        outputStream: 'Custom-FoundryEvals_CL'
      }
    ]
  }
}

output dataCollectionEndpointUri string = dce.properties.logsIngestion.endpoint
output dataCollectionEndpointId string = dce.id
output dataCollectionRuleImmutableId string = dcr.properties.immutableId
output dataCollectionRuleId string = dcr.id
