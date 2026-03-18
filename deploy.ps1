#!/usr/bin/env pwsh
# deploy.ps1 - Deploy nightly-evals Function App via Run-From-Package (blob storage).
# - No SCM/Kudu, no basic auth, no shared keys
# - pip installs Linux manylinux cp311 wheels (cross-platform targeting):
#     --platform manylinux_2_17_x86_64 --python-version 3.11 --abi cp311
#   This is REQUIRED when building on Windows for a Linux Function App.
#   Without it, pip installs Windows .pyd binaries that crash the Linux container.
# - Zip entries use forward slashes (/) — Linux requires this; ZipFile.CreateFromDirectory
#   on Windows produces backslash paths which the Functions runtime can't find.
# - Uploads zip to blob; Function App reads it via system-assigned managed identity
# - Manually syncs triggers after deploy (required for external package URL method)
# Usage: ./deploy.ps1
param(
    [string]$FunctionAppName   = $env:FUNCTION_APP_NAME,
    [string]$ResourceGroup     = $env:AZURE_RESOURCE_GROUP,
    [string]$StorageAccountName = $env:AZURE_STORAGE_ACCOUNT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load values from .env if not set
if (-not $FunctionAppName -or -not $ResourceGroup -or -not $StorageAccountName) {
    if (Test-Path .env) {
        Get-Content .env | ForEach-Object {
            if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
                $val = $Matches[2].Trim().Trim('"')
                [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $val)
            }
        }
        if (-not $FunctionAppName)    { $FunctionAppName    = $env:FUNCTION_APP_NAME }
        if (-not $ResourceGroup)      { $ResourceGroup      = $env:AZURE_RESOURCE_GROUP }
        if (-not $StorageAccountName) { $StorageAccountName = $env:AZURE_STORAGE_ACCOUNT }
    }
}
$FunctionAppName    = $FunctionAppName.Trim('"')
$ResourceGroup      = $ResourceGroup.Trim('"')
$StorageAccountName = $StorageAccountName.Trim('"')

if (-not $FunctionAppName)    { throw 'FUNCTION_APP_NAME not set.' }
if (-not $ResourceGroup)      { throw 'AZURE_RESOURCE_GROUP not set.' }
if (-not $StorageAccountName) { throw 'AZURE_STORAGE_ACCOUNT not set.' }

$BlobName = "$FunctionAppName-latest.zip"
$BlobUrl  = "https://$StorageAccountName.blob.core.windows.net/deployments/$BlobName"

Write-Host "Deploying $FunctionAppName -> $BlobUrl"

# Use a short base path to avoid Windows MAX_PATH (260-char) limit with deep PyPI package trees
$tmpBase = 'C:\t'
New-Item -ItemType Directory -Path $tmpBase -Force | Out-Null
$tmpPkg = Join-Path $tmpBase "fp$([Guid]::NewGuid().ToString('N').Substring(0,8))"
$tmpZip = "$tmpPkg.zip"
New-Item -ItemType Directory -Path $tmpPkg | Out-Null

try {

    # Copy source files (no __pycache__, no .pyc)
    Write-Host '  Copying source files ...'
    Get-ChildItem src/nightly_evals -Recurse |
        Where-Object { $_.FullName -notmatch '__pycache__' -and $_.Extension -ne '.pyc' } |
        ForEach-Object {
            $rel  = $_.FullName.Substring((Resolve-Path 'src/nightly_evals').Path.Length + 1)
            $dest = Join-Path $tmpPkg $rel
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item $_.FullName $dest
        }

    # Install dependencies targeting Linux Python 3.11.
    # CRITICAL: when building on Windows, pip normally installs Windows .pyd binaries.
    # --platform manylinux_2_17_x86_64 + --python-version 3.11 + --only-binary :all:
    # forces pip to download Linux-compatible wheels that actually run on the Function App.
    Write-Host '  Installing dependencies (Linux manylinux_2_17_x86_64 cp311 wheels) ...'
    $pkgDir = Join-Path $tmpPkg '.python_packages\lib\site-packages'
    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    pip install `
        -r src/nightly_evals/requirements.txt `
        --target $pkgDir `
        --platform manylinux_2_17_x86_64 `
        --python-version 3.11 `
        --implementation cp `
        --abi cp311 `
        --only-binary :all: `
        --no-input -q 2>&1 | Out-Null
    $pipExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    if ($pipExitCode -ne 0) {
        Write-Host '  pip failed — showing full output for diagnosis:'
        pip install `
            -r src/nightly_evals/requirements.txt `
            --target $pkgDir `
            --platform manylinux_2_17_x86_64 `
            --python-version 3.11 `
            --implementation cp `
            --abi cp311 `
            --only-binary :all: 2>&1
        throw "pip install failed (exit $pipExitCode). If a package has no Linux wheel, pin an older version or remove it from requirements.txt."
    }

    # Create zip with FORWARD SLASH entry paths — Linux requires '/', not Windows '\'.
    # ZipFile.CreateFromDirectory on Windows produces backslash paths, which cause the
    # Functions runtime to fail to find .python_packages/lib/site-packages on Linux.
    Write-Host '  Creating zip (Linux-compatible forward-slash paths) ...'
    Add-Type -AssemblyName System.IO.Compression
    $stream  = [System.IO.File]::Create($tmpZip)
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    Get-ChildItem $tmpPkg -Recurse -File | ForEach-Object {
        $entryName  = $_.FullName.Substring($tmpPkg.Length + 1).Replace('\', '/')
        $entry      = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        $fileStream  = [System.IO.File]::OpenRead($_.FullName)
        $fileStream.CopyTo($entryStream)
        $fileStream.Dispose()
        $entryStream.Dispose()
    }
    $archive.Dispose()
    $stream.Dispose()

    # Upload to blob using logged-in Azure credentials (no SAS, no key)
    # Use ErrorActionPreference=Continue: az writes progress to stderr which PowerShell
    # treats as an error stream under 'Stop', aborting even on successful uploads.
    Write-Host '  Uploading to blob storage (--auth-mode login) ...'
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    az storage blob upload `
        --account-name $StorageAccountName `
        --container-name deployments `
        --name $BlobName `
        --file $tmpZip `
        --overwrite `
        --auth-mode login 2>&1 | ForEach-Object {
            # Suppress "az :" NativeCommandError wrapper but keep the actual output
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $msg = $_.Exception.Message
                if ($msg -match 'blocked by network rules') { Write-Warning $msg }
                # else: swallow progress/formatting noise
            } else { $_ }
        }
    $azExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    if ($azExitCode -ne 0) { throw "az storage blob upload failed (exit $azExitCode)" }

    # Point WEBSITE_RUN_FROM_PACKAGE at the blob URL (Function App reads via MI)
    Write-Host '  Updating WEBSITE_RUN_FROM_PACKAGE ...'
    az functionapp config appsettings set `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --settings "WEBSITE_RUN_FROM_PACKAGE=$BlobUrl" | Out-Null

    # Manually sync triggers — required by Azure docs for the external package URL deployment method.
    # Without this, the platform may not detect the new/updated function triggers.
    Write-Host '  Syncing function triggers ...'
    $subId = $(az account show --query id -o tsv)
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    az rest --method post `
        --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FunctionAppName/syncfunctiontriggers?api-version=2016-08-01" 2>&1 | Out-Null
    $ErrorActionPreference = $prevPref

    Write-Host 'Done. Function App will restart and load the new package.'
} finally {
    Remove-Item -Path $tmpPkg -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $tmpZip -Force -ErrorAction SilentlyContinue
}
