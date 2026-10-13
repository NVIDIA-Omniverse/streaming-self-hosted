---
name: caches-ovdc-deploy
description: Deploy Omniverse Derived Cache (OVDC) 6.0.1 for Kit/write-render-worker shader caching on GKE, AKS, EKS or on-prem Kubernetes. Prepare a Helm deployment script with chart sizing presets and drivercachewrapper/UJITSO client values; optionally verify cold/warm cache use. Use for new OVDC deployments replacing GXCache, not legacy DDCS upgrades.
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# OVDC Shader Cache Deployment

Deploy **Omniverse Derived Cache (OVDC)** using the `ovderivedcache` chart and
`nvcr.io/nvidia/omniverse/ovderivedcache` image. The default chart version is
`6.0.1`, matching the release manifest. The values use its CPU/RAM presets
and were rendered against the selected 6.0.1 chart. Verify access and inspect
`helm show values` / `helm template` for the exact artifact being deployed;
these offline checks do not establish public availability or runtime sizing.
Do not substitute the 6.0.0 chart or DDCS 5.x values for this preset profile.

Use an NGC key with access to `nvidia/omniverse`; verify chart and image access
rather than assuming a MEGA or SRTX key has the required entitlement.
For a customer-managed mirror, use its repository and scoped credentials. Set `CACHES_HELM_REPO_NAME` to
that chart repository and set `OVDC_IMAGE_REGISTRY`, `OVDC_IMAGE_REPOSITORY`
and `OVDC_IMAGE_TAG` in the generated script; its explicit Helm flags take
precedence over the platform values file. Chart
and image versions are independent; render the values and confirm the full
image reference before deployment.
The legacy `caches-ddcs-deploy` skill remains available for DDCS 5.0.0.
Deploy OVDC into its own namespace/release; this skill does not migrate a DDCS
PVC or promise compatibility with its existing on-disk database.

Generates an ordered, executable bash script that deploys OVDC to an existing GKE, AKS, EKS or on-prem Kubernetes cluster and configures Kit (write-render-worker) to use it for shader caching via the `drivercachewrapper` and UJITSO datastore.

## Background

Kit's `DriverShaderCacheManager` redirects driver shader compilation through a GRPC datastore backed by OVDC. This replaces GX cache. The configuration requires:

1. A running OVDC instance (gRPC on port 3010, TLS off for in-cluster)
2. Kit CLI flags that set `drivercachewrapper/enableByProtocol` to `grpcdns://` pointing at OVDC
3. UJITSO datastore flags for textures, geometry, and materials caching

On Linux container drivers, the shader cache wrapper can intercept driver shader compilation and route it through OVDC.

## Sizing

### Compute Node

Place OVDC on the GPU nodes with the highest network bandwidth. OVDC
serves compiled shaders to WRWs via gRPC during startup, before GPU
rendering begins; it does not compete with GPU workloads. If the GPU
nodes have significantly more bandwidth than the CPU pool (e.g. 400 Gbps
vs 32 Gbps), place OVDC there with a GPU taint toleration. OVDC does
not consume GPU resources. Prefer stable GPU labels over node-pool names
so OVDC can spread across equivalent GPU pools in larger clusters. Use
the reference values files in `references/`, which already encode
`nodeSelector`, `tolerations`, and `affinity` for node placement (GPU pool on
GKE; the `node-type=compute` CPU pool on AKS; site-selected placement on EKS/on-prem):

- `references/ovdc-gcp-g4-values.yaml` — PVC-backed cache (default;
  durable across pod/node recreate). Selects `cloud.google.com/gke-gpu=true`.
- `references/ovdc-gcp-g4-no-pvc-values.yaml` — no PVC, RocksDB writes
  use the chart’s writable `/env` emptyDir. On g4 nodes labelled
  `cloud.google.com/gke-ephemeral-storage-local-ssd=true` that path is
  node ephemeral storage. Cache survives a container restart but is lost
  when the pod is deleted or rescheduled. Selects both `cloud.google.com/gke-gpu=true` and
  `cloud.google.com/gke-ephemeral-storage-local-ssd=true`.
- `references/ovdc-aks-values.yaml` — AKS (NVCF/streaming). A 600Gi PVC on
  `ovdc-premium-v2`, provisioned with 4000 IOPS and 1000 MB/s using
  `references/aks-premium-v2-storageclass.yaml`,
  placed on the `node-type=compute` CPU pool (no GPU labels or tolerations), and
  memory request `16Gi` with the `12GB` RAM preset (the chart's default
  56G request may not fit the node). The install uses `NGC_SECRET_NAME`.

- [EKS values](references/ovdc-eks-values.yaml) — PVC-backed cache using an
  existing `gp3` StorageClass (or `STORAGE_CLASS` override). Verify the EBS CSI
  driver, EC2 node limits and provisioned disk performance; no node-pool label is assumed.
