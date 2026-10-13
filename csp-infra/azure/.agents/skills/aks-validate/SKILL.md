---
name: aks-validate
description: Generates a read-only validation script that confirms an AKS cluster bootstrapped via iam-vpc → aks-cluster → aks-nodes → acr → blob-storage → gpu-operator is healthy end-to-end. Checks RG, VNet, AKS provisioning state, node pool composition, ACR + AcrPull role, Storage + Blob Data Contributor role, GPU operator pods, GPU resource advertisement, a CUDA smoke pod, and a Blob auth probe. Emits PASS/WARN/FAIL plus a JSON report. Emitted as Stage 07 by `aks-bootstrap`; can be run standalone after the stack is up. Trigger when the user mentions "validate the cluster", "is the cluster ready", "smoke test the bootstrap", "kick the tires", or after any stack change.
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AKS bootstrap validation

## What this skill produces

A read-only bash script that runs ~10 checks against the live stack and emits:

- Stdout: per-check `PASS`, `WARN`, `FAIL` lines + summary.
- `generated/stage07-<cluster-name>-validate-report.json` — machine-readable report.
- Exit code: `0` if all checks PASS (WARN is non-fatal), `1` if any FAIL, `2` if preflight failed (missing tool, cluster unreachable).

This is the "cluster is ready" gate. Tolerant in orchestrator mode (see `aks-bootstrap`).

## Inputs

Source from `streaming-env.sh` and any `.env.*` files written by upstream stages.

**Required:**

| Variable | Description |
|---|---|
| `CLUSTER_NAME` | Name |
| `RESOURCE_GROUP` | RG |
| `AZURE_SUBSCRIPTION_ID` | Subscription |

**Optional (passed through from upstream stages for observed-vs-expected checks):**

| Variable | Description | Default |
|---|---|---|
| `GPU_POOL_NAME`, `GPU_VM_SIZE`, `GPU_MIN_COUNT`, `GPU_MAX_COUNT` | from `aks-nodes` | (unset) |
| `ACR_NAME`, `KUBELET_IDENTITY_OBJECT_ID` | from `acr`/`aks-cluster` | (unset) |
| `STORAGE_ACCOUNT_NAME` | from `blob-storage` | (unset) |
| `BLOB_PROBE_NAMESPACE` | Namespace containing the workload identity service account | `default` |
| `BLOB_PROBE_SERVICE_ACCOUNT` | K8s ServiceAccount bound to a workload identity with Blob access | (unset; skips probe with WARN) |
| `BLOB_PROBE_IMAGE` | Azure CLI image used for the in-cluster Blob auth probe | `mcr.microsoft.com/azure-cli:2.61.0` |
| `SKIP_CUDA` | Skip the CUDA smoke pod | `false` |
| `SKIP_BLOB_PROBE` | Skip the Blob auth probe | `false` |
| `TIMEOUT_MIN` | Per-check timeout cap | `5` |
| `OVDC_REPLICAS` | Number of OVDC replicas the CPU compute pool must host | `0` |
| `OVDC_MEMORY_REQUEST_GIB` | Rendered pod request rounded up to GiB; required when replicas are nonzero | _(unset)_ |
| `OVDC_PLATFORM_RESERVE_GIB` | Additional allocatable-memory headroom per eligible compute node | `8` |

## Output

`generated/stage07-<cluster-name>-validate.sh` and at runtime, `generated/stage07-<cluster-name>-validate-report.json`.

JSON shape:

