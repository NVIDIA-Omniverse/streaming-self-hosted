---
name: caches-ovcontentcache-deploy
description: Deploy NVIDIA Omniverse Content Cache (OVCC) alongside a MEGA simulation stack. Covers evaluation, sizing (NGINX queue-depth model), configuration for GCS/S3/Azure backends, Helm install from NGC (chart ovcontentcache v4.0.4), TLS setup, in-place upgrade from UCC 3.0.3, and wiring to write-render-worker and storage-service. MEGA does not use Nucleus; always disable it. Use when deploying OVCC for MEGA — whether exploring fit, sizing replicas, or ready to install.
---

# OVCC Deployment Advisor

**Naming.** The product is Omniverse Content Cache. This directory is named
`caches-ovcontentcache-deploy`, but everything you generate uses `ovcc`:

| Layer | Use |
|---|---|
| Helm release name | `ovcc` (`helm install ovcc ...`) |
| Namespace | `ovcc` |
| TLS secret | `ovcc-tls` |
| Generated script | `ovcc-deploy.sh` |
| Reference files | `references/ovcc-*.yaml` |
| Env vars | `OVCC_NAMESPACE`, `OVCC_CHART_VERSION`, `OVCC_IMAGE_REPOSITORY` |
| **NGC chart path** | `ovcontentcache` (catalog name — this is the only place `ovcontentcache` appears in commands) |
| **Container image repo** | `usd-content-cache` (unchanged — 4.0.x is a chart rename only) |

Do NOT rename the Helm release, namespace, or image to `ovcontentcache`. The
chart `ovcontentcache` renders Kubernetes names under `nameOverride` (default
`ovcc`); installing with release `ovcc` collapses `<release>-<name>` to `ovcc`,
giving endpoint `ovcc.ovcc.svc.cluster.local:14128`.

**Pin chart version `v4.0.4`.** The `ovcontentcache` chart name does not exist
before `v4.0.3` (earlier tags are `ovcc`/`ov-cc`); `v4.0.4` is the first stable
post-rename chart. The runtime container is pinned by the chart `appVersion`
(`3.0.1`) — do NOT set `image.tag`.

**Storage-service must be wired for OVCC before this skill is considered
complete.** OVCC only works when storage-service returns presigned URL redirects
and sends upstream requests through the OVCC proxy. This skill does not create a
separate storage-service values file. Instead, verify that the simulation Helm
values artifact used for every install and upgrade contains these
storage-service env vars (the env var **names** are part of the storage-service
contract and are unchanged from UCC; only the URL value points at `ovcc`):

| Env var | Required value |
|---|---|
| `STORAGE_SERVICE_S3__READ_REDIRECT_SIZE` | `"0"` |
| `UCC_PROXY` | `https://ovcc.<OVCC_NAMESPACE>.svc.cluster.local:14128` |
| `UCC_PROXY_SSL_VERIFYCERT` | `"false"` |
| `UCC_PROXY_SSL_VERIFYHOST` | `"false"` |

If any value is missing, stop and add it to the simulation values artifact
before deploying OVCC. Do not keep these keys in a one-off values layer that may
be omitted from later `helm upgrade` commands.

**OVCC uses a different NGC org from MEGA.** The OVCC Helm chart and
container image are in the same NGC org as the SRTX charts, not the
MEGA org. The pull secret needs an NGC API key with access to that org.

- **Standalone OVCC** (no MEGA): `NGC_API_KEY` works — it typically has
  access to the OVCC charts and images.
- **OVCC alongside MEGA**: MEGA environments use separate keys for
  MEGA and SRTX charts (`NGC_MEGA_API_KEY` and `NGC_SRTX_API_KEY`).
  `NGC_SRTX_API_KEY` also grants access to OVCC charts and images, so
  use it. `NGC_MEGA_API_KEY` does not have access and will fail with
  `403 Forbidden` / `ImagePullBackOff`. `NGC_API_KEY` may also be set
  to the MEGA-scoped key in these environments — verify it has access
  before using it.

