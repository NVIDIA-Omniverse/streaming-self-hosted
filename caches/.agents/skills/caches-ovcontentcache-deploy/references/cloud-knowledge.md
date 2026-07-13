
# OVCC Cloud Knowledge Base

Cloud-specific operational details for OVCC deployments. Use these sections during the conversation to inform advice. Each section contains operational facts an LLM would not know without domain context. OVCC 4.0.x ships the UCC 3.0 runtime unchanged (`usd-content-cache:3.0.1`), so all runtime/network behavior below carries forward from UCC.

## GKE

**C4 CPU quota** is region-specific and often zero by default. Before recommending C4 machines, tell the user to verify quota:

```bash
gcloud compute regions describe <REGION> \
  --format='table(quotas.metric,quotas.usage,quotas.limit)' | grep -i "C4"
```

C4 family naming: `C4_CPUS` (Intel Granite Rapids), `C4A_CPUS` (Google Axion ARM), `C4D_CPUS` (AMD EPYC Turin Zen 5). Use `highcpu` variants for OVCC (high-core, low-memory). If quota is 0, request via Cloud Console > Compute > Quotas > filter `C4 CPUs` > press Enter (autocomplete only shows "Committed" variants; standard quota appears after pressing Enter).

**StorageClass creation.** GKE only pre-installs `premium-rwo` (pd-ssd)
and `standard-rwo` (pd-balanced). OVCC on c4/g2 should use tuned
`hyperdisk-balanced` unless the user explicitly chooses a supported
ephemeral-local-SSD path. OVCC on g4 should use `hyperdisk-extreme` (see
Cross-Cloud Quick Reference). OVCC on n2 should use `pd-extreme-rwo`.
With explicit IOPS/throughput, tuned Hyperdisk Balanced can use a smaller
PVC such as `375Gi`; it does not need the chart's 2TiB default size just
to reach 2400Mi throughput.

```yaml
# Required for c4/c4a/c4d/g2 node pools when not using ephemeral local SSD
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hyperdisk-balanced
provisioner: pd.csi.storage.gke.io
parameters:
  type: hyperdisk-balanced
  provisioned-iops-on-create: "9600"
  provisioned-throughput-on-create: "2400Mi"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
```

```yaml
# Required for n2 node pools
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: pd-extreme-rwo
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-extreme
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
```

**Disk compatibility.** c4, g2, and g4 machines require Hyperdisk.
`pd-extreme` and `pd-ssd` are not supported on these families — Helm
install will succeed but PVCs will fail to attach with
`badRequest: pd-ssd disk type cannot be used by <machine-type>`.
pd-ssd throughput scales linearly: `0.48 MB/s × disk_size_GB`, capped
at 1,200 MB/s. A 2,048 GiB PVC delivers ~983 MB/s.

**GCS backend is built in.** The OVCC runtime (`usd-content-cache:3.0.1`) includes the GCS backend, and the `ovcontentcache` chart (>= 4.0.x) enables `azure`, `s3`, `gcs`, and `nucleus` by default. When deploying for GCS, no special chart version is needed beyond the `4.0.4` pin; just ensure the `gcs` backend is included (it is by default) and provide HMAC credentials.

**Monitoring.** Use `metrics.prometheus.podMonitoring.enabled=true` on GKE. The ServiceMonitor CRD does not exist on GKE — setting `serviceMonitor.enabled=true` will fail silently (no scraping). GKE Managed Prometheus runs as a DaemonSet in `gmp-system` and is enabled by default on new clusters.

**GCS NGINX gotchas:**
- `proxy_ssl_server_name: on` is required because `proxy_pass` uses a variable (`$host`). Without it: `sslv3 alert handshake failure`.
- `proxy_ignore_headers: Cache-Control Expires` is required because GCS returns `Cache-Control: private, max-age=0` on all responses, which would prevent caching.
- GCS endpoint: `https://storage.googleapis.com` only (no regional endpoints). TLS 1.3 only.

**Two-pool cluster patterns.** When the cluster has separate compute-pool (OVCC) and gpu-pool (workers):

- Scale OVCC pods to 0 **before** removing compute nodes. Otherwise the StatefulSet stays Pending indefinitely.
- `helm upgrade --wait` hangs if the compute-pool has 0 nodes — the pod stays Pending and Helm blocks until timeout. Always resize compute-pool to >= 1 node before any Helm operation.
- Keep pool node count and `replicaCount` in sync. Extra nodes run idle; missing nodes leave pods Pending.
- Only grow pools during test runs; shrink to 0 only after all tests complete. Shrinking mid-run evicts pods and destroys cache state.

