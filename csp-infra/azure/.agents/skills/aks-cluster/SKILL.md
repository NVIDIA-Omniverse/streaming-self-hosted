---
name: aks-cluster
description: Generates a Terraform module (AVM resource module) that creates an AKS Standard cluster with a system node pool, AAD + Azure RBAC, OIDC issuer + workload identity, Azure CNI Overlay (Cilium NetworkPolicy), API server VNet integration, and an optional corp-egress allowlist. Does NOT create the GPU node pool — that's `aks-nodes`. Use as Stage 02 of `aks-bootstrap`, after `iam-vpc`. Trigger when the user mentions "create AKS cluster", "aks-cluster", "AKS control plane", or asks to "spin up an AKS cluster".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AKS cluster (system pool + control plane)

## What this skill produces

A Terraform module that creates one AKS Standard cluster with the **system pool only**. GPU pool and compute pool come from `aks-nodes` after this lands.

| Component | Setting |
|---|---|
| AVM module | `Azure/avm-res-containerservice-managedcluster/azurerm` pinned `= 0.5.4` |
| `enable_telemetry` | `false` |
| Network plugin | Azure CNI Overlay |
| Network policy | Cilium |
| Pod CIDR | `100.64.0.0/16` (synthetic; per AKS overlay) |
| Service CIDR | `10.0.0.0/16` |
| API server access | VNet integration + public FQDN, **no IP allowlist by default**; access gated by AAD + Azure RBAC (`disable_local_accounts=true`). IP allowlist is optional hardening. |
| AAD + Azure RBAC | `aad_profile.enable_azure_rbac = true`, `disable_local_accounts = true` |
| OIDC + workload identity | both enabled |
| System pool | `Standard_D8ds_v5` × 3, autoscale 3–5, zone `["1"]` |
| Cluster identity | User-assigned, from `iam-vpc` |

Why `Standard_D8ds_v5` (not the AVM default `D4d_v5`): the NVCF self-managed stack + caches don't fit on 4 vCPU / 16 GiB. See [`tf-conventions`](../tf-conventions/SKILL.md) R2.

Why **3 nodes** (not 1): the NVCF self-managed stack is a 3-replica HA design — OpenBao server runs a 3-node Raft cluster, Cassandra `replicaCount: 3`, NATS 3, and the OpenBao injector uses hard anti-affinity. A 1-node floor leaves these Pending and the OpenBao Raft join cannot form. Default the system pool to a floor of 3 so a fresh deploy runs the control plane HA without a manual scale-up. Drop to 1 only for a throwaway single-replica test (set `SYSTEM_POOL_MIN_COUNT=1` and disable HA in the stack env).

## Inputs

Source from `streaming-env.sh` and `generated/.env.iam-vpc` (written by the `iam-vpc` skill).

**Required:**

