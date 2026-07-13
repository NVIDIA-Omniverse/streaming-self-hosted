---
name: iam-vpc
description: Generates a bash script or Terraform module that provisions the Azure foundation for an AKS deployment — Resource Group, VNet, node subnet, API server subnet (for VNet integration), and a user-assigned managed identity for the cluster control plane. No NSG attached to subnets by default (AKS auto-manages a NIC-level NSG). Use as Stage 01 of `aks-bootstrap`, or standalone when laying down networking before any cluster work. Trigger when the user mentions "VNet", "resource group", "subnets", "managed identity", "network setup", "iam-vpc", or asks to "set up the Azure foundation".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# Azure IAM + VPC foundation for AKS

## What this skill produces

A self-contained script (bash with `az`, or Terraform module) that creates:

| Resource | Purpose |
|---|---|
| Resource Group | Container for all stack resources |
| Virtual Network (VNet) | Cluster network |
| Node subnet (`/22` default) | AKS node pool NICs |
| API server subnet (`/28`) | AKS API server VNet integration (per [`tf-conventions`](../tf-conventions/SKILL.md) R3) |
| User-assigned Managed Identity | Assigned to the AKS control plane |
| `Network Contributor` role assignments | Granted to the cluster identity on the node subnet **and** the API server subnet — required for `aks-cluster` to join those subnets (see "Cluster identity network permissions" below) |

**Not in scope:** NSG attached to the node subnet (AKS auto-manages a NIC-level NSG — see `tf-conventions` R5). AKS cluster itself (see `aks-cluster`). ACR, Blob, GPU operator (separate skills).

## Inputs

Source from `streaming-env.sh` (or pass as env vars). If any required input is missing, fail fast with `: "${VAR:?...}"`.

**Required:**

