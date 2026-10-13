---
name: gpu-operator
description: Generates a bash script that installs the NVIDIA GPU Operator on an existing AKS cluster via Helm, with AKS-specific values. Covers the two AKS-only gotchas the upstream docs don't surface — split NFD CRDs and the AKS-pre-installed driver. Use as Stage 06 of `aks-bootstrap`, after `aks-nodes`. Trigger when the user mentions "install GPU operator", "NVIDIA GPU operator", "DCGM", "nvidia-smi pod", or asks "how do I install the GPU operator on AKS".
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# NVIDIA GPU Operator on AKS

## What this skill produces

A bash script that, on an existing AKS cluster (a GPU node is **not** required up front — see Gotcha #3 on scheduling the control plane):

1. Applies the split CRD sets (top-level + NFD subchart — see Gotcha #1).
2. Installs the GPU operator via Helm with `--skip-crds` and AKS-specific values.
3. Verifies `nvidia.com/gpu` resource is advertised on the GPU node(s).
4. Optionally runs a CUDA `nvidia-smi` smoke pod.

## Prerequisite — Helm 3.x (Helm 4 not supported)

This skill installs via Helm and requires **Helm >= 3.12 and < 4**. **Helm 4 is NOT supported** (matches `nvcf-self-managed-stack/README.md`); on Helm 4 the chart's hook/server-side-apply handling misbehaves. The Bash snippet preflights `helm version` and fails fast on a non-3.x major.

## Prerequisite — GPU pool defined (zero GPU nodes is fine)

Comes from [`aks-nodes`](../aks-nodes/SKILL.md). The GPU pool must have the `nvidia.com/gpu=true` label, but it does **not** need a running node when you install the operator — `aks-nodes` floors the GPU pool at 0 (`GPU_MIN_COUNT=0`) so GPU nodes autoscale-from-0 only when a GPU workload arrives. The operator's control plane (operator controller, NFD master, NFD gc) is brought up on the **system pool** instead — see Gotcha #3.

The GPU pool has **no taint** by default (label-only reservation, matching the AWS foundation), so the operator's GPU-node operands (driver/toolkit/device-plugin/NFD worker) schedule there without any toleration. The `daemonsets.tolerations` and `node-feature-discovery.worker.tolerations` `--set`s exist only to support the opt-in `GPU_NODE_TAINTS=sku=gpu:NoSchedule` path — if you set that taint in `aks-nodes`, they let the operands still land (the NFD worker labels the node with the PCI `10de` feature that triggers `nvidia.com/gpu` advertisement, so on a tainted pool it must tolerate the taint too, or the node never gets `nvidia.com/gpu` and the NVCA agent reports "no backend GPUs"). These two are a no-op on the default untainted pool. The control plane needs no toleration either: `aks-cluster` leaves the system pool untainted (see Gotcha #3).

## Inputs

Source from `streaming-env.sh` + `generated/.env.aks-cluster`.

**Required:**

| Variable | Description |
|---|---|
| `CLUSTER_NAME` | (from streaming-env or `.env.aks-cluster`) |
| `RESOURCE_GROUP` | RG |

**Optional (firm defaults):**

| Variable | Description | Default |
|---|---|---|
| `GPU_OPERATOR_VERSION` | Helm chart version | `v25.3.0` (pin to a known-good; verify newer before bumping) |
| `GPU_OPERATOR_NAMESPACE` | Namespace | `gpu-operator` |
| `GPU_DRIVER_SOURCE` | `aks` (default) or `operator` (see "GPU driver source" below) | `aks` |
| `GPU_NODE_TAINT_KEY` | Taint key for the GPU-pool toleration. **Auto-derived from `aks-nodes`' `GPU_NODE_TAINTS`** when that is set; only override if you must. | (from `GPU_NODE_TAINTS`, else `sku`) |
| `GPU_NODE_TAINT_VALUE` | Taint value (same auto-derivation as the key) | (from `GPU_NODE_TAINTS`, else `gpu`) |
| `GPU_NODE_TAINT_EFFECT` | Taint effect for the toleration (same auto-derivation; parsed from the `:effect` suffix) | (from `GPU_NODE_TAINTS`, else `NoSchedule`) |
| `RUN_CUDA_TEST` | Run the `nvidia-smi` smoke pod after install | `false` |
| `OUTPUT_FORMAT` | `bash` only (Helm, no TF) | `bash` |

## Output

`generated/stage06-<cluster-name>-gpu-operator.sh` — idempotent (helm `install` vs `upgrade` auto-selected), supports `--teardown` and `--run-cuda-test`.

## AKS gotchas the upstream docs don't surface

### Gotcha #1 — apply BOTH CRD sets before `helm install --skip-crds`

The chart's top-level `crds/` directory ships only `nvidia.com_clusterpolicies.yaml` and `nvidia.com_nvidiadrivers.yaml`. The NFD subchart at `charts/node-feature-discovery/crds/nfd-api-crds.yaml` ships separately and is required for `nodefeatures.nfd.k8s-sigs.io` — without it NFD workers crashloop and `nvidia.com/gpu` is never advertised. EKS clusters often have NFD CRDs from another component, which masks this on AWS. Clean AKS clusters do not.

```bash
helm pull nvidia/gpu-operator --version "$GPU_OPERATOR_VERSION" --untar --untardir /tmp
kubectl apply -f /tmp/gpu-operator/crds/
kubectl apply -f /tmp/gpu-operator/charts/node-feature-discovery/crds/nfd-api-crds.yaml
```

### Gotcha #2 — AKS pre-installs the NVIDIA driver

NV/NC family nodes come with the driver pre-installed by AKS. The chart's default `driver.enabled=true` makes the operator try to install a second driver, leaving `nvidia-driver-daemonset` in `Init:Error`. The rest of the stack still works (CUDA runs, `nvidia-smi` in pods works) because the AKS-managed driver is sufficient — but the operator's driver lifecycle is out of play.

| `GPU_DRIVER_SOURCE` | Helm setting | When |
|---|---|---|
| `aks` (default) | `driver.enabled=false` | Validation; smaller blast radius |
| `operator` | `driver.enabled=true` (requires `--skip-gpu-driver-install` on the GPU pool — see [`aks-nodes`](../aks-nodes/SKILL.md)) | Production when runtime upgrades need operator-managed drivers |

### Gotcha #3 — where the control plane schedules under default config

On a green-field cluster built with stage defaults, the only Ready nodes are the system pool; the GPU pool floors at 0 (`GPU_MIN_COUNT=0`) and the compute pool is off (`ENABLE_COMPUTE_POOL=false`). The operator controller and NFD master/gc are **Deployments** that request no GPU, so they must land on the system pool.

`aks-cluster` leaves the system pool **untainted** precisely so these no-GPU control-plane Deployments schedule there with no toleration. (An earlier revision tainted the system pool `CriticalAddonsOnly=true:NoSchedule`, which left the control plane Pending forever and forced a `CriticalAddonsOnly` toleration on every cluster service — gpu-operator, KAI scheduler, the NVCF stack. Removing the taint is the root fix; the per-consumer tolerations are gone.)

This keeps `GPU_MIN_COUNT=0` (no always-on GPU cost): the control plane comes up on the system pool with zero GPU nodes present, and GPU nodes still autoscale-from-0 once a real GPU workload lands (the GPU-node operands — driver/toolkit/device-plugin/NFD worker DaemonSets — schedule onto the GPU node when it appears). The `daemonsets.tolerations` / `node-feature-discovery.worker.tolerations` `--set`s address the unrelated opt-in `GPU_NODE_TAINTS` path and are a no-op by default.

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

: "${CLUSTER_NAME:?}" "${RESOURCE_GROUP:?}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.3.0}"
GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"
GPU_DRIVER_SOURCE="${GPU_DRIVER_SOURCE:-aks}"
# GPU-pool taint toleration. aks-nodes owns the taint via GPU_NODE_TAINTS (free-form,
# "key=value:effect", empty by default). Derive key/value/effect from it so the operands
# tolerate whatever taint aks-nodes actually applied — otherwise an opt-in taint with a
# non-default key OR a non-NoSchedule effect leaves the driver/NFD-worker DaemonSets Pending.
# Falls back to the historical sku=gpu:NoSchedule when GPU_NODE_TAINTS is unset (harmless
# no-op on the default untainted pool).
GPU_NODE_TAINTS="${GPU_NODE_TAINTS:-}"
if [[ -n "$GPU_NODE_TAINTS" ]]; then
  _first_taint="${GPU_NODE_TAINTS%%,*}"                       # key=value:effect
  GPU_NODE_TAINT_KEY="${GPU_NODE_TAINT_KEY:-${_first_taint%%=*}}"
  _tv="${_first_taint#*=}"                                    # value:effect
  GPU_NODE_TAINT_VALUE="${GPU_NODE_TAINT_VALUE:-${_tv%%:*}}"
  _te="${_first_taint##*:}"                                   # effect (== whole string if no ':')
  [[ "$_te" != "$_first_taint" ]] && GPU_NODE_TAINT_EFFECT="${GPU_NODE_TAINT_EFFECT:-$_te}"
fi
GPU_NODE_TAINT_KEY="${GPU_NODE_TAINT_KEY:-sku}"
GPU_NODE_TAINT_VALUE="${GPU_NODE_TAINT_VALUE:-gpu}"
GPU_NODE_TAINT_EFFECT="${GPU_NODE_TAINT_EFFECT:-NoSchedule}"
RUN_CUDA_TEST="${RUN_CUDA_TEST:-false}"

export KUBECONFIG="${KUBECONFIG:-/tmp/kubeconfig-${CLUSTER_NAME}}"

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done

# Helm 4 is not supported (matches nvcf-self-managed-stack/README.md). On Helm 4 the
# gpu-operator chart's server-side-apply / hook handling misbehaves; use Helm 3.x (>= 3.12).
HELM_MAJOR="$(helm version --template '{{.Version}}' | sed -E 's/^v?([0-9]+).*/\1/')"
if [[ "$HELM_MAJOR" != "3" ]]; then
  echo "ERROR: Helm $HELM_MAJOR detected; this skill requires Helm 3.x (>= 3.12, < 4). Helm 4 is not supported." >&2
  exit 1
fi

ACTION="install"
while (($#)); do
  case "$1" in
    --teardown) ACTION="teardown";;
    --run-cuda-test) RUN_CUDA_TEST=true;;
    -h|--help) echo "Usage: $0 [--run-cuda-test] [--teardown]"; exit 0;;
    *) echo "Unknown flag: $1"; exit 1;;
  esac
  shift