**Image org must match the Helm repo org; the image repo stays
`usd-content-cache`.** OVCC 4.0.x is a chart rename only — the runtime image is
still `usd-content-cache:3.0.1`. The container image lives in the same NGC org
as the Helm chart. When using the staging repo (`storage-caches-stg`), the image
is at `nvcr.io/<staging-org>/storage-caches-stg/usd-content-cache`; when using
the production repo (`nvidia/omniverse`), it is at
`nvcr.io/nvidia/omniverse/usd-content-cache`. Resolve `OVCC_IMAGE_REPOSITORY`
from `CACHES_HELM_REPO` during the conversation phase and inject the literal into
the generated script — do not hardcode the image org and do not parse the repo
URL at runtime. Note the chart **path** is `ovcontentcache` but the image
**repository** is `usd-content-cache`; they differ on purpose.

You are an OVCC deployment advisor. When a user mentions OVCC (Omniverse Content Cache), guide them through evaluation and deployment rather than waiting for a complete set of inputs. Ask questions, interpret answers using the reference data below, and generate a deployment script only when you have enough context.

The cluster should already exist with the node pools, labels, taints, and StorageClasses referenced by this skill. All performance data comes from testing with the kion_warehouse scene (1,659 USD files, 3.1 GB, HTTP/2) and is carried forward from UCC 3.0 — the OVCC 4.0.x runtime is byte-identical (`usd-content-cache:3.0.1`), so the sizing model is unchanged. Consult `references/cloud-knowledge.md` for cloud-specific operational details.

## Reference Files

Long-form details live in `references/`:

| File | Contents |
|---|---|
| `references/sizing-detail.md` | Decision tree, tested configurations tables, key observations |
| `references/cloud-knowledge.md` | GKE, EKS, AKS operational facts + cross-cloud quick reference |
| `references/script-template.md` | Full `ovcc-deploy.sh` script template (preflight → teardown) |
| `references/troubleshooting.md` | Symptom → root cause → fix patterns |
| `references/client-integration.md` | OmniClient TLS requirements, storage-service wiring, prewarming |
| `references/upgrade-from-ucc.md` | In-place upgrade from UCC 3.0.3 (`compat.useUccDefaults`) |
| `references/ovcc-gcp-g4-s3-values.yaml` | S3-only on GKE GPU nodes |
| `references/ovcc-gcp-g4-s3-gcs-values.yaml` | S3+GCS on GKE GPU nodes |
| `references/ovcc-overrides.yaml` | Simulation overrides (OVCC proxy wiring for mega-core and WRW) |
| `references/dashboards/ovcc-gcloud-dashboard.json` | GKE Cloud Monitoring dashboard |

## Conversation Flow

Follow these phases in order. Skip phases the user has already answered. Adapt your wording naturally — these are not scripts to read verbatim.

### Phase 1 — Understand the workload

Ask:

1. **Storage backend(s):** What object storage do your simulation workers read from? (GCS, S3, Azure Blob)
2. **Worker count:** How many concurrent simulation workers will hit OVCC simultaneously?
3. **Greenfield or upgrade:** Is this a fresh install, or an upgrade from an existing UCC 3.0.3 (`usd-content-cache`) release? If upgrade, read `references/upgrade-from-ucc.md` first.

If deploying for MEGA, do not ask about Nucleus. MEGA does not use
Nucleus; always disable it. For other workloads, Nucleus may be
relevant; ask only if the user is not deploying MEGA.

Do NOT ask the user what machine type to run OVCC on. Instead, inspect
the cluster's node pools (`gcloud container node-pools list` or
`kubectl get nodes`) and pick the pool with the highest network
bandwidth. OVCC's cache load happens during scene open, before GPU
rendering starts, so it does not compete with GPU workloads. If the
GPU pool has significantly more bandwidth than the CPU pool, place OVCC
there with a GPU taint toleration. Use the reference values files in
`references/` (e.g. `ovcc-gcp-g4-s3-values.yaml`) which already have
`nodeSelector`, `tolerations`, and `affinity` configured for this.

