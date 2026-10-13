---
name: blob-storage
description: Generates a bash or Terraform snippet that creates an Azure Storage Account (StorageV2, LRS, hot tier) with one or more Blob containers, and grants the AKS kubelet identity (or a workload-identity service account) `Storage Blob Data Contributor` on it. For passwordless access from cluster workloads via workload identity. Optional private endpoint for hardening. Use as Stage 05 of `aks-bootstrap`, after `aks-cluster`. Trigger when the user mentions "create storage account", "blob container", "blob storage", "Storage Blob Data Contributor", or "passwordless blob access from AKS".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# Azure Blob Storage for cluster workloads

## What this skill produces

| Resource | Setting |
|---|---|
| `azurerm_storage_account` | StorageV2, LRS, hot access tier, HTTPS-only, TLS 1.2 minimum |
| `azurerm_storage_container` (one or more) | Private (no public access) |
| `azurerm_role_assignment` | `Storage Blob Data Contributor` to the kubelet identity (or specified workload identity) on the account scope |
| *(optional)* `azurerm_private_endpoint` | Private endpoint for hardening (set `STORAGE_PUBLIC_ACCESS=false`) |

## Inputs

Source from `streaming-env.sh` + `generated/.env.iam-vpc` + `generated/.env.aks-cluster`.

**Required:**

| Variable | Description |
|---|---|
| `AZURE_SUBSCRIPTION_ID` | Subscription |
| `RESOURCE_GROUP` | RG |
| `LOCATION` | Region |
| `STORAGE_ACCOUNT_NAME` | 3–24 chars, **lowercase alphanumeric only, NO hyphens**, globally unique |
| `STORAGE_CONTAINERS` | Comma-separated list of container names to create | `models,outputs,scratch` |

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `STORAGE_SKU` | Replication: `Standard_LRS` / `Standard_ZRS` / `Standard_GRS` | `Standard_LRS` |
| `STORAGE_TIER` | Access tier | `Hot` |
| `STORAGE_PUBLIC_ACCESS` | Allow public network access | `true` (set `false` + add private endpoint for prod) |
| `STORAGE_GRANTEE_OBJECT_ID` | AAD object ID to grant `Storage Blob Data Contributor`. Defaults to AKS kubelet identity. | `${KUBELET_IDENTITY_OBJECT_ID}` |
| `STORAGE_GRANTEE_TYPE` | `ServicePrincipal` (kubelet/workload identity) or `User` | `ServicePrincipal` |
| `OUTPUT_FORMAT` | `bash` or `terraform` | `bash` |

## Outputs

- **Bash:** `generated/stage05-<cluster-name>-blob-storage.sh`
- **Terraform:** `generated/<cluster-name>/blob-storage/main.tf`

Writes `generated/.env.blob-storage` with `STORAGE_ACCOUNT_ID`, `STORAGE_ACCOUNT_NAME`, `STORAGE_PRIMARY_ENDPOINT`.

## Granting Workload Identity access (preferred over kubelet identity for least privilege)

For workloads to access Blob without imagePullSecrets-style key management, **prefer workload identity** over granting the kubelet identity broad data access:

1. Create a user-assigned managed identity for the workload (e.g., `id-storage-client`).
2. Create a federated credential binding the workload's K8s ServiceAccount to the identity (consumes `OIDC_ISSUER_URL` from `aks-cluster`).
3. Grant `Storage Blob Data Contributor` to the identity (not the kubelet identity).

The bash/TF snippets below show the kubelet-identity path (simpler for validation). Promote to workload identity before any production-intent data access.

## Bash snippet (reference)

