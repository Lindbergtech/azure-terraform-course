#!/usr/bin/env bash
# Bootstraps the Terraform remote state backend on Azure.
#
# Creates (idempotently):
#   - a resource group
#   - a storage account (TLS 1.2+, no public blob access, versioning on)
#   - a blob container for tfstate
#
# Then writes bootstrap/backend.tfbackend with the values terraform init needs.
# That file is gitignored — it's per-student and per-subscription.
#
# Why a script and not Terraform: the backend can't store its own state.
# Standard practice is to bootstrap once with a script, then point Terraform at it.
#
# Requires: az CLI, an active `az login` session.

set -euo pipefail

# ---- Config (override via env vars) ----------------------------------------
LOCATION="${LOCATION:-swedencentral}"
RG_NAME="${RG_NAME:-rg-tfstate-course}"
# Storage account names must be globally unique, 3-24 chars, lowercase alphanumeric.
# Default appends a hash of your subscription id for uniqueness.
SUB_ID="$(az account show --query id -o tsv)"
SUFFIX="$(echo -n "$SUB_ID" | shasum | cut -c1-6)"
SA_NAME="${SA_NAME:-sttfstate${SUFFIX}}"
CONTAINER_NAME="${CONTAINER_NAME:-tfstate}"
STATE_KEY="${STATE_KEY:-course.tfstate}"
# Public IP (or CIDR) allowed through the storage account firewall.
# Required: terraform from your laptop and CI runners need to reach the blob
# data plane. Pass as the first arg or via ALLOWED_IP.
ALLOWED_IP="${ALLOWED_IP:-${1:-}}"
# ---------------------------------------------------------------------------

if [[ -z "$ALLOWED_IP" ]]; then
  echo "Error: public IP is required for the storage account firewall." >&2
  echo "Usage:  ALLOWED_IP=1.2.3.4 $0     # or: $0 1.2.3.4" >&2
  echo "Hint:   curl -s ifconfig.me" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_FILE="$SCRIPT_DIR/backend.tfbackend"

echo "Subscription : $SUB_ID"
echo "Resource grp : $RG_NAME ($LOCATION)"
echo "Storage acct : $SA_NAME"
echo "Container    : $CONTAINER_NAME"
echo "Allowed IP   : $ALLOWED_IP"
echo "Backend file : $BACKEND_FILE"
echo

az group create \
  --name "$RG_NAME" \
  --location "$LOCATION" \
  --output none

az storage account create \
  --name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --default-action Deny \
  --bypass AzureServices \
  --output none

az storage account network-rule add \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --ip-address "$ALLOWED_IP" \
  --output none

az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-versioning true \
  --output none

# Grant the signed-in user Storage Blob Data Contributor on the storage
# account so `terraform init` (which uses Entra auth, not account keys) can
# read/write state. We tolerate "already assigned" so re-runs are idempotent.
USER_OID="$(az ad signed-in-user show --query id -o tsv)"
SA_ID="$(az storage account show \
  --name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --query id -o tsv)"

if [[ -z "$USER_OID" ]]; then
  echo "Error: az ad signed-in-user show returned no object id." >&2
  echo "Are you logged in with 'az login' as a user (not a service principal)?" >&2
  exit 1
fi

echo "Granting Storage Blob Data Contributor to $USER_OID on $SA_NAME..."
if ! az role assignment create \
  --assignee-object-id "$USER_OID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" \
  --only-show-errors 2>/tmp/backend_role_err; then
  if grep -q "RoleAssignmentExists" /tmp/backend_role_err; then
    echo "  (already assigned — skipping)"
  else
    cat /tmp/backend_role_err >&2
    exit 1
  fi
fi
rm -f /tmp/backend_role_err

echo "Note: RBAC propagation can take ~30-60s before 'terraform init' succeeds."

az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$SA_NAME" \
  --auth-mode login \
  --output none

cat > "$BACKEND_FILE" <<EOF
resource_group_name  = "$RG_NAME"
storage_account_name = "$SA_NAME"
container_name       = "$CONTAINER_NAME"
key                  = "$STATE_KEY"
use_azuread_auth     = true
EOF

cat <<EOF

Backend ready. Wrote $BACKEND_FILE (gitignored).

Next:
  cd infra
  terraform init -backend-config=../bootstrap/backend.tfbackend
  terraform apply
EOF