| Variable | Description | Example |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID` | Subscription | `60762596-...` |
| `RESOURCE_GROUP` | RG (from `iam-vpc`) | `rg-nvcf-westus3` |
| `LOCATION` | Region | `westus3` |
| `CLUSTER_NAME` | AKS cluster name (hyphens, lowercase) | `aks-nvcf-validation-westus3` |
| `NODE_SUBNET_ID` | from `.env.iam-vpc` | (resource ID) |
| `API_SERVER_SUBNET_ID` | from `.env.iam-vpc` | (resource ID) |
| `CLUSTER_IDENTITY_ID` | from `.env.iam-vpc` | (resource ID) |
| `AUTHORIZED_IP_RANGES` | **Optional** corp-egress CIDR(s) for the optional IP allowlist. Empty (default) = no allowlist; access is gated by AAD + Azure RBAC. NOT a laptop /32 (see [`tf-conventions`](../tf-conventions/SKILL.md) R3) | _(empty)_ |
| `ADMIN_AAD_OBJECT_IDS` | Comma-separated AAD object IDs granted kubectl cluster-admin (each gets "Cluster User Role" + "RBAC Cluster Admin" on the cluster scope). **User _or_ group** object IDs both work. For your own: `az ad signed-in-user show --query id -o tsv` | `<obj-id-1>,<obj-id-2>` |

> The AVM module input `parent_id` (TF var `resource_group_id`) is the RG's **full resource ID**, not its name — construct it as `/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}`.

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `KUBERNETES_VERSION` | K8s version (omit to use AKS-managed default) | (unset) |
| `SYSTEM_POOL_VM_SIZE` | System pool VM SKU | `Standard_D8ds_v5` |
| `SYSTEM_POOL_MIN_COUNT` | Autoscale floor (3 for the NVCF HA control plane) | `3` |
| `SYSTEM_POOL_MAX_COUNT` | Autoscale ceiling | `5` |
| `SYSTEM_POOL_ZONES` | System pool zone(s) | `1` (single-zone — see Architectural rules below) |
| `POD_CIDR` | Synthetic pod CIDR | `100.64.0.0/16` |
| `SERVICE_CIDR` | Service CIDR | `10.0.0.0/16` |
| `DNS_SERVICE_IP` | DNS IP within `SERVICE_CIDR` | `10.0.0.10` |

## Outputs

- `generated/<cluster-name>/aks-cluster/` containing `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`.

Terraform outputs for downstream stages:
- `cluster_id`
- `kubelet_identity_object_id` (for `AcrPull` role assignment in `acr`)
- `oidc_issuer_url` (for federated credentials)

After `terraform apply`, write the downstream env handoff that later script stages source:

```bash
AKS_DIR="generated/${CLUSTER_NAME}/aks-cluster"
mkdir -p generated
export KUBECONFIG="${KUBECONFIG:-/tmp/kubeconfig-${CLUSTER_NAME}}"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing --file "$KUBECONFIG"
command -v kubelogin >/dev/null || {
  echo "ERROR: kubelogin not found. Install with: az aks install-cli" >&2
  exit 1
}
kubelogin convert-kubeconfig -l azurecli
cat > generated/.env.aks-cluster <<EOF
export AKS_CLUSTER_ID="$(terraform -chdir="$AKS_DIR" output -raw cluster_id)"
export KUBELET_IDENTITY_OBJECT_ID="$(terraform -chdir="$AKS_DIR" output -raw kubelet_identity_object_id)"
export OIDC_ISSUER_URL="$(terraform -chdir="$AKS_DIR" output -raw oidc_issuer_url)"
export KUBECONFIG="$KUBECONFIG"
EOF
```

This handoff maps Terraform outputs into the env-file contract consumed by `aks-nodes`, `acr`, `blob-storage`, `gpu-operator`, and `aks-validate`. It does not create the AKS cluster.

## Architectural rules

Defer to [`tf-conventions`](../tf-conventions/SKILL.md) for the full set. The rules with cluster-side consequences:

1. **Resource module, not pattern module** (`avm-res-containerservice-managedcluster`, not `avm-ptn-aks-production`). Pattern module forces `private_cluster_enabled = true` and doesn't expose `authorized_ip_ranges`. Resource module exposes everything.
2. **VNet integration + identity-gated public endpoint by default; optional corp-egress allowlist** — if `authorized_ip_ranges` is set, use stable corp-egress CIDRs, not laptop /32. See [`tf-conventions`](../tf-conventions/SKILL.md) R3.
3. **Azure CNI Overlay + Cilium** — pods get IPs from the synthetic `POD_CIDR`; only nodes get VNet IPs. App-port restrictions belong in K8s NetworkPolicies (not the Azure NSG; see R5).
4. **AAD + Azure RBAC** — `aad_profile.enable_azure_rbac = true`, `disable_local_accounts = true`. Because local accounts are disabled, kubectl access is **only** via Azure RBAC: the skill emits `azurerm_role_assignment`s ("Azure Kubernetes Service Cluster User Role" for kubeconfig pull + "Azure Kubernetes Service RBAC Cluster Admin" for in-cluster authz) on the cluster scope for **each id in `ADMIN_AAD_OBJECT_IDS`** (works for users and groups). Without these the operator gets `Forbidden` on every kubectl call.
5. **OIDC + workload identity** — `oidc_issuer_profile.enabled = true` and `security_profile.workload_identity.enabled = true`. Federated credentials live with the consuming workload, not in this skill.
6. **Single-AZ system pool** when LLS will be deployed — Azure LB zonality must match GPU pool zonality, and the system pool LB carries cluster-internal Services. If LLS won't be deployed, set `SYSTEM_POOL_ZONES=1,2,3`.

## API server access

The default is VNet integration + a **public API FQDN with no IP allowlist**, gated by identity: **AAD authentication + Azure RBAC + `disable_local_accounts=true`** (all enabled by this skill). The endpoint is reachable from anywhere but does nothing without a valid AAD token *and* an Azure-RBAC role assignment — "public endpoint, still authenticated," not open access. This matches Azure's default posture and removes the IP-allowlist toil that the laptop-`/32` approach causes.

The ids in `ADMIN_AAD_OBJECT_IDS` are granted cluster-admin automatically by the skill (see Design principle 4). To grant **additional** people later — by identity, not by IP — assign them an Azure RBAC role on the cluster (prefer an AAD group over individual emails):

```text
# 1. let them pull a kubeconfig (az aks get-credentials)
az role assignment create --assignee <user@org.com> \
  --role "Azure Kubernetes Service Cluster User Role" --scope <cluster-resource-id>