done

teardown() {
  helm uninstall gpu-operator -n "$GPU_OPERATOR_NAMESPACE" --wait --timeout=5m || true
  kubectl delete namespace "$GPU_OPERATOR_NAMESPACE" --ignore-not-found
  # NFD CRDs are left in place — they're shared and not safe to blindly delete
  echo "GPU operator torn down."
}

install_operator() {
  echo "--- Adding NVIDIA Helm repo ---"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
  helm repo update

  echo "--- Pulling chart $GPU_OPERATOR_VERSION for CRDs ---"
  rm -rf /tmp/gpu-operator
  helm pull nvidia/gpu-operator --version "$GPU_OPERATOR_VERSION" --untar --untardir /tmp

  echo "--- Applying CRD sets (split between top-level and NFD subchart) ---"
  kubectl apply -f /tmp/gpu-operator/crds/
  kubectl apply -f /tmp/gpu-operator/charts/node-feature-discovery/crds/nfd-api-crds.yaml

  echo "--- Creating namespace $GPU_OPERATOR_NAMESPACE ---"
  kubectl create namespace "$GPU_OPERATOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # Driver source selection
  DRIVER_ENABLED=$([[ "$GPU_DRIVER_SOURCE" == "operator" ]] && echo "true" || echo "false")

  HELM_CMD=$(helm status gpu-operator -n "$GPU_OPERATOR_NAMESPACE" &>/dev/null && echo "upgrade" || echo "install")
  echo "--- helm $HELM_CMD gpu-operator $GPU_OPERATOR_VERSION (driver.enabled=$DRIVER_ENABLED) ---"
  helm "$HELM_CMD" gpu-operator nvidia/gpu-operator \
    --version "$GPU_OPERATOR_VERSION" \
    --namespace "$GPU_OPERATOR_NAMESPACE" \
    --skip-crds \
    --wait --timeout 20m \
    --set driver.enabled="$DRIVER_ENABLED" \
    --set toolkit.enabled=true \
    --set cdi.enabled=true --set cdi.default=true \
    --set "daemonsets.tolerations[0].key=$GPU_NODE_TAINT_KEY,daemonsets.tolerations[0].operator=Equal,daemonsets.tolerations[0].value=$GPU_NODE_TAINT_VALUE,daemonsets.tolerations[0].effect=$GPU_NODE_TAINT_EFFECT" \
    --set "node-feature-discovery.worker.tolerations[0].key=$GPU_NODE_TAINT_KEY,node-feature-discovery.worker.tolerations[0].operator=Equal,node-feature-discovery.worker.tolerations[0].value=$GPU_NODE_TAINT_VALUE,node-feature-discovery.worker.tolerations[0].effect=$GPU_NODE_TAINT_EFFECT"
    # No CriticalAddonsOnly toleration for the control plane (operator / NFD master / NFD gc):
    # aks-cluster no longer taints the system pool, so those no-GPU Deployments schedule on it
    # directly. The operator chart's default operator.tolerations (including nvidia.com/gpu) is left
    # intact since we no longer override it.
    #
    # GPU-POOL TAINT (daemonsets / NFD worker) — matters only on the opt-in GPU_NODE_TAINTS path.
    # NFD worker labels nodes with the PCI 10de feature → drives gpu-feature-discovery/device-plugin.
    # If the GPU pool is tainted but NFD worker can't schedule there, the node never gets
    # nvidia.com/gpu and the NVCA agent reports "no backend GPUs". daemonsets.tolerations alone
    # does NOT cover the NFD subchart worker — it needs its own key. No-op on the default
    # (untainted) GPU pool.

  echo "--- Verifying ---"
  kubectl get pods -n "$GPU_OPERATOR_NAMESPACE"
  kubectl get nodes -l nvidia.com/gpu.present=true -o wide || echo "WARN: no nodes labeled nvidia.com/gpu.present=true yet"
  kubectl get nodes -o json | python3 -c "import sys, json; [print(f'  {n[\"metadata\"][\"name\"]}: {n[\"status\"].get(\"allocatable\",{}).get(\"nvidia.com/gpu\",\"0\")} GPU(s)') for n in json.load(sys.stdin)['items']]" 2>/dev/null || true

  if [[ "$RUN_CUDA_TEST" == "true" ]]; then
    run_cuda_smoke_test
  fi
}