- [On-prem values](references/ovdc-onprem-values.yaml) — set `STORAGE_CLASS` to
  the site's existing class and adapt placement, capacity and memory to the
  cluster. The [EKS values](references/ovdc-eks-values.yaml) are a configuration
  reference, not a requirement to use AWS storage, node labels or sizing.
  These two profiles default to 16Gi / `12GB`; validate the chosen workload.

Two OVDC pods must never share the same node (hard anti-affinity). The soft rule selects cache pods across namespaces.
OVDC and OVCC should prefer different nodes to spread network load,
but co-location is acceptable when node count is limited (soft
anti-affinity).

### Sizing with chart presets

Use `presets.cpu` and `presets.ram` as the primary sizing interface in
`ovderivedcache` 6.0.1. The chart owns the corresponding RocksDB cache,
write-buffer and thread settings. Set Kubernetes resource requests separately:
the presets do not change them or reserve CPUs.

| Knob | Values path |
|---|---|
| Engine concurrency preset (1–8) | `presets.cpu` |
| Cache memory preset | `presets.ram` |
| Pod memory request, including overhead | `resources.requests.memory` |
| Volume size / storage class | `storage.volume.size` / `storage.volume.storageClassName` |
| Per-pod on-disk cache target | `settings.store.maxSize` |
| Replica count | `replicas` |

The PVC profiles cap cache data at `512G` independently of disk capacity,
to bound compaction/GC work. The ephemeral profile keeps its `275G` target.

### Memory configuration

The chart's RAM presets allocate their named budget across row and block
caches. They do not reserve memory for the process or network buffers. The
bundled profiles leave headroom within the pod request; validate peak memory
under the workload rather than assuming a fixed network-buffer allowance:

| Profile | Pod request | `presets.ram` | `presets.cpu` | Reference file |
|---|---|---|---|---|
| Small | 16Gi | `12GB` | 4 | `references/ovdc-memory-16gb.yaml` |
| Default | 32Gi | `24GB` | 8 | `references/ovdc-memory-32gb.yaml` |
| Large | 64Gi | `48GB` | 8 | `references/ovdc-memory-64gb.yaml` |

GKE platform files select the default profile; AKS, EKS and on-prem select small. Layer a
memory profile after the platform file and retain it on every upgrade:

```bash
set -euo pipefail
helm template ovdc "${CACHES_HELM_REPO_NAME:-nvidia-omniverse}/ovderivedcache" \
  --version "${OVDC_CHART_VERSION:-6.0.1}" \
  -f references/ovdc-gcp-g4-values.yaml \
  -f references/ovdc-memory-64gb.yaml
```

Use the chart's preset tables, then render and validate peak memory under the
customer workload. CPU preset 8 is the chart maximum; it tunes engine threads
and is not a CPU resource request. `useWriteBufferManager` is already true in
6.0.1, so the values files inherit shared block/write memory without restating
that default. They also inherit plaintext gRPC and JWT-off defaults. OTLP
exporters are explicitly disabled because their chart defaults target an
unconfigured local collector.

Customers who need engine fine-tuning can set `settings.engine` in their own
values file. A non-null preset overrides the engine keys it owns; set the
corresponding `presets.cpu` or `presets.ram` to `null` before tuning those keys.
Prefer presets for ordinary sizing and inspect the rendered TOML after any
fine-tuning. Do not copy old DDCS cache/buffer settings into OVDC.

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
| OVDC replicas | 9 (one per compute node) |

### Storage Performance Targets

- **IOPS:** ≥ 4000
- **Sustained throughput:** ≥ 800 MB/s

GPU node pool sizing is a cluster prerequisite: ensure the cluster already has enough GPU nodes and that their labels, taints, and StorageClasses match the reference values used by this skill.

## Inputs

Take inputs from the user's prompt first; if a required input is missing, try to discover it before failing:

- **ZONE** (GKE only): If the user provides `CLUSTER_NAME` but not `ZONE`, run `gcloud container clusters list --project=<PROJECT> --filter="name=<CLUSTER_NAME>" --format="value(location)"` to auto-detect the zone or region. Pass it with `--location` when obtaining credentials. Check the user's current project first (`gcloud config get-value project`), then try other known projects if needed. On AKS, EKS and on-prem, `ZONE` is not used; select the existing kubectl context first.

**Required** (platform-specific — `ZONE` applies to GKE only; see notes):

| Variable | Description | Example |
|---|---|---|
| `CLUSTER_NAME` | Name of the existing cluster (GKE, AKS, EKS or on-prem Kubernetes) | `<CLUSTER_NAME>` |
| `ZONE` | GKE zone (auto-detect via `gcloud` if not provided). **GKE only** — other platforms use the selected kubectl context | `us-east5-c` |
| `OVDC_NAMESPACE` | Kubernetes namespace for OVDC (default: `ovdc`) | `ovdc` |

