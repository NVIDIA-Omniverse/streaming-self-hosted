---
name: aks-nodes
description: Generates a bash or Terraform snippet that adds additional node pools to an existing AKS cluster — GPU pool (single-zone, NV/NC SKU) and optional compute pool (for LLS streaming-proxy or other CPU-heavy workloads). Use as Stage 03 of `aks-bootstrap`, after `aks-cluster`. Trigger when the user mentions "GPU node pool", "add node pool", "compute pool", "aks-nodes", or asks "how do I add a GPU pool to AKS".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AKS additional node pools (GPU + compute)

## What this skill produces

Adds 0–2 additional node pools to an existing AKS cluster:

| Pool | SKU (default) | Zone(s) | Labels | Purpose |
|---|---|---|---|---|
| GPU pool | `Standard_NV36ads_A10_v5` | `["1"]` | `nvidia.com/gpu=true` | NVCF function workloads (GPU) |
| Compute pool *(optional)* | `Standard_D8ds_v5` | `["1"]` | `node-type=compute` | LLS `streaming-proxy` and OVDC |

GPU pool MUST be single-zone if LLS will be deployed — Azure Standard LB zonality must match the GPU pool's zone (see [`nvcf-azure-deploy` architecture rule #9](https://gitlab-master.nvidia.com/omniverse/streaming-skills/-/blob/main/azure/.agents/skills/nvcf-azure-deploy/SKILL.md) — or locally [`tf-conventions`](../tf-conventions/SKILL.md)).

GPU SKU recommendations (validate quota per region; quota requests take 24–72h):

| Use case | SKU | GPU |
|---|---|---|
| Validation (easy quota) | `Standard_NV36ads_A10_v5` | 1× A10 |
| L40S parity | `Standard_NV18ads_L40S_v3` | 1× L40S |
| H100 prod-intent | `Standard_NC40ads_H100_v5` | 1× H100 |

## Inputs

Source from `streaming-env.sh` + `generated/.env.iam-vpc` + `generated/.env.aks-cluster`.

**Required:**

| Variable | Description |
|---|---|
| `AZURE_SUBSCRIPTION_ID` | Subscription |
| `RESOURCE_GROUP` | RG |
| `CLUSTER_NAME` | Existing AKS cluster |
| `NODE_SUBNET_ID` | from `.env.iam-vpc` |

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `GPU_POOL_NAME` | GPU pool name (1–12 chars, lowercase, alphanumeric only — NO hyphens; this is an AKS constraint, not project naming) | `gpu` |
| `GPU_VM_SIZE` | GPU SKU | `Standard_NV36ads_A10_v5` |
| `GPU_NODE_COUNT` | Initial GPU nodes (autoscaler floor) | `0` |
| `GPU_MIN_COUNT` | Autoscale floor | `0` |
| `GPU_MAX_COUNT` | Autoscale ceiling | `2` |
| `GPU_ZONES` | Single zone for the GPU pool | `1` |
| `GPU_NODE_TAINTS` | Comma-separated taints. **Empty by default** — the GPU pool is reserved via the `nvidia.com/gpu=true` label alone, matching the AWS foundation (`aws-infra` uses labels, no taint). A `sku=gpu:NoSchedule` taint blocks NVCF function pods (no matching toleration) → NVCA reports `capacity: 0` → `function deploy` 400s. Only set this if you intend to wire matching tolerations onto every GPU workload. | _(empty)_ |
| `GPU_DRIVER_INSTALL` | `enabled` (AKS installs driver) or `disabled` (GPU operator owns the driver lifecycle) — see "GPU driver source" below | `enabled` |
| `ENABLE_COMPUTE_POOL` | Create the compute pool? | `false` |
| `COMPUTE_POOL_NAME` | Compute pool name (same naming constraint as GPU) | `compute` |
| `COMPUTE_VM_SIZE` | Compute SKU | `Standard_D8ds_v5` |
| `COMPUTE_MIN_COUNT` | Autoscale floor | `1` |
| `COMPUTE_MAX_COUNT` | Autoscale ceiling | `1` |
| `COMPUTE_ZONES` | Compute zone(s) (single-zone to match LLS LB) | `1` |
| `COMPUTE_NODE_LABELS` | Pool labels | `node-type=compute` |
| `OUTPUT_FORMAT` | `bash` or `terraform` | `bash` |
| `OVDC_REPLICAS` | OVDC replicas the compute pool must host | `0` |
| `OVDC_MEMORY_REQUEST_GIB` | Rendered OVDC pod request rounded up to GiB; required when replicas are nonzero | _(unset)_ |
| `OVDC_PLATFORM_RESERVE_GIB` | Allocatable-memory headroom per OVDC node | `8` |