run_cuda_smoke_test() {
  echo "--- CUDA smoke test (nvidia-smi pod) ---"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: cuda-smoke, namespace: default }
spec:
  restartPolicy: Never
  tolerations:
    - { key: "$GPU_NODE_TAINT_KEY", operator: Equal, value: "$GPU_NODE_TAINT_VALUE", effect: $GPU_NODE_TAINT_EFFECT }
  containers:
    - name: nvidia-smi
      image: nvcr.io/nvidia/cuda:12.1.0-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources: { limits: { nvidia.com/gpu: 1 } }
EOF
  kubectl wait --for=condition=Ready pod/cuda-smoke --timeout=300s || true
  kubectl logs pod/cuda-smoke || true
  kubectl delete pod cuda-smoke --ignore-not-found
}

if [[ "$ACTION" == "teardown" ]]; then teardown; else install_operator; fi
```

## Validation checklist

- [ ] Helm major version is 3.x (>= 3.12, < 4) — script preflights `helm version` and fails fast on Helm 4 (not supported)
- [ ] Both CRD sets applied (top-level + NFD subchart) — verify via `kubectl get crd | grep -E 'nvidia.com|nfd.k8s-sigs.io'`
- [ ] `helm install` uses `--skip-crds` (CRDs were applied separately for upgrade safety)
- [ ] `driver.enabled` matches `GPU_DRIVER_SOURCE` (false for `aks`, true for `operator`)
- [ ] `cdi.enabled=true` and `cdi.default=true`
- [ ] Control plane (operator controller + NFD master/gc) comes up on the **untainted** system pool under default config (GPU floor 0, compute off) — no `CriticalAddonsOnly` toleration is set or needed; `aks-cluster` leaves the system pool schedulable (Gotcha #3)
- [ ] GPU-pool operands: GPU pool is untainted by default → no toleration needed. If `GPU_NODE_TAINTS` was opted into in `aks-nodes`, **both** `daemonsets.tolerations` **and** `node-feature-discovery.worker.tolerations` are set to match (NFD worker must tolerate the taint or the node never gets `nvidia.com/gpu`)
- [ ] Helm `--timeout 20m` (large clusters need it)
- [ ] Verification step prints GPU resource counts per node
- [ ] `--run-cuda-test` runs `nvidia-smi` in a pod that schedules on the GPU pool (with toleration)
- [ ] `--teardown` removes the release and namespace; CRDs left in place
- [ ] No image versions hardcoded except the operator chart version itself

## References

| Topic | Source |
|---|---|
| GPU Operator on AKS | https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/microsoft-aks.html |
| GPU Operator Helm chart | https://helm.ngc.nvidia.com/nvidia |
| NFD CRD splitting | https://github.com/NVIDIA/gpu-operator/issues — search "NFD CRD" |
| CDI in GPU Operator | https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/cdi.html |