If the user doesn't know worker count yet, proceed with backend selection and come back to sizing later.

### Phase 2 — Advise on fit

Use the decision tree in `references/sizing-detail.md` to determine whether OVCC will help. Be direct:

- **GCS (any hardware):** OVCC is recommended. Even for same-cloud GCS, OVCC prevents upstream throttling at scale and provides local-disk-speed cache hits for repeat access.
- **GCS on C4, 1–150 workers:** OVCC persistent is 8–46% faster depending on configuration. Recommend deploying with the sizing formula.
- **GCS on C4, 200+ workers:** Single-replica OVCC loses to direct GCS. Multi-replica on smaller machines may help but is untested beyond 100 workers. Advise caution.
- **S3 (AWS → S3):** OVCC is needed unless the user is using CloudFront as a CDN in front of S3. If CloudFront is in play, evaluate whether OVCC still adds value (caching layer vs. CDN edge). If not using CloudFront, recommend deploying OVCC.
- **Azure Blob:** OVCC is needed. Azure Blob requires OVCC for caching and protocol normalization. Recommend deploying.
- **Nucleus:** OVCC is the standard caching layer for Nucleus content. Recommend deploying.

### Phase 3 — Configure backends

Based on the user's answers, determine which backends to enable. Communicate what you're configuring and why:

- OVCC is a pass-through proxy. Clients send their own credentials (presigned URLs for S3/GCS, SAS tokens for Azure, JWTs for Nucleus). OVCC does not store storage credentials.
- At chart v4.0.4 the `azure`, `s3`, `gcs`, and `nucleus` backends are all enabled (`include: true`) by default. Explicitly disable every backend you are not using to avoid an unused listener and to avoid the OpenResty startup failure `"proxy_cache" zone "<name>" is unknown` (a cache zone is declared but its backend/volume is absent). The reference values files already disable the unused backends for their permutation.
- Each enabled backend gets its own PVC for cache isolation. It can be
  configured to use a single PVC.

For non-TLS deployments (common on AWS BYOC where Sensor RTX does not support TLS to OVCC yet), add `proxyPass` and `proxyAuthPass` overrides for S3 and Azure backends so OVCC still uses HTTPS upstream. See `references/cloud-knowledge.md` (AWS/EKS section).

Select the Helm flags from the Backend Configuration Reference section below.

### Phase 4 — Size the deployment

Ask for the concurrent worker count if you don't have it yet. Then compute:

```text
queue_depth = (workers × 20) / (REPLICA_COUNT × vCPUs_of_machine_type)
```

Target `queue_depth ≤ 14`. Walk the user through the math:
- State the machine type's vCPU count.
- Show what queue depth looks like at 1, 2, 3 replicas.
- Recommend the replica count that brings queue depth to ~14 or below.
- Warn if over-provisioning: at 100 workers on c4-highcpu-48, R=4 showed 3,415 cache misses from fragmentation across replicas vs R=3 with near-zero misses.

Refer to `references/sizing-detail.md` for the tested-configurations tables that back this formula. The data was collected on UCC 3.0 and applies unchanged to OVCC 4.0.x (same runtime).

### Phase 5 — Generate the script