**Node pool replacement.** GKE cannot change machine type in-place. You must delete the pool and create a new one. Namespaces, Secrets, Services, StatefulSets, and PVCs survive node pool replacement — they are control plane objects, not tied to nodes. The StatefulSet reschedules automatically and the PVC rebinds. No `helm uninstall`/`helm install` needed.

## AWS / EKS

**Storage class.** Use `gp3` (not `gp2`). gp3 provides 3,000 IOPS and 125 MB/s baseline regardless of size. A 2 TiB gp3 provides ~1,000 MB/s burst. Create the StorageClass if it doesn't exist:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.eks.amazonaws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
```

`WaitForFirstConsumer` is critical — EBS must be in the same AZ as the pod.

**Helm overrides for EKS.** Several defaults assume Azure and must be overridden:

| Override | Value | Why |
|---|---|---|
| release name | `ovcc` | Install with `helm install ovcc ...`; the chart default `nameOverride: ovcc` collapses `<release>-<name>` to `ovcc`, so DNS is `ovcc.ovcc.svc.cluster.local` (no `fullnameOverride` needed) |
| `service.selector` | `app.kubernetes.io/instance: ovcc` | Default Helm selectors incompatible with some EKS networking configurations |
| `persistence.storageClassName` | `gp3` | Default is Azure `managed-csi-premium-burst` |
| `tls.enabled` | `false` | **WARNING:** Only safe if ALL Kit clients use OmniClient >= v2.68.1 (Kit >= 109.0.1-249766). SRTX 1.0.1 ships Kit 107.3.4 (v2.67.0) which requires TLS. Set to `true` with self-signed cert if any client is on an older Kit. |
| `metrics.prometheus.serviceMonitor.enabled` | `true` | EKS uses ServiceMonitor (not PodMonitoring) |

**Non-TLS proxy pass.** When `tls.enabled=false` (only valid if ALL clients use Kit >= 109.0.1-249766), add backend proxy overrides so OVCC still uses HTTPS to upstream storage:

```bash
--set nginx.backends.s3.proxyPass=https://$host
--set nginx.backends.s3.proxyAuthPass=https://$host
--set nginx.backends.azure.proxyPass=https://$host
--set nginx.backends.azure.proxyAuthPass=https://$host
```

**S3 connection behavior.** The current OVCC release has no connection reuse to S3. Every cache MISS opens a new TCP + TLS connection. At high MISS rates (>3,000 RPS to S3), this causes:

- S3 503 (Service Unavailable) from request rate limits
- SNAT port exhaustion on the NAT Gateway
- P99 connect times spiking from <100ms to 5-10s

Mitigation: reduce MISS rate by pre-warming cache, increasing `metadataMemorySize`, and sizing PVCs adequately. Connection pooling is planned for a future release.

**S3 DNS TTL.** S3 uses DNS-based load balancing with 5-60s TTL. Set NGINX resolver cache `successTtlSecs` <= 52s to ensure OVCC discovers new S3 endpoints as S3 scales.

**SNAT monitoring.** Monitor NAT Gateway `ActiveConnectionCount` in CloudWatch. Alert at >70% of allocated SNAT ports. Each OVCC MISS consumes one SNAT port for the lifetime of the upstream connection.

**Network sizing.** 10 Gbps minimum per OVCC node; 25+ Gbps preferred for complex scenes. OVCC replicas operate independently — aggregate bandwidth scales linearly with replica count.

**Worker connections formula (EKS):**

```text
worker_connections = (GPU_count × client_concurrency) / replicas / vCPU × 1.5
```

Example: 66 GPUs, 256 concurrency, 5 replicas, 32 vCPUs → `(66 × 256) / 5 / 32 × 1.5 ≈ 1,600`.

**Node placement decision.** Place OVCC on the node pool with the
highest network bandwidth. OVCC's cache load happens during scene open,
before GPU rendering starts; it does not compete with GPU workloads.
If the GPU pool has significantly more bandwidth than the CPU pool
(e.g. 400 Gbps vs 32 Gbps), place OVCC there with a GPU taint
toleration. OVCC does not consume GPU resources.

**Node affinity (when a dedicated compute pool exists).** If a
compute pool with adequate bandwidth is available, prefer it:

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-type
              operator: In
              values:
                - compute
```

## Azure / AKS

**Storage class.** Use `managed-csi-premium-burst`. The chart default (`managed-csi`) is standard SSD — insufficient for production cache workloads. Premium burst uses credit-based bursting; monitor credit consumption to avoid throttling. A 2 TiB Premium SSD P40 provides 200 MB/s baseline, 900 MB/s burst.

**SNAT port exhaustion.** Azure LB uses 5-tuple hash for SNAT port allocation, which can cause uneven distribution. Set `featureFlags.useRoundRobinLoadBalancing: true` to switch to round-robin and avoid imbalance. Worker connections formula for Azure:

