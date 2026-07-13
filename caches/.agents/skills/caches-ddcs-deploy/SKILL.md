---
name: caches-ddcs-deploy
description: Deploy DDCS as a shader cache for Kit/write-render-worker on GKE. Produces Kubernetes manifests, the Helm values override for write-render-worker (drivercachewrapper + UJITSO), and optionally runs a proof-of-life test. Use when setting up DDCS for MEGA shader caching (replacing GX cache).
---

# DDCS Shader Cache Deployment

**DDCS uses a different NGC org from MEGA.** The DDCS Helm chart and
container image are in the same NGC org as the SRTX charts, not the
MEGA org. The pull secret needs an NGC API key with access to that org.

- **Standalone DDCS** (no MEGA): `NGC_API_KEY` works — it typically has
  access to the DDCS charts and images.
- **DDCS alongside MEGA**: MEGA environments use separate keys for
  MEGA and SRTX charts (`NGC_MEGA_API_KEY` and `NGC_SRTX_API_KEY`).
  `NGC_SRTX_API_KEY` also grants access to DDCS charts and images, so
  use it. `NGC_MEGA_API_KEY` does not have access and will fail with
  `403 Forbidden` / `ImagePullBackOff`. `NGC_API_KEY` may also be set
  to the MEGA-scoped key in these environments — verify it has access
  before using it.

Generates an ordered, executable bash script that deploys DDCS to an existing GKE cluster and configures Kit (write-render-worker) to use it for shader caching via the `drivercachewrapper` and UJITSO datastore.

## Background

Kit's `DriverShaderCacheManager` redirects driver shader compilation through a GRPC datastore backed by DDCS. This replaces GX cache. The configuration requires:

1. A running DDCS instance (gRPC on port 3010, TLS off for in-cluster)
2. Kit CLI flags that set `drivercachewrapper/enableByProtocol` to `grpcdns://` pointing at DDCS
3. UJITSO datastore flags for textures, geometry, and materials caching

On Linux container drivers, the shader cache wrapper can intercept driver shader compilation and route it through DDCS.

## Sizing

### Compute Node

Place DDCS on the GPU nodes with the highest network bandwidth. DDCS
serves compiled shaders to WRWs via gRPC during startup, before GPU
rendering begins; it does not compete with GPU workloads. If the GPU
nodes have significantly more bandwidth than the CPU pool (e.g. 400 Gbps
vs 32 Gbps), place DDCS there with a GPU taint toleration. DDCS does
not consume GPU resources. Prefer stable GPU labels over node-pool names
so DDCS can spread across equivalent GPU pools in larger clusters. Use
the reference values files in `references/`, which already encode
`nodeSelector`, `tolerations`, and `affinity` for node placement (GPU pool on
GKE; the `node-type=compute` CPU pool on AKS):

- `references/ddcs-gcp-g4-values.yaml` — PVC-backed cache (default;
  durable across pod/node recreate). Selects `cloud.google.com/gke-gpu=true`.
- `references/ddcs-gcp-g4-no-pvc-values.yaml` — no PVC, RocksDB writes
  fall through to the container writable layer. On g4 nodes labelled
  `cloud.google.com/gke-ephemeral-storage-local-ssd=true` that path is
  the local NVMe SSD RAID0 — fastest available, cache lost on pod or
  node recreate. Selects both `cloud.google.com/gke-gpu=true` and
  `cloud.google.com/gke-ephemeral-storage-local-ssd=true`.
- `references/ddcs-aks-values.yaml` — AKS (NVCF/streaming). PVC-backed on
  `managed-csi-premium-burst` at 2 TiB (production-ready: meets the >=4000 IOPS
  target via on-demand burst; a quick smoke-test can use `managed-csi`/`50Gi`),
  placed on the `node-type=compute` CPU pool (no GPU labels or tolerations), and
  memory request `16Gi` (the chart default ~56Gi is too large for typical AKS node
  SKUs and leaves the pod Pending). Pull secret `nvcr-creds`.

Two DDCS pods must never share the same node (hard anti-affinity).
DDCS and UCC should prefer different nodes to spread network load,
but co-location is acceptable when node count is limited (soft
anti-affinity).

### Sizing knobs

These are the chart values that affect DDCS sizing. The chart's
defaults and the reference values in `references/` are both starting
points, not authoritative — defaults can change between chart versions,
and the references are tested values for one particular cluster shape.
Inspect the actual numbers for the chart version being deployed before
recommending overrides.