Collect remaining inputs:
- Cluster name and zone
- `GCP_PROJECT_ID` (GKE only — the cluster's project; read from the GKE kubectl context `gke_<project>_<zone>_<cluster>` or `gcloud config get-value project`, then inject as a literal)
- `NGC_API_KEY` (from environment — must have access to OVCC charts; in MEGA environments use `NGC_SRTX_API_KEY`, NOT `NGC_MEGA_API_KEY`)
- `CACHES_HELM_REPO` and `CACHES_HELM_REPO_NAME` (from `helm repo list` or AGENTS.md defaults)
- `OVCC_IMAGE_REPOSITORY` (resolve at generation time: strip `https://helm.ngc.nvidia.com/` from `CACHES_HELM_REPO`, append `/usd-content-cache` — NOT `/ovcontentcache`)
- `OVCC_CHART_VERSION` (default `4.0.4`)
- `GCS_HMAC_ACCESS_KEY_ID` and `GCS_HMAC_SECRET_ACCESS_KEY` (if GCS backend; provision HMAC keys from your GCS project)

**Use the reference values files** in `references/` as the base for the
Helm install. These contain tested configurations for node placement,
tolerations, anti-affinity, backend toggles, PVC sizing, and monitoring:

- `references/ovcc-gcp-g4-s3-values.yaml` — S3-only on GKE GPU nodes
- `references/ovcc-gcp-g4-s3-gcs-values.yaml` — S3+GCS on GKE GPU nodes
- `references/ovcc-overrides.yaml` — simulation overrides (OVCC proxy wiring for mega-core and WRW)

Pass the appropriate values file with `-f` in the Helm command instead
of assembling `--set` flags manually. Only use `--set` for values that
differ from the reference (e.g. `replicaCount`, `persistence.storageClassName`,
`image.registry`, `image.repository`). **The reference values files do not
set `image.repository`** — you must always pass it via `--set` using the
`OVCC_IMAGE_REPOSITORY` literal you resolved from `CACHES_HELM_REPO` at
generation time. Without this override, the chart defaults to the
production image path, which will 404 when installing from the staging
chart.

Generate `ovcc-deploy.sh` using the full script template in `references/script-template.md`. The script goes in `generated/` for human review — do NOT execute it.

## New in chart v4.x (knobs to be aware of)

The OVCC 4.x chart adds knobs not present in UCC 3.0.3. Defaults are fine for
MEGA; surface them only when relevant:

- **`persistence.mode`** — `pvc` (default, durable) vs `ephemeral` (emptyDir;
  cache is lost on pod or node recreate). Switching modes in place is blocked by
  the chart as an intentional migration; pick one at install time.
- **`compat.useUccDefaults` / `compat.emitLegacyCacheReset`** — UCC→OVCC
  migration knobs. Covered in `references/upgrade-from-ucc.md`. Not needed for a
  fresh install.
- **`nginx.sslVerifyDepth`** and a `passthrough` pseudo-backend exist in the
  chart; the chart defaults are correct for MEGA. Mention, do not tune.

The OVCC runtime cache-reset path is `/__/cache/reset` with a `CC-Instance`
response header (the legacy `/__ucc/cache/reset` + `UCC-Instance` are
dual-emitted while `compat.emitLegacyCacheReset=true`). The default metrics
prefix is `cc_`.

## Sizing

**Bottleneck:** NGINX connection queue depth. Each OVCC pod runs one NGINX worker process per CPU core. Each worker handles HTTP/2 streams sequentially. Performance degrades when queue depth (concurrent streams per NGINX worker) exceeds approximately 14.

**Formula:**

```text
nginx_workers_per_replica = vCPUs of OVCC machine type
total_concurrent_streams  = workers × concurrent_files_per_worker
queue_depth               = total_concurrent_streams / (REPLICA_COUNT × nginx_workers_per_replica)
```

Target: `queue_depth ≤ 14` for optimal throughput. Tested with `concurrent_files_per_worker = 20`.

**Example:** 100 workers on c4-highcpu-48 → `(100 × 20) / (R × 48)`. At R=2: queue depth 21 (borderline). At R=3: queue depth 14 (optimal). At R=4: queue depth 10 (over-provisioned, 3,415 misses due to cache fragmentation across replicas).

These are the chart values that affect per-replica sizing. The chart's
defaults and the reference values in `references/` are both starting
points, not authoritative — defaults can change between chart versions,
and the references are tested values for one particular cluster shape.
Inspect the actual numbers for the chart version being deployed before
recommending overrides.

| Knob | Values path |
|---|---|
| Replicas | `replicaCount` |
| Cache PVC size (per backend) | `persistence.volumes[*].sizeGi` |
| Cache eviction headroom | `persistence.volumes[*].minFreeSizePercentage` |
| Cache zone metadata memory | `nginx.proxyCache.paths[*].metadataMemorySize` |
| Storage class | `persistence.storageClassName` |

The chart default `sizeGi: 2048` (2 TiB per backend) is the safe choice
on `hyperdisk-balanced` because baseline IOPS/throughput on that disk
type scales with size. **If the user shrinks `sizeGi` (rare unless they
ask), tune the StorageClass first** with
`provisioned-iops-on-create=9600` and `provisioned-throughput-on-create=2400Mi`
(see `references/cloud-knowledge.md` > Cross-Cloud Quick Reference). Don't quietly cut the PVC size on a
default `hyperdisk-balanced` — IOPS will collapse with it.

See `references/sizing-detail.md` for the full decision tree, per-machine-type tested configurations, key observations, and untested ranges.

## Backend Configuration Reference

OVCC routes requests by Host header: cloud backends (S3, Azure, GCS) share
port 14128, Nucleus uses port 14129. Each backend is toggled via
`nginx.backends.<name>.include`.

The reference values files in `references/` already encode each tested
backend permutation, including the `nginx.backends.*.include` toggles,
the matching `persistence.volumes[]`, and `nginx.proxyCache.paths[]`:

- `references/ovcc-gcp-g4-s3-values.yaml` — S3 only
- `references/ovcc-gcp-g4-s3-gcs-values.yaml` — S3 + GCS

For a combination not covered (Azure-only, multi-backend with Nucleus,
etc.), copy the closest reference into `references/`, adjust the four
backend lists in the new file, and pass it with `helm install -f`. Do
not assemble the same values inline as `--set` flags in the script.

Per-backend semantics the reference files do not capture:

- **GCS** uses HMAC keys (S3-compatible XML API). The script must create a `gcs-hmac-credentials` secret from `GCS_HMAC_ACCESS_KEY_ID` and `GCS_HMAC_SECRET_ACCESS_KEY` environment variables. Provision those HMAC keys from the GCS project that stores the simulation assets. GCS is enabled by default at chart v4.0.4 — disable it explicitly when unused.
- **S3** uses presigned URLs. Clients include `X-Amz-*` query parameters. No OVCC-side credentials secret needed.
- **Azure Blob** uses SAS tokens. Clients include `sv`, `sp`, `sr`, `se`, `sig` query parameters. No OVCC-side credentials secret needed.
- **Nucleus** runs on port 14129 and can coexist with any cloud backend. Add it as another entry in `persistence.volumes[]` and `nginx.proxyCache.paths[]`. **MEGA does not use Nucleus** — always set `nginx.backends.nucleus.include: false`. For non-MEGA deployments only: set `nginx.backends.nucleus.bridgeResolver` when using Unbound DNS (e.g. `unbound-dns-addon.ovcc-unbound.svc.cluster.local:53`); HTTP/2 is not supported on the Nucleus port; optional JWT via `Omni-Tenant-Token` header is forwarded but not validated.
- **Multi-backend:** each backend gets its own PVC and cache zone. Cache is isolated per backend.

## Inputs

Gather these during the conversation. Do not present this as a form to the user.

| Variable | When needed | Source |
|---|---|---|
| `CLOUD_PROVIDER` | Always | Ask the user (`gke`, `eks`, or `aks`). Drives StorageClass selection and monitoring config |
| `CLUSTER_NAME` | Always | Ask the user |
| `ZONE` | Always (GKE: zone, EKS: region, AKS: location) | Ask the user |
| `STORAGE_CLASS` | When overriding the values file's pinned class | Cluster-specific name passed via `--set persistence.storageClassName`. The g4 reference values pin `hyperdisk-extreme`; only set `STORAGE_CLASS` when you need to override (e.g., n2 cluster, EKS, AKS) — pick per cloud + machine family from `references/cloud-knowledge.md` > Cross-Cloud Quick Reference > Storage class per cloud. |
| `NGC_API_KEY` | Always | Environment variable with access to OVCC charts and images. Must be `export`ed for Python subprocesses. In MEGA environments use `NGC_SRTX_API_KEY` (covers OVCC). Do NOT use `NGC_MEGA_API_KEY` (different org, no access to OVCC). |
| `CACHES_HELM_REPO` | Always | NGC Helm repo URL for cache charts. Staging: `https://helm.ngc.nvidia.com/<org>/storage-caches-stg`. Production: `https://helm.ngc.nvidia.com/nvidia/omniverse`. From `helm repo list` or AGENTS.md defaults. |
| `CACHES_HELM_REPO_NAME` | Always | Local Helm repo alias (e.g. `storage-caches-stg` or `nvidia-omniverse`). From `helm repo list`. |
| `OVCC_CHART_VERSION` | Always (default: `4.0.4`) | Chart `ovcontentcache` version. Do NOT pin below `4.0.3` — the `ovcontentcache` chart name does not exist before then. |
| `OVCC_IMAGE_REGISTRY` | Always (default: `nvcr.io`) | Registry hostname only. Do NOT include org path. |
| `OVCC_IMAGE_REPOSITORY` | Always (resolved at generation time from `CACHES_HELM_REPO`) | **Resolved by the agent, not by the script.** Strip `https://helm.ngc.nvidia.com/` from `CACHES_HELM_REPO`, append `/usd-content-cache` (the image repo is unchanged by the rename), and inject the literal into the script. E.g. staging → `<org>/storage-caches-stg/usd-content-cache`, production → `nvidia/omniverse/usd-content-cache`. |
| `REPLICA_COUNT` | Always | Computed in Phase 4 |
| `GCS_HMAC_ACCESS_KEY_ID` | GCS backend | Environment variable |
| `GCS_HMAC_SECRET_ACCESS_KEY` | GCS backend | Environment variable |
| `OVCC_NAMESPACE` | Always (default: `ovcc`) | Ask or default. Use a separate namespace from mega to protect cache PVCs from simulation lifecycle operations. |
| `PVC_SIZE_GI` | Always | Use the chart/reference values default unless the user provides a cache capacity requirement. Do not shrink PVCs below the backend reference size for disk types whose throughput scales with size. With tuned Hyperdisk Balanced (`9600` IOPS, `2400Mi` throughput), size can be driven by cache capacity needs (for example `375Gi`) rather than inflated to 2TiB just to unlock throughput. |
| `OVCC_VALUES_FILE` | Always | Path to the reference values file passed via `helm install -f`. Pick the file in `references/` matching the cloud + node-pool + backend combination (e.g. `references/ovcc-gcp-g4-s3-values.yaml`). If no reference matches, copy the closest one and edit it for the new combination rather than expanding `--set` flags in the script. |

## Steps

Generate the deployment script following the full template in `references/script-template.md`. The script must:

1. **Preflight** — validate `CLUSTER_NAME`, `ZONE`, `NGC_API_KEY`, `GCP_PROJECT_ID` (GKE), `CACHES_HELM_REPO`, `CACHES_HELM_REPO_NAME`, and `OVCC_IMAGE_REPOSITORY` (all resolved by the agent and injected as literals); export `NGC_API_KEY`; check HMAC vars only when GCS is enabled; verify `kubectl cluster-info`.
2. **StorageClass check** — only override the values file's pinned class when `STORAGE_CLASS` is set; verify the class exists.
3. **Namespace + secrets** — create namespace; create `ngc-secret` via a Python heredoc (no `$` reaches the shell); create self-signed `ovcc-tls`; create `gcs-hmac-credentials` only when GCS is enabled.
4. **Helm install** — install chart `${CACHES_HELM_REPO_NAME}/ovcontentcache` with `--version ${OVCC_CHART_VERSION}`; pass `-f "${OVCC_VALUES_FILE}"`; reserve `--set` for `replicaCount`, `image.registry`, `image.repository`, `image.tag`, `image.pullSecrets[0].name`, `tls.secretName`, and optional `persistence.storageClassName`. Do not set `image.tag` (chart `appVersion` pins it).
5. **Validation** — pod status, PVC status, log tail per replica, port-forward healthz + cache_metrics. The container is distroless; no `kubectl exec`.
6. **Scale (`--scale N`)** — `helm upgrade --reuse-values` with new `replicaCount`.
7. **Teardown (`--teardown`)** — uninstall release; delete secrets; delete PVCs; delete namespace.

Use the exact code blocks in `references/script-template.md`; do not paraphrase or omit safety checks.

## Validation

After generating the script, verify:

- [ ] Chart path is `ovcontentcache` and `--version` is `4.0.4` (or a later `4.0.x`/`4.x`); image repository resolves to `usd-content-cache`, not `ovcontentcache`
- [ ] If `STORAGE_CLASS` is set (override of the values file's pinned class), it matches the row for the target cloud + machine family in `references/cloud-knowledge.md` > Cross-Cloud Quick Reference > Storage class per cloud and is verified to exist before install
- [ ] `image.repository` is set via `--set` from the agent-resolved `OVCC_IMAGE_REPOSITORY` literal — chart default points to production; staging images will 404 without this override
- [ ] `image.tag` is NOT set (the chart `appVersion` pins the runtime)
- [ ] Only selected backends have `include=true`; others `include=false` (including `gcs`, which defaults on); Nucleus explicitly disabled if unused
- [ ] Each enabled backend has its own cache volume (`persistence.volumes[]`) and cache path (`nginx.proxyCache.paths[]`); volume indices sequential
- [ ] NGC pull secret uses literal `$oauthtoken` as username
- [ ] `--teardown` deletes release → secrets → PVCs → namespace in order

## Upgrade From UCC

When the user is upgrading an existing UCC 3.0.3 (`usd-content-cache`) install
rather than deploying greenfield, consult `references/upgrade-from-ucc.md`. A
stock UCC install must be upgraded with `--set compat.useUccDefaults=true` or the
chart blocks the upgrade at render time. Fresh installs use the OVCC defaults and
do not need compatibility mode.

## Cloud Knowledge Base

Cloud-specific operational details (StorageClass requirements, quota gotchas, monitoring shape, networking caveats, production baselines) live in `references/cloud-knowledge.md`. Consult it when:

- The user names a cloud (GKE, EKS, AKS) — apply the override table for that cloud.
- The user mentions a machine family (c4, n2, g4) — check disk compatibility before recommending PVC size.
- You need to advise on quota, SNAT, DNS TTL, Azure 504 patterns, or cross-AZ pitfalls.

## Troubleshooting

When the user describes a problem, consult `references/troubleshooting.md` for symptom → root cause → fix patterns covering metadata cache undersizing, disk bandwidth, connection saturation, upstream S3 spikes, and network bandwidth saturation.

## Client Integration

OmniClient TLS requirements (mandatory for OmniClient < v2.68.1 / Kit < 109.0.1-249766), GCS `proxyPass` override, storage-service and worldsim/WRW environment variables, cache prewarming for large scenes, and scene reference sizes are documented in `references/client-integration.md`. Consult it whenever wiring OVCC into a MEGA simulation stack.

## Testing with curl

OVCC is a reverse proxy. Test it by calling its endpoint directly and overriding
the `Host` header to the upstream; for the self-signed cert add `-k` (or
`--cacert ovcc.crt`):

```bash
curl -k -H 'Host: storage.googleapis.com' \
  'https://ovcc.ovcc.svc.cluster.local:14128/<bucket>/<object>?<presigned-query>'
```

Do **not** pass curl proxy flags (`-x` / `--proxy`) or rely on
`HTTPS_PROXY` / `ALL_PROXY` env — that uses OVCC as a forward proxy, which it
rejects with HTTP `400` (`curl: (56) CONNECT tunnel failed, response 400`) and
caches nothing. See `references/troubleshooting.md`.

## References

| Description | URL |
|---|---|
| GCS HMAC Keys | https://cloud.google.com/storage/docs/authentication/hmackeys |
| GKE PodMonitoring | https://cloud.google.com/stackdriver/docs/managed-prometheus/setup-managed#gmp-pod-monitoring |
| GKE Cloud Monitoring dashboard (OVCC) | `references/dashboards/ovcc-gcloud-dashboard.json` — import via `gcloud monitoring dashboards create --config-from-file` |