# 2. in-cluster authorization — least-privilege: RBAC Reader / Writer / Admin / Cluster Admin
az role assignment create --assignee <user@org.com> \
  --role "Azure Kubernetes Service RBAC Admin" --scope <cluster-resource-id>
```

**Do not allowlist laptop `/32`s** (R3): on corporate VPN the egress IP rotates, and every rotation silently knocks `kubectl`/`helm` off the allowlist → `Unable to connect … EOF` or, worse, a mid-operation `http2: client connection lost` that can corrupt a `helm` release. Re-running `az aks update --api-server-authorized-ip-ranges` per rotation is toil and racy. The identity gate above is the primary control; only add a network restriction if your security posture requires defense-in-depth.

**Optional network-layer hardening** (on top of the identity gate; pick at most one):

1. **Allowlist the corporate VPN egress CIDR(s)** — one stable range, not per-laptop `/32`s, so it survives per-session rotation. Requires knowing the VPN NAT egress block. Set via `AUTHORIZED_IP_RANGES`; toggle live with `az aks update --api-server-authorized-ip-ranges <cidr>` (restore) / `""` (clear).
2. **Private cluster** (API server private endpoint) reached over VPN/ExpressRoute — removes the public FQDN entirely. Heaviest change (the AVM **resource** module supports `private_cluster_enabled`; note R1 — the pattern module forces it on); best end state for a long-lived cluster.
3. **Bastion / jump host with a static IP** in (or peered to) the cluster VNet — allowlist that one IP; operators `ssh`/SSM in. Stable, but another box to run.

For one-off ops from a rotating IP without touching any allowlist, **`az aks command invoke`** runs `kubectl`/`helm` **server-side** in the cluster (no allowlist entry needed; slower, no `kubectl logs -f`/`port-forward`).

If you do keep an allowlist, make the per-IP fallback **idempotent and safe**: detect the lockout, **add** the current egress IP to the existing list (don't replace it), and **never start a destructive `helm` op while connectivity is unverified** (a rotation mid-`helm upgrade` corrupts release state).

## Terraform snippet (reference)

```hcl
terraform {
  required_version = ">= 1.11"   # AVM 0.5.4 submodules declare ~> 1.11

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"   # required by AVM 0.5.4 (NOT azurerm 3.x)
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"               # AVM 0.5.4 drives the cluster through azapi
    }
  }
}

provider "azurerm" {
  features {}
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.5.4"   # exact pin per tf-conventions Override 1

  # This is an AVM RESOURCE MODULE: inputs follow the AVM interface, NOT the
  # azurerm_kubernetes_cluster resource schema (e.g. parent_id not
  # resource_group_name; managed_identities not identity; default_agent_pool
  # not default_node_pool).
  name      = var.cluster_name
  parent_id = var.resource_group_id   # the RG's FULL resource ID (from iam-vpc), not its name
  location  = var.location

  enable_telemetry   = false
  kubernetes_version = var.kubernetes_version

  enable_rbac            = true   # Kubernetes RBAC
  disable_local_accounts = true

  addon_profile_azure_policy = { enabled = true }
  oidc_issuer_profile        = { enabled = true }
  security_profile = {
    workload_identity = { enabled = true }   # workload identity lives under security_profile in AVM
  }

  managed_identities = {
    user_assigned_resource_ids = [var.cluster_identity_id]   # user-assigned identity from iam-vpc
  }

  aad_profile = {
    managed                = true
    enable_azure_rbac      = true
    admin_group_object_ids = var.admin_aad_object_ids   # only GROUP ids take effect here (managed-AAD admin binding); individual USERS get access via the role assignments below
  }

  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_dataplane   = "cilium"     # Azure CNI Powered by Cilium — REQUIRED when network_policy = "cilium", else AKS create fails with NetworkPolicyNotSupported / NetworkPolicyCiliumRequiresCiliumDataplane
    network_policy      = "cilium"     # enforce NetworkPolicy via the Cilium dataplane above
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "loadBalancer"
  }

  api_server_access_profile = {
    enable_vnet_integration = true
    subnet_id               = var.api_server_subnet_id
    enable_private_cluster  = false
    authorized_ip_ranges    = var.authorized_ip_ranges   # default [] = no allowlist (identity-gated); set CIDRs only for optional hardening
  }

  default_agent_pool = {
    name                = "system"
    vm_size             = var.system_pool_vm_size
    vnet_subnet_id      = var.node_subnet_id
    enable_auto_scaling = true
    min_count           = var.system_pool_min_count
    max_count           = var.system_pool_max_count
    availability_zones  = var.system_pool_zones
    # No CriticalAddonsOnly taint: the system pool is the only general-purpose pool by default
    # (GPU pool floors at 0, compute pool off) and is sized for the HA control plane, so cluster
    # services — gpu-operator control plane, KAI scheduler, the NVCF self-managed stack — schedule
    # here directly without per-consumer tolerations. Add a dedicated untainted compute pool in
    # aks-nodes before reserving the system pool for critical addons.
  }

  tags = var.tags
}

