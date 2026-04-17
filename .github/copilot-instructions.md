# GitHub Copilot Instructions for ai-central-evals

## Deployment Rules (CRITICAL)

### No Direct Resource Patching
**DO NOT** use Azure CLI (`az`), PowerShell, or any other tool to directly modify Azure resources. This includes:
- `az functionapp config appsettings set`
- `az resource update`
- `az webapp config set`
- Any `az ... update` or `az ... set` commands that modify deployed resources
- Direct ARM/REST API calls to patch resources

### All Changes Must Use azd
All deployments and configuration changes **MUST** go through the Azure Developer CLI (`azd`):
- `azd up` - Full provision and deploy
- `azd provision` - Provision/update infrastructure and deploy code (runs `deploy.ps1` via postprovision hook)

**Note:** `azd deploy` does NOT work for this project. The Function App uses Run-From-Package with blob storage. Code deployment is handled by `deploy.ps1` which is called automatically by the `postprovision` hook.

To deploy code changes only (without reprovisioning infrastructure):
```powershell
./deploy.ps1   # Windows
./deploy.sh    # Linux/macOS
```

### Infrastructure as Code Only
All Azure resource configurations **MUST** be defined in:
- **Bicep files** in the `infra/` directory
- **azure.yaml** for service definitions
- **Application code** (e.g., `function_app.py` for function triggers/bindings)

When fixing issues:
1. Identify the root cause in the source files (Bicep, azure.yaml, or app code)
2. Make changes to the appropriate source file
3. Deploy using `./deploy.ps1` (code only) or `azd provision` (infra + code)

### Examples

❌ **WRONG** - Direct patching:
```bash
az functionapp config appsettings set --name func-xxx --resource-group rg-xxx --settings "WEBSITE_RUN_FROM_PACKAGE=1"
```

✅ **CORRECT** - Update Bicep and deploy:
```bicep
// infra/modules/functionApp.bicep
resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  properties: {
    siteConfig: {
      appSettings: [
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
      ]
    }
  }
}
```
Then run: `azd provision`

## Project Structure

- `infra/` - Bicep infrastructure templates
  - `main.bicep` - Main orchestration
  - `modules/` - Reusable Bicep modules
- `src/nightly_evals/` - Azure Function app code
- `azure.yaml` - azd service definitions
- `deploy.ps1` / `deploy.sh` - Code deployment scripts (Run-From-Package to blob storage)
- `.env` - Local environment variables (azd-managed)

## Troubleshooting Deployments

If `azd deploy` fails with "Run-From-Zip" error:
- This is expected. Use `./deploy.ps1` instead for code-only deploys.

If `deploy.ps1` fails:
1. Check the error message for the root cause
2. Fix the issue in the source files (Bicep or app code)
3. Re-run `./deploy.ps1` or `azd provision` as appropriate

Do NOT attempt to work around deployment issues by directly patching Azure resources.