| Variable | Description | Example |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID` | Target subscription | `60762596-e998-40df-8b39-796ed1f4f2ee` |
| `RESOURCE_GROUP` | RG name (Azure resource name; use hyphens) | `rg-nvcf-westus3` |
| `LOCATION` | Azure region | `westus3` |
| `VNET_NAME` | VNet name | `vnet-nvcf-westus3` |
| `CLUSTER_NAME` | Used to derive the cluster managed-identity name | `aks-nvcf-validation-westus3` |

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `VNET_ADDRESS_SPACE` | VNet CIDR | `10.10.0.0/16` |
| `NODE_SUBNET_NAME` | Node subnet name | `snet-aks-nodes` |
| `NODE_SUBNET_CIDR` | Node subnet CIDR | `10.10.0.0/22` |
| `API_SERVER_SUBNET_NAME` | API server subnet name | `snet-aks-api-server` |
| `API_SERVER_SUBNET_CIDR` | API server subnet CIDR (must be `/28` minimum, and **must not overlap** `NODE_SUBNET_CIDR`) | `10.10.4.0/28` |
| `CLUSTER_IDENTITY_NAME` | User-assigned managed identity for the cluster | `id-${CLUSTER_NAME}` |
| `TAGS` | Resource tags map | `{ env = "validation", "managed-by" = "terraform", owner = "nvcf" }` |
| `OUTPUT_FORMAT` | `bash` or `terraform` | `bash` |

> **Subnet CIDRs must be disjoint.** The node subnet (`10.10.0.0/22` → `10.10.0.0`–`10.10.3.255`) and the API server subnet (`10.10.4.0/28` → `10.10.4.0`–`10.10.4.15`) do not overlap, and both sit inside the VNet `10.10.0.0/16`. If you override one CIDR, keep the other outside its range — an overlap makes Azure reject the second subnet with `NetcfgSubnetRangesOverlap`. (Earlier defaults paired the `/22` node subnet with `10.10.2.0/28`, which sits *inside* the `/22` and broke green-field deploys.)

## Outputs

- **Bash mode:** `generated/stage01-<cluster-name>-iam-vpc.sh` — idempotent, supports `--teardown`.
- **Terraform mode:** `generated/<cluster-name>/iam-vpc/` containing `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`.

Outputs (for downstream stages):
- `RESOURCE_GROUP_ID`
- `VNET_ID`
- `NODE_SUBNET_ID`
- `API_SERVER_SUBNET_ID`
- `CLUSTER_IDENTITY_ID`, `CLUSTER_IDENTITY_PRINCIPAL_ID`

The script writes these to `generated/.env.iam-vpc` for sourcing by later stages.

## Cluster identity network permissions (required — do not skip)

This skill creates a **user-assigned** identity for the control plane and a **BYO** VNet/subnets, and `aks-cluster` then assigns that identity to the cluster with API server VNet integration (`--apiserver-subnet-id`) and a custom node subnet (`--vnet-subnet-id`). With a BYO subnet + user-assigned identity, **AKS does not auto-grant the network role** — the identity needs `Network Contributor` on **both** the node subnet and the API server subnet, or `az aks create` fails at provisioning with:

```text
ResourceMissingPermissionError ... joinLoadBalancer/action ... on .../subnets/<api-server-subnet>
```

This is Microsoft's documented procedure: grant `Network Contributor` to the cluster identity on each subnet **before** `az aks create` ([API Server VNet Integration — "Create a managed identity and give it permissions on the virtual network"](https://learn.microsoft.com/azure/aks/api-server-vnet-integration)). `iam-vpc` owns the identity *and* the subnets, so it emits these grants; `aks-cluster` only references them by ID.

- **Scope to the two subnets**, not the whole VNet — least privilege, and `Network Contributor` already includes `subnets/join/action` and `subnets/joinLoadBalancer/action`.
- **RBAC propagation** is eventually consistent (~60–90s). In `aks-bootstrap`'s one-pass run, stage 02 starts right after this stage, so the grant may not have propagated yet — guard it (Terraform: a `time_sleep` on the role assignments; Bash: the grant plus a short propagation wait, and `aks-cluster` should retry `az aks create` on `ResourceMissingPermissionError`).

## Generation rules

1. The script MUST open with `set -euo pipefail` and source `streaming-env.sh` (or read env vars).
2. Hardcode no secrets. RG, VNet, subnet CIDRs come from env vars with defaults.
3. Use `az group create`, `az network vnet create`, `az network vnet subnet create`, `az identity create`. Each with `--only-show-errors`. Create the VNet without `--subnet-name` — never pass subnets inline to `az network vnet create`, because re-running against a VNet that already has differently-named subnets causes Azure to DELETE the existing subnet to reconcile to the specified list. Instead, create each subnet with a separate existence-guarded call: `az network vnet subnet show ... &>/dev/null || az network vnet subnet create ...`.
4. Support `--teardown`: delete the RG (which cascades to everything else). Confirm before delete unless `--yes` is passed.
5. Per [`tf-conventions`](../tf-conventions/SKILL.md) R5 — **do not** attach an `azurerm_subnet_network_security_group_association` to the node subnet. AKS auto-manages a NIC-level NSG.
6. Grant the cluster identity `Network Contributor` on the node subnet **and** the API server subnet (see "Cluster identity network permissions" above). Bash: `az role assignment create` per subnet, using `--assignee-object-id "$IDENTITY_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal` (avoids a Graph lookup race on the just-created identity). Terraform: one `azurerm_role_assignment` per subnet, scoped to the subnet ID.

## Bash snippet (reference)

