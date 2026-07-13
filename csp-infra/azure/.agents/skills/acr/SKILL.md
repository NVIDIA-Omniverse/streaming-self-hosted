---
name: acr
description: Generates a bash or Terraform snippet that creates an Azure Container Registry (Standard tier) in the cluster's resource group and grants the AKS kubelet identity `AcrPull` on it. Output enables passwordless image pulls from the cluster — no `imagePullSecrets` needed. Does NOT populate the registry — see the `acr-mirror` skill for the bulk NGC → ACR mirror. Use as Stage 04 of `aks-bootstrap`, after `aks-cluster`. Trigger when the user mentions "create ACR", "container registry", "AcrPull", "passwordless pull from AKS".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# Azure Container Registry + AcrPull

## What this skill produces

| Resource | Setting |
|---|---|
| `azurerm_container_registry` | SKU `Standard` (Basic for cost-sensitive dev), zone-redundant `false`, public access enabled |
| `azurerm_role_assignment` | `AcrPull` for the AKS kubelet identity on the ACR scope |

This skill creates the registry only. Populating it with NVCF images (~50 images from the SBOM) is covered by the [`acr-mirror`](../acr-mirror/SKILL.md) skill — the operational counterpart to this one. Run `acr-mirror` after `acr` and before any NVCF stack install.

For a **one-off** sanity-check mirror (e.g., right after creation to verify the AcrPull binding works), see the [Verifying the pull works](#verifying-the-pull-works) section below.

## Inputs

Source from `streaming-env.sh` + `generated/.env.iam-vpc` + `generated/.env.aks-cluster`.

**Required:**

| Variable | Description |
|---|---|
| `AZURE_SUBSCRIPTION_ID` | Subscription |
| `RESOURCE_GROUP` | RG |
| `LOCATION` | Region |
| `ACR_NAME` | ACR name — 5–50 chars, **lowercase alphanumeric only, NO hyphens**, globally unique |
| `KUBELET_IDENTITY_OBJECT_ID` | from `.env.aks-cluster` |

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `ACR_SKU` | ACR tier (`Basic`, `Standard`, `Premium`) | `Standard` |
| `ACR_ADMIN_ENABLED` | Admin user (avoid for prod) | `false` |
| `ACR_PUBLIC_ACCESS` | Public network access | `true` (set `false` + add private endpoint for hardening) |
| `OUTPUT_FORMAT` | `bash` or `terraform` | `bash` |

## Outputs

- **Bash:** `generated/stage04-<cluster-name>-acr.sh`
- **Terraform:** `generated/<cluster-name>/acr/main.tf`

Writes `generated/.env.acr` with `ACR_ID`, `ACR_LOGIN_SERVER`, `ACR_NAME`.

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

: "${AZURE_SUBSCRIPTION_ID:?}" "${RESOURCE_GROUP:?}" "${LOCATION:?}" "${ACR_NAME:?}" "${KUBELET_IDENTITY_OBJECT_ID:?}"
ACR_SKU="${ACR_SKU:-Standard}"

# ACR name validation: 5–50 chars, lowercase alphanumeric only
if [[ ! "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]]; then
  echo "ERROR: ACR_NAME='$ACR_NAME' must be 5–50 chars, lowercase alphanumeric only (no hyphens)."
  exit 1
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

echo "--- Creating ACR $ACR_NAME ($ACR_SKU) ---"
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$ACR_SKU" \
  --admin-enabled "${ACR_ADMIN_ENABLED:-false}" \
  --only-show-errors

ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
ACR_LOGIN_SERVER=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query loginServer -o tsv)

echo "--- Granting AcrPull on $ACR_NAME to AKS kubelet identity ---"
# Idempotent: az role assignment create errors if it exists; ignore that one specific error.
az role assignment create \
  --assignee-object-id "$KUBELET_IDENTITY_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role AcrPull \
  --scope "$ACR_ID" \
  --only-show-errors 2>&1 | grep -v "already exists" || true

mkdir -p "$REPO_ROOT/generated"
cat > "$REPO_ROOT/generated/.env.acr" <<EOF
export ACR_ID="$ACR_ID"
export ACR_LOGIN_SERVER="$ACR_LOGIN_SERVER"
export ACR_NAME="$ACR_NAME"
EOF
echo "Wrote generated/.env.acr"
```

## Terraform snippet (reference)

```hcl
resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.acr_sku        # "Basic" | "Standard" | "Premium"
  admin_enabled       = var.acr_admin_enabled
  tags                = var.tags

  lifecycle { prevent_destroy = true }
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = var.kubelet_identity_object_id
  principal_type       = "ServicePrincipal"
}

output "acr_id"           { value = azurerm_container_registry.main.id }
output "acr_login_server" { value = azurerm_container_registry.main.login_server }
output "acr_name"         { value = azurerm_container_registry.main.name }
```

## Teardown

ACR contains image data — `prevent_destroy = true` in TF; bash teardown should require `--yes` confirmation:

```bash
az acr delete --name "$ACR_NAME" --yes
```

## Verifying the pull works

After the role assignment lands (RBAC propagation: 30s–2min):

```bash
# Mirror one small image (manual)
az acr import --name "$ACR_NAME" \
  --source mcr.microsoft.com/azuredocs/aks-helloworld:v1 \
  --image aks-helloworld:v1

# Pull from AKS to confirm the kubelet can authenticate
kubectl run hello --image "${ACR_LOGIN_SERVER}/aks-helloworld:v1" --restart=Never
kubectl wait --for=condition=Ready pod/hello --timeout=60s
kubectl delete pod hello
```

If the pull fails with `imagePullBackOff` and `unauthorized`, the role assignment hasn't propagated yet — wait 2 minutes and retry. If it still fails, verify `KUBELET_IDENTITY_OBJECT_ID` matches `az aks show ... --query identityProfile.kubeletidentity.objectId`.

## Validation checklist

- [ ] `ACR_NAME` matches `^[a-z0-9]{5,50}$`
- [ ] `AcrPull` role assignment on the ACR scope (not on a parent RG or subscription — least privilege)
- [ ] `principal_type = ServicePrincipal` (kubelet identity is a SP, not a User)
- [ ] `prevent_destroy = true` on the ACR resource (Terraform)
- [ ] Idempotent (role assignment "already exists" error tolerated)
- [ ] No `--admin-enabled true` for prod-intent deploys
- [ ] `generated/.env.acr` written

## References

| Topic | Source |
|---|---|
| ACR + AKS passwordless pull | https://learn.microsoft.com/azure/aks/cluster-container-registry-integration |
| ACR naming rules | https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftcontainerregistry |
| `az acr import` (image mirror) | https://learn.microsoft.com/cli/azure/acr#az-acr-import |
| ACR private endpoint (hardening) | https://learn.microsoft.com/azure/container-registry/container-registry-private-link |
