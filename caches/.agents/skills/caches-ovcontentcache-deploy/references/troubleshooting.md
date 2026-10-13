
# OVCC Troubleshooting

Distilled from operational runbooks. Each pattern is symptom → root cause → fix. Use during conversation when the user describes a problem. This skill uses chart 4.0.4 with `usd-content-cache:3.0.2`. These patterns originated with UCC; confirm the symptoms and deployed image before applying them.

## Metadata cache undersizing

**Symptom:** High cache MISS rate (>30%) on warm cache. Same files returning MISS repeatedly despite being on disk.

**Root cause:** NGINX `keys_zone` (metadata cache) is too small. When exceeded, NGINX silently evicts oldest metadata via LRU — no error messages logged. Clients re-fetch from upstream.

**Fix:** Increase `metadataMemorySize` under `nginx.proxyCache.paths[]` (not elsewhere — wrong YAML section is a common mistake). The reference values files set `1024m`; the chart default may differ — check it before deciding. Sizing formula:

```text
keys_zone_size = unique_urls × 250 bytes × 1.5 headroom
```

Rule of thumb: 256m ≈ 1M items, 512m ≈ 2M items, 1g ≈ 4M items. For MEGA-scale workloads, start at 512m minimum.

## Data disk bandwidth

**Symptom:** Slow cache warmup. High disk I/O wait. Cold-cache performance not improving.

**Root cause:** StorageClass provides insufficient IOPS or throughput. Common mistakes: using `gp2` on EKS (limited IOPS), `pd-standard` on GKE (slow warmup), or PVC too small (cloud disk throughput scales with size).

**Fix:** Use the recommended StorageClass per cloud (see `cloud-knowledge.md` > Cross-Cloud Quick Reference). PVC size >= 1 TiB minimum for adequate throughput. GKE pd-ssd: `0.48 MB/s × disk_size_GB` (2 TiB = 983 MB/s). EKS gp3: 2 TiB = ~1,000 MB/s burst.

## Connection saturation

**Symptom:** P99 response time spikes to 5-10s. Clients report "connection refused" or timeout. `nginx_connections_waiting` is non-zero.

**Root cause:** `worker_connections` undersized for the workload, or too few replicas / vCPUs to handle concurrent connections.

**Fix:** Size `worker_connections` using the formula: `(GPU_count × concurrency) / replicas / vCPU × 1.5`. Scale replicas to distribute connection load. Enable HTTP/2 (multiplexes requests over fewer connections). Monitor `nginx_connections_active` — alert at 80% of `worker_connections` limit.

## Upstream S3 connection spikes

**Symptom:** S3 returns 503. SNAT port utilization >70%. P99 upstream connect time spikes from <100ms to 5-10s.

**Root cause:** No connection reuse to S3 in current release. Each MISS opens a new TCP + TLS connection. At >3,000 MISS RPS, connections exhaust SNAT capacity. S3 uses DNS-based load balancing with short TTLs; high DNS cache TTL in NGINX concentrates traffic on stale endpoints.

**Fix (current release):** Reduce MISS rate — pre-warm cache before production loads, increase `metadataMemorySize`, ensure PVC is large enough to avoid eviction. Monitor NAT Gateway `ActiveConnectionCount` (AWS) or `UsedSnatPorts` (Azure). Connection pooling is planned for a future release.

## Network bandwidth saturation

**Symptom:** Slow asset downloads despite cache HIT. Network TX per pod approaching instance NIC limit.

**Root cause:** Too few OVCC replicas for the GPU fleet size. OVCC replicas are independent — aggregate bandwidth = replicas × NIC bandwidth.

**Fix:** Scale replicas until per-pod bandwidth is well below NIC capacity (<70%). Minimum 10 Gbps per OVCC node, 25+ Gbps preferred. Verify OVCC and GPU pods are in the same AZ (cross-AZ incurs latency and bandwidth penalties). Check load distribution across replicas — uneven traffic may indicate load balancer misconfiguration.

## HTTP 400 when testing through curl (forward-proxy misuse)

**Symptom:** Requests sent through OVCC return `400 Bad Request`. With curl in proxy mode the client reports `curl: (56) CONNECT tunnel failed, response 400`, and `curl -v` shows a `CONNECT <upstream>:443 HTTP/1.1` line answered by `HTTP/1.1 400 Bad Request` (`Server: openresty`). Nothing is cached.

**Root cause:** OVCC is being used as a **forward proxy** — curl was given `-x` / `--proxy`, or inherited `HTTPS_PROXY` / `https_proxy` / `ALL_PROXY` from the environment. In proxy mode curl issues an HTTP `CONNECT` to open an end-to-end TLS tunnel to the upstream. OVCC is a reverse proxy and rejects `CONNECT` with `400`, so it never sees — or caches — the real request. (This is the failure mode from the GCS/MEGA escalation.)

**Fix:** Call OVCC directly and override the `Host` header to the real upstream; drop the proxy flags and proxy env vars. For a self-signed OVCC cert use `--cacert <ovcc.crt>` (or `-k` for bootstrap):

```bash
env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY \
curl -k -H 'Host: storage.googleapis.com' \
  'https://ovcc.ovcc.svc.cluster.local:14128/<bucket>/<object>?<presigned-query>'
```

Verified against a local OVCC deploy: the reverse-proxy form returns `HTTP 200`, while the `-x` forward-proxy form fails with `curl: (56) CONNECT tunnel failed, response 400`.