# Cluster-admin access. With disable_local_accounts = true + Azure RBAC, kubectl access is
# ONLY via Azure RBAC role assignments — admin_group_object_ids alone grants nothing to a
# USER, and an AAD admin group is optional. Grant each id in ADMIN_AAD_OBJECT_IDS (works for
# users AND groups; see tf-conventions R7):
#   - "Cluster User Role"        → lets them pull a kubeconfig (az aks get-credentials)
#   - "RBAC Cluster Admin"       → in-cluster cluster-admin authorization
# Without these, every kubectl call is "Forbidden ... User does not have access to the
# resource in Azure" after a clean create.
resource "azurerm_role_assignment" "cluster_user" {
  for_each             = toset(var.admin_aad_object_ids)
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "rbac_cluster_admin" {
  for_each             = toset(var.admin_aad_object_ids)
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

output "cluster_id"                 { value = module.aks.resource_id }
output "kubelet_identity_object_id" { value = module.aks.kubelet_identity.objectId }   # azapi raw output is camelCase
output "oidc_issuer_url"            { value = module.aks.oidc_issuer_profile_issuer_url }
```

## Teardown

Use `terraform destroy` on the aks-cluster module. This does NOT delete the RG, VNet, or subnets; use `iam-vpc` for those resources.

## Validation checklist

- [ ] `authorized_ip_ranges` defaults to `[]` (no allowlist; identity-gated) and is set only for optional network-layer hardening
- [ ] API server VNet integration is enabled with a delegated `/28` subnet
- [ ] `aad_profile.managed = true`, `aad_profile.enable_azure_rbac = true`, and `disable_local_accounts = true` are all present
- [ ] `oidc_issuer_profile.enabled = true` and `security_profile.workload_identity.enabled = true` are both present
- [ ] An `azurerm_role_assignment` for "Azure Kubernetes Service RBAC Cluster Admin" (and "Cluster User Role") on the cluster scope is emitted for each `ADMIN_AAD_OBJECT_IDS` id — without it, `disable_local_accounts=true` leaves kubectl `Forbidden`
- [ ] Inputs use the AVM interface, not `azurerm_kubernetes_cluster` resource arguments (`parent_id`/`managed_identities`/`default_agent_pool`, not `resource_group_name`/`identity`/`default_node_pool`)
- [ ] `terraform { required_providers }` pins `azurerm >= 4.46.0, < 5.0.0` and `required_version >= 1.11` (AVM 0.5.4 requirements)
- [ ] Network plugin is Azure CNI Overlay + Cilium policy — `network_profile` sets **both** `network_dataplane = "cilium"` and `network_policy = "cilium"` (the policy requires the dataplane; omitting it fails AKS create with `NetworkPolicyNotSupported`)
- [ ] System pool single-zone if LLS will be deployed; multi-zone otherwise
- [ ] User-assigned identity from `iam-vpc` is attached to the cluster
- [ ] AVM module pinned `= 0.5.4`
- [ ] `enable_telemetry = false`
- [ ] Terraform outputs expose `cluster_id`, `kubelet_identity_object_id`, `oidc_issuer_url`
- [ ] After apply, `generated/.env.aks-cluster` maps Terraform outputs to `AKS_CLUSTER_ID`, `KUBELET_IDENTITY_OBJECT_ID`, `OIDC_ISSUER_URL`, and `KUBECONFIG` for downstream stages
- [ ] No secrets, no image versions, no AAD object IDs hardcoded

## References

| Topic | Source |
|---|---|
| AVM AKS resource module | https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster |
| Azure CNI Overlay + Cilium | https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium |
| AKS API server VNet integration | https://learn.microsoft.com/azure/aks/api-server-vnet-integration |
| Workload identity on AKS | https://learn.microsoft.com/azure/aks/workload-identity-overview |
| Azure RBAC for K8s | https://learn.microsoft.com/azure/aks/manage-azure-rbac |