```json
{
  "cluster": "aks-nvcf-validation-westus3",
  "timestamp": "2026-05-27T12:34:56Z",
  "summary": { "pass": 8, "warn": 1, "fail": 0 },
  "checks": [
    { "id": "rg",          "status": "PASS", "detail": "RG exists in westus3" },
    { "id": "vnet",        "status": "PASS", "detail": "VNet 10.10.0.0/16; subnets: snet-aks-nodes, snet-aks-api-server" },
    { "id": "aks",         "status": "PASS", "detail": "Succeeded; v1.30.2" },
    { "id": "nodes",       "status": "PASS", "detail": "system=1, gpu=1 (Standard_NV36ads_A10_v5, zone 1)" },
    { "id": "platform-capacity", "status": "PASS", "detail": "OVDC replicas=1; eligible compute nodes=1; required allocatable memory per node=64 GiB" },
    { "id": "acr-pull",    "status": "PASS", "detail": "AcrPull granted to kubelet identity" },
    { "id": "blob-rbac",   "status": "PASS", "detail": "Storage Blob Data Contributor on grantee" },
    { "id": "gpu-op",      "status": "PASS", "detail": "9/9 pods Ready; chart v25.3.0" },
    { "id": "gpu-resource","status": "PASS", "detail": "1 node advertises nvidia.com/gpu=1" },
    { "id": "cuda-smoke",  "status": "PASS", "detail": "nvidia-smi pod returned 0; A10 detected" },
    { "id": "blob-probe",  "status": "WARN", "detail": "Skipped (no STORAGE_ACCOUNT_NAME)" }
  ]
}
```

## Checks

| ID | What it verifies | Severity if fail |
|---|---|---|
| `rg` | RG exists in the expected region | FAIL |
| `vnet` | VNet exists; node + API-server subnets present | FAIL |
| `aks` | `provisioningState=Succeeded`; OIDC issuer URL non-empty; workload identity enabled | FAIL |
| `nodes` | Expected pools present; `node-vm-size` matches `aks-nodes` inputs; GPU pool zone matches | FAIL |
| `platform-capacity` | One distinct Ready, non-GPU `node-type=compute` node per OVDC replica with request plus reserve in allocatable memory | FAIL when requested; WARN when not requested |
| `acr-pull` | `AcrPull` role assignment exists on the ACR scope to the kubelet identity | FAIL |
| `blob-rbac` | `Storage Blob Data Contributor` on the storage account scope to the grantee | WARN if grantee/account unset |
| `gpu-op` | GPU operator pods all Ready; chart version matches `GPU_OPERATOR_VERSION` if set | FAIL |
| `gpu-resource` | At least one node advertises `nvidia.com/gpu` >= 1 | FAIL |
| `cuda-smoke` | Pod with `nvcr.io/nvidia/cuda:...` requesting 1 GPU runs `nvidia-smi`, exits 0; pod is cleaned up | FAIL unless `SKIP_CUDA=true` |
| `blob-probe` | (Optional) From a pod using `BLOB_PROBE_SERVICE_ACCOUNT`, `az storage blob list --auth-mode login` succeeds | WARN if `SKIP_BLOB_PROBE=true`, storage account unset, or service account unset |

Each check has a per-check timeout (default 60s; cuda-smoke up to 5min).

## Bash script (complete)