## OVDC compute capacity contract

When `OVDC_REPLICAS > 0`:

1. Require `OVDC_MEMORY_REQUEST_GIB` to be a positive integer and force
   `ENABLE_COMPUTE_POOL=true`.
2. Require `COMPUTE_MIN_COUNT >= OVDC_REPLICAS`. OVDC uses hard pod
   anti-affinity, so every replica needs a distinct eligible node.
3. Query the selected SKU with `az vm list-sizes` and require its physical
   memory to be greater than
   `OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB`. This is a planning
   preflight only; kubelet and operating-system reservations mean Stage 07's
   Kubernetes allocatable-memory check is authoritative.
4. Keep `node-type=compute` on the pool. Do not satisfy an undersized compute
   pool by placing OVDC on a GPU node.

With the default 8 GiB reserve, a 16 GiB request can start with a 32 GiB class,
a 32 GiB request needs at least a 64 GiB class, and a 56 GiB request should use
a 128 GiB class because a nominal 64 GiB node will not retain 64 GiB of
allocatable memory.

## Outputs

- **Bash:** `generated/stage03-<cluster-name>-aks-nodes.sh` — idempotent (`az aks nodepool add` errors on exists; the script checks first).
- **Terraform:** `generated/<cluster-name>/aks-nodes/main.tf` containing `azurerm_kubernetes_cluster_node_pool` resources.

## GPU driver source — pick one

AKS NV/NC SKUs pre-install the NVIDIA driver. The GPU Operator (from the `gpu-operator` skill) also wants to install one. Pick exactly one source:

| `GPU_DRIVER_INSTALL` | What happens | When to use |
|---|---|---|
| `enabled` (default) | AKS installs the driver. GPU Operator runs with `driver.enabled=false`. | Validation; smallest blast radius. |
| `disabled` | Pass `--skip-gpu-driver-install` (Azure CLI flag; not in AVM resource module today — needs `azapi` patch or post-create `az aks nodepool update`). GPU Operator owns driver lifecycle with `driver.enabled=true`. | Production when NVCF runtime requires operator-managed drivers. |

For default validation, leave at `enabled`.

## Bash snippet (reference)