```text
worker_connections = (Max_SNAT / Num_Pods / Num_vCPUs) × 1.2
```

**504 timeout pattern.** Azure Blob upstream keepalive defaults to `false`. This causes a recurring 504-504-200 pattern (~60s cycle) under sustained load. Fix: set `nginx.backends.azure.enableUpstreamKeepalive: true`.

**HTTP/1.1 to Azure Blob.** NGINX to Azure Blob always uses `proxy_http_version 1.1` regardless of client protocol. This is an NGINX limitation — HTTP/2 upstream is not supported. Clients can still use HTTP/2 to OVCC (`allowHttp2Clients: true` requires `tls.enabled: true`).

**Distroless container.** The OVCC image is distroless — `kubectl exec` is not available. Debug using `kubectl logs`, ConfigMap inspection, or an external curl pod in the same namespace.

**Monitoring.** Use `metrics.prometheus.serviceMonitor.enabled=true` on AKS (same as EKS). PodMonitoring is GKE-only.

**MEGA 0.2.11 production baseline (Azure).** Reference for sizing comparisons (collected on the predecessor UCC deployment; runtime is identical to OVCC 4.0.x):

| Property | Value |
|---|---|
| Platform | AKS (`aks-ucc-az60-prd`) |
| Region | Germany West Central |
| VM type | `Standard_E32bds_v5` (30 vCPU) |
| Nodes | 5 replicas |
| Disk | Premium SSD P40, 2 TiB |
| Network | 16 Gbps per node |
| Data source | AWS S3 (cross-cloud: cache in Azure, content in AWS) |
| Warm completion | ~300s (kion_warehouse, HTTP/2) |

## Cross-Cloud Quick Reference

### Storage class per cloud

| Cloud | Recommended | Avoid | Provisioner | Critical setting |
|---|---|---|---|---|
| GKE (g4) | `hyperdisk-extreme` | `pd-ssd`, `pd-extreme`, untuned `hyperdisk-balanced` | `pd.csi.storage.gke.io` | Default for the `ovcc-gcp-g4-*-values.yaml` references per in-cluster fio benchmark; ~1.7x write throughput vs untuned hyperdisk-balanced at 128 GiB. |
| GKE (c4, g2) | tuned `hyperdisk-balanced` (`9600` IOPS / `2400Mi`) unless using supported local ephemeral SSD | `pd-ssd`, `pd-extreme` | `pd.csi.storage.gke.io` | Ask about ephemeral SSD if present; otherwise create tuned class manually |
| GKE (n2) | `pd-extreme-rwo` | `pd-standard` | `pd.csi.storage.gke.io` | Must create manually |
| EKS | `gp3` | `gp2` | `ebs.csi.eks.amazonaws.com` | `WaitForFirstConsumer` |
| AKS | `managed-csi-premium-burst` | `managed-csi` | Built-in | Monitor burst credits |

### Backend keepalive defaults

| Backend | Default | Production fix |
|---|---|---|
| S3 | `true` | Required; no connection reuse yet |
| GCS | `true` | — |
| Azure Blob | `false` | Set `enableUpstreamKeepalive: true` (fixes 504 pattern) |
| Nucleus | `false` | Unsupported; do not enable |

### Monitoring per cloud

| Cloud | Use | Avoid |
|---|---|---|
| GKE | `podMonitoring.enabled: true` | `serviceMonitor.enabled` (CRD missing) |
| EKS | `serviceMonitor.enabled: true` | `podMonitoring.enabled` (GKE-only) |
| AKS | `serviceMonitor.enabled: true` | `podMonitoring.enabled` (GKE-only) |

### Helm defaults to override per cloud

| Cloud | Overrides |
|---|---|
| GKE | `persistence.storageClassName`, `metrics.prometheus.podMonitoring.enabled=true`, `image.pullSecrets[0].name=ngc-secret`, `tls.secretName=ovcc-tls` |
| EKS | release name `ovcc` (gives `ovcc.ovcc.svc...`; no `fullnameOverride` needed), `service.selector`, `persistence.storageClassName=gp3`, `tls.enabled=false` (only if all clients are OmniClient >= v2.68.1 / Kit >= 109.0.1-249766; otherwise leave TLS enabled with a cert secret), `metrics.prometheus.serviceMonitor.enabled=true`, `nginx.backends.*.proxyPass=https://$host` |
| AKS | `persistence.storageClassName=managed-csi-premium-burst`, `featureFlags.useRoundRobinLoadBalancing=true`, `nginx.backends.azure.enableUpstreamKeepalive=true`, `metrics.prometheus.serviceMonitor.enabled=true` |