```bash
#!/bin/bash
set -euo pipefail

# Resolve repo root from script location — works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/streaming-env.sh"

: "${AZURE_SUBSCRIPTION_ID:?}" "${RESOURCE_GROUP:?}" "${LOCATION:?}" "${VNET_NAME:?}" "${CLUSTER_NAME:?}"
VNET_ADDRESS_SPACE="${VNET_ADDRESS_SPACE:-10.10.0.0/16}"
NODE_SUBNET_NAME="${NODE_SUBNET_NAME:-snet-aks-nodes}"
NODE_SUBNET_CIDR="${NODE_SUBNET_CIDR:-10.10.0.0/22}"
API_SERVER_SUBNET_NAME="${API_SERVER_SUBNET_NAME:-snet-aks-api-server}"
# API server subnet must not overlap NODE_SUBNET_CIDR (10.10.0.0/22 = 10.10.0.0-10.10.3.255).
# 10.10.4.0/28 is the next block past the node /22, still inside the VNet 10.10.0.0/16.
API_SERVER_SUBNET_CIDR="${API_SERVER_SUBNET_CIDR:-10.10.4.0/28}"
CLUSTER_IDENTITY_NAME="${CLUSTER_IDENTITY_NAME:-id-${CLUSTER_NAME}}"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

echo "--- Resource Group ---"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --only-show-errors

echo "--- VNet + subnets ---"
# Create VNet without --subnet-name: passing --subnet-name to az network vnet create is a
# PUT-like reconcile — if the VNet already exists with differently-named subnets, Azure deletes
# those subnets to converge. Guard each resource separately instead.
if ! az network vnet show --name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" --only-show-errors &>/dev/null; then
  az network vnet create \
    --name "$VNET_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --address-prefixes "$VNET_ADDRESS_SPACE" \
    --only-show-errors
fi

if ! az network vnet subnet show --name "$NODE_SUBNET_NAME" --vnet-name "$VNET_NAME" \
     --resource-group "$RESOURCE_GROUP" --only-show-errors &>/dev/null; then
  az network vnet subnet create \
    --name "$NODE_SUBNET_NAME" \
    --vnet-name "$VNET_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --address-prefixes "$NODE_SUBNET_CIDR" \
    --only-show-errors
fi

if ! az network vnet subnet show --name "$API_SERVER_SUBNET_NAME" --vnet-name "$VNET_NAME" \
     --resource-group "$RESOURCE_GROUP" --only-show-errors &>/dev/null; then
  az network vnet subnet create \
    --name "$API_SERVER_SUBNET_NAME" \
    --vnet-name "$VNET_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --address-prefixes "$API_SERVER_SUBNET_CIDR" \
    --delegations Microsoft.ContainerService/managedClusters \
    --only-show-errors
fi

echo "--- Cluster managed identity ---"
az identity create \
  --name "$CLUSTER_IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --only-show-errors

# Emit downstream env file
RG_ID=$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)
VNET_ID=$(az network vnet show -n "$VNET_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
NODE_SUBNET_ID=$(az network vnet subnet show --vnet-name "$VNET_NAME" -g "$RESOURCE_GROUP" -n "$NODE_SUBNET_NAME" --query id -o tsv)
API_SUBNET_ID=$(az network vnet subnet show --vnet-name "$VNET_NAME" -g "$RESOURCE_GROUP" -n "$API_SERVER_SUBNET_NAME" --query id -o tsv)
IDENTITY_ID=$(az identity show -n "$CLUSTER_IDENTITY_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show -n "$CLUSTER_IDENTITY_NAME" -g "$RESOURCE_GROUP" --query principalId -o tsv)

# Cluster identity MUST have Network Contributor on both BYO subnets, or `aks-cluster` fails at
# provisioning with ResourceMissingPermissionError (.../subnets/joinLoadBalancer/action). AKS does
# not auto-grant this for a BYO subnet + user-assigned identity. Scope to the subnets (least
# privilege; Network Contributor includes subnets/join + joinLoadBalancer). Idempotent: az role
# assignment create is a no-op if the assignment already exists. Use --assignee-object-id +
# --assignee-principal-type ServicePrincipal to avoid an AAD Graph lookup race on the new identity.
echo "--- Granting Network Contributor to cluster identity on node + api-server subnets ---"
for SUBNET_ID in "$NODE_SUBNET_ID" "$API_SUBNET_ID"; do
  az role assignment create \
    --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" \
    --scope "$SUBNET_ID" \
    --only-show-errors
done
# RBAC propagation is eventually consistent (~60-90s). In aks-bootstrap's one-pass run, stage 02
# starts immediately after this stage, so aks-cluster should retry `az aks create` on
# ResourceMissingPermissionError rather than assume the grant is live.

mkdir -p "$REPO_ROOT/generated"
cat > "$REPO_ROOT/generated/.env.iam-vpc" <<EOF
export RESOURCE_GROUP_ID="$RG_ID"
export VNET_ID="$VNET_ID"
export NODE_SUBNET_ID="$NODE_SUBNET_ID"
export API_SERVER_SUBNET_ID="$API_SUBNET_ID"
export CLUSTER_IDENTITY_ID="$IDENTITY_ID"
export CLUSTER_IDENTITY_PRINCIPAL_ID="$IDENTITY_PRINCIPAL_ID"
EOF
echo "Wrote generated/.env.iam-vpc"
```

## Terraform snippet (reference)

Use `azurerm` provider `>= 4.46.0, < 5.0.0` — the version the `aks-cluster` AVM module (`= 0.5.4`) requires; keep the whole bootstrap on one azurerm 4.x line so Stages 01 and 02 share a provider. Requires Terraform `>= 1.11`. Pin AVM modules exactly per [`tf-conventions`](../tf-conventions/SKILL.md) Override 1. The role-assignment propagation guard uses `time_sleep`, so also declare the `hashicorp/time` provider in `providers.tf`.

