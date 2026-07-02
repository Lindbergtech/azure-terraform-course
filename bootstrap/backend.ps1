<#
.SYNOPSIS
  Bootstraps the Terraform remote state backend on Azure.

.DESCRIPTION
  Creates (idempotently): resource group, storage account (TLS 1.2+, no public
  blob access, versioning on), and a blob container for tfstate. Then writes
  bootstrap/backend.tfbackend with the values terraform init needs. That file
  is gitignored — it's per-student and per-subscription.

  Why a script and not Terraform: the backend can't store its own state.
  Standard practice is to bootstrap once with a script, then point Terraform
  at it.

.NOTES
  Requires: Azure CLI, an active `az login` session.
#>

param(
    [Parameter(Position = 0)]
    [string]$AllowedIp = $env:ALLOWED_IP
)

$ErrorActionPreference = "Stop"

# ---- Config (override via env vars) ----------------------------------------
$Location      = $env:LOCATION       ?? "swedencentral"
$RgName        = $env:RG_NAME        ?? "rg-tfstate-course"
$SubId         = az account show --query id -o tsv
$Suffix        = ([System.BitConverter]::ToString(
                    [System.Security.Cryptography.SHA1]::Create().ComputeHash(
                        [System.Text.Encoding]::UTF8.GetBytes($SubId)
                    )
                  ) -replace '-', '').Substring(0, 6).ToLower()
$SaName        = $env:SA_NAME        ?? "sttfstate$Suffix"
$ContainerName = $env:CONTAINER_NAME ?? "tfstate"
$StateKey      = $env:STATE_KEY      ?? "course.tfstate"
# Public IP (or CIDR) allowed through the storage account firewall.
# Required: terraform from your laptop and CI runners need to reach the blob
# data plane. Pass as -AllowedIp or via $env:ALLOWED_IP.
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($AllowedIp)) {
    Write-Error @"
Public IP is required for the storage account firewall.
  Usage:  ./backend.ps1 -AllowedIp 1.2.3.4
     or:  `$env:ALLOWED_IP = '1.2.3.4'; ./backend.ps1
  Hint:   (Invoke-WebRequest ifconfig.me -UseBasicParsing).Content.Trim()
"@
    exit 1
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendFile = Join-Path $ScriptDir "backend.tfbackend"

Write-Host "Subscription : $SubId"
Write-Host "Resource grp : $RgName ($Location)"
Write-Host "Storage acct : $SaName"
Write-Host "Container    : $ContainerName"
Write-Host "Allowed IP   : $AllowedIp"
Write-Host "Backend file : $BackendFile"
Write-Host ""

az group create `
    --name $RgName `
    --location $Location `
    --output none

az storage account create `
    --name $SaName `
    --resource-group $RgName `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --default-action Deny `
    --bypass AzureServices `
    --output none

az storage account network-rule add `
    --account-name $SaName `
    --resource-group $RgName `
    --ip-address $AllowedIp `
    --output none

az storage account blob-service-properties update `
    --account-name $SaName `
    --resource-group $RgName `
    --enable-versioning true `
    --output none

# Grant the signed-in user Storage Blob Data Contributor on the storage
# account so `terraform init` (which uses Entra auth, not account keys) can
# read/write state. We tolerate "already assigned" so re-runs are idempotent.
$UserOid = az ad signed-in-user show --query id -o tsv
$SaId    = az storage account show `
    --name $SaName `
    --resource-group $RgName `
    --query id -o tsv

if ([string]::IsNullOrWhiteSpace($UserOid)) {
    Write-Error "az ad signed-in-user show returned no object id. Are you logged in with 'az login' as a user (not a service principal)?"
    exit 1
}

Write-Host "Granting Storage Blob Data Contributor to $UserOid on $SaName..."
$roleErr = az role assignment create `
    --assignee-object-id $UserOid `
    --assignee-principal-type User `
    --role "Storage Blob Data Contributor" `
    --scope $SaId `
    --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($roleErr -match "RoleAssignmentExists") {
        Write-Host "  (already assigned — skipping)"
    } else {
        Write-Error "$roleErr"
        exit 1
    }
}

Write-Host "Note: RBAC propagation can take ~30-60s before 'terraform init' succeeds."

az storage container create `
    --name $ContainerName `
    --account-name $SaName `
    --auth-mode login `
    --output none

@"
resource_group_name  = "$RgName"
storage_account_name = "$SaName"
container_name       = "$ContainerName"
key                  = "$StateKey"
use_azuread_auth     = true
"@ | Set-Content -Path $BackendFile -NoNewline

@"

Backend ready. Wrote $BackendFile (gitignored).

Next:
  cd infra
  terraform init -backend-config=../bootstrap/backend.tfbackend
  terraform apply
"@ | Write-Host
