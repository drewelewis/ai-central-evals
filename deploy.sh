#!/usr/bin/env bash
# deploy.sh — Deploy nightly-evals Function App via Run-From-Package (blob storage).
# - No SCM/Kudu, no basic auth
# - pip installs into an isolated temp dir from PyPI (not the local venv)
# - Uploads zip to blob; Function App reads it via managed identity
set -euo pipefail

FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"

if [ -f .env ]; then
    set -a; source .env; set +a
    FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-}"
    RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
    STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
fi

FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | tr -d '"')
RESOURCE_GROUP=$(echo "$RESOURCE_GROUP" | tr -d '"')
STORAGE_ACCOUNT=$(echo "$STORAGE_ACCOUNT" | tr -d '"')

[ -z "$FUNCTION_APP_NAME" ] && { echo "ERROR: FUNCTION_APP_NAME not set."; exit 1; }
[ -z "$RESOURCE_GROUP" ]   && { echo "ERROR: AZURE_RESOURCE_GROUP not set."; exit 1; }
[ -z "$STORAGE_ACCOUNT" ]  && { echo "ERROR: AZURE_STORAGE_ACCOUNT not set."; exit 1; }

BLOB_NAME="${FUNCTION_APP_NAME}-latest.zip"
BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/deployments/${BLOB_NAME}"

echo "Deploying $FUNCTION_APP_NAME -> $BLOB_URL"

TMP_PKG=$(mktemp -d /tmp/funcpkg-XXXXXX)
TMP_ZIP="${TMP_PKG}.zip"
cleanup() {
    rm -rf "$TMP_PKG" "$TMP_ZIP" 2>/dev/null || true
}
trap cleanup EXIT

echo "  Copying source files ..."
rsync -a --exclude='__pycache__' --exclude='*.pyc' src/nightly_evals/ "$TMP_PKG/"

echo "  Installing dependencies (isolated, from PyPI) ..."
PKG_DIR="$TMP_PKG/.python_packages/lib/site-packages"
mkdir -p "$PKG_DIR"
pip install -r src/nightly_evals/requirements.txt --target "$PKG_DIR" --no-input -q 2>/dev/null \
    || { echo "  pip failed — re-running for diagnostics:"; pip install -r src/nightly_evals/requirements.txt --target "$PKG_DIR"; exit 1; }

echo "  Creating zip ..."
(cd "$TMP_PKG" && zip -r "$TMP_ZIP" . -q)

echo "  Uploading to blob storage (--auth-mode login) ..."
az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name deployments \
    --name "$BLOB_NAME" \
    --file "$TMP_ZIP" \
    --overwrite \
    --auth-mode login

echo "  Updating WEBSITE_RUN_FROM_PACKAGE ..."
az functionapp config appsettings set \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings "WEBSITE_RUN_FROM_PACKAGE=$BLOB_URL" > /dev/null

echo "Done. Function App will restart and load the new package."