```bash
#!/bin/bash
set -euo pipefail

# Resolve repo root from script location — works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/streaming-env.sh"
for envfile in .env.iam-vpc .env.aks-cluster; do
  if [[ ! -f "$REPO_ROOT/generated/$envfile" ]]; then
    echo "ERROR: $REPO_ROOT/generated/$envfile not found. Run earlier stages first." >&2
    exit 1
  fi
  source "$REPO_ROOT/generated/$envfile"
done

: "${CLUSTER_NAME:?}" "${RESOURCE_GROUP:?}" "${NODE_SUBNET_ID:?}"
GPU_POOL_NAME="${GPU_POOL_NAME:-gpu}"
GPU_VM_SIZE="${GPU_VM_SIZE:-Standard_NV36ads_A10_v5}"
GPU_NODE_COUNT="${GPU_NODE_COUNT:-0}"
GPU_MIN_COUNT="${GPU_MIN_COUNT:-0}"
GPU_MAX_COUNT="${GPU_MAX_COUNT:-2}"
GPU_ZONES="${GPU_ZONES:-1}"
GPU_NODE_TAINTS="${GPU_NODE_TAINTS:-}"   # empty = no taint (AWS-parity); label-only GPU-pool reservation
GPU_DRIVER_INSTALL="${GPU_DRIVER_INSTALL:-enabled}"
ENABLE_COMPUTE_POOL="${ENABLE_COMPUTE_POOL:-false}"
OVDC_REPLICAS="${OVDC_REPLICAS:-0}"
OVDC_PLATFORM_RESERVE_GIB="${OVDC_PLATFORM_RESERVE_GIB:-8}"

if ! [[ "$OVDC_REPLICAS" =~ ^[0-9]+$ ]] || \
   ! [[ "$OVDC_PLATFORM_RESERVE_GIB" =~ ^[0-9]+$ ]]; then
  echo "ERROR: OVDC_REPLICAS and OVDC_PLATFORM_RESERVE_GIB must be non-negative integers" >&2
  exit 1
fi
if [[ "$OVDC_REPLICAS" -gt 0 ]]; then
  if ! [[ "${OVDC_MEMORY_REQUEST_GIB:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: OVDC_MEMORY_REQUEST_GIB must be a positive integer when OVDC_REPLICAS>0" >&2
    exit 1
  fi
  ENABLE_COMPUTE_POOL=true
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# Quota preflight — surface failures BEFORE the slow nodepool add.
# Derive a 2-char UPPERCASE prefix from the SKU family (e.g. Standard_NV36ads_A10_v5 → "NV")
# because `az vm list-usage` returns uppercase quota names.
echo "--- Quota check for $GPU_VM_SIZE in $LOCATION ---"
SKU_PREFIX=$(echo "$GPU_VM_SIZE" | awk -F_ '{print toupper(substr($2,1,2))}')
az vm list-usage --location "$LOCATION" \
  --query "[?contains(name.value, '$SKU_PREFIX')].{name:name.localizedValue, limit:limit, current:currentValue}" \
  -o table || echo "WARN: quota lookup failed; proceeding anyway"

# GPU pool — idempotent add
if az aks nodepool show --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$GPU_POOL_NAME" &>/dev/null; then
  echo "GPU pool $GPU_POOL_NAME already exists; skipping add"
else
  DRIVER_FLAG=""
  if [[ "$GPU_DRIVER_INSTALL" == "disabled" ]]; then
    DRIVER_FLAG="--skip-gpu-driver-install"
  fi
  # Taint is opt-in and empty by default (AWS-parity). Only pass --node-taints when set,
  # otherwise the pool is reserved by the nvidia.com/gpu=true label alone.
  TAINT_FLAG=""
  if [[ -n "$GPU_NODE_TAINTS" ]]; then
    TAINT_FLAG="--node-taints $GPU_NODE_TAINTS"
  fi
  echo "--- Adding GPU node pool $GPU_POOL_NAME ($GPU_VM_SIZE, zone $GPU_ZONES) ---"
  az aks nodepool add \
    --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
    --name "$GPU_POOL_NAME" --node-vm-size "$GPU_VM_SIZE" \
    --node-count "$GPU_NODE_COUNT" \
    --enable-cluster-autoscaler --min-count "$GPU_MIN_COUNT" --max-count "$GPU_MAX_COUNT" \
    --zones $GPU_ZONES \
    $TAINT_FLAG \
    --labels nvidia.com/gpu=true \
    --vnet-subnet-id "$NODE_SUBNET_ID" \
    $DRIVER_FLAG \
    --only-show-errors
fi

# Optional compute pool
if [[ "$ENABLE_COMPUTE_POOL" == "true" ]]; then
  COMPUTE_POOL_NAME="${COMPUTE_POOL_NAME:-compute}"
  COMPUTE_VM_SIZE="${COMPUTE_VM_SIZE:-Standard_D8ds_v5}"
  COMPUTE_MIN_COUNT="${COMPUTE_MIN_COUNT:-1}"
  COMPUTE_MAX_COUNT="${COMPUTE_MAX_COUNT:-1}"
  if [[ "$OVDC_REPLICAS" -gt 0 ]]; then
    if [[ "$COMPUTE_MIN_COUNT" -lt "$OVDC_REPLICAS" ]]; then
      echo "ERROR: COMPUTE_MIN_COUNT=$COMPUTE_MIN_COUNT must be >= OVDC_REPLICAS=$OVDC_REPLICAS" >&2
      exit 1
    fi
    REQUIRED_MEMORY_MIB=$(( (OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB) * 1024 ))
    SKU_MEMORY_MIB="$(az vm list-sizes --location "$LOCATION" \
      --query "[?name=='${COMPUTE_VM_SIZE}'].memoryInMb | [0]" -o tsv 2>/dev/null || true)"
    if ! [[ "$SKU_MEMORY_MIB" =~ ^[0-9]+$ ]]; then
      echo "ERROR: could not determine memory for compute SKU $COMPUTE_VM_SIZE in $LOCATION" >&2
      exit 1
    fi
    if [[ "$SKU_MEMORY_MIB" -le "$REQUIRED_MEMORY_MIB" ]]; then
      echo "ERROR: $COMPUTE_VM_SIZE has ${SKU_MEMORY_MIB} MiB; OVDC requires more than ${REQUIRED_MEMORY_MIB} MiB physical memory for request plus reserve" >&2
      exit 1
    fi
  fi
  if az aks nodepool show --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$COMPUTE_POOL_NAME" &>/dev/null; then
    echo "Compute pool $COMPUTE_POOL_NAME already exists; skipping add"
  else
    echo "--- Adding compute node pool $COMPUTE_POOL_NAME ---"
    az aks nodepool add \
      --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
      --name "$COMPUTE_POOL_NAME" \
      --node-vm-size "$COMPUTE_VM_SIZE" \
      --node-count "$COMPUTE_MIN_COUNT" \
      --enable-cluster-autoscaler --min-count "$COMPUTE_MIN_COUNT" --max-count "$COMPUTE_MAX_COUNT" \
      --zones "${COMPUTE_ZONES:-1}" \
      --labels "${COMPUTE_NODE_LABELS:-node-type=compute}" \
      --vnet-subnet-id "$NODE_SUBNET_ID" \
      --only-show-errors
  fi
fi

kubectl get nodes -o wide
```