```hcl
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle { prevent_destroy = true }
}

resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = var.node_subnet_name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.node_subnet_cidr]
}

resource "azurerm_subnet" "api_server" {
  name                 = var.api_server_subnet_name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.api_server_subnet_cidr]

  delegation {
    name = "aks-api-server"
    service_delegation {
      name = "Microsoft.ContainerService/managedClusters"
    }
  }
}

resource "azurerm_user_assigned_identity" "cluster" {
  name                = var.cluster_identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# Cluster identity needs Network Contributor on BOTH BYO subnets, or aks-cluster fails at
# provisioning with ResourceMissingPermissionError (.../subnets/joinLoadBalancer/action). AKS does
# not auto-grant this for a BYO subnet + user-assigned identity. Scope to the subnets (least
# privilege; Network Contributor includes subnets/join + joinLoadBalancer).
# Ref: https://learn.microsoft.com/azure/aks/api-server-vnet-integration
resource "azurerm_role_assignment" "cluster_identity_node_subnet" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

resource "azurerm_role_assignment" "cluster_identity_apiserver_subnet" {
  scope                = azurerm_subnet.api_server.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# RBAC propagation is eventually consistent; let the grants settle before aks-cluster consumes the
# identity. Tune the delay if cluster create still races the role assignment.
resource "time_sleep" "wait_for_rbac" {
  depends_on = [
    azurerm_role_assignment.cluster_identity_node_subnet,
    azurerm_role_assignment.cluster_identity_apiserver_subnet,
  ]
  create_duration = "90s"
}

output "resource_group_id"           { value = azurerm_resource_group.main.id }
output "vnet_id"                     { value = azurerm_virtual_network.main.id }
output "node_subnet_id"              { value = azurerm_subnet.nodes.id }
output "api_server_subnet_id"        { value = azurerm_subnet.api_server.id }
output "cluster_identity_id"         { value = azurerm_user_assigned_identity.cluster.id }
output "cluster_identity_principal_id" { value = azurerm_user_assigned_identity.cluster.principal_id }
```

## Teardown

Bash: `bash generated/stage01-<cluster>-iam-vpc.sh --teardown` — runs `az group delete --name "$RESOURCE_GROUP" --yes --no-wait` after confirmation.

Terraform: `terraform destroy` — but RG has `prevent_destroy = true`. Either temporarily disable, or `terraform state rm` the RG and delete via `az group delete`.

## Validation checklist

- [ ] Script opens with `set -euo pipefail` and resolves the repo root via `BASH_SOURCE` (works regardless of CWD)
- [ ] Sources `streaming-env.sh` via the resolved absolute path
- [ ] All required env vars have `: "${VAR:?}"` fail-fast checks
- [ ] VNet created without `--subnet-name` — no inline subnet in `az network vnet create`
- [ ] Node subnet and API server subnet each created with a separate existence-guarded `az network vnet subnet show ... &>/dev/null || az network vnet subnet create ...`
- [ ] No NSG attached to either subnet (per [`tf-conventions`](../tf-conventions/SKILL.md) R5)
- [ ] API server subnet is delegated to `Microsoft.ContainerService/managedClusters`
- [ ] API server subnet CIDR is at least `/28` (AKS minimum)
- [ ] Node subnet and API server subnet CIDRs are **disjoint** (no containment/overlap) — defaults `10.10.0.0/22` + `10.10.4.0/28` are; an overlap makes Azure reject the second subnet with `NetcfgSubnetRangesOverlap`
- [ ] User-assigned identity created in the same RG as the cluster (so its lifecycle is bound)
- [ ] Cluster identity is granted `Network Contributor` on **both** the node subnet and the API server subnet (scoped to the subnets, not the VNet) — without this, `aks-cluster` fails with `ResourceMissingPermissionError (joinLoadBalancer)`. Bash uses `--assignee-object-id`/`--assignee-principal-type ServicePrincipal`; Terraform uses one `azurerm_role_assignment` per subnet
- [ ] RBAC propagation is accounted for (Terraform `time_sleep`; Bash relies on `aks-cluster` retrying on `ResourceMissingPermissionError`)
- [ ] `generated/.env.iam-vpc` is written with downstream-needed IDs
- [ ] `--teardown` deletes the entire RG (cascade)
- [ ] No image versions, no secrets, no AAD object IDs hardcoded — everything from env or fail-fast

## References

| Topic | Source |
|---|---|
| AKS API server VNet integration (incl. the Network Contributor grants on both subnets) | https://learn.microsoft.com/azure/aks/api-server-vnet-integration |
| AVM AKS resource module | https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster |
| Subnet delegation for AKS API server | https://learn.microsoft.com/azure/virtual-network/subnet-delegation-overview |