**Optional:**

| Variable | Description | Default |
|---|---|---|
| `GCP_PROJECT_ID` | GCP project ID | auto-detected from `gcloud config` |
| `GPU_POOL` | Node pool for Kit test pod (OVDC placement is in the reference values file) | `gpu-pool` |
| `CACHES_HELM_REPO_NAME` | Local Helm repo alias hosting the OVDC chart, from `helm repo list` | `nvidia-omniverse` |
| `OVDC_CHART_VERSION` | OVDC chart version on NGC. Defaults from repo `image-manifest/manifest.yaml` keys `ovdc.helm-ovderivedcache` (`6.0.1`) and `ovdc.ovderivedcache` (`6.0.1`). Render the chart and verify the selected image. | `6.0.1` |
| `CACHE_PLATFORM` | Target platform for default values-file selection: `gke`, `aks`, `eks` or `onprem` | `gke` |
| `OVDC_VALUES_FILE` | Reference values file passed via `helm install -f` | derived from `CACHE_PLATFORM` + `CACHE_STORAGE_MODE`: `CACHE_PLATFORM=aks` → `references/ovdc-aks-values.yaml` (`ovdc-premium-v2` created/reused by Step 3); `eks` → `references/ovdc-eks-values.yaml`, `onprem` → `references/ovdc-onprem-values.yaml`; GKE uses `references/ovdc-gcp-g4-values.yaml` for `pvc`, `references/ovdc-gcp-g4-no-pvc-values.yaml` for `ephemeral` |
| `OVDC_REPLICAS` | Replica count | `1` |
| `OVDC_MEMORY_PROFILE` | Preset/resource layer via `-f` after the platform file (`16gb`, `32gb`, `64gb` name pod memory requests) | empty (GKE: 32Gi / `24GB`; AKS/EKS/on-prem: 16Gi / `12GB`) |
| `NGC_API_KEY` | Exported, scoped NGC key; read only when creating a missing image-pull secret for the selected NVCR repository | unset when reusing an existing secret |
| `NGC_SECRET_NAME` | Name of the NGC pull secret | `ngc-secret` |
| `CACHE_STORAGE_MODE` | OVDC cache storage mode | `pvc`; on GKE node pools with local ephemeral SSD, ask whether to use `ephemeral` for maximum speed and cache-loss-on-node-recreate semantics |
| `STORAGE_CLASS` | PVC StorageClass override for GKE/EKS/on-prem; passed via `--set storage.volume.storageClassName`. EKS/on-prem classes must already exist; required on-prem. Custom EKS values require an explicit `STORAGE_CLASS`. Ignored for ephemeral mode and AKS (provision the class named in a custom AKS `OVDC_VALUES_FILE` before deployment). | `hyperdisk-balanced` on GKE: reused if present, otherwise created with `9600` IOPS and `2400Mi` throughput. Bundled AKS values use `ovdc-premium-v2`; EKS defaults to `gp3`; on-prem has no default class. |
| `TENANT_ID` | Tenant ID for gRPC metadata key isolation | empty (no tenant prefix) |
| `ENABLE_TEST` | Run proof-of-life test with Isaac Sim | `false` |
| `KIT_IMAGE` | Kit image for proof-of-life test | `nvcr.io/nvidia/isaac-sim:5.1.0` |

The platform files contain deployment-specific storage, scheduling, resource
and preset values. Omitted settings inherit the selected chart's defaults.
Use `OVDC_MEMORY_PROFILE` to layer `references/ovdc-memory-{16,32,64}gb.yaml`
when the node RAM differs; inspect the merged values and rendered resources.

## Outputs

- **Generated `ovdc-shader-cache.sh`** next to `SKILL.md` -- deploys OVDC and prints Helm values override for write-render-worker
- If `ENABLE_TEST=true`: runs a Kit pod that validates `created GRPC datastore` appears in logs

This script is an output of Workflow step 2, not a bundled input file.
Write it inside this skill directory for human review before execution.
Run it from the skill directory so bundled `references/` paths resolve.

## Workflow

1. Select the existing GKE/AKS/EKS/on-prem cluster, storage mode, artifact source and preset
   profile. Confirm the namespace/release and inspect the selected 6.0.1 chart.
2. Read `references/deployment.md` and assemble its ordered install steps into
   `ovdc-shader-cache.sh` beside `SKILL.md`. Keep all required values files in
   this skill. Handle `--teardown` before install steps and `--test` as opt-in.
3. Reuse the namespace's existing `NGC_SECRET_NAME` pull secret where possible.
   Only its creation requires an exported, scoped `NGC_API_KEY`. The supplied
   code sends it through stdin to the selected Kubernetes API; never log the
   key, place it in arguments, persist a plaintext copy, or send it elsewhere.