## Terraform snippet (reference)

```hcl
terraform {
  required_version = ">= 1.11"   # one azurerm 4.x line with aks-cluster (AVM 0.5.4)

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"   # auto_scaling_enabled below is the 4.x argument name
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  name                  = var.gpu_pool_name
  kubernetes_cluster_id = var.cluster_id
  vm_size               = var.gpu_vm_size
  node_count            = var.gpu_node_count
  auto_scaling_enabled  = true
  min_count             = var.gpu_min_count
  max_count             = var.gpu_max_count
  zones                 = var.gpu_zones
  vnet_subnet_id        = var.node_subnet_id
  node_labels           = { "nvidia.com/gpu" = "true" }
  # No taint by default — label-only reservation, matching the AWS foundation.
  # A sku=gpu:NoSchedule taint blocks NVCF function pods (no matching toleration) → capacity:0.
  # Set node_taints only if you also wire matching tolerations onto every GPU workload.
  node_taints           = var.gpu_node_taints   # declare with default [] in your variables.tf

  # GPU_DRIVER_INSTALL = "disabled" needs an azapi resource (not exposed by azurerm today):
  #   resource "azapi_update_resource" "skip_driver" {
  #     type        = "Microsoft.ContainerService/managedClusters/agentPools@2024-02-01"
  #     resource_id = azurerm_kubernetes_cluster_node_pool.gpu.id
  #     body = jsonencode({ properties = { gpuProfile = { installGPUDriver = false } } })
  #   }
}

resource "azurerm_kubernetes_cluster_node_pool" "compute" {
  count = var.enable_compute_pool ? 1 : 0

  name                  = var.compute_pool_name
  kubernetes_cluster_id = var.cluster_id
  vm_size               = var.compute_vm_size
  auto_scaling_enabled  = true
  min_count             = var.compute_min_count
  max_count             = var.compute_max_count
  zones                 = var.compute_zones
  vnet_subnet_id        = var.node_subnet_id
  node_labels           = { "node-type" = "compute" }
}
```

## Teardown

```bash
az aks nodepool delete --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$GPU_POOL_NAME" --no-wait
az aks nodepool delete --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$COMPUTE_POOL_NAME" --no-wait
```

## Validation checklist

- [ ] GPU pool name is 1–12 chars, lowercase alphanumeric (no hyphens) — AKS hard constraint
- [ ] Quota preflight runs before nodepool add (skippable but should print a warning, not silently bypass)
- [ ] Quota query uses an **uppercase** SKU prefix (e.g. `NV`, `NC`) — `az vm list-usage` returns uppercase quota names; lowercase prefix never matches
- [ ] GPU pool is single-zone if LLS will be deployed
- [ ] `nvidia.com/gpu=true` label is set on the GPU pool
- [ ] GPU pool has **no taint** by default (label-only reservation, matching the AWS foundation). A taint is opt-in via `GPU_NODE_TAINTS` and must be paired with matching workload tolerations — otherwise NVCF function pods can't schedule (NVCA `capacity: 0`)
- [ ] `GPU_DRIVER_INSTALL=disabled` path uses `--skip-gpu-driver-install` (and a TF azapi snippet is provided as a comment)
- [ ] Compute pool is gated by `ENABLE_COMPUTE_POOL=true`
- [ ] `OVDC_REPLICAS > 0` forces the compute pool on, requires at least one
      distinct compute node per replica, and rejects a compute SKU whose
      published memory cannot exceed request plus reserve
- [ ] OVDC uses only `node-type=compute`; Stage 07 validates live allocatable
      memory and never counts GPU nodes as OVDC capacity
- [ ] Both pools attach to `NODE_SUBNET_ID` from `iam-vpc`
- [ ] Idempotent (check before add)
- [ ] `--teardown` removes both pools

## References

| Topic | Source |
|---|---|
| AKS GPU node pools | https://learn.microsoft.com/azure/aks/gpu-cluster |
| `--skip-gpu-driver-install` | https://learn.microsoft.com/azure/aks/gpu-cluster#skip-gpu-driver-installation |
| GPU SKU families | https://learn.microsoft.com/azure/virtual-machines/sizes-gpu |
| Quota requests | https://learn.microsoft.com/azure/quotas/regional-quota-requests |