| Knob | Values path |
|---|---|
| Memory request | `cluster.container.resources.requests.memory` |
| Row cache (RAM) | `cluster.container.settings.engine."sys.cache_size"` |
| Block cache (RAM) | `cluster.container.settings.engine."sys.block_cache_size"` |
| Write buffers | `cluster.container.settings.engine."cf.max_write_buffer_number"` |
| Volume size | `cluster.container.storage.volume.size` |
| Storage class | `cluster.container.storage.volume.storageClassName` |
| Replicas | `cluster.replicas` |

### Memory configuration

The DDCS Helm chart defaults (`cf.max_write_buffer_number: 8`, smaller cache
sizes) are insufficient for production shader-cache workloads. Undersized write
buffers cause write failures such as `multi part value is not complete` under
burst load. Always set engine memory explicitly to match the RAM available on
the DDCS node.

The [DDCS memory configuration docs](https://docs.omniverse.nvidia.com/ovcaches/ddcs/latest/configure.html#memory-configuration)
define three pre-baked profiles. Pick the one that matches the DDCS node's RAM:

| Profile | RAM | `sys.cache_size` | `sys.block_cache_size` | `cf.max_write_buffer_number` | Reference file |
|---|---|---|---|---|---|
| Small | 16Gi | 4G | 8G | 64 | `references/ddcs-memory-16gb.yaml` |
| Default | 32Gi | 10G | 18G | 128 | `references/ddcs-memory-32gb.yaml` |
| Large | 64Gi | 20G | 36G | 128 | `references/ddcs-memory-64gb.yaml` |

The bundled G4 reference values files (`ddcs-gcp-g4-values.yaml`,
`ddcs-gcp-g4-no-pvc-values.yaml`) already include the 32Gi profile. To use a
different profile, merge the matching memory file after the platform file:

```bash
helm install ddcs ... \
  -f references/ddcs-gcp-g4-values.yaml \
  -f references/ddcs-memory-64gb.yaml
```

Each write buffer consumes ~64MB. A `cf.max_write_buffer_number` of 128
provides ~8GB of write-buffer capacity to absorb burst writes before flushing
to disk.

When the user needs sizing different from the chart defaults or the
reference values, override in a copy of a reference file rather than
passing per-knob `--set` flags from the script.

For storage class on GKE c4/g2/g4: ask about local ephemeral SSD if
present; otherwise use tuned `hyperdisk-balanced` (`9600` IOPS /
`2400Mi` throughput).

### Scaling (25-GPU cluster example)

| Metric | Value |
|---|---|
| GPU count | 25 |
| Bandwidth per GPU | ~3.3 Gbps |
| Total bandwidth required | ~83 Gbps |
| Compute nodes needed | 9 |
| DDCS replicas | 9 (one per compute node) |

### Storage Performance Targets

- **IOPS:** ≥ 4000
- **Sustained throughput:** ≥ 800 MB/s

GPU node pool sizing is a cluster prerequisite: ensure the cluster already has enough GPU nodes and that their labels, taints, and StorageClasses match the reference values used by this skill.

## Inputs

Take inputs from the user's prompt first; if a required input is missing, try to discover it before failing:

- **ZONE** (GKE only): If the user provides `CLUSTER_NAME` but not `ZONE`, run `gcloud container clusters list --project=<PROJECT> --filter="name=<CLUSTER_NAME>" --format="value(location)"` to auto-detect the zone. Check the user's current project first (`gcloud config get-value project`), then try other known projects if needed. On AKS (`CACHE_PLATFORM=aks`) `ZONE` is not used.

**Required** (platform-specific — `ZONE` applies to GKE only; see notes):

| Variable | Description | Example |
|---|---|---|
| `CLUSTER_NAME` | Name of the existing cluster (GKE or AKS) | `<CLUSTER_NAME>` |
| `ZONE` | GKE zone (auto-detect via `gcloud` if not provided). **GKE only** — not required when `CACHE_PLATFORM=aks` (kubectl context is set via `az aks get-credentials`) | `us-east5-c` |
| `DDCS_NAMESPACE` | Kubernetes namespace for DDCS (default: `ddcs`) | `ddcs` |

**Optional:**

| Variable | Description | Default |
|---|---|---|
| `GCP_PROJECT_ID` | GCP project ID | auto-detected from `gcloud config` |
| `GPU_POOL` | Node pool for Kit test pod (DDCS placement is in the reference values file) | `gpu-pool` |
| `CACHES_HELM_REPO_NAME` | Local Helm repo alias hosting the DDCS chart, from `helm repo list` | `nvidia-omniverse` |
| `DDCS_CHART_VERSION` | DDCS chart version on NGC. Default comes from repo `image-manifest/manifest.yaml` key `ddcs.helm-ddcs`. The chart's `appVersion` pins the image tag, so chart `5.0.0` deploys the matching DDCS image automatically. | `5.0.0` |
| `CACHE_PLATFORM` | Target platform for default values-file selection: `gke` or `aks` | `gke` |
| `DDCS_VALUES_FILE` | Reference values file passed via `helm install -f` | derived from `CACHE_PLATFORM` + `CACHE_STORAGE_MODE`: `CACHE_PLATFORM=aks` → `references/ddcs-aks-values.yaml` (managed-csi-premium-burst pinned, no `STORAGE_CLASS` needed); otherwise `references/ddcs-gcp-g4-values.yaml` for `pvc`, `references/ddcs-gcp-g4-no-pvc-values.yaml` for `ephemeral` |
| `DDCS_REPLICAS` | Replica count | `1` |
| `DDCS_MEMORY_PROFILE` | Engine memory profile layered via `-f` after the platform values file (`16gb`, `32gb`, `64gb`) | `32gb` (already baked into G4 reference files) |
| `NGC_API_KEY` | NGC API key for pulling DDCS image from `nvcr.io/nvidia/omniverse` (NOT `NGC_MEGA_API_KEY` — DDCS uses a different NGC org) | from environment |
| `NGC_SECRET_NAME` | Name of the NGC pull secret | `ngc-secret` |
| `CACHE_STORAGE_MODE` | DDCS cache storage mode | `pvc`; on GKE node pools with local ephemeral SSD, ask whether to use `ephemeral` for maximum speed and cache-loss-on-node-recreate semantics |
| `STORAGE_CLASS` | StorageClass for DDCS PVC (PVC mode only); passed via `--set cluster.container.storage.volume.storageClassName` | For GKE c4/g2/g4, use tuned `hyperdisk-balanced` (`9600` IOPS, `2400Mi` throughput); for non-GKE choose the provider-specific StorageClass |
| `TENANT_ID` | Tenant ID for gRPC metadata key isolation | empty (no tenant prefix) |
| `ENABLE_TEST` | Run proof-of-life test with Isaac Sim | `false` |
| `KIT_IMAGE` | Kit image for proof-of-life test | `nvcr.io/nvidia/isaac-sim:5.1.0` |

Memory, CPU, PVC size, RocksDB engine settings, node selector, tolerations,
anti-affinity, TLS/JWT defaults, and metrics exposition are in the
reference values files in `references/`. The G4 reference files include the
32Gi memory profile from the DDCS docs. Override there (or by editing a
copy), not via per-run script variables. Use `DDCS_MEMORY_PROFILE` to layer
`references/ddcs-memory-{16,32,64}gb.yaml` when the node RAM differs.

## Outputs

- **`ddcs-shader-cache.sh`** in `generated/` -- deploys DDCS and prints Helm values override for write-render-worker
- If `ENABLE_TEST=true`: runs a Kit pod that validates `created GRPC datastore` appears in logs

The script is placed in `generated/` for human review before execution.

## Steps

### Idempotency rule

Every resource creation command MUST be guarded by an existence check. Use `kubectl get ... &>/dev/null` before `kubectl apply/create`.

### Step 1 — Preflight checks

```bash
#!/bin/bash
set -euo pipefail
# Generated by: infra-as-doc / caches-ddcs-deploy skill
# Cluster: <CLUSTER_NAME>  Zone: <ZONE>  Namespace: <DDCS_NAMESPACE>
#
# Deploys DDCS as shader cache for Kit/write-render-worker.
# Produces Helm values override for write-render-worker extraCmdArgs.
#
# Usage:
#   ./ddcs-shader-cache.sh            # deploy DDCS + print Helm values
#   ./ddcs-shader-cache.sh --test     # also run proof-of-life Kit test
#   ./ddcs-shader-cache.sh --teardown # remove DDCS namespace

: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
CACHE_PLATFORM="${CACHE_PLATFORM:-gke}"
DDCS_NAMESPACE="${DDCS_NAMESPACE:-ddcs}"

# ZONE and the gcloud/GCP_PROJECT_ID resolution below are GKE-only. On AKS the
# kubectl context is expected to already point at the cluster (via
# `az aks get-credentials`), so neither ZONE nor a GCP project is required.
if [ "$CACHE_PLATFORM" = "gke" ]; then
  : "${ZONE:?Set ZONE for CACHE_PLATFORM=gke}"

  # GCP_PROJECT_ID: prefer the project the kubectl context points at; the
  # user's gcloud default project may differ from the cluster's project,
  # and project-scoped operations (e.g. importing the Cloud Monitoring
  # dashboard) must target the cluster's project to see metrics. The GKE
  # context format is `gke_<project>_<zone>_<cluster>`; fall back to
  # `gcloud config` for non-GKE contexts.
  if [ -z "${GCP_PROJECT_ID:-}" ]; then
    ctx=$(kubectl config current-context 2>/dev/null)
    case "$ctx" in
      gke_*) GCP_PROJECT_ID=$(echo "$ctx" | cut -d_ -f2) ;;
      *)     GCP_PROJECT_ID=$(gcloud config get-value project 2>/dev/null) ;;
    esac
  fi
  gcloud_default=$(gcloud config get-value project 2>/dev/null)
  if [ -n "$gcloud_default" ] && [ "$gcloud_default" != "$GCP_PROJECT_ID" ]; then
    echo "WARN: gcloud default project ($gcloud_default) differs from cluster project ($GCP_PROJECT_ID)."
    echo "      Project-scoped commands (dashboards, IAM, logs) will use $GCP_PROJECT_ID."
  fi
fi

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach cluster. Run:"
  if [ "$CACHE_PLATFORM" = "gke" ]; then
    echo "  gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE --project $GCP_PROJECT_ID"
  else
    echo "  az aks get-credentials --resource-group <RESOURCE_GROUP> --name $CLUSTER_NAME"
  fi
  exit 1
fi
```

### Step 2 — Create namespace and NGC secret

```bash
if ! kubectl get namespace "$DDCS_NAMESPACE" &>/dev/null; then
  kubectl create namespace "$DDCS_NAMESPACE"
fi

if ! kubectl get secret "$NGC_SECRET_NAME" -n "$DDCS_NAMESPACE" &>/dev/null; then
  : "${NGC_API_KEY:?Set NGC_API_KEY before running}"
  # Pipes the secret manifest to kubectl via stdin so no $ touches the shell.
  # Python \x24 produces a literal $ in the auth payload.
  NGC_SECRET_NAME="$NGC_SECRET_NAME" DDCS_NAMESPACE="$DDCS_NAMESPACE" python3 << 'PYEOF' | kubectl apply -f -
import json, base64, os
name = os.environ["NGC_SECRET_NAME"]
ns = os.environ["DDCS_NAMESPACE"]
auth = base64.b64encode(b"\x24oauthtoken:" + os.environ["NGC_API_KEY"].encode()).decode()
cfg = base64.b64encode(json.dumps({"auths": {"nvcr.io": {"auth": auth}}}).encode()).decode()
print(f"""apiVersion: v1
kind: Secret
metadata:
  name: {name}
  namespace: {ns}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {cfg}""")
PYEOF
fi
```

### Step 3 — Choose cache storage and create StorageClass

**AKS (`CACHE_PLATFORM=aks`): skip this step.** The AKS values file
`references/ddcs-aks-values.yaml` pins a built-in StorageClass
(`managed-csi-premium-burst`, production-ready), so **no `STORAGE_CLASS` is
required and no StorageClass is created** (the GKE block below is gated on
`CACHE_PLATFORM=gke`). The values file notes how to drop to `managed-csi` for a quick
smoke-test only; do not create a StorageClass here.

For GKE c4/g2/g4 node pools, first check whether the selected node pool
has local ephemeral SSD. Ask whether the user wants ephemeral cache
storage for maximum speed; cache contents are lost on pod reschedule to a
different node, node recreate, or node-pool scale-down. If the user does
not choose ephemeral storage, use a tuned Hyperdisk Balanced StorageClass.
With explicit `9600` IOPS and `2400Mi` throughput, the PVC does **not**
need to be 2TiB to reach maximum throughput; use a smaller size such as
`375Gi` unless the workload needs more cache capacity.

```bash
set -euo pipefail
CACHE_PLATFORM="${CACHE_PLATFORM:-gke}"
CACHE_STORAGE_MODE="${CACHE_STORAGE_MODE:-pvc}"
# AKS pins a built-in StorageClass (managed-csi-premium-burst) in references/ddcs-aks-values.yaml,
# so no StorageClass is created and no STORAGE_CLASS is needed. This GKE-only block (which
# uses the GKE pd.csi provisioner) is gated on CACHE_PLATFORM=gke.
if [ "$CACHE_PLATFORM" = "gke" ] && [ "$CACHE_STORAGE_MODE" = "pvc" ] && [ -n "${STORAGE_CLASS:-}" ] && ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $STORAGE_CLASS
provisioner: pd.csi.storage.gke.io
parameters:
  type: $STORAGE_CLASS
  provisioned-iops-on-create: "9600"
  provisioned-throughput-on-create: "2400Mi"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
fi
```

### Step 4 — Helm install

Install DDCS via the chart, passing the reference values file that matches
the target platform (`CACHE_PLATFORM`) and cache storage mode. The chart generates the ConfigMap, StatefulSet,
Service, and (when `monitoring.enabled=true`) the ServiceMonitor from the
values file. Do not hand-roll those manifests.

```bash
set -euo pipefail
: "${CACHES_HELM_REPO_NAME:?Set CACHES_HELM_REPO_NAME (e.g. nvidia-omniverse)}"
DDCS_CHART_VERSION="${DDCS_CHART_VERSION:-5.0.0}"
DDCS_REPLICAS="${DDCS_REPLICAS:-1}"
DDCS_MEMORY_PROFILE="${DDCS_MEMORY_PROFILE:-}"

if [ "${CACHE_PLATFORM}" = "aks" ]; then
  # AKS: the values file pins managed-csi-premium-burst and the node-type=compute pool, so
  # neither a STORAGE_CLASS nor a CACHE_STORAGE_MODE branch is needed here.
  DDCS_VALUES_FILE="${DDCS_VALUES_FILE:-references/ddcs-aks-values.yaml}"
  HELM_STORAGE_ARGS=()
elif [ "${CACHE_STORAGE_MODE}" = "ephemeral" ]; then
  DDCS_VALUES_FILE="${DDCS_VALUES_FILE:-references/ddcs-gcp-g4-no-pvc-values.yaml}"
  HELM_STORAGE_ARGS=()
else
  : "${STORAGE_CLASS:?Set STORAGE_CLASS for CACHE_STORAGE_MODE=pvc}"
  DDCS_VALUES_FILE="${DDCS_VALUES_FILE:-references/ddcs-gcp-g4-values.yaml}"
  HELM_STORAGE_ARGS=(--set "cluster.container.storage.volume.storageClassName=${STORAGE_CLASS}")
fi

HELM_MEMORY_ARGS=()
case "${DDCS_MEMORY_PROFILE}" in
  16gb) HELM_MEMORY_ARGS=(-f references/ddcs-memory-16gb.yaml) ;;
  32gb) HELM_MEMORY_ARGS=(-f references/ddcs-memory-32gb.yaml) ;;
  64gb) HELM_MEMORY_ARGS=(-f references/ddcs-memory-64gb.yaml) ;;
  "") ;;
  *)
    echo "ERROR: DDCS_MEMORY_PROFILE must be empty, 16gb, 32gb, or 64gb (got '${DDCS_MEMORY_PROFILE}')"
    exit 1
    ;;
esac

helm repo update "${CACHES_HELM_REPO_NAME}" >/dev/null

helm install ddcs "${CACHES_HELM_REPO_NAME}/ddcs" \
  --version "${DDCS_CHART_VERSION}" \
  --namespace "${DDCS_NAMESPACE}" --wait --timeout 5m \
  -f "${DDCS_VALUES_FILE}" \
  "${HELM_MEMORY_ARGS[@]}" \
  --set "cluster.replicas=${DDCS_REPLICAS}" \
  --set "image.pullSecrets[0].name=${NGC_SECRET_NAME}" \
  "${HELM_STORAGE_ARGS[@]}"
```

| Override | Why it stays as `--set` (not in the values file) |
|---|---|
| `cluster.replicas` | Per-deployment sizing decision |
| `image.pullSecrets[0].name` | Default expects `regcred`; NGC deployments use `${NGC_SECRET_NAME}` |
| `cluster.container.storage.volume.storageClassName` | Cluster-specific StorageClass name (PVC mode only) |

### Step 5 — Deploy PodMonitoring for GKE Managed Prometheus

The chart exposes Prometheus metrics on container port `3051` at `/metrics`.
GKE Managed Prometheus scrapes these via a PodMonitoring CRD. The reference
values files set `monitoring.enabled=false`, so the chart's Prometheus
Operator `ServiceMonitor` is suppressed; this step adds the GMP-native
PodMonitoring instead. Use integer port (not named) — named ports can
silently fail with Managed Prometheus.

**AKS: skipped.** `PodMonitoring` (`monitoring.googleapis.com`) is a GKE Managed Prometheus
CRD that does not exist on AKS, and the AKS reference values run with monitoring off. The
script gates the apply on `CACHE_PLATFORM=gke` **and** the CRD being present, so under
`set -euo pipefail` it is a clean no-op on AKS instead of a fatal `kubectl apply` error.

```bash
set -euo pipefail
CACHE_PLATFORM="${CACHE_PLATFORM:-gke}"
# PodMonitoring is a GKE Managed Prometheus CRD (monitoring.googleapis.com); it is absent on
# AKS, where the reference values run with monitoring off. Gate on platform AND CRD presence
# so this step never aborts the script under `set -euo pipefail`.
if [ "$CACHE_PLATFORM" = "gke" ] && kubectl get crd podmonitorings.monitoring.googleapis.com &>/dev/null; then
  kubectl apply -f - <<EOF
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: ddcs
  namespace: $DDCS_NAMESPACE
spec:
  selector:
    matchLabels:
      ddcs: kvnode
  endpoints:
    - port: 3051
      interval: 15s
      path: /metrics
EOF
else
  echo "Skipping PodMonitoring (CACHE_PLATFORM=$CACHE_PLATFORM; GKE Managed Prometheus CRD not present)."
fi
```

Key metrics to monitor in Cloud Monitoring (Metrics Explorer):
- `ddcs_m_api_keys_total{operation="grpc_get"}` — cache lookups
- `ddcs_m_api_keys_total{operation="grpc_put"}` — cache writes
- `ddcs_m_adapter_entry_cache_total{operation="hit"}` — cache hits
- `ddcs_m_adapter_entry_cache_total{operation="miss"}` — cache misses
- `ddcs_m_adapter_bytes_returned_total` — data served by level (in_memory, rocksdb)

An example Cloud Monitoring dashboard built on these metrics is shipped at
`references/dashboards/ddcs-gcloud-dashboard.json`. Import on demand
with `gcloud monitoring dashboards create --config-from-file=...`; not a
required step of the deploy.

### Step 6 — Print write-render-worker Helm values

After DDCS is deployed, the script MUST print the Helm values override that
configures Kit to use DDCS for shader caching. The values block, the
DDCS endpoint format, and the drivercachewrapper path rules are defined
in the **Client Integration** section below; the script just emits them
to stdout for the operator to copy into their Mega deployment config.

### Step 7 — Proof-of-life test (optional)

Only when `ENABLE_TEST=true` or `--test` flag is passed. Deploys a Kit pod (Isaac Sim) that connects to DDCS and validates the shader cache pipeline end-to-end. The full Kit launch command (including the GKE `/usr/local/nvidia/lib64` `ldconfig` fix, `warmupMode=1` invocation, pass/fail checks, and test-pod constraints) lives in `references/test-and-verify.md` under "Step 7 — Proof-of-life test". Use it verbatim when emitting the test step.

### Note on persisting overrides

The DDCS values in `references/ddcs-overrides.yaml` must be present on every
`helm upgrade` of the simulation release. Prefer merging them into the same
Helm values artifact used for install and upgrade. If the reference file is
kept as a separate layer, pass it on every upgrade after UCC proxy wiring.

### Step 8 — Teardown

When `--teardown` is passed:

```bash
kubectl delete namespace "$DDCS_NAMESPACE" --wait=false
echo "DDCS namespace $DDCS_NAMESPACE deleted."
```

## Client Integration

After DDCS is deployed, configure Kit (write-render-worker) to use it for
shader caching by passing `references/ddcs-overrides.yaml` to the
mega-simulation umbrella chart. The reference file targets
`srtx.write-render-worker` in the umbrella; for a standalone
write-render-worker chart, drop the `srtx:` prefix.

The reference assumes DDCS is in namespace `ddcs` (the default). If
deployed elsewhere, replace `ddcs.ddcs.svc.cluster.local` in the file
with `ddcs.<namespace>.svc.cluster.local` (four `*DnsName` /
`enableByProtocol` URLs).

The generated script should print the contents of
`references/ddcs-overrides.yaml` to stdout (or copy it alongside the
script in `generated/`) so the operator can paste it into their Mega
deployment values without leaving the script's working directory.

**CRITICAL — drivercachewrapper path:** the mega-simulation umbrella chart
passes extraCmdArgs verbatim to Kit, so the override file must use
single-level drivercachewrapper paths (`--/drivercachewrapper/...`).
Doubled paths silently fail — Kit ignores the unknown path with no error,
so shader caching appears to work (DDCS receives some UJITSO traffic) but
the driver shader cache is never routed through DDCS. The warm shader cook
time stays at ~100s instead of dropping to <1s.

## Validation

After generating the script, verify:

- [ ] Script opens with `set -euo pipefail`
- [ ] Required variables have `: "${VAR:?message}"` checks
- [ ] NGC secret creation prefers `NGC_API_KEY` (direct create), falls back to namespace copy, errors clearly if neither available
- [ ] Namespace and NGC secret creation are idempotent
- [ ] GKE c4/g2/g4 storage selection asks about local ephemeral SSD when present; otherwise uses tuned `hyperdisk-balanced` (`9600` IOPS / `2400Mi`)
- [ ] `helm install` is invoked with `-f` pointing at the matching reference values file (`ddcs-gcp-g4-values.yaml` for `pvc`, `ddcs-gcp-g4-no-pvc-values.yaml` for `ephemeral`); ConfigMap, StatefulSet, and Service are NOT hand-rolled
- [ ] Reference values set `cf.max_write_buffer_number: 128` (32Gi profile) or the matching value from `ddcs-memory-{16,32,64}gb.yaml`; chart default of 8 is insufficient
- [ ] PodMonitoring uses integer port `3051` (chart's metrics port; named ports can silently fail with GMP) and selector `ddcs: kvnode`
- [ ] Helm values include `gxcache.enabled: false` and `gxcache.autoinject: false` (gxcache competes with drivercachewrapper)
- [ ] Helm values use single-level `drivercachewrapper/` paths
- [ ] Helm values include `grpcDnsName`, `grpcUseTLS=false`, and `tenantID` in `extraCmdArgs`
- [ ] Kit test pod (if enabled) has `securityContext.runAsUser: 0` and `OMNI_KIT_ALLOW_ROOT=1`
- [ ] Kit test pod includes the `ldconfig` fix for `/usr/local/nvidia/lib64`
- [ ] Kit test uses warmup-mode `kit/kit` invocation with `warmupMode=1` and `fastShutdown=1` (preferred over `isaac-sim.sh`)
- [ ] Kit test uses `--no-window` and `--/app/quitAfter=300`
- [ ] Kit test uses single-level `drivercachewrapper/` paths (not doubled -- that's Helm only)
- [ ] Kit test includes `tenantID` flag when `TENANT_ID` is set
- [ ] No secrets are hardcoded
- [ ] Teardown mode is implemented

## Post-deployment verification, Troubleshooting, and Benchmarks

Once DDCS is deployed and write-render-worker is configured, validate the pipeline using the four checks in `references/test-and-verify.md` (WRW args, shader cook time, DDCS metrics, gxcache disabled). The same file holds the symptom → cause → fix matrix for the common failure modes (path doubling, gxcache contention, missing drivercachewrapper args) and the reference benchmark numbers from the `mega-cache-test` cluster (GKE Standard, L4 GPU, warehouse20x20).

## References

| Description | URL |
|---|---|
| GKE GPU node pools | https://cloud.google.com/kubernetes-engine/docs/how-to/gpus |
| GKE Cloud Monitoring dashboard (DDCS) | `references/dashboards/ddcs-gcloud-dashboard.json` — import via `gcloud monitoring dashboards create --config-from-file` |