4. Review the script, render the selected Helm values and check storage,
   resource headroom, placement, image identity and service/client DNS.
5. Execute within the user's authorized deployment scope. For validation, read
   `references/test-and-verify.md`; keep runtime/performance claims separate
   from offline Helm renders.

## Client Integration

After OVDC is deployed, configure Kit (write-render-worker) to use it for
shader caching by passing `references/ovdc-overrides.yaml` to the
mega-simulation umbrella chart. The reference file targets
`srtx.write-render-worker` in the umbrella; for a standalone
write-render-worker chart, drop the `srtx:` prefix.

The reference assumes OVDC is in namespace `ovdc` (the default). If
deployed elsewhere, replace `ovdc.ovdc.svc.cluster.local` in the file
with `ovdc.<namespace>.svc.cluster.local` (four `*DnsName` /
`enableByProtocol` URLs).

The generated script should print the contents of
`references/ovdc-overrides.yaml` to stdout (or copy it alongside the
script beside `SKILL.md`) so the operator can paste it into their Mega
deployment values without leaving the script's working directory.

**CRITICAL — drivercachewrapper path:** the mega-simulation umbrella chart
passes extraCmdArgs verbatim to Kit, so the override file must use
single-level drivercachewrapper paths (`--/drivercachewrapper/...`).
Doubled paths silently fail — Kit ignores the unknown path with no error,
so shader caching appears to work (OVDC receives some UJITSO traffic) but
the driver shader cache is never routed through OVDC. Compare cold and warm shader cook times and correlate them with cache hits.

## Validation

After generating the script, verify:

- [ ] Script opens with `set -euo pipefail`
- [ ] Required variables have `: "${VAR:?message}"` checks
- [ ] NGC secret is reused if present; otherwise creation requires an exported `NGC_API_KEY` and does not print its contents
- [ ] Namespace and NGC secret creation are idempotent
- [ ] GKE c4/g2/g4 storage selection asks about local ephemeral SSD when present; otherwise uses tuned `hyperdisk-balanced` (`9600` IOPS / `2400Mi`)
- [ ] EKS/on-prem use an existing site-selected StorageClass and reviewed placement; do not create a cloud class for on-prem.
- [ ] AKS default profile creates/reuses the bundled Premium SSD v2 class; verify region/zone support and node disk performance limits
- [ ] `helm upgrade --install` is invoked with `-f` pointing at the matching reference values file (GKE PVC/ephemeral, AKS, EKS or on-prem); ConfigMap, StatefulSet, and Service are NOT hand-rolled
- [ ] Sizing uses `presets.cpu` / `presets.ram`; pod requests leave memory headroom. Advanced engine overrides explicitly unset the corresponding preset when necessary.
- [ ] PodMonitoring uses integer port `3051` (chart's metrics port; named ports can silently fail with GMP) and selector `ovdc: kvnode`
- [ ] Helm values include `gxcache.enabled: false` and `gxcache.autoinject: false` (gxcache competes with drivercachewrapper)
- [ ] Helm values use single-level `drivercachewrapper/` paths
- [ ] Helm values include `grpcDnsName` and `grpcUseTLS=false` in `extraCmdArgs`; when `TENANT_ID` is set, append `--/UJITSO/datastore/GRPCDataStore/tenantID=<value>`
- [ ] Kit test pod (if enabled) has `securityContext.runAsUser: 0` and `OMNI_KIT_ALLOW_ROOT=1`
- [ ] Kit test pod includes the `ldconfig` fix for `/usr/local/nvidia/lib64`
- [ ] Kit test uses warmup-mode `kit/kit` invocation with `warmupMode=1` and `fastShutdown=1` (preferred over `isaac-sim.sh`)
- [ ] Kit test uses `--no-window` and `--/app/quitAfter=300`
- [ ] Kit test uses single-level `drivercachewrapper/` paths
- [ ] Kit test includes `tenantID` flag when `TENANT_ID` is set
- [ ] No secrets are hardcoded
- [ ] Teardown mode is implemented

## Post-deployment verification and troubleshooting

Once OVDC is deployed and write-render-worker is configured, validate the pipeline using the four checks in `references/test-and-verify.md` (WRW args, shader cook time, OVDC metrics, gxcache disabled). The same file holds the symptom → cause → fix matrix for the common failure modes (path doubling, gxcache contention, missing drivercachewrapper args) and the validation guidance. Historical DDCS benchmarks remain in the legacy skill.

## References

| Description | URL |
|---|---|
| GKE GPU node pools | https://cloud.google.com/kubernetes-engine/docs/how-to/gpus |
| Omniverse Derived Cache documentation | https://docs.omniverse.nvidia.com/ovcaches/ovderivedcache/latest/index.html |