```bash
#!/bin/bash
set -uo pipefail   # NOT -e — we want to collect all check results, not bail on the first fail

# Resolve repo root from script location — works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/streaming-env.sh"
for envfile in .env.iam-vpc .env.aks-cluster .env.acr .env.blob-storage; do
  [[ -f "$REPO_ROOT/generated/$envfile" ]] && source "$REPO_ROOT/generated/$envfile"
done

: "${CLUSTER_NAME:?}" "${RESOURCE_GROUP:?}" "${AZURE_SUBSCRIPTION_ID:?}"
export KUBECONFIG="${KUBECONFIG:-/tmp/kubeconfig-${CLUSTER_NAME}}"
SKIP_CUDA="${SKIP_CUDA:-false}"
SKIP_BLOB_PROBE="${SKIP_BLOB_PROBE:-false}"
TIMEOUT_MIN="${TIMEOUT_MIN:-5}"
OVDC_REPLICAS="${OVDC_REPLICAS:-0}"
OVDC_PLATFORM_RESERVE_GIB="${OVDC_PLATFORM_RESERVE_GIB:-8}"

mkdir -p "$REPO_ROOT/generated"
REPORT="$REPO_ROOT/generated/stage07-${CLUSTER_NAME}-validate-report.json"
declare -a CHECKS
PASS=0; WARN=0; FAIL=0

record() {
  local id="$1" status="$2" detail="$3"
  CHECKS+=("$(printf '{"id":"%s","status":"%s","detail":"%s"}' "$id" "$status" "$(echo "$detail" | sed 's/"/\\"/g')")")
  case "$status" in PASS) ((PASS++));; WARN) ((WARN++));; FAIL) ((FAIL++));; esac
  printf "[%s] %s — %s\n" "$status" "$id" "$detail"
}

# Preflight
for tool in az kubectl jq; do
  command -v "$tool" >/dev/null || { echo "MISSING TOOL: $tool"; exit 2; }
done
az account show >/dev/null 2>&1 || { echo "az not authenticated"; exit 2; }
kubectl cluster-info >/dev/null 2>&1 || {
  echo "kubectl can't reach cluster $CLUSTER_NAME — fetch a kubeconfig first:"
  echo "  az aks get-credentials -g \$RESOURCE_GROUP -n $CLUSTER_NAME && kubelogin convert-kubeconfig -l azurecli"
  exit 2; }
# Azure-RBAC gate: aks-cluster runs with disable_local_accounts=true, so cluster-info can
# succeed (API discovery) while every real call returns 403 Forbidden because the caller has
# no cluster role assignment. Detect that here and fail with remediation, instead of letting
# the gpu-op / gpu-resource / cuda-smoke checks below mis-report it as a broken GPU stack.
RBAC_PROBE=$(kubectl get nodes 2>&1 >/dev/null) || true
if printf '%s' "$RBAC_PROBE" | grep -qiE 'Forbidden|does not have access to the resource'; then
  echo "Azure RBAC: this identity has NO cluster role assignment — kubectl is Forbidden, not broken."
  echo "  aks-cluster grants this automatically for ADMIN_AAD_OBJECT_IDS (see tf-conventions R7)."
  echo "  To grant an additional identity:"
  echo "    CID=\$(az aks show -g \$RESOURCE_GROUP -n $CLUSTER_NAME --query id -o tsv)"
  echo "    az role assignment create --assignee <obj-id> --role 'Azure Kubernetes Service Cluster User Role' --scope \"\$CID\""
  echo "    az role assignment create --assignee <obj-id> --role 'Azure Kubernetes Service RBAC Cluster Admin' --scope \"\$CID\""
  exit 2
fi

# --- check: rg ---
LOC=$(az group show -n "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || echo "")
if [[ -n "$LOC" ]]; then record rg PASS "RG exists in $LOC"; else record rg FAIL "RG $RESOURCE_GROUP not found"; fi

# --- check: vnet ---
VNET_NAME="${VNET_NAME:-}"
NODE_SUBNET_NAME="${NODE_SUBNET_NAME:-snet-aks-nodes}"
API_SERVER_SUBNET_NAME="${API_SERVER_SUBNET_NAME:-snet-aks-api-server}"
if [[ -z "$VNET_NAME" ]]; then
  record vnet WARN "VNET_NAME unset; skipping VNet check"
else
  VNET_EXISTS=$(az network vnet show -n "$VNET_NAME" -g "$RESOURCE_GROUP" --query addressSpace.addressPrefixes[0] -o tsv 2>/dev/null || echo "")
  if [[ -z "$VNET_EXISTS" ]]; then
    record vnet FAIL "VNet $VNET_NAME not found in $RESOURCE_GROUP"
  else
    SUBNETS=$(az network vnet subnet list --vnet-name "$VNET_NAME" -g "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || echo "")
    MISSING=""
    [[ "$SUBNETS" != *"$NODE_SUBNET_NAME"* ]] && MISSING="$NODE_SUBNET_NAME"
    [[ "$SUBNETS" != *"$API_SERVER_SUBNET_NAME"* ]] && MISSING="${MISSING:+$MISSING, }$API_SERVER_SUBNET_NAME"
    if [[ -n "$MISSING" ]]; then
      record vnet FAIL "VNet $VNET_NAME exists ($VNET_EXISTS) but missing subnets: $MISSING"
    else
      record vnet PASS "VNet $VNET_NAME ($VNET_EXISTS); subnets: $NODE_SUBNET_NAME, $API_SERVER_SUBNET_NAME"
    fi
  fi
fi

# --- check: aks ---
STATE=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query provisioningState -o tsv 2>/dev/null || echo "")
OIDC=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query oidcIssuerProfile.issuerUrl -o tsv 2>/dev/null || echo "")
WI=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query securityProfile.workloadIdentity.enabled -o tsv 2>/dev/null || echo "")
K8S_VER=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query currentKubernetesVersion -o tsv 2>/dev/null || echo "")
if [[ "$STATE" == "Succeeded" && -n "$OIDC" && "$WI" == "true" ]]; then
  record aks PASS "Succeeded; v${K8S_VER}; OIDC + workload identity enabled"
else
  record aks FAIL "state=$STATE oidc=${OIDC:-unset} wi=${WI:-unset}"
fi

# --- check: nodes ---
GPU_POOL_NAME="${GPU_POOL_NAME:-}"
GPU_VM_SIZE="${GPU_VM_SIZE:-}"
GPU_POOL_ZONE="${GPU_POOL_ZONE:-}"
POOL_JSON=$(az aks nodepool list -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" -o json 2>/dev/null || echo "[]")
SYSTEM_COUNT=$(echo "$POOL_JSON" | jq '[.[] | select(.mode=="System")] | length')
GPU_COUNT=$(echo "$POOL_JSON" | jq --arg n "${GPU_POOL_NAME:-gpu}" '[.[] | select(.name==$n or .mode=="User")] | length')
if [[ "$SYSTEM_COUNT" -eq 0 ]]; then
  record nodes FAIL "No system node pool found"
elif [[ "$GPU_COUNT" -eq 0 ]]; then
  record nodes FAIL "No user/GPU node pool found (expected name=${GPU_POOL_NAME:-gpu})"
else
  DETAIL="system=${SYSTEM_COUNT}, gpu=${GPU_COUNT}"
  NODE_STATUS="PASS"
  if [[ -n "$GPU_POOL_NAME" && -n "$GPU_VM_SIZE" ]]; then
    ACTUAL_SIZE=$(echo "$POOL_JSON" | jq -r --arg n "$GPU_POOL_NAME" '.[] | select(.name==$n) | .vmSize // ""')
    if [[ -n "$ACTUAL_SIZE" && "$ACTUAL_SIZE" != "$GPU_VM_SIZE" ]]; then
      DETAIL="$DETAIL; vm-size mismatch: expected=$GPU_VM_SIZE actual=$ACTUAL_SIZE"
      NODE_STATUS="FAIL"
    else
      DETAIL="$DETAIL; vm-size=$ACTUAL_SIZE"
    fi
  fi
  if [[ -n "$GPU_POOL_NAME" && -n "$GPU_POOL_ZONE" ]]; then
    ACTUAL_ZONES=$(echo "$POOL_JSON" | jq -r --arg n "$GPU_POOL_NAME" '.[] | select(.name==$n) | (.availabilityZones // []) | join(",")')
    DETAIL="$DETAIL; zone=${ACTUAL_ZONES:-unset}"
  fi
  record nodes "$NODE_STATUS" "$DETAIL"
fi

# --- check: platform-capacity ---
NODES_JSON="$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')"
if ! [[ "$OVDC_REPLICAS" =~ ^[0-9]+$ ]] || \
   ! [[ "$OVDC_PLATFORM_RESERVE_GIB" =~ ^[0-9]+$ ]]; then
  record platform-capacity FAIL "OVDC_REPLICAS and OVDC_PLATFORM_RESERVE_GIB must be non-negative integers"
elif [[ "$OVDC_REPLICAS" -eq 0 ]]; then
  record platform-capacity WARN "not requested (OVDC_REPLICAS=0)"
elif ! [[ "${OVDC_MEMORY_REQUEST_GIB:-}" =~ ^[1-9][0-9]*$ ]]; then
  record platform-capacity FAIL "OVDC_MEMORY_REQUEST_GIB must be a positive integer when OVDC_REPLICAS>0"
else
  REQUIRED_MIB=$(( (OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB) * 1024 ))
  ELIGIBLE_COMPUTE_NODES="$(echo "$NODES_JSON" | jq --argjson required "$REQUIRED_MIB" '
    def mem_mib:
      if test("Ki$") then (rtrimstr("Ki") | tonumber / 1024)
      elif test("Mi$") then (rtrimstr("Mi") | tonumber)
      elif test("Gi$") then (rtrimstr("Gi") | tonumber * 1024)
      elif test("K$") then (rtrimstr("K") | tonumber * 1000 / 1048576)
      elif test("M$") then (rtrimstr("M") | tonumber * 1000000 / 1048576)
      elif test("G$") then (rtrimstr("G") | tonumber * 1000000000 / 1048576)
      else (tonumber / 1048576) end;
    [.items[] |
      select(.metadata.labels["node-type"] == "compute") |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
      select(((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber) == 0) |
      select((.status.allocatable.memory | mem_mib) >= $required)
    ] | length')"
  REQUIRED_GIB=$((OVDC_MEMORY_REQUEST_GIB + OVDC_PLATFORM_RESERVE_GIB))
  if [[ "$ELIGIBLE_COMPUTE_NODES" -ge "$OVDC_REPLICAS" ]]; then
    record platform-capacity PASS "OVDC replicas=${OVDC_REPLICAS}; eligible compute nodes=${ELIGIBLE_COMPUTE_NODES}; required allocatable memory per node=${REQUIRED_GIB} GiB"
  else
    record platform-capacity FAIL "OVDC replicas=${OVDC_REPLICAS}; eligible compute nodes=${ELIGIBLE_COMPUTE_NODES}; need ${OVDC_REPLICAS} Ready non-GPU node-type=compute nodes with at least ${REQUIRED_GIB} GiB allocatable each"
  fi
fi

# --- check: acr-pull ---
if [[ -z "${ACR_NAME:-}" || -z "${KUBELET_IDENTITY_OBJECT_ID:-}" ]]; then
  record acr-pull WARN "ACR_NAME or KUBELET_IDENTITY_OBJECT_ID unset; skipping AcrPull check"
else
  ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null || echo "")
  if [[ -z "$ACR_ID" ]]; then
    record acr-pull FAIL "ACR $ACR_NAME not found in $RESOURCE_GROUP"
  else
    ROLE_COUNT=$(az role assignment list --scope "$ACR_ID" \
      --query "[?principalId=='${KUBELET_IDENTITY_OBJECT_ID}' && roleDefinitionName=='AcrPull'] | length(@)" \
      -o tsv 2>/dev/null || echo "0")
    if [[ "${ROLE_COUNT:-0}" -gt 0 ]]; then
      record acr-pull PASS "AcrPull granted to kubelet identity on $ACR_NAME"
    else
      record acr-pull FAIL "AcrPull not found on $ACR_NAME for kubelet identity $KUBELET_IDENTITY_OBJECT_ID"
    fi
  fi
fi

# --- check: blob-rbac ---
if [[ -z "${STORAGE_ACCOUNT_NAME:-}" ]]; then
  record blob-rbac WARN "STORAGE_ACCOUNT_NAME unset; skipping Blob RBAC check"
else
  SA_ID=$(az storage account show -n "$STORAGE_ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null || echo "")
  if [[ -z "$SA_ID" ]]; then
    record blob-rbac FAIL "Storage account $STORAGE_ACCOUNT_NAME not found"
  else
    BLOB_ROLE_COUNT=$(az role assignment list --scope "$SA_ID" \
      --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" \
      -o tsv 2>/dev/null || echo "0")
    if [[ "${BLOB_ROLE_COUNT:-0}" -gt 0 ]]; then
      record blob-rbac PASS "Storage Blob Data Contributor assigned on $STORAGE_ACCOUNT_NAME"
    else
      record blob-rbac FAIL "Storage Blob Data Contributor not found on $STORAGE_ACCOUNT_NAME"
    fi
  fi
fi

# --- check: gpu-op ---
GPU_OP_NS="gpu-operator"
GPU_OP_TIMEOUT="${TIMEOUT_MIN}m"
PODS_JSON=$(kubectl get pods -n "$GPU_OP_NS" -o json 2>/dev/null || echo '{"items":[]}')
TOTAL=$(echo "$PODS_JSON" | jq '.items | length')
if [[ "$TOTAL" -eq 0 ]]; then
  record gpu-op FAIL "No pods found in namespace $GPU_OP_NS"
else
  NOT_READY=$(echo "$PODS_JSON" | jq '[.items[] | select(.status.phase != "Succeeded") | select(((.status.conditions // []) | map(select(.type=="Ready" and .status=="True")) | length) == 0)] | length')
  # gpu-operator is installed via plain `helm install` (not Flux), so read the chart version
  # from helm, not a Flux `helmrelease` CRD (which doesn't exist on this path). Best-effort.
  CHART_VER=""
  if command -v helm >/dev/null 2>&1; then
    CHART_VER=$(helm list -n "$GPU_OP_NS" -o json 2>/dev/null \
      | jq -r '(.[] | select(.name=="gpu-operator").chart) // ""' | sed -E 's/^gpu-operator-//')
  fi
  DETAIL="${TOTAL} pods; ready-condition-missing=${NOT_READY}${CHART_VER:+; chart=$CHART_VER}"
  if [[ "$NOT_READY" -eq 0 ]]; then
    record gpu-op PASS "$DETAIL"
  else
    record gpu-op FAIL "$DETAIL"
  fi
fi

# --- check: gpu-resource ---
GPU_NODE_COUNT=$(kubectl get nodes -o json 2>/dev/null \
  | jq '[.items[] | select((.status.capacity["nvidia.com/gpu"] // "0" | tonumber) >= 1)] | length')
if [[ "${GPU_NODE_COUNT:-0}" -gt 0 ]]; then
  record gpu-resource PASS "${GPU_NODE_COUNT} node(s) advertise nvidia.com/gpu >= 1"
else
  record gpu-resource FAIL "No nodes advertise nvidia.com/gpu (GPU operator may not be ready)"
fi

# --- check: cuda-smoke ---
if [[ "$SKIP_CUDA" == "true" ]]; then
  record cuda-smoke WARN "Skipped (SKIP_CUDA=true)"
else
  SMOKE_POD="validate-cuda-smoke-$$"
  CUDA_IMAGE="${CUDA_IMAGE:-nvcr.io/nvidia/cuda:12.4.0-base-ubuntu22.04}"
  GPU_TAINT_KEY="${GPU_TAINT_KEY:-nvidia.com/gpu}"
  # Ensure pod is deleted on every exit path from this check
  cleanup_smoke() { kubectl delete pod "$SMOKE_POD" --ignore-not-found >/dev/null 2>&1 || true; }
  trap cleanup_smoke EXIT
  # Schedule onto a GPU node via the resource limit alone (no node-type selector —
  # the GPU pool is labeled nvidia.com/gpu=true, never node-type=gpu). The toleration
  # is harmless when the pool has no taint (repo default) and works if GPU_NODE_TAINTS is set.
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: $SMOKE_POD, namespace: default }
spec:
  restartPolicy: Never
  tolerations:
    - { key: "$GPU_TAINT_KEY", operator: Exists, effect: NoSchedule }
  containers:
    - name: nvidia-smi
      image: $CUDA_IMAGE
      command: ["nvidia-smi"]
      resources: { limits: { nvidia.com/gpu: 1 } }
EOF
  if kubectl wait pod "$SMOKE_POD" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${TIMEOUT_MIN}m" >/dev/null 2>&1; then
    GPU_MODEL=$(kubectl logs "$SMOKE_POD" 2>/dev/null | grep -m1 "GPU" | sed 's/^[[:space:]]*//' || echo "unknown")
    record cuda-smoke PASS "nvidia-smi exited 0; ${GPU_MODEL}"
  else
    POD_PHASE=$(kubectl get pod "$SMOKE_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    record cuda-smoke FAIL "nvidia-smi pod did not complete (phase=$POD_PHASE)"
  fi
  cleanup_smoke
  trap - EXIT
fi

# --- check: blob-probe ---
if [[ "$SKIP_BLOB_PROBE" == "true" || -z "${STORAGE_ACCOUNT_NAME:-}" || -z "${BLOB_PROBE_SERVICE_ACCOUNT:-}" ]]; then
  record blob-probe WARN "Skipped (SKIP_BLOB_PROBE=${SKIP_BLOB_PROBE} STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME:-unset} BLOB_PROBE_SERVICE_ACCOUNT=${BLOB_PROBE_SERVICE_ACCOUNT:-unset})"
else
  BLOB_PROBE_NAMESPACE="${BLOB_PROBE_NAMESPACE:-default}"
  BLOB_PROBE_IMAGE="${BLOB_PROBE_IMAGE:-mcr.microsoft.com/azure-cli:2.61.0}"
  BLOB_CONTAINER="$(echo "${STORAGE_CONTAINERS:-scratch}" | cut -d, -f1)"
  BLOB_POD="validate-blob-probe-$$"
  cleanup_blob_probe() { kubectl delete pod "$BLOB_POD" -n "$BLOB_PROBE_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true; }
  trap cleanup_blob_probe EXIT
  kubectl run "$BLOB_POD" -n "$BLOB_PROBE_NAMESPACE" \
    --image="$BLOB_PROBE_IMAGE" \
    --restart=Never \
    --overrides="{\"spec\":{\"serviceAccountName\":\"${BLOB_PROBE_SERVICE_ACCOUNT}\"}}" \
    -- /bin/sh -lc "az storage blob list --account-name '${STORAGE_ACCOUNT_NAME}' --container-name '${BLOB_CONTAINER}' --auth-mode login --output none" >/dev/null 2>&1
  if kubectl wait pod "$BLOB_POD" -n "$BLOB_PROBE_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${TIMEOUT_MIN}m" >/dev/null 2>&1; then
    record blob-probe PASS "workload identity pod listed blobs in $STORAGE_ACCOUNT_NAME/$BLOB_CONTAINER using serviceAccount=$BLOB_PROBE_SERVICE_ACCOUNT"
  else
    POD_PHASE=$(kubectl get pod "$BLOB_POD" -n "$BLOB_PROBE_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    record blob-probe FAIL "workload identity Blob probe failed (phase=$POD_PHASE serviceAccount=$BLOB_PROBE_SERVICE_ACCOUNT) — check federated credential / RBAC"
  fi
  cleanup_blob_probe
  trap - EXIT
fi

# --- emit report ---
printf '{ "cluster":"%s","timestamp":"%s","summary":{"pass":%d,"warn":%d,"fail":%d},"checks":[%s] }\n' \
  "$CLUSTER_NAME" "$(date -u +%FT%TZ)" "$PASS" "$WARN" "$FAIL" \
  "$(IFS=,; echo "${CHECKS[*]}")" | jq . > "$REPORT"

echo
echo "=== Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL ==="
echo "Report: $REPORT"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
```

