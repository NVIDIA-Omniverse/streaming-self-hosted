
# OVCC Sizing — Decision Tree and Tested Configurations

Long-form sizing data used by the `caches-ovcontentcache-deploy` skill. SKILL.md keeps the queue-depth formula inline; this file contains the decision tree and the empirical tables behind it.

All data was collected on the UCC 3.0 runtime and applies unchanged to OVCC 4.0.x: the OVCC 4.0.x release is a chart rename only and ships the identical container image (`usd-content-cache:3.0.1`), so the data plane and its performance characteristics are the same.

## Decision Tree

Reference data for Phase 2 of the conversation flow. Use this to advise the user — do not present the raw tree.

```text
1. What is your storage backend?
   ├─ S3 or Azure Blob
   │    → OVCC provides caching + protocol normalization.
   │      Deploy OVCC. Sizing: use the queue depth formula.
   │
   └─ GCS
        │
        2. What machine type family will run OVCC?
           ├─ N2
           │    → OVCC is unlikely to help. At 100 workers on n2-standard-16:
           │      • 2 replicas (queue depth 63): 7% slower than direct GCS
           │      • 4 replicas (queue depth 31): 17% faster, but requires
           │        4 extra N2 nodes
           │      GCS scales nearly linearly on its own on N2 hardware.
           │
           └─ C4
                │
                3. How many concurrent simulation workers?
                   ├─ 1–150 workers
                   │    → OVCC persistent is 8–16% faster than direct GCS
                   │      on a single c4-highcpu-288 node.
                   │      With multi-replica c4-highcpu-48 at 100 workers:
                   │      ~46% faster with 3 replicas vs direct GCS.
                   │      Deploy OVCC. Sizing: use the queue depth formula.
                   │
                   └─ 200+ workers
                        → Single-replica OVCC is ~10–15% slower than direct GCS
                          at 200 workers on c4-highcpu-288 due to per-pod
                          networking limits. Multi-replica c4-highcpu-48 has not
                          been tested beyond 100 workers.
                          Evaluate with caution. If deploying, use multi-replica
                          on smaller machines (c4-highcpu-48) rather than a
                          single large node.
```

**Caveats:**

- All GCS data was collected with `concurrent_files_per_worker = 20` (simulating USD scene loads via HTTP/2 multiplexed streams). Workloads with different concurrency patterns may see different results.
- Test scene: kion_warehouse (1,659 USD files, 3.1 GB total). Larger or smaller scenes were not tested.
- The tree covers warm-cache (persistent) performance. Cold-cache (ephemeral) OVCC showed no consistent advantage over direct GCS at any worker count.

## Tested Configurations

All data: persistent cache model, kion_warehouse scene, GCS backend via HMAC, HTTP/2.

**c4-highcpu-48** (48 NGINX workers/replica):

| Workers | Replicas | Queue depth | Time (s) | p50 Mbps | vs Direct GCS |
|---|---|---|---|---|---|
| 50 | 1 | 21 | 53.8 | 65.6 | +6% faster |
| 100 | 2 | 21 | 60.9 | 73.2 | +3% faster (1,782 misses) |
| 100 | 3 | 14 | 42.9 | 84.0 | +46% faster |
| 100 | 4 | 10 | 51.4 | 79.7 | +36% faster (3,415 misses) |

**c4-highcpu-288** (288 NGINX workers, single replica):

| Workers | Queue depth | Persistent (s) | Direct (s) | OVCC advantage |
|---|---|---|---|---|
| 50 | 3 | 50.2 | 57.2 | +14% faster |
| 100 | 7 | 54.6 | 59.4 | +8% faster |
| 150 | 10 | 52.1 | 60.4 | +16% faster |
| 200 | 14 | 72.9 | 62.7 | −14% slower |

**c4-highmem-144** (144 NGINX workers, single replica):

| Workers | Queue depth | Time (s) | vs Direct |
|---|---|---|---|
| 100 | 14 | 52.5 | +34% faster |
| 150 | 21 | 51.7 | +14% faster |
| 200 | 28 | 63.6 | comparable |

**n2-standard-16** (16 NGINX workers/replica):

| Workers | Replicas | Queue depth | Time (s) | vs Direct |
|---|---|---|---|---|
| 100 | 2 (1:50) | 63 | 83.4 | −7% slower |
| 100 | 4 (1:25) | 31 | 66.2 | +17% faster |

## Key Observations

Stated as facts from the test data, not recommendations:

- Multi-replica on smaller machines (3× c4-highcpu-48 = 144 NGINX workers) outperformed single large machines (1× c4-highcpu-288 = 288 NGINX workers) by ~20% at 100 workers despite fewer total NGINX workers. Root cause: single-pod networking contention.
- On c4-highcpu-288, OVCC is ~14% slower than direct GCS at 200 workers despite queue depth of only 14, confirming a per-pod networking ceiling independent of queue depth.
- On n2-standard-16 with GCS backend, OVCC at 2 replicas (1:50 ratio) is 7% slower than direct GCS at 100 workers. 4 replicas (1:25 ratio) is 17% faster but requires 4 additional N2 nodes.
- GCS scales nearly linearly on its own (Google Cloud Storage uses Spanner for metadata and Colossus for data). OVCC's value on GCS increases with C4 hardware and decreases on N2.
- For non-GCS backends (S3, Azure Blob), OVCC provides protocol translation and caching regardless of machine type.

## Not Tested

Multi-replica c4-highcpu-48 beyond 100 workers; c4-highcpu-96 or c4-standard machines; worker counts above 200; scenes larger than kion_warehouse (3.1 GB); concurrent_files_per_worker values other than 20.