```bash
#!/bin/bash
set -euo pipefail

# Resolve repo root from script location — works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/streaming-env.sh"
if [[ ! -f "$REPO_ROOT/generated/.env.aks-cluster" ]]; then
  echo "ERROR: $REPO_ROOT/generated/.env.aks-cluster not found. Run stage02 first." >&2
  exit 1
fi
source "$REPO_ROOT/generated/.env.aks-cluster"

: "${AZURE_SUBSCRIPTION_ID:?}" "${RESOURCE_GROUP:?}" "${LOCATION:?}" "${STORAGE_ACCOUNT_NAME:?}" "${STORAGE_CONTAINERS:?}"
STORAGE_SKU="${STORAGE_SKU:-Standard_LRS}"
STORAGE_TIER="${STORAGE_TIER:-Hot}"
STORAGE_PUBLIC_ACCESS="${STORAGE_PUBLIC_ACCESS:-true}"
STORAGE_GRANTEE_OBJECT_ID="${STORAGE_GRANTEE_OBJECT_ID:-$KUBELET_IDENTITY_OBJECT_ID}"
STORAGE_GRANTEE_TYPE="${STORAGE_GRANTEE_TYPE:-ServicePrincipal}"

if [[ ! "$STORAGE_ACCOUNT_NAME" =~ ^[a-z0-9]{3,24}$ ]]; then
  echo "ERROR: STORAGE_ACCOUNT_NAME='$STORAGE_ACCOUNT_NAME' must be 3–24 chars, lowercase alphanumeric only."
  exit 1
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

echo "--- Creating storage account $STORAGE_ACCOUNT_NAME ---"
PUBLIC_FLAG=$([[ "$STORAGE_PUBLIC_ACCESS" == "false" ]] && echo "--public-network-access Disabled" || echo "--public-network-access Enabled")
az storage account create \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$STORAGE_SKU" \
  --access-tier "$STORAGE_TIER" \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  $PUBLIC_FLAG \
  --only-show-errors

STORAGE_ID=$(az storage account show -n "$STORAGE_ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
STORAGE_ENDPOINT=$(az storage account show -n "$STORAGE_ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query primaryEndpoints.blob -o tsv)

echo "--- Creating containers: $STORAGE_CONTAINERS ---"
IFS=',' read -ra CONTAINERS <<< "$STORAGE_CONTAINERS"
for c in "${CONTAINERS[@]}"; do
  az storage container create \
    --name "$c" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --auth-mode login \
    --only-show-errors >/dev/null
  echo "  $c"
done

echo "--- Granting Storage Blob Data Contributor on $STORAGE_ACCOUNT_NAME ---"
az role assignment create \
  --assignee-object-id "$STORAGE_GRANTEE_OBJECT_ID" \
  --assignee-principal-type "$STORAGE_GRANTEE_TYPE" \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID" \
  --only-show-errors 2>&1 | grep -v "already exists" || true

mkdir -p "$REPO_ROOT/generated"
cat > "$REPO_ROOT/generated/.env.blob-storage" <<EOF
export STORAGE_ACCOUNT_ID="$STORAGE_ID"
export STORAGE_ACCOUNT_NAME="$STORAGE_ACCOUNT_NAME"
export STORAGE_PRIMARY_ENDPOINT="$STORAGE_ENDPOINT"
EOF
echo "Wrote generated/.env.blob-storage"
```

## Terraform snippet (reference)

```hcl
terraform {
  required_version = ">= 1.11"   # one azurerm 4.x line with the rest of the bootstrap

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_storage_account" "main" {
  name                            = var.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = trimprefix(var.storage_sku, "Standard_")  # "LRS" | "ZRS" | "GRS"
  account_kind                    = "StorageV2"
  access_tier                     = var.storage_tier
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = var.storage_public_access
  tags                            = var.tags

  lifecycle { prevent_destroy = true }
}

resource "azurerm_storage_container" "main" {
  for_each = toset(split(",", var.storage_containers))

  name                  = each.value
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

resource "azurerm_role_assignment" "blob_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.storage_grantee_object_id
  principal_type       = var.storage_grantee_type
}

output "storage_account_id"      { value = azurerm_storage_account.main.id }
output "storage_account_name"    { value = azurerm_storage_account.main.name }
output "storage_primary_endpoint" { value = azurerm_storage_account.main.primary_blob_endpoint }
```

## Hardening: private endpoint

When `STORAGE_PUBLIC_ACCESS=false`, add a private endpoint into the cluster's VNet so workloads can reach Blob:

```hcl
resource "azurerm_private_endpoint" "storage" {
  name                = "pe-${var.storage_account_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.node_subnet_id

  private_service_connection {
    name                           = "psc-${var.storage_account_name}"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
}
```

You'll also need an `azurerm_private_dns_zone` for `privatelink.blob.core.windows.net` and a zone link to the VNet. Out of scope for validation; add when promoting to prod.

## Teardown

Storage account contains data — `prevent_destroy = true` in TF; bash teardown should require `--yes` confirmation:

```bash
az storage account delete --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" --yes
```

## Validation checklist

- [ ] `STORAGE_ACCOUNT_NAME` matches `^[a-z0-9]{3,24}$`
- [ ] `https_only` + `min_tls_version=TLS1_2` + `allow_blob_public_access=false`
- [ ] Container access type is `private` (never `blob` or `container`)
- [ ] Role assignment is `Storage Blob Data Contributor` (not `Storage Account Contributor` — that's control-plane)
- [ ] Role assignment scope is the account, not the RG or subscription
- [ ] Idempotent (role assignment "already exists" tolerated, container create tolerates exists)
- [ ] `prevent_destroy = true` on the storage account (Terraform)
- [ ] Private endpoint path documented but gated on `STORAGE_PUBLIC_ACCESS=false`
- [ ] `generated/.env.blob-storage` written

## References

| Topic | Source |
|---|---|
| Storage Account naming | https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftstorage |
| Blob RBAC roles | https://learn.microsoft.com/azure/storage/blobs/assign-azure-role-data-access |
| Workload identity → Blob | https://learn.microsoft.com/azure/aks/workload-identity-overview |
| Storage private endpoint | https://learn.microsoft.com/azure/storage/common/storage-private-endpoints |