## Tolerant execution

When run from `aks-bootstrap` deploy mode, the orchestrator reports the exit code but does NOT treat exit 1 as a bootstrap failure — stages 01–06 have already succeeded. The validate stage is diagnostic, not constructive. See `aks-bootstrap` for the contract.

## Validation checklist (for the generator)

- [ ] Script uses `set -uo pipefail` (NOT `-e` — needs to keep collecting results past failures)
- [ ] Preflight exits with code 2 (not 1) if a tool is missing or cluster is unreachable, so the orchestrator can distinguish "ran but failed checks" from "couldn't run"
- [ ] Every check is wrapped to capture its own success/failure without aborting the script
- [ ] Platform-capacity check uses Kubernetes allocatable memory and counts only
      Ready, non-GPU `node-type=compute` nodes, one per OVDC replica
- [ ] GPU operator check inspects pod Ready conditions, not just pod phase
- [ ] CUDA smoke pod has the GPU pool toleration
- [ ] CUDA smoke waits for `phase=Succeeded` directly so short-lived `nvidia-smi` pods do not false-fail before becoming Ready
- [ ] CUDA smoke pod is deleted on every exit path (use trap or explicit cleanup at end of check)
- [ ] Blob probe runs inside the cluster using `BLOB_PROBE_SERVICE_ACCOUNT`, not the operator's local Azure login
- [ ] Report is written unconditionally on exit 0 and exit 1 (only exit 2 skips it)
- [ ] No persistent write/modify operations against cluster or Azure resources; temporary smoke/probe pods are cleaned up
- [ ] Per-check timeout — a hung Helm pod can't stall the whole validate
- [ ] `SKIP_CUDA` and `SKIP_BLOB_PROBE` flags work
- [ ] Summary line on stdout includes counts (consumed by `aks-bootstrap` in deploy mode)

## References

| Topic | Source |
|---|---|
| `az aks show` JSON shape | https://learn.microsoft.com/cli/azure/aks#az-aks-show |
| `kubectl get nodes -o json` | https://kubernetes.io/docs/reference/kubectl/jsonpath/ |
| GPU Operator readiness | https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html |
